using DataVisualisation
using Test
using Bonito, Observables, JLD2, CSV, DataFrames, Colors
using DataVisualisation.WGLMakie: Makie, Point2

const DV = DataVisualisation

include("fixtures.jl")

@testset "DataVisualisation.jl" begin
    @testset "Utils"    include("test_utils.jl")
    @testset "Types"    include("test_types.jl")
    @testset "Import"   include("test_import.jl")
    @testset "Demo"     include("test_demo.jl")
    @testset "Plotting" include("test_plotting.jl")
    @testset "Widgets"  include("test_widgets.jl")
    @testset "App"      include("test_app.jl")
end
