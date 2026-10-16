plotfuncs(ax) = [Makie.plotfunc(p) for p in ax.scene.plots]
axis_of(fig)  = only(c for c in fig.content if c isa Makie.Axis)
has_colorbar(fig) = any(c -> c isa Makie.Colorbar, fig.content)
new_axis() = Makie.Axis(Makie.Figure()[1, 1])

@testset "load_fields" begin
    root = make_dataset()
    path = joinpath(datadir(root, "run_001"), frame_name(2))
    ref  = frame_fields(1, 2)

    @test DV.load_fields(path, String[]) == Dict{String,Any}()

    one = DV.load_fields(path, ["rho"])
    @test collect(keys(one)) == ["rho"]
    @test one["rho"] == ref["rho"]

    two = DV.load_fields(path, ["v", "Q"])
    @test Set(keys(two)) == Set(["v", "Q"])
    @test two["v"] == ref["v"]
    @test two["Q"] == ref["Q"]

    @test_throws Exception DV.load_fields(path, ["does_not_exist"])
end

@testset "overlay_alpha!" begin
    field = reshape(collect(1.0:80.0), 10, 8)

    ax = new_axis()
    DV.overlay_alpha!(ax, field, 1.0)               # alpha = 1 → no overlay at all
    @test isempty(ax.scene.plots)

    ax = new_axis()
    DV.overlay_alpha!(ax, field, 0.0)
    @test plotfuncs(ax) == [Makie.image]
    mask = ax.scene.plots[1][3][]
    @test size(mask) == size(field)
    @test eltype(mask) == RGBA{Float32}
    @test mask[1].alpha ≈ 1                         # minimum → fully dark
    @test mask[end].alpha ≈ 0                       # maximum → transparent
    @test all(c -> c.r == 0 && c.g == 0 && c.b == 0, mask)

    ax = new_axis()
    DV.overlay_alpha!(ax, field, 0.4)               # min brightness 0.4 → max opacity 0.6
    mask = ax.scene.plots[1][3][]
    @test maximum(c.alpha for c in mask) ≈ 0.6
    @test minimum(c.alpha for c in mask) ≈ 0.0

    @testset "vector field uses the norm" begin
        v = zeros(10, 8, 2); v[:, :, 1] .= 3; v[:, :, 2] .= 4; v[1, 1, :] .= 0
        ax = new_axis()
        DV.overlay_alpha!(ax, v, 0.0)
        mask = ax.scene.plots[1][3][]
        @test size(mask) == (10, 8)
        @test mask[1, 1].alpha ≈ 1
        @test mask[2, 2].alpha ≈ 0
    end

    @testset "constant field doesn't divide by zero" begin
        ax = new_axis()
        DV.overlay_alpha!(ax, fill(2.0, 5, 5), 0.3)
        mask = ax.scene.plots[1][3][]
        @test all(c -> c.alpha ≈ 0.7, mask)
    end
end

@testset "draw_arrows!" begin
    field = zeros(20, 10, 2); field[:, :, 1] .= 1.0; field[:, :, 2] .= 2.0

    @testset "polar" begin
        ax = new_axis()
        DV.draw_arrows!(ax, field, 5, 3.0, false)
        @test plotfuncs(ax) == [Makie.arrows2d]
        p = ax.scene.plots[1]
        @test length(p[1][]) == length(1:5:20) * length(1:5:10)
        @test all(==(Point2(1.0, 2.0)), p[2][])     # directions are the raw vectors
        @test p.lengthscale[] == 3.0
        @test p.color[] == :black
    end

    @testset "nematic: headless, doubled angle, length 4|Q|" begin
        Q = zeros(20, 10, 2); Q[:, :, 1] .= 0.0; Q[:, :, 2] .= 1.0   # angle π/2 → director π/4
        ax = new_axis()
        DV.draw_arrows!(ax, Q, 10, 1.0, true)
        p = ax.scene.plots[1]
        @test p.tiplength[] == 0
        @test p.color[] == :white
        d = p[2][][1]
        @test hypot(d...) ≈ 4.0 atol=1e-5
        @test atan(d[2], d[1]) ≈ π/4 atol=1e-5
    end
end

