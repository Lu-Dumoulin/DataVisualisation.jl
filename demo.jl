# Usage: julia demo.jl [dims]       dims = 1, 2 (default) or 3
# Generates the demo ensemble (see `demo_dataset`) in a temporary folder and
# opens the dashboard on it — no simulation data needed.

import Pkg
Pkg.activate(@__DIR__; io=devnull)
Pkg.instantiate()

using DataVisualisation
using Bonito

dims = parse(Int, get(ARGS, 1, "2"))
csv  = demo_dataset(dims=dims)
@info "Demo ensemble ($(dims)D) in $(dirname(csv))"

server = Bonito.Server(explor_app(DataWorkspace(csv, ".jld")), "127.0.0.1", 8080)
@info "Dashboard at http://127.0.0.1:8080 — Ctrl-C to stop"
wait(server)
