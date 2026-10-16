# The generated demo ensemble: layout, parameter space, and that its fields
# point where they should (outward normal, tangent, nematic axis).

@testset "geometry helpers" begin
    @test DV.sphere_distance((3.0, 4.0), 2.0) == (3.0, (0.6, 0.8))
    @test DV.sphere_distance((0.0, 0.0), 2.0)[2] == (1.0, 0.0)          # centre: any unit normal
    @test DV.box_distance((5.0, -1.0), (2.0, 2.0)) == (3.0, (1.0, 0.0))
    @test DV.box_distance((0.5, -4.0), (2.0, 2.0)) == (2.0, (0.0, -1.0))
    @test DV.tangent((1.0, 0.0)) == (-0.0, 1.0)                           # 2D: +90°
    @test DV.tangent((1.0, 0.0, 0.0)) == (-0.0, 1.0, 0.0)                 # 3D: ẑ × n
    @test DV.tangent((0.0, 0.0, 1.0)) == (0.0, -1.0, 0.0)                 # pole: x̂ × n
    @test DV.tangent((1.0,)) == (0.0,)                                    # 1D: none
end

@testset "demo_dataset" begin
    grid2 = (24, 16)
    csv = demo_dataset(mktempdir(); dims=2, grid=grid2, radii=[4, 6], nframes=3)
    df  = CSV.read(csv, DataFrame; stringtype=String)
    root = dirname(csv)

    @testset "parameter space" begin
        @test names(df) == ["shape", "R", "order", "anchoring", "w", "fn"]
        @test nrow(df) == 2 * 2 * 3 * 2 - 1                              # one combination left out
        @test !any((df.shape .== "cube") .& (df.R .== 6) .& (df.order .== "nemato-polar") .&
                   (df.anchoring .== "tangential"))
        @test allequal(df.w)
        ws = DataWorkspace(csv, ".jld")
        @test ws.changing_variable_list == ["shape", "R", "order", "anchoring"]   # w hidden
        @test ws.Nfiles == 3
        @test length(DV.frame_files(DV.run_path(ws, nrow(df)), ".jld")) == 1     # last run shorter
        @test DV.frame_times(DV.run_path(ws, 1), ".jld") == [0.0, 10.0, 20.0]    # named by time
    end

    # fields of the first frame of the run with these parameters
    function frame(shape, order, anchoring; R=6)
        i = findfirst((df.shape .== shape) .& (df.R .== R) .& (df.order .== order) .&
                      (df.anchoring .== anchoring))
        path = joinpath(root, df.fn[i], "Data", "0000000000.jld")
        return DV.load_fields(path, DV.field_keys(path))
    end
    c = DV.demo_center(grid2, 0, 3)                                       # frame 0: no drift
    at(dx, dy) = (round(Int, c[1] + dx), round(Int, c[2] + dy))

    @testset "fields per order" begin
        @test Set(keys(frame("sphere", "polar", "normal")))        == Set(["rho", "P"])
        @test Set(keys(frame("sphere", "nematic", "normal")))      == Set(["rho", "Q"])
        @test Set(keys(frame("sphere", "nemato-polar", "normal"))) == Set(["rho", "P", "Q"])
        f = frame("sphere", "polar", "normal")
        @test size(f["rho"]) == grid2 && size(f["P"]) == (grid2..., 2)
        @test eltype(f["rho"]) == Float32
        @test DV.field_keys(joinpath(root, df.fn[1], "Data", "0000000000.jld")) == ["P", "rho"]  # no _creator
    end

    @testset "density" begin
        rho = frame("sphere", "polar", "normal")["rho"]
        @test rho[at(0, 0)...] > 0.99                                     # inside
        @test rho[1, 1] < 0.01                                            # outside
    end

    @testset "polarity: normal points outward, tangential is +90°" begin
        P = frame("sphere", "polar", "normal")["P"]
        i, j = at(5, 0)                                                   # +x side, near the surface
        @test P[i, j, 1] > 0.5 && abs(P[i, j, 2]) < 0.2
        i, j = at(0, -5)                                                  # −y side
        @test P[i, j, 2] < -0.5 && abs(P[i, j, 1]) < 0.2
        @test maximum(abs, P[at(0, 0)..., :]) < 0.2                        # ~0 at the centre…
        @test maximum(abs, P[1, 1, :]) < 1e-3                              # …and outside

        T = frame("sphere", "polar", "tangential")["P"]
        i, j = at(5, 0)                                                   # +x → tangent +y (vortex)
        @test T[i, j, 2] > 0.5 && abs(T[i, j, 1]) < 0.2

        Pc = frame("cube", "polar", "normal")["P"]
        i, j = at(1, 5)                                                   # +y face of the square
        @test Pc[i, j, 2] > 0.5 && abs(Pc[i, j, 1]) < 1e-6
    end

    @testset "nematic: director along the normal or the tangent" begin
        Q = frame("sphere", "nematic", "normal")["Q"]
        i, j = at(5, 0);  @test Q[i, j, 1] > 0.5                          # director ∥ x
        i, j = at(0, 5);  @test Q[i, j, 1] < -0.5                         # director ∥ y
        T = frame("sphere", "nematic", "tangential")["Q"]
        i, j = at(5, 0);  @test T[i, j, 1] < -0.5                         # tangent ∥ y
        # the app's nematic arrows recover the director angle from (Q1, Q2)
        i, j = at(3, 3)
        θ = 0.5 * atan(Q[i, j, 2], Q[i, j, 1])
        @test isapprox(θ, π / 4; atol=0.15)
    end

    @testset "3D and 1D" begin
        csv3 = demo_dataset(mktempdir(); dims=3, grid=(20, 16, 14), radii=[5], nframes=2,
                            orders=["polar"], anchorings=["tangential"], shapes=["sphere"])
        ws3  = DataWorkspace(csv3, ".jld")
        s = Bonito.Session()
        d3 = DV.dashboard(ws3, s)                                        # only 3D fields: starts in 3D
        try
            @test d3.dim.value[] == "3D" && d3.zslider[] isa Bonito.Slider
            @test waitfor(() -> d3.plot[] isa Makie.Figure)
        finally
            close(s)
        end
        f3   = DV.load_fields(joinpath(DV.run_path(ws3, 1), "0000000000.jld"), ["rho", "P"])
        @test size(f3["P"]) == (20, 16, 14, 3)
        c3 = DV.demo_center((20, 16, 14), 0, 2)
        i, j, k = round.(Int, c3 .+ (4, 0, 0))                           # +x → azimuthal tangent +y
        @test f3["P"][i, j, k, 2] > 0.5

        csv1 = demo_dataset(mktempdir(); dims=1, grid=(60,), radii=[10], nframes=2,
                            shapes=["sphere"], anchorings=["normal", "tangential"], orders=["nemato-polar"])
        df1 = CSV.read(csv1, DataFrame; stringtype=String)
        f(r) = DV.load_fields(joinpath(dirname(csv1), r, "Data", "0000000000.jld"), ["P", "Q"])
        c1 = round(Int, DV.demo_center((60,), 0, 2)[1] + 8)
        n, t = f(df1.fn[1]), f(df1.fn[2])
        @test n["P"][c1] > 0.5 && n["Q"][c1] > 0.5                        # normal: outward, Q = +1
        @test all(iszero, t["P"]) && t["Q"][c1] < -0.5                    # tangential: no P, Q = −1
    end

    @testset "stacked 1D layout, read back with unstack_runs" begin
        src = demo_dataset(mktempdir(); dims=1, grid=(40,), radii=[6, 8], nframes=4, layout=:stacked)
        @test length(readdir(src)) == 2 * 2 * 3 * 2 - 1
        ws = DataWorkspace(unstack_runs(src; fields=["rho", "P", "Q"]), ".jld")
        @test ws.all_keys == ["P", "Q", "rho"] && ws.Nfiles == 4
    end

    @testset "arguments" begin
        @test_throws ArgumentError demo_dataset(mktempdir(); dims=4)
        @test_throws ArgumentError demo_dataset(mktempdir(); dims=2, grid=(10,))
        @test_throws ArgumentError demo_dataset(mktempdir(); dims=2, layout=:stacked)
        @test_throws ArgumentError demo_dataset(mktempdir(); dims=1, layout=:other)
        one = demo_dataset(mktempdir(); dims=2, grid=(12, 8), radii=[3], nframes=2,
                           shapes=["cube"], orders=["polar"], anchorings=["normal"])
        @test nrow(CSV.read(one, DataFrame)) == 1                         # a single run: no hole
        two = demo_dataset(mktempdir(); dims=2, grid=(12, 8), radii=[3], nframes=2,
                           shapes=["cube"], orders=["polar"])
        @test nrow(CSV.read(two, DataFrame)) == 2                         # one value somewhere: no hole
    end

    @testset "in the app" begin
        s = Bonito.Session()
        d = DV.dashboard(DataWorkspace(csv, ".jld"), s)
        try
            @test waitfor(() -> d.plot[] isa Makie.Figure)
            d.overlays[1].field[] = "P"
            ax() = only(c for c in d.plot[].content if c isa Makie.Axis)
            @test waitfor(() -> length(ax().scene.plots) == 2)                # heatmap + arrows
        finally
            close(s)
        end
    end
end