@testset "draw_overlay!" begin
    ax = new_axis()
    DV.draw_overlay!(ax, rand(10, 8), overlay(; alpha=0.5, stepp=2))          # scalar: mask only
    @test plotfuncs(ax) == [Makie.image]

    ax = new_axis()
    DV.draw_overlay!(ax, rand(10, 8, 2), overlay(; alpha=0.5, stepp=2))       # vector: arrows + mask
    @test plotfuncs(ax) == [Makie.arrows2d, Makie.image]

    ax = new_axis()
    DV.draw_overlay!(ax, rand(10, 8, 2), overlay(; stepp=2, nematic=true))    # alpha = 1: arrows only
    @test plotfuncs(ax) == [Makie.arrows2d]
    @test ax.scene.plots[1].tiplength[] == 0
end

@testset "heatmap_field" begin
    s = rand(4, 3)
    @test DV.heatmap_field(s) === s
    v = cat(fill(3.0, 4, 3), fill(4.0, 4, 3); dims=3)
    @test DV.heatmap_field(v) == fill(5.0, 4, 3)
end

@testset "frame files" begin
    root = make_dataset()
    dir  = datadir(root, "run_001")

    @test DV.frame_files(dir, ".jld") == frame_name.(1:3)
    @test DV.frame_files(joinpath(root, "nope"), ".jld") == String[]        # no throw
    @test DV.frame_path(dir, 2, ".jld")  == joinpath(dir, frame_name(2))
    @test DV.frame_path(dir, 99, ".jld") == joinpath(dir, frame_name(3))   # clamped
    @test DV.frame_path(dir, 0, ".jld")  == joinpath(dir, frame_name(1))
    @test isnothing(DV.frame_path(dir, 1, ".h5"))
    @test DV.field_keys(joinpath(dir, frame_name(1))) == ["Q", "rho", "v"]
    @test DV.field_keys(joinpath(datadir(root, "run_004"), frame_name(1))) == ["Q", "p", "rho", "v"]

    @test DV.fig_dir(dir * "/") == joinpath(root, "run_001", "Fig")
    @test DV.fig_dir(dir) == joinpath(root, "run_001", "Fig")
    @test DV.png_path(dir, joinpath(dir, "t0002.jld")) == joinpath(root, "run_001", "Fig", "t0002.png")
end

@testset "load_frame" begin
    root = make_dataset()
    dir  = datadir(root, "run_001")

    @test occursin("No directory", DV.load_frame(joinpath(root, "nope"), test_config(), ".jld"))
    @test occursin("No files",     DV.load_frame(dir, test_config(), ".h5"))
    @test occursin("No fields",    DV.load_frame(dir, test_config(; heatmap="None"), ".jld"))

    data = DV.load_frame(dir, test_config(; nfile=2, overlays=[overlay(; field="v"), overlay(; field="rho")]), ".jld")
    @test Set(keys(data)) == Set(["rho", "v"])          # each key loaded once
    @test data["v"] == frame_fields(1, 2)["v"]
end

@testset "plot_frame" begin
    data = frame_fields(1, 2)

    @testset "scalar heatmap" begin
        fig = DV.plot_frame(data, test_config())
        @test fig isa Makie.Figure
        @test has_colorbar(fig)
        ax = axis_of(fig)
        @test plotfuncs(ax) == [Makie.heatmap]
        @test ax.scene.plots[1][3][] == data["rho"]
        @test ax.scene.plots[1].colormap[] == "viridis"
    end

    @testset "figure size follows field aspect ratio and fig_base" begin
        fig = DV.plot_frame(data, test_config(; fig_base=480))
        # NX=24, NY=12 → scale 20 → (480 + 100 for the colorbar, 240)
        @test Tuple(fig.scene.viewport[].widths) == (580, 240)
    end

    @testset "vector heatmap shows the norm" begin
        fig = DV.plot_frame(data, test_config(; heatmap="v"))
        @test axis_of(fig).scene.plots[1][3][] ≈ fill(hypot(1, 2), NX, NY)
    end

    @testset "overlays" begin
        cfg = test_config(; overlays=[overlay(; field="v", alpha=0.5),
                                      overlay(; field="Q", nematic=true)])
        ax  = axis_of(DV.plot_frame(data, cfg))
        @test plotfuncs(ax) == [Makie.heatmap, Makie.arrows2d, Makie.image, Makie.arrows2d]
        @test ax.scene.plots[2].color[] == :black
        @test ax.scene.plots[4].color[] == :white

        ax = axis_of(DV.plot_frame(data, test_config(; overlays=[overlay(; field="rho", alpha=0.0)])))
        @test plotfuncs(ax) == [Makie.heatmap, Makie.image]

        ax = axis_of(DV.plot_frame(data, test_config(; overlays=DV.OverlayConfig[])))
        @test plotfuncs(ax) == [Makie.heatmap]
    end

    @testset "1D: profile panels" begin
        cfg = test_config(; Ndim="1D", fig_base=300, fields1d=["rho", "v"], cut_pos=2)
        fig = DV.plot_frame(DV.reduce_frame(data, cfg), cfg)
        @test count(c -> c isa Makie.Axis, fig.content) == 2
        @test Tuple(fig.scene.viewport[].widths) == (400, 60 + 2 * 75)        # panel = fig_base/4
        @test DV.panel_height(test_config(; fig_base=800)) == 200
        @test DV.panel_height(test_config(; fig_base=800, view1d="Kymograph")) == 300
        @test DV.panel_height(test_config(; fig_base=800, view1d="Times overlaid")) == 220
    end

    @testset "wrong-dimension fields are a message, not a crash" begin
        d4 = Dict{String,Any}("v3" => rand(6, 4, 3, 3), "u" => rand(6), "rho" => rand(6, 4))
        @test DV.plot_frame(d4, test_config(; heatmap="v3")) == "v3 is a 3D field — choose Dimension: 3D"
        @test DV.plot_frame(d4, test_config(; heatmap="u")) == "u is a 1D field — choose Dimension: 1D"
        @test DV.plot_frame(d4, test_config(; overlays=[overlay(; field="v3")])) ==
              "v3 is a 3D field — choose Dimension: 3D"
    end

    @testset "unknown dimension is a message, not a crash" begin
        @test DV.plot_frame(data, test_config(; Ndim="4D")) == "4D view not implemented yet"
    end
