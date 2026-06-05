# ==============================================================================
# Utils.jl — parameter-space nearest-row search
# ==============================================================================
#
# Pinned parameters (checkbox = true) get weight W_PIN >> 1.
# All parameters still contribute so no holes in the parameter space
# can ever cause an empty result.
# Distances are normalised by column range so magnitudes don't dominate.
# String columns: distance = 0 if equal, 1 if not.

const W_PIN = 1000.0

function col_range(df, varname)
    col = df[:, varname]
    isa(col[1], AbstractString) && return 1.0
    r = Float64(maximum(col)) - Float64(minimum(col))
    return r == 0 ? 1.0 : r
end

# ranges is precomputed in DataWorkspace — one scan at construction time
# instead of once per widget event.
function find_closest_row(df, changing_variable_list, ranges, widget_vals, pinned)
    N = length(changing_variable_list)

    best_idx  = 1
    best_dist = Inf

    for r in 1:nrow(df)
        d = 0.0
        for c in 1:N
            w   = pinned[c] ? W_PIN : 1.0
            val = df[r, changing_variable_list[c]]
            d  += w * (isa(val, AbstractString) ?
                        Float64(val != widget_vals[c]) :
                        abs(Float64(val) - Float64(widget_vals[c])) / ranges[c])
        end
        if d < best_dist
            best_dist = d
            best_idx  = r
        end
    end
    return best_idx
end

function mysplitpath(pathfn)
    return dirname(pathfn)*"/", basename(pathfn)
end

function get_all_ext(dir; ext=".gif", hidden=false)
    path_to_exts = Vector{String}()
    for (root, _, files) in walkdir(dir)
        !hidden && contains(root, ".") && continue
        for file in files
            if endswith(file, ext)
                push!(path_to_exts, joinpath(root, file))
            end
        end
    end
    return path_to_exts
end

function get_all_dir_ext(dir="/home/"; ext=".gif", hidden=false)
    path_to_exts = Vector{String}()
    for (root, _, files) in walkdir(dir)
        !hidden && contains(root, ".") && continue
        for file in files
            if endswith(file, ext)
                push!(path_to_exts, joinpath(root))
                break
            end
        end
    end
    return path_to_exts
end

readdir_ext(dir, ext) = filter(endswith(ext), Base.readdir(dir))
