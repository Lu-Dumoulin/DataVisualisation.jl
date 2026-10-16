# ==============================================================================
# Demo.jl — a generated ensemble, to try the app without simulation data
# ==============================================================================
#
# Built so that mistakes are visible: a non-square grid and an off-centre
# object (a swapped x/y or a transposed image shows), order with a known
# direction relative to the surface (a flipped sign or a 90° error shows),
# motion in time, a parameter space with a hole, runs with different fields
# and lengths, and metadata in the files.

const DEMO_SHAPES     = ["sphere", "cube"]
const DEMO_ORDERS     = ["polar", "nematic", "nemato-polar"]
const DEMO_ANCHORINGS = ["normal", "tangential"]

"""
    demo_dataset(dest=mktempdir(); dims=2, grid, nframes=10, radii,
                 shapes, orders, anchorings, layout=:frames) -> path to DF.csv

Write a synthetic ensemble in the app's layout and return its `DF.csv`:

```julia
explor_app(DataWorkspace(demo_dataset(dims=3), ".jld"))
```

Each run is a dense object on a non-square `grid` (default `(400,)`,
`(160, 96)` or `(36, 24, 18)`), off-centre, breathing (size ±15 %) and
drifting along x during the run.

`DF.csv` columns (what varies):
- `shape`     `"sphere"` or `"cube"` (disc / square in 2D, segment in 1D);
- `R`         three radii (cube: half-width);
- `order`     `"polar"`, `"nematic"` or `"nemato-polar"` (both);
- `anchoring` `"normal"` (order along the surface normal) or `"tangential"`
              (along a tangent: in 2D the normal turned by +90°, in 3D the
              azimuthal direction ẑ × n; in 1D there is no tangent, so the
              polarity is zero and the nematic order is −1);

plus `w` (interface width, constant, so hidden in the sidebar) and `fn`. When
every parameter has several values, the last combination is left out — a hole
to snap around. The last run has 3 frames fewer than the others.

Fields, Float32, in files named by time (`0000000000.jld`, `0000000010.jld`, …),
next to a `_creator` metadata group the app must ignore:
- `rho` density, ≈1 inside and ≈0 outside, smooth interface;
- `P`   (polar, nemato-polar) polarity along the director, filling the object:
        0 at the centre, full at the surface, 0 outside — an aster (normal) or a
        vortex (tangential): `(grid…, dims)` (`(N,)` in 1D);
- `Q`   (nematic, nemato-polar) nematic order of the director, same profile, stored as
        `(Qxx − Qyy, 2Qxy)` of its in-plane part — the components the app's
        nematic arrows read: `(grid…, 2)` (`(N,)` in 1D).

The default `dest` is a temporary folder, deleted when Julia exits; pass a
folder to keep the data.

`layout=:stacked` (1D only) instead writes one file per run, `data` of size
`(N, 3, nframes)` holding `rho`, `P`, `Q` (zero when absent) — the format read
by [`unstack_runs`](@ref) with `fields=["rho", "P", "Q"]` — and returns `dest`.
"""
function demo_dataset(dest=mktempdir(); dims=2,
                      grid=dims == 3 ? (36, 24, 18) : dims == 2 ? (160, 96) : (400,),
                      nframes=10, radii=round.(Int, minimum(grid) .* [0.2, 0.28, 0.36]),
                      shapes=DEMO_SHAPES, orders=DEMO_ORDERS, anchorings=DEMO_ANCHORINGS,
                      layout=:frames)
    dims in (1, 2, 3) && length(grid) == dims ||
        throw(ArgumentError("dims must be 1, 2 or 3 and grid must have dims sizes"))
    layout in (:frames, :stacked) || throw(ArgumentError("layout must be :frames or :stacked"))
    layout == :stacked && dims != 1 && throw(ArgumentError("layout=:stacked is for dims=1"))

    combos = [(shape=s, R=Float64(r), order=o, anchoring=a)
              for s in shapes for r in radii for o in orders for a in anchorings]
    hole   = all(>(1) ∘ length, (shapes, radii, orders, anchorings))
    rows   = hole ? combos[1:end-1] : combos                     # leave one combination out
    fns    = ["run_" * lpad(i, 2, '0') for i in eachindex(rows)]
    w      = 1.5

    for (i, (row, fn)) in enumerate(zip(rows, fns))
        n = i == length(rows) && length(rows) > 1 ? max(1, nframes - 3) : nframes
        frames = [demo_fields(row, grid, demo_center(grid, k, nframes),
                              row.R * (1 + 0.15 * sin(2π * k / nframes)); w) for k in 0:n-1]
        if layout == :stacked
            zero1 = zeros(Float32, grid...)
            data  = cat([hcat(f["rho"], get(f, "P", zero1), get(f, "Q", zero1)) for f in frames]...; dims=3)
            jldopen(joinpath(mkpath(dest), "$fn.jld"), "w") do f
                f["data"] = data
                f["_creator/generator"] = "DataVisualisation.demo_dataset"
            end
            continue
        end
        dir = mkpath(joinpath(dest, fn, "Data"))
        for (k, fields) in zip(0:n-1, frames)
            jldopen(joinpath(dir, lpad(10k, 10, '0') * ".jld"), "w") do f
                for (name, field) in fields
                    f[name] = field
                end
                f["_creator/generator"] = "DataVisualisation.demo_dataset"
            end
        end
    end
    layout == :stacked && return dest

    CSV.write(joinpath(dest, "DF.csv"),
              DataFrame(shape=[r.shape for r in rows], R=[r.R for r in rows],
                        order=[r.order for r in rows], anchoring=[r.anchoring for r in rows],
                        w=fill(w, length(rows)), fn=fns))
    return joinpath(dest, "DF.csv")