end

@testset "field_view" begin
    root = make_dataset()
    dir  = datadir(root, "run_001")
    @test occursin("No directory", DV.field_view(joinpath(root, "nope"), test_config(), ".jld"))
    @test DV.field_view(dir, test_config(; Ndim="4D"), ".jld") == "4D view not implemented yet"
    heat(n) = axis_of(DV.field_view(dir, test_config(; nfile=n), ".jld")).scene.plots[1][3][]
    @test heat(2)  == frame_fields(1, 2)["rho"]
    @test heat(99) == frame_fields(1, 3)["rho"]
    @test heat(-5) == frame_fields(1, 1)["rho"]
    @test_throws Exception DV.field_view(dir, test_config(; heatmap="not_a_field"), ".jld")
end

@testset "field_shapes: numeric arrays only" begin
    path = joinpath(mktempdir(), "f.jld")
    jldopen(path, "w") do f
        f["rho"] = rand(4, 3)
        f["v"]   = rand(4, 3, 2)
        f["name"] = "not a field"
        f["n"]    = 7                                    # a number, not an array
        f["_creator/JULIA_VERSION"] = "1.12"             # metadata group, as in MT / P_IBM files
    end
    @test DV.field_shapes(path) == Dict("rho" => (4, 3), "v" => (4, 3, 2))
    @test DV.field_keys(path) == ["rho", "v"]
end

@testset "3D slicing" begin
    @testset "depth / nslices" begin
        @test DV.depth((8, 8)) == 1
        @test DV.depth((8, 8, 2)) == 1                   # 2D vector
        @test DV.depth((8, 8, 5)) == 5                   # 3D scalar / stack
        @test DV.depth((8, 8, 5, 3)) == 5                # 3D vector
        @test DV.nslices(Dict("a" => (8, 8), "b" => (8, 8, 7), "c" => (8, 8, 4, 3))) == 7
        @test DV.nslices(Dict("a" => (8, 8))) == 1
        @test DV.nslices(Dict{String,Tuple}()) == 1
    end

    s3 = [Float64(z) for i in 1:4, j in 1:3, z in 1:5]
    v3 = cat(fill(1.0, 4, 3, 5), fill(2.0, 4, 3, 5), s3; dims=4)
    @testset "slice_field" begin
        @test DV.slice_field(s3, 2) == fill(2.0, 4, 3)
        @test DV.slice_field(s3, 99) == fill(5.0, 4, 3)  # clamped
        @test DV.slice_field(s3, 0) == fill(1.0, 4, 3)
        sv = DV.slice_field(v3, 3)
        @test size(sv) == (4, 3, 3) && sv[1, 1, :] == [1.0, 2.0, 3.0]
        v2 = rand(4, 3, 2); s2 = rand(4, 3)
        @test DV.slice_field(v2, 3) === v2               # 2D vector untouched
        @test DV.slice_field(s2, 3) === s2
    end

    @testset "slice_frame only in 3D" begin
        data = Dict{String,Any}("s3" => s3, "rho" => rand(4, 3))
        @test DV.slice_frame(data, test_config(; Ndim="2D", zslice=2)) === data
        sl = DV.slice_frame(data, test_config(; Ndim="3D", zslice=2))
        @test sl["s3"] == fill(2.0, 4, 3) && sl["rho"] === data["rho"]
    end

    @testset "plot of a 3D vector slice" begin
        data = DV.slice_frame(Dict{String,Any}("v3" => v3), test_config(; Ndim="3D", zslice=4))
        cfg  = test_config(; Ndim="3D", heatmap="v3", overlays=[overlay(; field="v3", stepp=2)])
        ax   = axis_of(DV.plot_frame(data, cfg))
        @test ax.scene.plots[1][3][] ≈ fill(sqrt(1 + 4 + 16), 4, 3)   # full norm, z included
        @test all(==(Point2(1.0, 2.0)), ax.scene.plots[2][2][])      # arrows: in-plane x, y
    end

    @testset "field_view / export in 3D" begin
        root = make_dataset_3d()
        dir  = datadir(root, "run_a")
        cfg  = test_config(; Ndim="3D", heatmap="s3", zslice=3)
        @test axis_of(DV.field_view(dir, cfg, ".jld")).scene.plots[1][3][] == fill(3.0, NX, NY)
        @test DV.save_frames(dir, cfg, ".jld") == (2, 2)
    end
