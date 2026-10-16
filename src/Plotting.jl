# ==============================================================================
# Plotting.jl — frame access, figure building, PNG export
# ==============================================================================
#
# Everything here is a plain function of (directory, PlotConfig, extension):
# no widgets, no session. Functions that can fail for a user-visible reason
# return a message String instead of throwing; render_view turns it into a div.


# ── Frame files ───────────────────────────────────────────────────────────────

frame_files(dir, ext) = isdir(dir) ? readdir_ext(dir, ext) : String[]

# Path of frame n (clamped to the run's length), or nothing if there are no frames.
function frame_path(dir, n, ext)
    files = frame_files(dir, ext)
    isempty(files) && return nothing
    return joinpath(dir, files[clamp(n, 1, length(files))])
end

# Size of every field stored in one frame file. Only numeric arrays count:
# files can also hold metadata (e.g. a JLD2 `_creator` group) that can't be plotted.
field_shapes(path) = Dict{String,Tuple}(k => size(v) for (k, v) in FileIO.load(path)
                                        if v isa AbstractArray{<:Real})

# Sorted field names stored in one frame file.
field_keys(path) = sort!(collect(keys(field_shapes(path))))

# Exported PNGs live next to the run's Data/ folder.
fig_dir(dir)              = normpath(joinpath(dir, "..", "Fig"))
png_path(dir, frame_file) = joinpath(fig_dir(dir), splitext(basename(frame_file))[1] * ".png")

# Load only the keys needed from a frame file (single file open).
function load_fields(path, keys_needed)
    isempty(keys_needed) && return Dict{String,Any}()
    raw = FileIO.load(path, keys_needed...)
    return length(keys_needed) == 1 ?
        Dict(keys_needed[1] => raw) :
        Dict(zip(keys_needed, raw))
end

# Fields used by cfg for its frame, or a message saying why there is nothing to plot.
function load_frame(dir, cfg::PlotConfig, ext)
    isdir(dir) || return "No directory: $dir"
    path = frame_path(dir, cfg.nfile, ext)
    isnothing(path) && return "No files in: $dir"
    keys_needed = cfg.Ndim == "1D" ? copy(cfg.fields1d) :
                  unique(filter(!=("None"), [cfg.heatmap; [o.field for o in cfg.overlays]]))
    isempty(keys_needed) && return "No fields selected"
    return load_fields(path, keys_needed)
end


# ── Overlay helpers ───────────────────────────────────────────────────────────

# ── 3D: slicing ─────────────────────────────────────────────────────────────
# In 3D mode a field is read from its shape:
#   (Nx, Ny)          2D scalar             → as is
#   (Nx, Ny, 2)       2D vector             → as is
#   (Nx, Ny, Nz≠2)    3D scalar, or a stack of 2D fields (e.g. phase fields)
#   (Nx, Ny, Nz, c)   3D vector with c components
# Slicing at z turns the last two into a 2D scalar / an (Nx, Ny, c) vector, so
# everything downstream (heatmap, arrows, mask, export) is the 2D code. The
# heatmap of a sliced 3D vector shows its full norm; arrows show its x, y part.

# Number of z-slices of a field with this shape (1 = not sliceable).
depth(sz) = length(sz) == 4 || (length(sz) == 3 && sz[3] != 2) ? sz[3] : 1

nslices(shapes) = maximum(depth, values(shapes); init=1)

function slice_field(f, z)
    ndims(f) == 4 && return f[:, :, clamp(z, 1, size(f, 3)), :]
    ndims(f) == 3 && size(f, 3) != 2 && return f[:, :, clamp(z, 1, size(f, 3))]
    return f
end

slice_frame(data, cfg::PlotConfig) =
    cfg.Ndim == "3D" ? Dict{String,Any}(k => slice_field(v, cfg.zslice) for (k, v) in data) : data


# ── 1D: profiles ──────────────────────────────────────────────────────────────
# 1D fields (Nx,) are plotted as they are. 2D fields are cut along one axis —
# at a position of the other axis, or averaged over it; 2D vectors via their
# norm. 3D fields have no profile (nothing returned).

is_2d(sz) = length(sz) == 2 || (length(sz) == 3 && sz[3] == 2)

function profile(f, cfg::PlotConfig)
    ndims(f) == 1 && return f
    g = ndims(f) == 3 && size(f, 3) == 2 ? heatmap_field(f) : f
    ndims(g) == 2 || return nothing
    other = cfg.cut_axis == "x" ? 2 : 1                  # the axis that is fixed / averaged
    cfg.cut_mean && return vec(sum(g; dims=other)) ./ size(g, other)
    i = clamp(cfg.cut_pos, 1, size(g, other))
    return other == 2 ? g[:, i] : g[i, :]