end

# Off-centre (45 %, 55 %, 50 % of the grid), drifting ±8 % along x.
demo_center(grid, k, nframes) =
    ntuple(i -> grid[i] * (0.45, 0.55, 0.5)[i] + (i == 1 ? 0.08 * grid[1] * sin(π * k / nframes) : 0.0),
           length(grid))

# Fields of one frame of `row` (shape, order, anchoring) with size R, centred at c.
function demo_fields(row, grid, c, R; w=1.5)
    dims  = length(grid)
    polar = row.order in ("polar", "nemato-polar")
    nem   = row.order in ("nematic", "nemato-polar")
    rho   = Array{Float32}(undef, grid...)
    P     = zeros(Float32, grid..., dims)
    Q     = zeros(Float32, grid..., 2)
    for I in CartesianIndices(rho)
        x = ntuple(i -> I[i] - c[i], dims)
        s, n = row.shape == "sphere" ? sphere_distance(x, R) : box_distance(x, ntuple(_ -> R, dims))
        e = row.anchoring == "normal" ? n : tangent(n)            # director
        rho[I] = (1 - tanh(s / w)) / 2
        # order fills the object: 0 at the centre (where the direction is
        # undefined), full at the surface, gone outside — an aster for normal
        # anchoring, a vortex for tangential
        amp = rho[I] * clamp(1 + s / R, 0, 1)
        for j in 1:dims
            P[I, j] = amp * e[j]
        end
        ex, ey = e[1], dims == 1 ? (row.anchoring == "normal" ? 0.0 : 1.0) : e[2]
        Q[I, 1] = amp * (ex^2 - ey^2)
        Q[I, 2] = amp * 2ex * ey
    end
    fields = Dict{String,Any}("rho" => rho)
    polar && (fields["P"] = dims == 1 ? P[:, 1] : P)
    nem   && (fields["Q"] = dims == 1 ? Q[:, 1] : Q)
    return fields
end

# A unit tangent to the surface of normal n: n turned by +90° in 2D, the
# azimuthal direction ẑ × n in 3D (x̂ × n where n ∥ z); none in 1D.
function tangent(n)
    length(n) == 1 && return (0.0,)
    length(n) == 2 && return (-n[2], n[1])
    t = (-n[2], n[1], 0.0)                                         # ẑ × n
    norm = sqrt(sum(abs2, t))
    norm < 1e-9 && (t = (0.0, -n[3], n[2]); norm = sqrt(sum(abs2, t)))   # x̂ × n
    return t ./ norm
end

# Signed distance to the surface (negative inside) and outward unit normal,
# for a sphere of radius R…
function sphere_distance(x, R)
    r = sqrt(sum(abs2, x))
    return r - R, r == 0 ? ntuple(i -> Float64(i == 1), length(x)) : x ./ r
end

# …and for a box of half-widths h (the normal of the nearest face).
function box_distance(x, h)
    gaps = abs.(x) .- h
    i    = argmax(gaps)
    return gaps[i], ntuple(j -> j == i ? (x[i] < 0 ? -1.0 : 1.0) : 0.0, length(x))
end