end

@testset "1D profiles" begin
    g = [10.0 * i + j for i in 1:4, j in 1:3]              # g[i, j]
    cfgx(; kw...) = test_config(; Ndim="1D", cut_axis="x", kw...)
    cfgy(; kw...) = test_config(; Ndim="1D", cut_axis="y", kw...)

    @testset "profile" begin
        u = rand(7)
        @test DV.profile(u, cfgx()) === u                   # 1D: as is
        @test DV.profile(g, cfgx(; cut_pos=2)) == g[:, 2]   # along x at y=2
        @test DV.profile(g, cfgx(; cut_pos=99)) == g[:, 3]  # clamped
        @test DV.profile(g, cfgy(; cut_pos=3)) == g[3, :]   # along y at x=3
        @test DV.profile(g, cfgx(; cut_mean=true)) ≈ vec(sum(g; dims=2)) / 3
        @test DV.profile(g, cfgy(; cut_mean=true)) ≈ vec(sum(g; dims=1)) / 4
        v = cat(fill(3.0, 4, 3), fill(4.0, 4, 3); dims=3)
        @test DV.profile(v, cfgx(; cut_pos=1)) == fill(5.0, 4)          # 2D vector → norm
        @test isnothing(DV.profile(rand(4, 3, 5), cfgx()))              # 3D: no profile
    end

    @testset "cut_length / is_2d" begin
        shapes = Dict("a" => (40, 20), "v" => (40, 20, 2), "u" => (40,), "s" => (40, 20, 5))
        @test DV.cut_length(shapes, "x") == 20
        @test DV.cut_length(shapes, "y") == 40
        @test DV.cut_length(Dict("u" => (40,)), "x") == 0
        @test DV.is_2d((4, 3)) && DV.is_2d((4, 3, 2)) && !DV.is_2d((4,)) && !DV.is_2d((4, 3, 5))
    end

    @testset "profiles_frame / reduce_frame" begin
        data = Dict{String,Any}("g" => g, "u" => rand(4), "s" => rand(4, 3, 5))
        p = DV.profiles_frame(data, cfgx(; fields1d=["g", "u", "s", "missing"], cut_pos=1))
        @test Set(keys(p)) == Set(["g", "u"])               # 3D and missing fields dropped
        @test p["g"] == g[:, 1]
        @test DV.reduce_frame(data, cfgx(; fields1d=["g"])) == Dict("g" => g[:, 1])
        @test DV.reduce_frame(data, test_config(; Ndim="2D")) === data
    end

    @testset "plot_profiles" begin
        data = Observable{Dict{String,Any}}(Dict("a" => [1.0, 2.0, 3.0], "b" => [5.0, 5.0, 6.0]))
        cfg  = cfgx(; fields1d=["b", "a"])
        fig  = DV.plot_frame(data, cfg)
        axs  = [c for c in fig.content if c isa Makie.Axis]
        @test length(axs) == 2
        @test [ax.ylabel[] for ax in axs] == ["b", "a"]     # order of fields1d
        @test [p[2] for p in axs[2].scene.plots[1][1][]] == [1.0, 2.0, 3.0]
        data[] = Dict("a" => [10.0, 20.0, 30.0], "b" => [0.0, 0.0, 1.0])
        @test [p[2] for p in axs[2].scene.plots[1][1][]] == [10.0, 20.0, 30.0]
        @test axs[2].finallimits[].origin[2] > 5           # y limits followed the new data
        @test DV.plot_frame(Dict{String,Any}(), cfgx(; fields1d=["a"])) == "No 1D or 2D field selected"
    end

    @testset "frame_times" begin
        root = make_dataset_1d()
        @test DV.frame_times(datadir(root, "r1"), ".jld") == [1.0, 2.0, 3.0]   # t0001 … t0003
        dir = mktempdir()
        foreach(n -> touch(joinpath(dir, n)), ["a.jld", "b.jld"])
        @test DV.frame_times(dir, ".jld") == [1.0, 2.0]                        # not numbers: index
        foreach(n -> touch(joinpath(dir, n)), ["x1.jld", "y1.jld"])
        @test DV.frame_times(dir, ".jld") == [1.0, 2.0, 3.0, 4.0]              # duplicates: index
    end

    @testset "run_profiles / plot_run" begin
        root = make_dataset_1d()
        dir  = datadir(root, "r1")
        cfg  = test_config(; Ndim="1D", fields1d=["u", "w"], view1d="Kymograph", nfile=2)
        run  = DV.run_profiles(dir, cfg, ".jld")
        @test run.names == ["u", "w"] && run.times == [1.0, 2.0, 3.0]
        @test size(run.fields["u"]) == (N1, 3)
        @test run.fields["u"][:, 2] == [Float64(i + 2) for i in 1:N1]
        @test DV.run_profiles(joinpath(root, "nope"), cfg, ".jld") == "No directory: $(joinpath(root, "nope"))"
        @test DV.run_profiles(dir, cfg, ".h5") == "No files in: $dir"
        @test DV.run_profiles(dir, DV.with(cfg; fields1d=String[]), ".jld") == "No fields selected"

        # kymograph: one heatmap (x × t) per field, marker at the current frame
        frame = Observable(2)
        fig   = DV.plot_run(run, cfg; frame)
        axs   = [c for c in fig.content if c isa Makie.Axis]
        @test length(axs) == 2 && count(c -> c isa Makie.Colorbar, fig.content) == 2
        @test axs[1].scene.plots[1][3][] == run.fields["u"]
        marker = axs[1].scene.plots[2]
        @test marker[1][] == 2.0
        frame[] = 3
        @test marker[1][] == 3.0                                     # moved in place

        # times overlaid: every frame coloured by time + the current one in black
        cfg2 = DV.with(cfg; view1d="Times overlaid")
        fig2 = DV.plot_run(run, cfg2; frame)
        ax2  = [c for c in fig2.content if c isa Makie.Axis][1]
        @test length(ax2.scene.plots) == 3 + 1
        @test [p[2] for p in ax2.scene.plots[end][1][]] == run.fields["u"][:, 3]
        @test DV.plot_run("a message", cfg) == "a message"

        # export: one image per frame, with the marker
        @test DV.save_frames(dir, cfg, ".jld") == (3, 3)
        @test DV.run_view(cfg) && !DV.run_view(DV.with(cfg; view1d="Profiles"))
        @test DV.field_view(dir, cfg, ".jld") isa Makie.Figure
    end

    @testset "load_frame / export in 1D" begin
        root = make_dataset_1d()
        dir  = datadir(root, "r1")
        cfg  = test_config(; Ndim="1D", fields1d=["u"], nfile=2)
        @test collect(keys(DV.load_frame(dir, cfg, ".jld"))) == ["u"]
        @test DV.load_frame(dir, test_config(; Ndim="1D", fields1d=String[]), ".jld") == "No fields selected"
        @test DV.save_frames(dir, cfg, ".jld") == (3, 3)
    end