end

# Length of the axis the cut position moves along (0: no 2D field to cut).
cut_length(shapes, cut_axis) =
    maximum((sz[cut_axis == "x" ? 2 : 1] for sz in values(shapes) if is_2d(sz)); init=0)

profiles_frame(data, cfg::PlotConfig) =
    Dict{String,Any}(k => p for (k, p) in ((k, profile(data[k], cfg)) for k in cfg.fields1d
                                           if haskey(data, k)) if !isnothing(p))

# What gets plotted from a loaded frame: a z-slice in 3D, profiles in 1D.
reduce_frame(data, cfg::PlotConfig) =
    cfg.Ndim == "1D" ? profiles_frame(data, cfg) : slice_frame(data, cfg)


# Scalar field, or the norm of a vector field (Nx, Ny, c).
heatmap_field(f) = ndims(f) > 2 ? dropdims(sqrt.(sum(f.^2; dims=3)); dims=3) : f

# Block-average so that A has at most max_cells cells along each axis. A canvas
# ~fig_base px wide can't show more, and every cell is sent to the browser on
# each frame. Returned unchanged when already small enough.
function downsample(A::AbstractMatrix, max_cells)
    f = cld(maximum(size(A)), max_cells)
    f <= 1 && return A
    Nx, Ny = size(A)
    out = Matrix{Float32}(undef, cld(Nx, f), cld(Ny, f))
    for j in axes(out, 2), i in axes(out, 1)
        block     = view(A, (i-1)*f+1:min(i*f, Nx), (j-1)*f+1:min(j*f, Ny))
        out[i, j] = sum(block) / length(block)
    end
    return out
end

# Cell edges spanning the full grid 0.5…N+0.5, whatever the displayed resolution,
# so downsampled heatmaps and masks stay aligned with the arrows.
edges(N, n) = range(0.5, N + 0.5; length=n + 1)

# The plot functions below take Observables: updating the observable redraws
# the plot in place (WGLMakie then only sends the new arrays to the browser).
# Plain arrays are wrapped, for one-off figures.
as_obs(x) = x isa Observable ? x : Observable(x)

# Transparency mask: low values → more opaque black overlay.
# alpha = minimum brightness (0 = fully opaque at min, 1 = no overlay).
function mask_colors(field, alpha)
    tmp        = heatmap_field(field)
    mini, maxi = extrema(tmp)
    denom      = maxi == mini ? one(maxi) : maxi - mini
    return [RGBA{Float32}(0, 0, 0, Float32(1 - (alpha + (1 - alpha) * (t - mini) / denom)))
            for t in tmp]
end

function overlay_alpha!(ax, field, alpha; max_cells=typemax(Int))
    alpha >= 1.0 && return
    field  = as_obs(field)
    Nx, Ny = size(field[])[1:2]
    mask   = lift(f -> mask_colors(downsample(heatmap_field(f), max_cells), alpha), field)
    image!(ax, Makie.ClosedInterval(0.5, Nx + 0.5), Makie.ClosedInterval(0.5, Ny + 0.5), mask)
end

# Arrow components on the (stepp-spaced) grid — polar, or nematic (headless,
# doubled angle, length 4|Q|).
function arrow_dirs(field, x, y, is_nematic)
    tu, tv = field[x,y,1], field[x,y,2]
    if is_nematic
        S     = 4 .* sqrt.(tu.^2 .+ tv.^2)
        theta = 0.5 .* atan.(tv .+ 1e-6, tu)
        tu, tv = S .* cos.(theta), S .* sin.(theta)
    end
    return vec(Vec2f.(tu, tv))
end

function draw_arrows!(ax, field, stepp, arrowsize_factor, is_nematic)
    field  = as_obs(field)
    Nx, Ny = size(field[])[1:2]
    x, y   = 1:stepp:Nx, 1:stepp:Ny
    points = vec([Point2f(i, j) for i in x, j in y])
    dirs   = lift(f -> arrow_dirs(f, x, y, is_nematic), field)
    if is_nematic
        arrows2d!(ax, points, dirs; lengthscale=arrowsize_factor, align=:center,
                  tiplength=0, color=:white)
    else
        arrows2d!(ax, points, dirs; lengthscale=arrowsize_factor, align=:center,
                  color=:black)
    end
end

