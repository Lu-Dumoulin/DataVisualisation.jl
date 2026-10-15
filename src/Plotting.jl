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

# Sorted field names stored in one frame file.
field_keys(path) = sort!(collect(keys(FileIO.load(path))))

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
    keys_needed = unique(filter(!=("None"), [cfg.heatmap; [o.field for o in cfg.overlays]]))
    isempty(keys_needed) && return "No fields selected"
    return load_fields(path, keys_needed)
end


# ── Overlay helpers ───────────────────────────────────────────────────────────

# Scalar field, or the norm of a vector field (Nx, Ny, 2).
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

# Figure for one frame. `data` may be an Observable{Dict}: setting data[] to the
# next frame (same fields and sizes) redraws in place — that's how the live view
# animates. Shared with the PNG export (plain Dict, full resolution), so saved
# images look like the screen. max_cells caps the heatmap/mask resolution.
function plot_frame(data, cfg::PlotConfig; max_cells=typemax(Int))
    if cfg.Ndim == "1D"
        return Figure(size=(cfg.fig_base + 100, 400))       # TODO: 1D view
    end
    cfg.Ndim == "2D" || return "$(cfg.Ndim) view not implemented yet"

    data   = as_obs(data)
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

# Figure from the raw fields, or a message.
function field_view(dir, cfg::PlotConfig, ext)
    data = load_frame(dir, cfg, ext)
    data isa AbstractString && return data
    return plot_frame(data, cfg)
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
    for (i, fname) in enumerate(files)
        try
            fig = field_view(dir, with(cfg; nfile=i), ext)
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