end

@testset "downsample" begin
    A = reshape(Float64.(1:24), 6, 4)
    @test DV.downsample(A, 10) === A                     # small enough: untouched
    B = DV.downsample(A, 3)                              # factor 2
    @test size(B) == (3, 2)
    @test B[1, 1] ≈ (A[1,1] + A[2,1] + A[1,2] + A[2,2]) / 4
    C = DV.downsample(rand(7, 5), 3)                     # factor 3, partial edge blocks
    @test size(C) == (3, 2)
    big = rand(2000, 1000)
    @test maximum(size(DV.downsample(big, 400))) <= 400
    @test sum(DV.downsample(big, 400)) / length(DV.downsample(big, 400)) ≈ sum(big) / length(big) rtol=1e-2
    @test DV.edges(10, 5) == range(0.5, 10.5; length=6)
end

@testset "plot_frame caps the resolution sent to the browser" begin
    data = Dict{String,Any}("rho" => rand(2000, 1000), "v" => rand(2000, 1000, 2))
    cfg  = test_config(; fig_base=400, overlays=[overlay(; field="v", alpha=0.5, stepp=100)])
    ax   = axis_of(DV.plot_frame(data, cfg; max_cells=400))
    @test size(ax.scene.plots[1][3][]) == (400, 200)                 # heatmap
    @test size(ax.scene.plots[3][3][]) == (400, 200)                 # mask
    @test length(ax.scene.plots[2][1][]) == length(1:100:2000) * length(1:100:1000)
    # still spans the full grid, so arrows stay aligned
    @test first(ax.scene.plots[1][1][]) == 0.5 && last(ax.scene.plots[1][1][]) == 2000.5
    # export path: no cap
    @test size(axis_of(DV.plot_frame(data, cfg)).scene.plots[1][3][]) == (2000, 1000)
