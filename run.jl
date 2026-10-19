# Usage: julia -t auto run.jl    (from anywhere — always runs this checkout;
#        -t auto: background work such as the run colour range uses other threads)
# In Pluto, the last expression returns the app for display.

const IN_PLUTO = isdefined(Main, :PlutoRunner)

if !IN_PLUTO
    import Pkg
    Pkg.activate(@__DIR__; io=devnull)   # this repo's Project.toml, not the global env
    Pkg.instantiate()
end

using DataVisualisation
using Bonito

ws  = DataWorkspace(normpath(joinpath(homedir(), "Data/PQ_FFT/DF.csv")), ".jld")
app = explor_app(ws)

if IN_PLUTO
    app
else
    server = Bonito.Server(app, "127.0.0.1", 8080)
    @info "Dashboard at http://127.0.0.1:8080 — Ctrl-C to stop"
    wait(server)                         # keep the script alive while serving
end
