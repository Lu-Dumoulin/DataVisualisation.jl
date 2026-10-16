# Single-file runs `(points, fields, times)` → standard layout.

function stacked_source()
    src = mktempdir()
    mkpath(joinpath(src, "1", "Data"))
    a = [Float64(100t + 10j + i) for i in 1:5, j in 1:2, t in 1:3]     # a[i, j, t]
    b = [-Float64(100t + 10j + i) for i in 1:5, j in 1:2, t in 1:4]
    jldsave(joinpath(src, "1", "Data", "a.jld"); data=a)
    jldsave(joinpath(src, "1", "Data", "b.jld2"); data=b)
    jldsave(joinpath(src, "1", "Data", "other.jld"); x=rand(3))         # no `data`: skipped
    jldsave(joinpath(src, "1", "Data", "flat.jld"); data=rand(5, 2))    # not 3D: skipped
    write(joinpath(src, "notes.txt"), "hello")
    return src, a, b
end

@testset "unstack_runs" begin
    src, a, b = stacked_source()
    csv = unstack_runs(src, mktempdir(); fields=["x", "y"])
    df  = CSV.read(csv, DataFrame; stringtype=String)
    @test df.run == ["a", "b"] && df.fn == ["a", "b"]
    dir = dirname(csv)
    @test DV.frame_files(joinpath(dir, "a", "Data"), ".jld") == ["t0001.jld", "t0002.jld", "t0003.jld"]
    @test length(DV.frame_files(joinpath(dir, "b", "Data"), ".jld")) == 4
    f2 = DV.load_fields(joinpath(dir, "a", "Data", "t0002.jld"), ["x", "y"])
    @test f2["x"] == a[:, 1, 2] && f2["y"] == a[:, 2, 2]

    ws = DataWorkspace(csv, ".jld")
    @test ws.changing_variable_list == ["run"]
    @test ws.all_keys == ["x", "y"] && ws.Nfiles == 4

    @testset "defaults and errors" begin
        csv2 = unstack_runs(src)                                            # temp dest, f1, f2…
        @test DV.field_keys(joinpath(dirname(csv2), "a", "Data", "t0001.jld")) == ["f1", "f2"]
        @test_throws ErrorException unstack_runs(src; fields=["only_one"])
        @test_throws ErrorException unstack_runs(src; key="nope")
        mkpath(joinpath(src, "2"))                                     # same run name twice
        jldsave(joinpath(src, "2", "a.jld"); data=a)
        @test_throws ErrorException unstack_runs(src; fields=["x", "y"])
    end

    @testset "in the app: starts in 1D, runs switch from the sidebar" begin
        s = Bonito.Session()
        d = DV.dashboard(ws, s)
        try
            @test d.dim.value[] == "1D"
            @test waitfor(() -> d.plot[] isa Makie.Figure)
            line(i) = [p[2] for p in [c for c in d.plot[].content if c isa Makie.Axis][i].scene.plots[1][1][]]
            @test waitfor(() -> line(1) == a[:, 1, 1])
            d.params[1].value[] = "b"
            @test waitfor(() -> d.pathdir[] == DV.run_path(ws, 2) && line(1) == b[:, 1, 1])
        finally
            close(s)
        end
    end
end