end

@testset "plot_frame from an Observable updates in place" begin
    data = Observable{Dict{String,Any}}(frame_fields(1, 1))
    cfg  = test_config(; overlays=[overlay(; field="v", alpha=0.3),
                                   overlay(; field="Q", nematic=true)])
    fig  = DV.plot_frame(data, cfg)
    ax   = axis_of(fig)
    hm, arr, mask = ax.scene.plots[1:3]
    before_mask = copy(mask[3][])
    data[] = frame_fields(3, 2)
    @test hm[3][] == frame_fields(3, 2)["rho"]
    @test all(==(Point2(3.0, 2.0)), arr[2][])                         # v = (run, t)
    @test axis_of(fig) === ax && length(ax.scene.plots) == 4          # same plots, new data
    @test mask[3][] isa Matrix{RGBA{Float32}}
end

@testset "PNG lookup" begin
    root = make_dataset()
    dir  = datadir(root, "run_001")
    cfg  = test_config(; nfile=2)
    @test DV.png_file(dir, cfg, ".jld").msg == "No Fig/ folder found — save images first"
    mkpath(DV.fig_dir(dir))
    @test DV.png_file(dir, cfg, ".jld").msg == "PNG not found — save images first"
    png = joinpath(DV.fig_dir(dir), "t0002.png")
    DV.Cairo.save(png, DV.plot_frame(frame_fields(1, 2), cfg))
    @test DV.png_file(dir, cfg, ".jld") == (file=png, msg=nothing)
    @test DV.png_file(dir, test_config(; nfile=1), ".jld").msg == "PNG not found — save images first"
    @test DV.png_file(dir, cfg, ".h5").msg == "No Fig/ folder found — save images first"

    uri = DV.png_data_uri(png)
    @test startswith(uri, "data:image/png;base64,")
    @test DV.base64decode(uri[length("data:image/png;base64,")+1:end]) == read(png)
    img = DV.png_img(Observable(uri))
    @test Hyperscript.tag(img) == "img"
end

@testset "save_frames" begin
    root = make_dataset()
    dir  = datadir(root, "run_001")
    cfg  = test_config(; overlays=[overlay(; field="v", alpha=0.5), overlay()])

    progress = Tuple{Int,Int}[]
    @test DV.save_frames((i, N) -> push!(progress, (i, N)), dir, cfg, ".jld") == (3, 3)
    @test progress == [(1, 3), (2, 3), (3, 3)]
    pngs = joinpath.(DV.fig_dir(dir), ["t0001.png", "t0002.png", "t0003.png"])
    @test all(isfile, pngs)

    # Saved images have the live view's aspect ratio (NX:NY = 2:1, + colorbar)
    img = DV.FileIO.load(pngs[1])
    @test size(img, 2) > size(img, 1)

    @test DV.save_frames(joinpath(root, "nope"), cfg, ".jld") == (0, 0)
    @test DV.save_frames(dir, cfg, ".h5") == (0, 0)

    # Frames that cannot be drawn are counted, not fatal
    @test DV.save_frames(dir, test_config(; heatmap="not_a_field"), ".jld") == (0, 3)
    @test DV.save_frames(dir, test_config(; Ndim="4D"), ".jld") == (0, 3)
end