function draw_overlay!(ax, field, o::OverlayConfig; max_cells=typemax(Int))
    field = as_obs(field)
    ndims(field[]) > 2 && draw_arrows!(ax, field, o.stepp, o.arrowsize, o.nematic)
    overlay_alpha!(ax, field, o.alpha; max_cells)
end


# ── Figures ───────────────────────────────────────────────────────────────────

# Figure for one frame (in 3D: one slice, already cut by slice_frame).
# `data` may be an Observable{Dict}: setting data[] to the
# next frame (same fields and sizes) redraws in place — that's how the live view
# animates. Shared with the PNG export (plain Dict, full resolution), so saved
# images look like the screen. max_cells caps the heatmap/mask resolution.
function plot_frame(data, cfg::PlotConfig; max_cells=typemax(Int))
    cfg.Ndim == "1D" && return plot_profiles(data, cfg)
    cfg.Ndim in ("2D", "3D") || return "$(cfg.Ndim) view not implemented yet"

    data   = as_obs(data)
    for k in [cfg.heatmap; [o.field for o in cfg.overlays if o.field != "None"]]
        n = ndims(data[][k])                     # after slicing in 3D: 2 or 3 (a 2D vector / stack)
        n == 1 && return "$k is a 1D field — choose Dimension: 1D"
        n > 3  && return "$k is a 3D field — choose Dimension: 3D"
    end
    Nx, Ny = size(data[][cfg.heatmap])[1:2]
    scale  = cfg.fig_base / max(Nx, Ny)
    fig    = Figure(size=(round(Int, Nx * scale) + 100, round(Int, Ny * scale)))
    ax     = Makie.Axis(fig[1,1]; aspect=DataAspect())
    limits!(ax, 0.5, Nx + 0.5, 0.5, Ny + 0.5)

    heat = lift(d -> downsample(heatmap_field(d[cfg.heatmap]), max_cells), data)
    nx, ny = size(heat[])
    hm = heatmap!(ax, edges(Nx, nx), edges(Ny, ny), heat; colormap=cfg.cmap)
    Colorbar(fig[:,end+1], hm)

    for o in cfg.overlays
        o.field == "None" && continue
        draw_overlay!(ax, lift(d -> d[o.field], data), o; max_cells)
    end
    return fig
end

# Height of one 1D panel; Fig size scales it (200 / 300 / 220 px at the default 800).
panel_height(cfg::PlotConfig) =
    round(Int, cfg.fig_base * (cfg.view1d == "Kymograph" ? 3 / 8 : cfg.view1d == "Times overlaid" ? 11 / 40 : 1 / 4))

# 1D profiles: one panel per field (they rarely share a scale), stacked with a
# shared x axis. `data` holds the profiles (see reduce_frame); as in 2D it may
# be an Observable, updated in place; y limits follow each new frame.
function plot_profiles(data, cfg::PlotConfig)
    data  = as_obs(data)
    names = [k for k in cfg.fields1d if haskey(data[], k)]
    isempty(names) && return "No 1D or 2D field selected"
    fig  = Figure(size=(cfg.fig_base + 100, 60 + panel_height(cfg) * length(names)))
    axes = [Makie.Axis(fig[i, 1]; ylabel=name) for (i, name) in enumerate(names)]
    for (ax, name) in zip(axes, names)
        lines!(ax, lift(d -> d[name], data); color=:black)
    end
    length(axes) > 1 && linkxaxes!(axes...)
    foreach(ax -> hidexdecorations!(ax; grid=false, ticks=false), axes[1:end-1])
    axes[end].xlabel = cfg.cut_axis
    on(_ -> foreach(reset_limits!, axes), data)
    return fig
end

# ── 1D: whole-run views (kymograph, times overlaid) ───────────────────────────

const VIEWS_1D = ["Profiles", "Kymograph", "Times overlaid"]
run_view(cfg::PlotConfig) = cfg.Ndim == "1D" && cfg.view1d != "Profiles"

# Time of each frame: the number in its file name (files are often named by
# time, e.g. 0000000025.jld), or the frame index when names aren't numbers.
function frame_times(dir, ext)
    files = frame_files(dir, ext)
    nums  = [tryparse(Float64, filter(isdigit, splitext(f)[1])) for f in files]
    return all(!isnothing, nums) && allunique(nums) ? Float64.(nums) : collect(1.0:length(files))
end

