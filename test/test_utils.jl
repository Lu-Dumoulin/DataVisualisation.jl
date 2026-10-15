@testset "col_range" begin
    df = DataFrame(a=[1.0, 4.0, 2.5], b=[3, 3, 3], s=["x", "y", "x"])
    @test DV.col_range(df, "a") == 3.0
    @test DV.col_range(df, "b") == 1.0          # constant column → 1, never 0
    @test DV.col_range(df, "s") == 1.0          # strings → unit distance
end

@testset "find_closest_row" begin
    df     = copy(FIXTURE_DF)
    vars   = ["Re", "mode"]
    ranges = [DV.col_range(df, v) for v in vars]
    none   = [false, false]

    @testset "exact match" begin
        for r in 1:nrow(df)
            @test DV.find_closest_row(df, vars, ranges, [df.Re[r], df.mode[r]], none) == r
        end
    end

    @testset "numeric snapping uses normalised distance" begin
        @test DV.find_closest_row(df, vars, ranges, [12.0, "nematic"], none) == 2
        @test DV.find_closest_row(df, vars, ranges, [45.0, "polar"],   none) == 3
        # integer widget value against a Float64 column
        @test DV.find_closest_row(df, vars, ranges, [50, "nematic"],   none) == 4
    end

    @testset "ties resolve to the first row" begin
        @test DV.find_closest_row(df, vars, ranges, [30.0, "nematic"], none) == 2
    end

    @testset "pinned parameter wins over unpinned ones" begin
        # Holes in parameter space: (50, "a") does not exist.
        holes  = DataFrame(Re=[10.0, 50.0], mode=["a", "b"], fn=["r1", "r2"])
        rg     = [DV.col_range(holes, v) for v in vars]
        @test DV.find_closest_row(holes, vars, rg, [50.0, "a"], [false, true]) == 1
        @test DV.find_closest_row(holes, vars, rg, [50.0, "a"], [true, false]) == 2
        # Both pinned on a hole: still returns a row (never empty)
        @test DV.find_closest_row(holes, vars, rg, [50.0, "a"], [true, true]) in (1, 2)
    end

    @testset "normalisation: large-magnitude column doesn't dominate" begin
        d  = DataFrame(big=[0.0, 1000.0, 0.0], small=[0.0, 0.0, 1.0], fn=["a", "b", "c"])
        vs = ["big", "small"]
        rg = [DV.col_range(d, v) for v in vs]
        # 400/1000 = 0.4 on big vs 0.9 on small → row 1 (big=0, small=0)
        @test DV.find_closest_row(d, vs, rg, [400.0, 0.1], [false, false]) == 1
        @test DV.find_closest_row(d, vs, rg, [400.0, 0.9], [false, false]) == 3
    end

    @testset "W_PIN dominates any unpinned distance" begin
        @test DV.W_PIN > 2 * length(vars)   # max unpinned contribution is 1 per column
    end
end

@testset "snap" begin
    root = make_dataset()
    ws   = DataWorkspace(joinpath(root, "DF.csv"), ".jld")
    @test DV.snap(ws, [45.0, "nematic"], [false, false]) == (4, [50.0, "nematic"])
    @test DV.snap(ws, [10.0, "polar"],   [false, false]) == (1, [10.0, "polar"])
    # values keep the widget's type
    idx, vals = DV.snap(ws, [45, "polar"], [false, false])
    @test idx == 3 && vals == [50, "polar"] && vals[1] isa Int
end

@testset "mysplitpath" begin
    @test DV.mysplitpath("/a/b/DF.csv") == ("/a/b/", "DF.csv")
    @test joinpath(DV.mysplitpath("/a/b/DF.csv")...) == "/a/b/DF.csv"
    # A bare file name stays relative to the cwd, not "/DF.csv".
    @test DV.mysplitpath("DF.csv") == ("./", "DF.csv")
    @test normpath(joinpath(DV.mysplitpath("DF.csv")...)) == "DF.csv"
    @test DV.mysplitpath("sub/DF.csv") == ("sub/", "DF.csv")
end

@testset "directory scanning" begin
    root = mktempdir()
    for d in ("runA/Data", "runB/Data", "runC/Other", ".hidden/Data", "empty")
        mkpath(joinpath(root, d))
    end
    touch.(joinpath.(root, ["runA/Data/t1.jld", "runA/Data/t2.jld",
                            "runB/Data/t1.jld", "runB/Data/t1.jld2",
                            "runC/Other/x.gif", ".hidden/Data/t1.jld"]))

    @testset "get_all_dir_ext" begin
        dirs = DV.get_all_dir_ext(root; ext=".jld")
        @test sort(dirs) == joinpath.(root, ["runA/Data", "runB/Data"])
        @test length(dirs) == length(unique(dirs))           # one entry per dir

        with_hidden = DV.get_all_dir_ext(root; ext=".jld", hidden=true)
        @test joinpath(root, ".hidden/Data") in with_hidden
        @test isempty(DV.get_all_dir_ext(joinpath(root, "empty"); ext=".jld"))
    end

    @testset "get_all_ext" begin
        files = DV.get_all_ext(root; ext=".jld")
        @test sort(files) == joinpath.(root, ["runA/Data/t1.jld", "runA/Data/t2.jld", "runB/Data/t1.jld"])
        @test DV.get_all_ext(root; ext=".gif") == [joinpath(root, "runC/Other/x.gif")]
        @test length(DV.get_all_ext(root; ext=".jld", hidden=true)) == 4
    end

    @testset "readdir_ext" begin
        @test DV.readdir_ext(joinpath(root, "runA/Data"), ".jld") == ["t1.jld", "t2.jld"]
        @test DV.readdir_ext(joinpath(root, "runB/Data"), ".jld") == ["t1.jld"]     # not .jld2
        @test DV.readdir_ext(joinpath(root, "runB/Data"), ".jld2") == ["t1.jld2"]
    end

    @testset "dotted parent directory is not 'hidden'" begin
        # `contains(root, ".")` tests the whole path, so any dot anywhere
        # (e.g. ~/Data/sweep_v1.2/) silently hides every run.
        dotted = joinpath(mktempdir(), "sweep_v1.2")
        mkpath(joinpath(dotted, "run/Data"))
        touch(joinpath(dotted, "run/Data/t1.jld"))
        @test DV.get_all_dir_ext(dotted; ext=".jld") == [joinpath(dotted, "run/Data")]
        @test DV.get_all_ext(dotted; ext=".jld") == [joinpath(dotted, "run/Data/t1.jld")]
        # a dot inside a run folder's name doesn't hide it either
        mkpath(joinpath(dotted, "Re_1.5/Data"))
        touch(joinpath(dotted, "Re_1.5/Data/t1.jld"))
        @test joinpath(dotted, "Re_1.5/Data") in DV.get_all_dir_ext(dotted; ext=".jld")
    end

    @testset "in_hidden_dir" begin
        @test !DV.in_hidden_dir("/a/b", "/a/b")
        @test !DV.in_hidden_dir("/x.y/b/c", "/x.y/b")
        @test  DV.in_hidden_dir("/a/b/.git/objects", "/a/b")
        @test  DV.in_hidden_dir("/a/b/.hidden", "/a/b")
        @test !DV.in_hidden_dir("/a/b/run_1.5/Data", "/a/b")
    end
end
