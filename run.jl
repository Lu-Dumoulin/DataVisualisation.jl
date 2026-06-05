using DataVisualisation
using Bonito

ws  = DataWorkspace(normpath(joinpath(homedir(), "Data/PQ_FFT/DF.csv")), ".jld")
app = explor_app(ws)

isdefined(Main, :PlutoRunner) ? app : Bonito.Server(app, "127.0.0.1", 8080)
