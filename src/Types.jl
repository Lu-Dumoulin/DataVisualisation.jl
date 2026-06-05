# ==============================================================================
# Types.jl — data structures shared across the dashboard
# ==============================================================================

# Replaces positional args indexing in make_plot.
# Adding/removing a field only requires changing this struct and the one
# place that constructs it (current_config in App.jl).
Base.@kwdef struct PlotConfig
    Ndim              ::String
    nfile             ::Int
    cmap              ::String
    first_field_key   ::String
    second_field_key  ::String
    alpha             ::Float64
    stepp             ::Int
    arrowsize_factor  ::Float64
    is_nematic        ::Bool
    third_field_key   ::String
    alpha_2           ::Float64
    stepp_2           ::Int
    arrowsize_factor_2::Float64
    is_nematic_2      ::Bool
    fig_base          ::Int
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

        Ncol     = ncol(df)
        var_list = names(df[:, setdiff(names(df), ["fn"])])
        tab_list = Any[sort!(unique(df[:, v])) for v in var_list]

        changing_variable_list = [var_list[i] for i in 1:Ncol-1 if length(tab_list[i]) > 1]
        N_changing             = length(changing_variable_list)

        all_dir = get_all_dir_ext(dir; ext=ext)
        Sys.iswindows() && (all_dir .= replace.(all_dir, "\\" => "/"))

        Nfiles          = maximum(length(readdir_ext(d, ext)) for d in all_dir)
        path_first_file = joinpath(all_dir[1], readdir_ext(all_dir[1], ext)[1])
        all_keys        = sort(collect(keys(FileIO.load(path_first_file))))
        all_cmaps       = sort(collect(Makie.all_gradient_names))

        ranges = [col_range(df, v) for v in changing_variable_list]

        return new(df, dir, name_csv, ext, var_list, tab_list, changing_variable_list,
                   N_changing, all_dir, Nfiles, all_keys, all_cmaps, ranges)
    end
end
