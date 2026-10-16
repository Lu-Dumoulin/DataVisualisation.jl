module DataVisualisation

using Bonito, Observables, WGLMakie, JLD2, FileIO, Colors, Base64,
      CSV, DataFrames, LinearAlgebra
import CairoMakie as Cairo
WGLMakie.activate!()

include("Utils.jl")
include("Types.jl")
include("Import.jl")
include("Demo.jl")
include("Plotting.jl")
include("Widgets.jl")
include("State.jl")
include("App.jl")
include("precompile.jl")

export DataWorkspace, explor_app, unstack_runs, demo_dataset

end
