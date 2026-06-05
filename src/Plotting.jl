# ==============================================================================
# Plotting.jl — field loaders, overlay helpers, WGLMakie and CairoMakie renders
# ==============================================================================


# ── Helpers ───────────────────────────────────────────────────────────────────

# Load only the keys needed from a .jld file (single file open).
function load_fields(path_jld, keys_needed)
    isempty(keys_needed) && return Dict{String,Any}()
    raw = FileIO.load(path_jld, keys_needed...)
    return length(keys_needed) == 1 ?
        Dict(keys_needed[1] => raw) :
        Dict(zip(keys_needed, raw))
end

# Transparency mask: low values → more opaque black overlay.
# alpha = minimum brightness (0 = fully opaque at min, 1 = no overlay).
function overlay_alpha!(ax, field, alpha)
    alpha >= 1.0 && return
    tmp        = ndims(field) < 3 ? field : sqrt.(field[:,:,1].^2 .+ field[:,:,2].^2)
    mini, maxi = extrema(tmp)
    denom      = maxi == mini ? one(maxi) : maxi - mini
    brightness = @. alpha + (1 - alpha) * (tmp - mini) / denom
    mask       = [RGBA{Float32}(0, 0, 0, Float32(1 - b)) for b in brightness]
    image!(ax, mask)
end

# Arrow overlay — handles polar (standard) and nematic (headless, doubled angle).
function draw_arrows!(ax, field, stepp, arrowsize_factor, is_nematic)
    Nx, Ny = size(field)[1:2]
    x, y   = 1:stepp:Nx, 1:stepp:Ny
    if is_nematic
        tu, tv = field[x,y,1], field[x,y,2]
        S      = 4 .* sqrt.(tu.^2 .+ tv.^2)
        theta  = 0.5 .* atan.(tv .+ 1e-6, tu)
        arrows2d!(ax, x, y, S.*cos.(theta), S.*sin.(theta);
                  lengthscale=arrowsize_factor, align=:center, tiplength=0, color=:white)
    else
        arrows2d!(ax, x, y, field[x,y,1], field[x,y,2];
                  lengthscale=arrowsize_factor, align=:center, color=:black)
    end
end

function draw_overlay!(ax, field, alpha, stepp, arrowsize_factor, is_nematic)
    ndims(field) > 2 && draw_arrows!(ax, field, stepp, arrowsize_factor, is_nematic)
    overlay_alpha!(ax, field, alpha)
end


# ── WGLMakie render (interactive display) ─────────────────────────────────────

function make_plot(dir_path::String, cfg::PlotConfig, ext::String)
    !isdir(dir_path)  && return DOM.div("No directory: $dir_path")

    list_jld = filter(endswith(ext), readdir(dir_path))
    isempty(list_jld) && return DOM.div("No files in: $dir_path")

    nfile    = clamp(cfg.nfile, 1, length(list_jld))
    path_jld = joinpath(dir_path, list_jld[nfile])

    keys_needed = unique(filter(!=("None"),
                    [cfg.first_field_key, cfg.second_field_key, cfg.third_field_key]))
    isempty(keys_needed) && return DOM.div("No fields selected")

    data_dict = load_fields(path_jld, keys_needed)

    if cfg.Ndim == "2D"
        first_field   = data_dict[cfg.first_field_key]
        heatmap_field = ndims(first_field) > 2 ?
                            dropdims(sqrt.(sum(first_field.^2; dims=3)); dims=3) :
                            first_field

        Nx, Ny   = size(heatmap_field)
        scale    = cfg.fig_base / max(Nx, Ny)
        fig = Figure(size=(round(Int, Nx * scale) + 100, round(Int, Ny * scale)))
        ax  = Makie.Axis(fig[1,1]; aspect=DataAspect())

        heat = heatmap!(ax, heatmap_field; colormap=cfg.cmap)
        Colorbar(fig[:,end+1], heat)

        cfg.second_field_key != "None" &&
            draw_overlay!(ax, data_dict[cfg.second_field_key],
                          cfg.alpha, cfg.stepp, cfg.arrowsize_factor, cfg.is_nematic)
        cfg.third_field_key != "None" &&
            draw_overlay!(ax, data_dict[cfg.third_field_key],
                          cfg.alpha_2, cfg.stepp_2, cfg.arrowsize_factor_2, cfg.is_nematic_2)

    elseif cfg.Ndim == "1D"
        fig = Figure(size=(cfg.fig_base + 100, 400))
        # TODO
        return fig
    end

    return fig
end


# ── CairoMakie render (offline save — no WGLMakie session involved) ───────────

function _cairo_arrows!(ax, field, x, y, arrowsize_factor, is_nematic)
    if is_nematic
        tu, tv = field[x,y,1], field[x,y,2]
        S      = 4 .* sqrt.(tu.^2 .+ tv.^2)
        theta  = 0.5 .* atan.(tv .+ 1e-6, tu)
        Cairo.arrows2d!(ax, x, y, S.*cos.(theta), S.*sin.(theta);
                        lengthscale=arrowsize_factor, align=:center, tiplength=0, color=:white)
    else
        Cairo.arrows2d!(ax, x, y, field[x,y,1], field[x,y,2];
                        lengthscale=arrowsize_factor, align=:center, color=:black)
    end
end

function make_plot_cairo(dir_path::String, cfg::PlotConfig, ext::String)
    !isdir(dir_path)  && return nothing

    list_jld = filter(endswith(ext), readdir(dir_path))
    isempty(list_jld) && return nothing

    nfile    = clamp(cfg.nfile, 1, length(list_jld))
    path_jld = joinpath(dir_path, list_jld[nfile])

    keys_needed = unique(filter(!=("None"),
                    [cfg.first_field_key, cfg.second_field_key, cfg.third_field_key]))
    isempty(keys_needed) && return nothing

    data_dict = load_fields(path_jld, keys_needed)

    fig = Cairo.Figure(size=(500, 500))
    ax  = Cairo.Axis(fig[1,1]; aspect=Cairo.DataAspect())

    if cfg.Ndim == "2D"
        first_field   = data_dict[cfg.first_field_key]
        heatmap_field = ndims(first_field) > 2 ?
                            dropdims(sqrt.(sum(first_field.^2; dims=3)); dims=3) :
                            first_field
        heat = Cairo.heatmap!(ax, heatmap_field; colormap=cfg.cmap)
        Cairo.Colorbar(fig[:,end+1], heat)

        for (key, stepp, arrowsize, nematic) in [
                (cfg.second_field_key, cfg.stepp,   cfg.arrowsize_factor,   cfg.is_nematic),
                (cfg.third_field_key,  cfg.stepp_2, cfg.arrowsize_factor_2, cfg.is_nematic_2)]
            key == "None" && continue
            field = data_dict[key]
            ndims(field) > 2 || continue
            Nx, Ny = size(field)[1:2]
            _cairo_arrows!(ax, field, 1:stepp:Nx, 1:stepp:Ny, arrowsize, nematic)
        end
    end

    return fig
end