# Profiles of every frame of the run: field => (points × frames) matrix, plus
# the frame times — or a message.
function run_profiles(dir, cfg::PlotConfig, ext)
    n = length(frame_files(dir, ext))
    n == 0 && return isdir(dir) ? "No files in: $dir" : "No directory: $dir"
    frames = [load_frame(dir, with(cfg; nfile=i), ext) for i in 1:n]
    frames[1] isa AbstractString && return frames[1]
    profs = [profiles_frame(f, cfg) for f in frames]
    names = [k for k in cfg.fields1d if haskey(profs[1], k)]
    isempty(names) && return "No 1D or 2D field selected"
    return (fields = Dict{String,Matrix{Float64}}(k => reduce(hcat, [p[k] for p in profs]) for k in names),
            names  = names,
            times  = frame_times(dir, ext))
end

# Figure of a whole run; `frame` (an Observable) marks the current frame and
# can be moved without rebuilding the figure.
function plot_run(run, cfg::PlotConfig; frame=Observable(cfg.nfile))
    run isa AbstractString && return run
    t    = run.times
    tnow = lift(i -> t[clamp(i, 1, length(t))], frame)
    fig  = Figure(size=(cfg.fig_base + 100, 60 + panel_height(cfg) * length(run.names)))
    axes = Makie.Axis[]
    for (i, name) in enumerate(run.names)
        A  = run.fields[name]
        ax = Makie.Axis(fig[i, 1]; title=name)
        push!(axes, ax)
        if cfg.view1d == "Kymograph"            # x horizontal, time vertical
            hm = heatmap!(ax, 1:size(A, 1), t, A; colormap=cfg.cmap)
            Colorbar(fig[i, 2], hm)
            hlines!(ax, tnow; color=:black, linewidth=2)
            ax.ylabel = "t"
        else                                    # every frame (≤ ~20), coloured by time
            step = cld(size(A, 2), 20)
            for j in 1:step:size(A, 2)
                lines!(ax, A[:, j]; color=t[j], colorrange=(first(t), max(last(t), first(t) + 1)),
                       colormap=:viridis)
            end
            lines!(ax, lift(j -> A[:, clamp(j, 1, size(A, 2))], frame); color=:black, linewidth=3)
            i == 1 && Colorbar(fig[1:length(run.names), 2]; colormap=:viridis, label="t",
                               limits=(first(t), max(last(t), first(t) + 1)))
        end
    end
    length(axes) > 1 && linkxaxes!(axes...)
    axes[end].xlabel = cfg.cut_axis
    return fig
end

# Figure from the raw fields, or a message.
function field_view(dir, cfg::PlotConfig, ext)
    run_view(cfg) && return plot_run(run_profiles(dir, cfg, ext), cfg)
    data = load_frame(dir, cfg, ext)
    data isa AbstractString && return data
    return plot_frame(reduce_frame(data, cfg), cfg)
end

# Exported PNG for cfg's frame: (file=path, msg=nothing) or (file=nothing, msg=why not).
function png_file(dir, cfg::PlotConfig, ext)
    path = frame_path(dir, cfg.nfile, ext)
    (isnothing(path) || !isdir(fig_dir(dir))) &&
        return (file=nothing, msg="No Fig/ folder found — save images first")
    png = png_path(dir, path)
    isfile(png) || return (file=nothing, msg="PNG not found — save images first")
    return (file=png, msg=nothing)
end

# PNGs are shown as a plain <img>: the browser decodes them natively, and
# swapping `src` is much cheaper than a new Makie figure per frame.
png_data_uri(path) = "data:image/png;base64," * base64encode(read(path))

png_img(src) = DOM.img(; src, style=Styles("max-width" => "100%", "max-height" => "80vh",
                                           "object-fit" => "contain", "display" => "block"))


# ── PNG export (CairoMakie, no WGLMakie session involved) ─────────────────────

# Save every frame of the run in dir to fig_dir(dir). on_progress(i, N) is called
# after each frame. Returns (number saved, number of frames).
function save_frames(on_progress, dir, cfg::PlotConfig, ext)
    files = frame_files(dir, ext)
    isempty(files) && return 0, 0
    mkpath(fig_dir(dir))
    saved = 0
    run   = run_view(cfg) ? run_profiles(dir, cfg, ext) : nothing    # whole-run views: load once
    for (i, fname) in enumerate(files)
        try
            c   = with(cfg; nfile=i)
            fig = isnothing(run) ? field_view(dir, c, ext) : plot_run(run, c)
            if fig isa Figure
                Cairo.save(png_path(dir, fname), fig; backend=Cairo)
                saved += 1
            end
        catch e
            @warn "Could not save $fname: $e"
        end
        on_progress(i, length(files))
    end
    return saved, length(files)
end

save_frames(dir, cfg::PlotConfig, ext) = save_frames((_, _) -> nothing, dir, cfg, ext)
