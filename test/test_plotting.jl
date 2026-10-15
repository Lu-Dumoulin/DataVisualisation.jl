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

    @testset "1D placeholder" begin
        fig = DV.plot_frame(data, test_config(; Ndim="1D", fig_base=300))
        @test fig isa Makie.Figure
        @test isempty(fig.content)              # TODO in source: nothing drawn yet
        @test Tuple(fig.scene.viewport[].widths) == (400, 400)
    end

    @testset "3D is a message, not a crash" begin
        @test DV.plot_frame(data, test_config(; Ndim="3D")) == "3D view not implemented yet"
    end
end

@testset "field_view" begin
    root = make_dataset()
    dir  = datadir(root, "run_001")
    @test occursin("No directory", DV.field_view(joinpath(root, "nope"), test_config(), ".jld"))
    @test DV.field_view(dir, test_config(; Ndim="3D"), ".jld") == "3D view not implemented yet"
    heat(n) = axis_of(DV.field_view(dir, test_config(; nfile=n), ".jld")).scene.plots[1][3][]
    @test heat(2)  == frame_fields(1, 2)["rho"]
    @test heat(99) == frame_fields(1, 3)["rho"]
    @test heat(-5) == frame_fields(1, 1)["rho"]
    @test_throws Exception DV.field_view(dir, test_config(; heatmap="not_a_field"), ".jld")
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
    @test DV.save_frames(dir, test_config(; Ndim="3D"), ".jld") == (0, 3)
end
