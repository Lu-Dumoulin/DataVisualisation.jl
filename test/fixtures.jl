# ==============================================================================
# fixtures.jl — synthetic ensemble on disk + helpers to drive the app headlessly
# ==============================================================================

const Hyperscript = Bonito.Hyperscript

const NX, NY = 24, 12

# Deterministic fields so tests can check values, not just shapes.
function frame_fields(run, t; extra=false)
    rho = [Float64(i + j + t) for i in 1:NX, j in 1:NY]
    v   = cat(fill(Float64(run), NX, NY), fill(Float64(t), NX, NY); dims=3)
    Q   = cat([cos(2π*i/NX) for i in 1:NX, j in 1:NY],
              [sin(2π*j/NY) for i in 1:NX, j in 1:NY]; dims=3)
    d   = Dict{String,Any}("rho" => rho, "v" => v, "Q" => Q)
    extra && (d["p"] = fill(Float64(t), NX, NY))
    return d
end

function write_frame(path, fields)
    jldopen(path, "w") do f
        for (k, v) in fields
            f[k] = v
        end
    end
end

frame_name(t) = "t" * lpad(t, 4, '0') * ".jld"

# Ensemble layout (matches the README):
#   root/DF.csv, root/<fn>/Data/t0001.jld …
# - Re   : numeric, varies
# - mode : string, varies
# - c    : constant → must not appear in changing_variable_list
# - run_002 has only 2 frames (exercises nfile clamping)
# - run_004 has an extra key "p" (exercises the key-reload path)
const FIXTURE_DF = DataFrame(
    Re   = [10.0, 10.0, 50.0, 50.0],
    mode = ["polar", "nematic", "polar", "nematic"],
    c    = [1, 1, 1, 1],
    fn   = ["run_001", "run_002", "run_003", "run_004"],
)

function make_dataset(root=mktempdir(); nframes=3)
    CSV.write(joinpath(root, "DF.csv"), FIXTURE_DF)
    for (r, fn) in enumerate(FIXTURE_DF.fn)
        d = joinpath(root, fn, "Data")
        mkpath(d)
        nt = fn == "run_002" ? nframes - 1 : nframes
        for t in 1:nt
            write_frame(joinpath(d, frame_name(t)), frame_fields(r, t; extra = fn == "run_004"))
        end
    end
    return root
end

datadir(root, fn) = joinpath(root, fn, "Data")

# 1D ensemble, standard layout: one file per frame, fields of shape (N1,).
# u[i] = i + t (run 1) or 2(i + t) (run 2); w = t everywhere.
const N1 = 50
function make_dataset_1d(root=mktempdir(); nframes=3)
    df = DataFrame(k=[1.0, 2.0], fn=["r1", "r2"])
    CSV.write(joinpath(root, "DF.csv"), df)
    for (r, fn) in enumerate(df.fn)
        d = joinpath(root, fn, "Data")
        mkpath(d)
        for t in 1:nframes
            write_frame(joinpath(d, frame_name(t)),
                        Dict{String,Any}("u" => [r * Float64(i + t) for i in 1:N1], "w" => fill(Float64(t), N1)))
        end
    end
    return root
end

# 3D ensemble: s3[i,j,z] = z (scalar), v3[i,j,z,:] = (run, t, z) (3D vector),
# plus a 2D field. run_a has NZ_A slices, run_b has NZ_B (exercises clamping).
const NZ_A, NZ_B = 6, 4
function make_dataset_3d(root=mktempdir(); nframes=2)
    df = DataFrame(Re=[1.0, 2.0], fn=["run_a", "run_b"])
    CSV.write(joinpath(root, "DF.csv"), df)
    for (r, (fn, nz)) in enumerate(zip(df.fn, (NZ_A, NZ_B)))
        d = joinpath(root, fn, "Data")
        mkpath(d)
        for t in 1:nframes
            s3 = [Float64(z) for i in 1:NX, j in 1:NY, z in 1:nz]
            v3 = cat(fill(Float64(r), NX, NY, nz), fill(Float64(t), NX, NY, nz),
                     [Float64(z) for i in 1:NX, j in 1:NY, z in 1:nz]; dims=4)
            write_frame(joinpath(d, frame_name(t)),
                        Dict{String,Any}("s3" => s3, "v3" => v3, "rho" => fill(Float64(t), NX, NY)))
        end
    end
    return root
end


# ── Default configs, overridable per test ─────────────────────────────────────

overlay(; kw...) = DV.OverlayConfig(; merge(
    (field="None", alpha=1.0, stepp=5, arrowsize=1.0, nematic=false), values(kw))...)

test_config(; overlays=[overlay(), overlay()], kw...) = DV.PlotConfig(; merge(
    (Ndim="2D", nfile=1, cmap="viridis", heatmap="rho", overlays, fig_base=400, zslice=1,
     fields1d=["rho"], cut_axis="x", cut_pos=1, cut_mean=false, view1d="Profiles"), values(kw))...)


# ── Headless dashboard ────────────────────────────────────────────────────────
# DV.dashboard(ws, session) builds the same state + listeners as explor_app,
# without a browser. Setting a widget's `.value[]` fires the same Julia-side
# `on(session, …)` listeners a browser event would.

# Widgets and observables reachable from a DOM tree (to check the layout uses them).
function collect_widgets(dom)
    out  = Any[]
    seen = IdDict{Any,Nothing}()
    function walk(x)
        haskey(seen, x) && return
        seen[x] = nothing
        if x isa Hyperscript.Node
            foreach(walk, Hyperscript.children(x))
        elseif x isa Observable
            push!(out, x)
            walk(x[])
        elseif x isa AbstractVector
            foreach(walk, x)
        elseif x isa Union{Bonito.Button, Bonito.Slider, Bonito.Dropdown,
                           Bonito.Checkbox, Bonito.StylableSlider}
            push!(out, x)
        end
    end
    walk(dom)
    return out
end

contains_obj(objs, x) = any(o -> o === x, objs)

# Wait for @async work spawned by listeners (sleep yields to the scheduler).
# Not `timedwait`: it never returns if the predicate throws, and predicates here
# can throw while the plot is a placeholder div — that counts as "not yet".
function waitfor(cond; timeout=30.0)
    t0 = time()
    while time() - t0 < timeout
        (try cond() catch; false end) === true && return true
        sleep(0.05)
    end
    return false
end

# Text content of a DOM.div("…") (plot / status messages).
dom_text(x) = x isa Hyperscript.Node ?
    join(dom_text.(Hyperscript.children(x))) :
    x isa AbstractString ? x : ""
