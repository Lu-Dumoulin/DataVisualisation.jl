@testset "PlotConfig" begin
    cfg = test_config(; nfile=2, overlays=[overlay(; field="v", nematic=true)])
    @test cfg.nfile == 2
    @test cfg.overlays[1].field == "v"
    @test cfg.overlays[1].nematic
    @test cfg.fig_base == 400
    @test cfg.zslice == 1
    # Every field is required — a missing keyword is an error, not a silent default.
    @test_throws UndefKeywordError DV.PlotConfig(; Ndim="2D")
    @test_throws UndefKeywordError DV.OverlayConfig(; field="v")

    @testset "with" begin
        c2 = DV.with(cfg; nfile=5, cmap="RdPu")
        @test c2.nfile == 5 && c2.cmap == "RdPu"
        @test all(getfield(c2, f) == getfield(cfg, f)
                  for f in fieldnames(DV.PlotConfig) if f ∉ (:nfile, :cmap))
        @test cfg.nfile == 2                               # original untouched
        @test all(getfield(DV.with(cfg), f) == getfield(cfg, f) for f in fieldnames(DV.PlotConfig))
    end
end

@testset "DataWorkspace" begin
    root = make_dataset()
    ws   = DataWorkspace(joinpath(root, "DF.csv"), ".jld")

    @test ws.dir == root * "/"
    @test ws.name_csv == "DF.csv"
    @test ws.ext == ".jld"
    @test ws.df == FIXTURE_DF

    @testset "parameter lists" begin
        @test ws.var_list == ["Re", "mode", "c"]                 # fn excluded
        @test ws.tab_list == Any[[10.0, 50.0], ["nematic", "polar"], [1]]
        @test ws.changing_variable_list == ["Re", "mode"]        # constant c dropped
        @test ws.N_changing == 2
        @test ws.ranges == [40.0, 1.0]
    end

    @testset "run discovery" begin
        @test sort(ws.all_dir) == [datadir(root, fn) for fn in FIXTURE_DF.fn]
        @test ws.Nfiles == 3                                     # max over runs
        @test ws.all_keys == ["Q", "rho", "v"]                   # sorted, from first run
    end

    @testset "colormaps" begin
        @test issorted(ws.all_cmaps)
        @test "viridis" in ws.all_cmaps
        @test DV.DEFAULT_CMAP in ws.all_cmaps
    end

    @testset "run_path" begin
        @test DV.run_path(ws, 1) == joinpath(root, "run_001", "Data") * "/"
        @test DV.run_path(ws, 4) == joinpath(root, "run_004", "Data") * "/"
    end

    @testset "fn column in any position" begin
        r2 = mktempdir()
        make_dataset(r2)
        CSV.write(joinpath(r2, "DF.csv"), select(FIXTURE_DF, :fn, :))
        ws2 = DataWorkspace(joinpath(r2, "DF.csv"), ".jld")
        @test ws2.changing_variable_list == ["Re", "mode"]
    end

    @testset "errors" begin
        @test_throws Exception DataWorkspace(joinpath(root, "missing.csv"), ".jld")
        # CSV present but no output files with that extension
        @test_throws ErrorException("No *.h5 files found under $root/") DataWorkspace(joinpath(root, "DF.csv"), ".h5")
    end
end
