# ==============================================================================
# Import.jl — other on-disk layouts, converted to the standard one
# ==============================================================================

"""
    unstack_runs(src, dest=mktempdir(); fields, key="data") -> path to DF.csv

Convert runs stored as **one file per run** into the standard layout the app
reads, and return the path of the new `DF.csv`.

Every `.jld`/`.jld2` file under `src` whose `key` entry is a 3-dimensional array
`(points, fields, times)` is one run (e.g. `PS_FFT_P_1D/1/Data/data_2.jld` with
`data` of size `(768, 3, 11)`). It becomes `dest/<run>/Data/t0001.jld …`, one
file per time, each holding the 1D fields named by `fields` (default `f1, f2, …`).
`DF.csv` lists the runs in a `run` column (the file name without extension),
so the sidebar switches between them.

```julia
ws = DataWorkspace(unstack_runs(expanduser("~/Data/PS_FFT_P_1D"); fields=["rho", "v", "P"]), ".jld")
```

Nothing is written to `src`; `dest` defaults to a temporary folder.
"""
function unstack_runs(src, dest=mktempdir(); fields=nothing, key="data")
    runs = String[]
    for (root, _, files) in walkdir(src), file in sort(files)
        endswith(file, ".jld") || endswith(file, ".jld2") || continue
        A = jldopen(f -> haskey(f, key) ? f[key] : nothing, joinpath(root, file), "r")
        (A isa AbstractArray{<:Real} && ndims(A) == 3) || continue

        names = something(fields, ["f$j" for j in 1:size(A, 2)])
        length(names) == size(A, 2) ||
            error("$file: `$key` has $(size(A, 2)) fields, got $(length(names)) names")
        run = splitext(file)[1]
        run in runs && error("two runs named \"$run\" under $src — rename one of the files")
        push!(runs, run)

        out = joinpath(dest, run, "Data")
        mkpath(out)
        for t in axes(A, 3)
            jldopen(joinpath(out, "t" * lpad(t, 4, '0') * ".jld"), "w") do f
                for (j, name) in enumerate(names)
                    f[name] = A[:, j, t]
                end
            end
        end
    end
    isempty(runs) && error("No file under $src holds a 3-dimensional `$key` array")
    csv = joinpath(dest, "DF.csv")
    CSV.write(csv, DataFrame(run=runs, fn=runs))
    return csv
end
