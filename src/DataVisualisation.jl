module DataVisualisation

using Bonito, Observables, WGLMakie, JLD2, FileIO, Colors,
      CSV, DataFrames, LinearAlgebra
import CairoMakie as Cairo
WGLMakie.activate!()

include("Utils.jl")
include("Types.jl")
include("Plotting.jl")
include("Widgets.jl")
include("App.jl")

export DataWorkspace, explor_app

end
