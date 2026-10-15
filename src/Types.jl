# ==============================================================================
# Types.jl — plot configuration and dataset description
# ==============================================================================

# One arrow/transparency overlay drawn on top of the heatmap.
Base.@kwdef struct OverlayConfig
    field     ::String     # field key, "None" = no overlay
    alpha     ::Float64    # min brightness of the transparency mask (1 = no mask)
    stepp     ::Int        # arrow spacing, in grid points
    arrowsize ::Float64
    nematic   ::Bool       # headless arrows with doubled angle
end

# Everything needed to draw one frame. Built from the widgets by plot_config(d)
# so that rendering never reads widgets directly.
Base.@kwdef struct PlotConfig
    Ndim     ::String
    nfile    ::Int
    cmap     ::String
    heatmap  ::String
    overlays ::Vector{OverlayConfig}
    fig_base ::Int
end

# Copy of cfg with some fields replaced, e.g. with(cfg; nfile=3).
function with(cfg::PlotConfig; kw...)
    names  = fieldnames(PlotConfig)
    fields = NamedTuple{names}(getfield.(Ref(cfg), names))
    return PlotConfig(; merge(fields, values(kw))...)
end


# ==============================================================================
# DataWorkspace — all dataset state, computed once at construction time
# ==============================================================================

struct DataWorkspace
    df                     ::DataFrame
    dir                    ::String
    name_csv               ::String
    ext                    ::String
    var_list               ::Vector{String}
    tab_list               ::Vector{Any}
    changing_variable_list ::Vector{String}
    N_changing             ::Int
    all_dir                ::Vector{String}
    Nfiles                 ::Int
    all_keys               ::Vector{String}
    all_cmaps              ::Vector{String}
    ranges                 ::Vector{Float64}

    function DataWorkspace(path_to_csv::String, ext::String)
        dir, name_csv = mysplitpath(path_to_csv)
        df            = CSV.read(joinpath(dir, name_csv), DataFrame; stringtype=String)

        var_list = setdiff(names(df), ["fn"])
        tab_list = Any[sort!(unique(df[:, v])) for v in var_list]

        changing_variable_list = [v for (v, tab) in zip(var_list, tab_list) if length(tab) > 1]
        N_changing             = length(changing_variable_list)

        all_dir = get_all_dir_ext(dir; ext=ext)
        isempty(all_dir) && error("No *$ext files found under $dir")
        Sys.iswindows() && (all_dir .= replace.(all_dir, "\\" => "/"))

        Nfiles    = maximum(length(frame_files(d, ext)) for d in all_dir)
        all_keys  = field_keys(frame_path(all_dir[1], 1, ext))
        all_cmaps = sort(collect(Makie.all_gradient_names))

        ranges = [col_range(df, v) for v in changing_variable_list]

        return new(df, dir, name_csv, ext, var_list, tab_list, changing_variable_list,
                   N_changing, all_dir, Nfiles, all_keys, all_cmaps, ranges)
    end
end

# Data/ folder of the run in DataFrame row idx.
run_path(ws::DataWorkspace, idx) = string(ws.dir, ws.df[idx, :fn], "/Data/")
