# Integration tests: a Dashboard in a Bonito session (no browser). Setting a
# widget's value fires the same listeners a browser event would; we then
# wait for the debounced @async work and check what gets plotted.

const ROOT = make_dataset()
const WS   = DataWorkspace(joinpath(ROOT, "DF.csv"), ".jld")

plot_fig(d)   = d.plot[] isa Makie.Figure ? d.plot[] : nothing
heat(d)       = (f = plot_fig(d); isnothing(f) ? nothing : axis_of(f).scene.plots[1][3][])
# Makie stores heatmap data as Float32 → compare approximately.
heat_is(d, A) = (x = heat(d); x !== nothing && size(x) == size(A) && x ≈ A)
plot_kinds(d) = (f = plot_fig(d); isnothing(f) ? [] : plotfuncs(axis_of(f)))
plot_msg(d)   = dom_text(d.plot[])
# src of the <img> shown in PNG mode (nothing if the panel shows something else)
img_src(d)    = (p = d.plot[]; p isa Hyperscript.Node && Hyperscript.tag(p) == "img" ?
                 Hyperscript.attrs(p)["src"][] : nothing)

# v[:,:,1] == run index, v[:,:,2] == frame → the |v| heatmap identifies both.
vnorm(run, t) = fill(hypot(run, t), NX, NY)

function with_dashboard(f, ws=WS)
    s = Bonito.Session()
    d = DV.dashboard(ws, s)
    try
        @test waitfor(() -> plot_fig(d) !== nothing)          # initial render
        f(d)
    finally
        close(s)
    end
end

@testset "Debouncer" begin
    runs = Ref(0)
    db   = DV.Debouncer(() -> (runs[] += 1; sleep(0.2)))
    DV.schedule!(db)
    @test waitfor(() -> runs[] == 1)  # first run is busy now
    for _ in 1:9
        DV.schedule!(db)
    end
    @test waitfor(() -> !db.active)
    @test runs[] == 2                 # the nine triggers that arrived while busy → one more run

    # a throwing f doesn't leave the loop marked active
    # (errormonitor prints "UNHANDLED TASK ERROR: boom" — expected)
    bad = DV.Debouncer(() -> error("boom"))
    DV.schedule!(bad)
    @test waitfor(() -> !bad.active)

    DV.schedule!(db); DV.reset!(db)
    @test !db.pending && !db.active
end

@testset "initial state" begin
    with_dashboard() do d
        @test d.pathdir[] == DV.run_path(WS, 1)
        @test d.current_keys[] == WS.all_keys
        @test d.dim.value[] == "2D"
        @test d.colormap[] == DV.DEFAULT_CMAP
        @test d.heatmap[] == WS.all_keys[1]
        @test all(o -> o.field[] == "None", d.overlays)
        @test d.nfile.value[] == 1
        @test d.fig_base.value[] == 800
        @test [w.value[] for w in d.params] == [10.0, "polar"]
        @test all(cb -> cb.value[] == false, d.pins)
        @test d.menus[].heatmap.options[] == WS.all_keys
        @test d.menus[].colormap.value[] == DV.DEFAULT_CMAP
        @test plot_kinds(d) == [Makie.heatmap]
    end
end

@testset "plot_config reads the widgets" begin
    with_dashboard() do d
        d.nfile.value[] = 2
        d.fig_base.value[] = 600
        d.overlays[2].alpha.value[] = 0.3
        d.overlays[2].nematic.value[] = true
        cfg = DV.plot_config(d)
        @test (cfg.Ndim, cfg.nfile, cfg.cmap, cfg.heatmap, cfg.fig_base) ==
              ("2D", 2, DV.DEFAULT_CMAP, WS.all_keys[1], 600)
        @test cfg.overlays[2].alpha == 0.3 && cfg.overlays[2].nematic
        @test DV.plot_config(d; nfile=3).nfile == 3
    end
end

@testset "layout" begin
    with_dashboard() do d
        found = collect_widgets(DV.layout(d))
        for w in [d.dim, d.fig_base, d.nfile, d.params..., d.pins...,
                  d.player.button, d.reset, d.save, d.png, d.plot, d.top, d.status]
            @test contains_obj(found, w)
        end
    end
    s    = Bonito.Session()
    html = string(Bonito.session_dom(s, explor_app(WS; width="50%", height="600px", scale=0.75)))
    @test occursin("Time: ", html)
    @test occursin("Overlay 2", html)
    close(s)

    # Default page box grows with the figure: no fixed height clipping the time
    # bar, and the gutter counts inside the width (no overflow on the right).
    s    = Bonito.Session()
    html = string(Bonito.session_dom(s, explor_app(WS)))
    @test occursin("height: auto", html)
    @test occursin("box-sizing: border-box", html)
    @test occursin("overflow: visible", html)
    @test !occursin("margin: 20px", html)
    close(s)
    s    = Bonito.Session()
    html = string(Bonito.session_dom(s, explor_app(WS; height="800px")))
    @test occursin("height: 800px", html) && occursin("overflow: auto", html)
    close(s)
end

@testset "field, colormap and time controls" begin
    with_dashboard() do d
        d.menus[].heatmap.value[] = "v"
        @test waitfor(() -> heat_is(d, vnorm(1, 1)))

        d.nfile.value[] = 3
        @test waitfor(() -> heat_is(d, vnorm(1, 3)))

        d.menus[].colormap.value[] = "viridis"
        @test waitfor(() -> axis_of(plot_fig(d)).scene.plots[1].colormap[] == "viridis")

        d.fig_base.value[] = 1200
        @test waitfor(() -> Tuple(plot_fig(d).scene.viewport[].widths) == (1300, 600))
    end
end

@testset "overlays" begin
    with_dashboard() do d
        o1, o2 = d.overlays
        m1, m2 = d.menus[].overlays
        m1.value[] = "v"
        @test waitfor(() -> plot_kinds(d) == [Makie.heatmap, Makie.arrows2d])

        o1.alpha.value[] = 0.3
        @test waitfor(() -> plot_kinds(d) == [Makie.heatmap, Makie.arrows2d, Makie.image])

        m2.value[] = "Q"
        o2.nematic.value[] = true
        @test waitfor(() -> length(plot_kinds(d)) == 4 &&
                            axis_of(plot_fig(d)).scene.plots[4].tiplength[] == 0)

        m1.value[] = "None"
        @test waitfor(() -> plot_kinds(d) == [Makie.heatmap, Makie.arrows2d])

        # arrow colours: overlay 1 black and overlay 2 white by default, selectable
        @test (o1.white.value[], o2.white.value[]) == (false, true)        # black, white
        @test axis_of(plot_fig(d)).scene.plots[2].color[] == :white          # overlay 2 (Q)
        o2.white.value[] = false
        @test waitfor(() -> axis_of(plot_fig(d)).scene.plots[2].color[] == :black)
    end
end

@testset "sidebar snaps to the nearest run" begin
    with_dashboard() do d
        re, mode = d.params
        d.menus[].heatmap.value[] = "v"
        @test waitfor(() -> heat_is(d, vnorm(1, 1)))

        re.value[] = 50.0                              # (50, polar) → run_003
        @test waitfor(() -> heat_is(d, vnorm(3, 1)))
        @test d.pathdir[] == DV.run_path(WS, 3)

        mode.value[] = "nematic"                       # (50, nematic) → run_004
        @test waitfor(() -> heat_is(d, vnorm(4, 1)))

        # widgets the browser shows follow the snap (index, not just value)
        @test re.index[] == 2

        # Off-grid value snaps back onto the ensemble: Re=45 → 50
        re.value[] = 45.0
        @test waitfor(() -> re.value[] == 50.0)

        # Pinning Re keeps it while the mode moves
        d.pins[1].value[] = true
        mode.value[] = "polar"
        @test waitfor(() -> heat_is(d, vnorm(3, 1)))
        @test re.value[] == 50.0

        # Time beyond a short run's length is clamped to its last frame
        re.value[] = 10.0
        mode.value[] = "nematic"                       # run_002 has 2 frames
        d.nfile.value[] = 3
        @test waitfor(() -> heat_is(d, vnorm(2, 2)))
    end
end

@testset "rapid sidebar edits are not dropped" begin
    # Before the Debouncer, an edit made while the previous snap was pending
    # was ignored and then reverted.
    with_dashboard() do d
        re, mode = d.params
        d.menus[].heatmap.value[] = "v"
        @test waitfor(() -> heat_is(d, vnorm(1, 1)))
        re.value[]   = 50.0
        mode.value[] = "nematic"
        @test waitfor(() -> heat_is(d, vnorm(4, 1)))
        @test (re.value[], mode.value[]) == (50.0, "nematic")
    end
end

@testset "a value that only exists with other changes is kept" begin
    # Like PQ_FFT: orientation=polar only exists together with other parameter
    # values, and fn is numeric. Picking polar must move to the polar run, not
    # snap back to the nearest "none" run.
    root = mktempdir()
    df   = DataFrame(Re=[10.0, 50.0, 10.0], chi=[0.0, 0.0, 0.1],
                     orientation=["none", "polar", "none"], fn=[1, 2, 3])
    CSV.write(joinpath(root, "DF.csv"), df)
    for fn in df.fn
        mkpath(joinpath(root, string(fn), "Data"))
        write_frame(joinpath(root, string(fn), "Data", frame_name(1)), frame_fields(fn, 1))
    end
    ws = DataWorkspace(joinpath(root, "DF.csv"), ".jld")
    with_dashboard(ws) do d
        re, chi, orientation = d.params
        orientation.value[] = "polar"
        @test waitfor(() -> d.pathdir[] == DV.run_path(ws, 2))
        @test waitfor(() -> re.value[] == 50.0)
        @test re.index[] == 2                          # the browser's slider moves too
        @test orientation.value[] == "polar"
        @test orientation.option_index[] == 2

        # and back: none → nearest none run from (50, 0.0) is run 1
        orientation.value[] = "none"
        @test waitfor(() -> d.pathdir[] == DV.run_path(ws, 1))
        @test re.value[] == 10.0 && chi.value[] == 0.0

        # an explicit pin still wins over the others
        d.pins[2].value[] = true                       # pin chi
        set = DV.set_value!
        set(chi, 0.1)
        @test waitfor(() -> d.pathdir[] == DV.run_path(ws, 3))
        @test (re.value[], chi.value[], orientation.value[]) == (10.0, 0.1, "none")
    end
end

@testset "field list reloads when a run has different keys" begin
    with_dashboard() do d
        d.menus[].heatmap.value[] = "v"
        @test waitfor(() -> heat_is(d, vnorm(1, 1)))
        d.params[1].value[] = 50.0
        d.params[2].value[] = "nematic"                # run_004 also has "p"
        @test waitfor(() -> d.current_keys[] == ["Q", "p", "rho", "v"])
        @test waitfor(() -> "p" in d.menus[].heatmap.options[])
        @test d.heatmap[] == "v"                       # selection kept across the rebuild
        d.menus[].heatmap.value[] = "p"
        @test waitfor(() -> heat_is(d, fill(1.0, NX, NY)))

        # back to a run without "p": heatmap falls back to the first key
        d.params[2].value[] = "polar"
        @test waitfor(() -> d.current_keys[] == WS.all_keys)
        @test waitfor(() -> d.heatmap[] == WS.all_keys[1])
    end
end

@testset "a run change renders once, after the fields are updated" begin
    with_dashboard() do d
        renders = Ref(0)
        keys_at_render = Vector{String}[]
        f0 = d.renderer.f
        d.renderer.f = () -> (renders[] += 1; push!(keys_at_render, copy(d.current_keys[])); f0())

        d.pathdir[] = DV.run_path(WS, 4)               # run_004 has an extra field "p"
        @test waitfor(() -> renders[] >= 1 && !d.renderer.active)
        sleep(0.5)
        @test renders[] == 1
        @test keys_at_render == [["Q", "p", "rho", "v"]]   # dropdowns rebuilt before rendering
        @test "p" in d.menus[].heatmap.options[]

        d.pathdir[] = DV.run_path(WS, 3)               # same fields as before run_004
        @test waitfor(() -> renders[] >= 2 && !d.renderer.active)
        sleep(0.5)
        @test renders[] == 2
    end
end

@testset "dimension dropdown" begin
    with_dashboard() do d
        d.dim.value[] = "1D"                           # one panel per field, all selected by default
        @test waitfor(() -> d.menus1d[] !== nothing && length(d.menus1d[].fields) == length(WS.all_keys))
        @test waitfor(() -> plot_fig(d) !== nothing &&
                            count(c -> c isa Makie.Axis, plot_fig(d).content) == length(WS.all_keys))

        d.dim.value[] = "3D"                           # no 3D fields here: 2D fields, a note, no slider
        @test waitfor(() -> occursin("No 3D fields", dom_text(d.top[])))
        @test isnothing(d.zslider[])
        @test waitfor(() -> plot_kinds(d) == [Makie.heatmap])

        d.dim.value[] = "2D"
        @test waitfor(() -> plot_kinds(d) == [Makie.heatmap])
        @test contains_obj(collect_widgets(d.top[]), d.menus[].heatmap)
    end
end

axes_of(fig) = [c for c in fig.content if c isa Makie.Axis]
line_y(fig, i) = [p[2] for p in axes_of(fig)[i].scene.plots[1][1][]]   # y values of panel i

@testset "1D: profiles cut from 2D fields" begin
    with_dashboard() do d
        d.dim.value[] = "1D"
        @test waitfor(() -> d.menus1d[] !== nothing && d.menus1d[].pos isa Bonito.Slider)
        m = d.menus1d[]
        @test m.pos.values[] == collect(1:NY)                     # along x: position runs over y
        @test d.cut_pos[] == cld(NY, 2)

        # only rho: one panel, rho[:, y] of frame 1
        for (k, cb) in zip(d.current_keys[], m.fields)
            cb.value[] = k == "rho"
        end
        @test waitfor(() -> d.fields1d[] == ["rho"])
        rho = frame_fields(1, 1)["rho"]
        @test waitfor(() -> plot_fig(d) !== nothing && length(axes_of(plot_fig(d))) == 1 &&
                            line_y(plot_fig(d), 1) ≈ rho[:, cld(NY, 2)])
        fig = plot_fig(d)

        m.pos.value[] = 3                                         # move the cut → in place
        @test waitfor(() -> line_y(plot_fig(d), 1) ≈ rho[:, 3])
        @test plot_fig(d) === fig

        d.nfile.value[] = 2                                       # time → in place
        @test waitfor(() -> line_y(plot_fig(d), 1) ≈ frame_fields(1, 2)["rho"][:, 3])
        @test plot_fig(d) === fig

        m.mean.value[] = true                                     # mean over y
        @test waitfor(() -> line_y(plot_fig(d), 1) ≈ vec(sum(frame_fields(1, 2)["rho"]; dims=2)) ./ NY)

        m.mean.value[] = false
        m.axis.value[] = "y"                                      # along y: slider over x, rebuilt
        @test waitfor(() -> d.menus1d[] !== m && d.menus1d[].pos.values[] == collect(1:NX))
        @test d.cut_pos[] == cld(NX, 2)
        @test waitfor(() -> length(line_y(plot_fig(d), 1)) == NY &&
                            line_y(plot_fig(d), 1) ≈ frame_fields(1, 2)["rho"][cld(NX, 2), :])

        # a 2D vector is cut through its norm
        d.menus1d[].fields[findfirst(==("v"), d.current_keys[])].value[] = true
        @test waitfor(() -> length(axes_of(plot_fig(d))) == 2)
        @test line_y(plot_fig(d), 2) ≈ fill(hypot(1, 2), NY)
    end
end

@testset "1D: standard 1D layout" begin
    root = make_dataset_1d()
    ws   = DataWorkspace(joinpath(root, "DF.csv"), ".jld")
    @test ws.all_keys == ["u", "w"]
    with_dashboard(ws) do d
        @test d.dim.value[] == "1D"                               # only 1D fields: starts in 1D
        @test waitfor(() -> d.menus1d[] !== nothing && plot_fig(d) !== nothing &&
                            length(axes_of(plot_fig(d))) == 2)
        @test isnothing(d.menus1d[].pos)                         # nothing to cut
        @test !occursin("2D fields", dom_text(d.top[]))
        @test line_y(plot_fig(d), 1) ≈ [Float64(i + 1) for i in 1:N1]
        fig  = plot_fig(d)
        ylo1 = axes_of(fig)[1].finallimits[].origin[2]          # data from 2: limit ≈ -0.5 (5% padding)
        d.nfile.value[] = 3
        @test waitfor(() -> line_y(plot_fig(d), 1) ≈ [Float64(i + 3) for i in 1:N1])
        @test plot_fig(d) === fig
        # y limits follow the data (now from 4: limit ≈ 1.5)
        @test waitfor(() -> axes_of(plot_fig(d))[1].finallimits[].origin[2] > ylo1 + 1.5)

        d.params[1].value[] = 2.0                                 # other run, same fields → in place
        @test waitfor(() -> line_y(plot_fig(d), 1) ≈ [2 * Float64(i + 3) for i in 1:N1])
        @test plot_fig(d) === fig

        # whole-run views: the frame only moves the marker
        d.menus1d[].view.value[] = "Kymograph"
        @test waitfor(() -> d.live[] isa DV.LiveRun)
        kfig = plot_fig(d)
        @test length(axes_of(kfig)) == 2
        d.nfile.value[] = 1
        @test waitfor(() -> d.live[].frame[] == 1)
        @test plot_fig(d) === kfig
        @test axes_of(kfig)[1].scene.plots[2][1][] == 1.0
        d.menus1d[].fields[2].value[] = false                    # fewer fields → rebuilt
        @test waitfor(() -> plot_fig(d) !== kfig && length(axes_of(plot_fig(d))) == 1)
        d.menus1d[].view.value[] = "Times overlaid"
        @test waitfor(() -> d.live[] isa DV.LiveRun && d.live[].key[2] == "Times overlaid")
        d.menus1d[].view.value[] = "Profiles"
        @test waitfor(() -> d.live[] isa DV.LiveFigure)

        # 2D mode on 1D-only data: a message, not a crash
        d.dim.value[] = "2D"
        @test waitfor(() -> plot_msg(d) == "u is a 1D field — choose Dimension: 1D")
    end
end

@testset "3D: slice slider" begin
    root = make_dataset_3d()
    ws   = DataWorkspace(joinpath(root, "DF.csv"), ".jld")
    @test ws.all_keys == ["rho", "s3", "v3"]
    with_dashboard(ws) do d
        @test d.nz[] == NZ_A
        d.dim.value[] = "3D"
        @test waitfor(() -> d.zslider[] isa Bonito.Slider)
        z = d.zslider[]
        @test z.values[] == collect(1:NZ_A)
        @test contains_obj(collect_widgets(d.top[]), z)

        d.menus[].heatmap.value[] = "s3"
        # (rho is also all 1.0 at t=1: wait for the s3 figure itself)
        @test waitfor(() -> d.live[] isa DV.LiveFigure && d.live[].key[3] == "s3" &&
                            heat_is(d, fill(1.0, NX, NY)))
        fig = plot_fig(d)

        z.value[] = 5                                   # new slice → same figure, new data
        @test waitfor(() -> heat_is(d, fill(5.0, NX, NY)))
        @test plot_fig(d) === fig
        @test DV.plot_config(d).zslice == 5

        d.nfile.value[] = 2                             # time still animates in 3D
        d.menus[].heatmap.value[] = "v3"
        @test waitfor(() -> heat_is(d, fill(sqrt(1 + 4 + 25), NX, NY)))

        # run_b has only NZ_B slices: slider rebuilt, selection clamped
        d.params[1].value[] = 2.0
        @test waitfor(() -> d.nz[] == NZ_B)
        @test waitfor(() -> d.zslider[] !== z && d.zslider[].values[] == collect(1:NZ_B))
        @test d.z[] == NZ_B
        @test waitfor(() -> heat_is(d, fill(sqrt(4 + 4 + 16), NX, NY)))

        # 2D mode ignores the slice
        d.dim.value[] = "2D"
        d.menus[].heatmap.value[] = "rho"
        @test waitfor(() -> heat_is(d, fill(2.0, NX, NY)))
    end
end

@testset "render errors are shown, not thrown" begin
    with_dashboard() do d
        d.menus[].heatmap.value[] = "not_a_field"
        @test waitfor(() -> startswith(plot_msg(d), "Error"))
        d.menus[].heatmap.value[] = "rho"
        @test waitfor(() -> plot_kinds(d) == [Makie.heatmap])
    end
end

@testset "frames update the figure in place" begin
    with_dashboard() do d
        d.menus[].heatmap.value[] = "v"
        @test waitfor(() -> heat_is(d, vnorm(1, 1)))
        fig = plot_fig(d)
        @test d.live[] isa DV.LiveFigure

        d.nfile.value[] = 2                            # new frame → same figure, new data
        @test waitfor(() -> heat_is(d, vnorm(1, 2)))
        @test plot_fig(d) === fig

        d.pathdir[] = DV.run_path(WS, 3)               # other run, same fields/sizes → still in place
        @test waitfor(() -> heat_is(d, vnorm(3, 2)))
        @test plot_fig(d) === fig

        d.menus[].colormap.value[] = "viridis"         # layout change → new figure
        @test waitfor(() -> plot_fig(d) !== nothing && plot_fig(d) !== fig)
        @test axis_of(plot_fig(d)).scene.plots[1].colormap[] == "viridis"

        fig2 = plot_fig(d)
        d.overlays[1].field[] = "v"                    # overlay change → new figure
        @test waitfor(() -> plot_fig(d) !== nothing && plot_fig(d) !== fig2)
        @test plot_kinds(d) == [Makie.heatmap, Makie.arrows2d]
    end
end

@testset "arrow size updates in place; fast layout changes rebuild once" begin
    with_dashboard() do d
        o = d.overlays[1]
        d.menus[].overlays[1].value[] = "v"
        @test waitfor(() -> plot_kinds(d) == [Makie.heatmap, Makie.arrows2d])
        fig    = plot_fig(d)
        arrows = axis_of(fig).scene.plots[2]
        @test arrows.lengthscale[] == DV.arrow_scale(20, 5)

        for k in 1:15                                   # a fast drag of the arrow size
            o.arrowsize.value[] = k
            sleep(0.02)
        end
        @test waitfor(() -> arrows.lengthscale[] == DV.arrow_scale(20, 15))
        @test plot_fig(d) === fig                       # same figure, no rebuild

        builds = Ref(0)                                 # figures put on screen from now on
        on(p -> p isa Makie.Figure && p !== fig && (builds[] += 1), d.plot)
        for k in 1:20                                   # a fast drag of the arrow step (layout)
            o.stepp.value[] = [5, 10, 15, 20, 25][mod1(k, 5)]
            sleep(0.02)
        end
        @test waitfor(() -> builds[] >= 1 && !d.renderer.active)
        sleep(1)
        @test builds[] == 1                             # one rebuild, after the drag
        @test length(axis_of(plot_fig(d)).scene.plots[2][1][]) == length(1:25:NX) * length(1:25:NY)
    end
end

# put the (simulated) mouse in the middle of axis k of the figure on screen
function hover_middle!(d; k=1)
    fig = d.plot[]
    Makie.update_state_before_display!(fig)
    ax  = [c for c in fig.content if c isa Makie.Axis][k]
    vp  = ax.scene.viewport[]
    Makie.events(fig).mouseposition[] = Tuple(Float64.(vp.origin .+ vp.widths ./ 2))
end

@testset "value under the cursor" begin
    with_dashboard() do d                                 # 2D
        d.menus[].heatmap.value[] = "v"
        @test waitfor(() -> heat_is(d, vnorm(1, 1)))
        hover_middle!(d)
        @test waitfor(() -> occursin("v = (1.0, 1.0)", d.cursor[]))
        @test startswith(d.cursor[], "x = ")
        d.nfile.value[] = 2                               # new frame, mouse still → follows
        @test waitfor(() -> occursin("v = (1.0, 2.0)", d.cursor[]))
        Makie.events(d.plot[]).mouseposition[] = (1.0, 1.0)   # outside the axis
        @test waitfor(() -> d.cursor[] == "")

        d.dim.value[] = "1D"                              # 1D profiles
        @test waitfor(() -> d.live[] isa DV.LiveFigure && d.live[].key[1] == "1D")
        hover_middle!(d)
        @test waitfor(() -> startswith(d.cursor[], "x = ") && occursin("rho = ", d.cursor[]))

        d.menus1d[].view.value[] = "Kymograph"            # whole-run view
        @test waitfor(() -> d.live[] isa DV.LiveRun)
        hover_middle!(d)
        @test waitfor(() -> occursin("t = ", d.cursor[]))
        d.menus1d[].view.value[] = "Times overlaid"
        @test waitfor(() -> d.live[] isa DV.LiveRun && d.live[].key[2] == "Times overlaid")
        hover_middle!(d)
        @test waitfor(() -> occursin("t = 2.0", d.cursor[]))   # the current frame's time
    end
end

@testset "colour range over the run" begin
    root = make_dataset()
    ws   = DataWorkspace(joinpath(root, "DF.csv"), ".jld")
    hm(d) = axis_of(plot_fig(d)).scene.plots[1]
    with_dashboard(ws) do d
        d.menus[].heatmap.value[] = "rho"
        @test waitfor(() -> d.live[] isa DV.LiveFigure && d.live[].key[3] == "rho")
        @test isnothing(DV.plot_config(d).colorrange)

        d.fixed_range.value[] = true                       # computed in the background…
        @test waitfor(() -> startswith(dom_text(d.status[]), "✓ Colour range of rho"))
        @test waitfor(() -> plot_fig(d) !== nothing && collect(hm(d).colorrange[]) ≈ [3, 39])
        @test DV.plot_config(d).colorrange == (3.0, 39.0)
        fig = plot_fig(d)
        d.nfile.value[] = 3                                # …then frames keep it, in place
        @test waitfor(() -> heat_is(d, frame_fields(1, 3)["rho"]))
        @test plot_fig(d) === fig && collect(hm(d).colorrange[]) ≈ [3, 39]

        d.menus[].heatmap.value[] = "v"                    # another field: its own range
        @test waitfor(() -> plot_fig(d) !== nothing && d.live[] isa DV.LiveFigure &&
                            d.live[].key[3] == "v" && collect(hm(d).colorrange[])[2] ≈ hypot(1, 3))
        @test length(ws.run_ranges.values) == 2 && isempty(ws.run_ranges.tasks)

        s2 = Bonito.Session()                              # another tab: cached, no recomputation
        d2 = DV.Dashboard(ws, s2)
        d2.fixed_range.value[] = true
        d2.heatmap[] = "rho"
        @test DV.plot_config(d2).colorrange == (3.0, 39.0)
        close(s2)

        d.heatmap[] = "not_a_field"                        # a failure is reported, not retried
        @test waitfor(() -> startswith(dom_text(d.status[]), "⚠ Colour range of not_a_field failed"))
        @test any(==(:none), values(ws.run_ranges.values))
        d.heatmap[] = "rho"

        d.fixed_range.value[] = false                      # back to per-frame colours
        @test waitfor(() -> plot_fig(d) !== nothing && hm(d).colorrange[] isa Makie.Automatic &&
                            isnothing(DV.plot_config(d).colorrange))
    end
end

@testset "player never skips a frame" begin
    with_dashboard() do d
        shown = Int[]
        f0 = d.renderer.f
        d.renderer.f = () -> (sleep(0.15); f0(); push!(shown, d.nfile.value[]))   # slow renders
        d.player.fps.value[] = 24                      # asks for faster than we can draw
        d.player.button.value[] = true
        @test waitfor(() -> length(shown) >= 6; timeout=20)
        d.player.button.value[] = true
        @test waitfor(() -> d.player.button.content[] == "▶")
        # consecutive frames, wrapping 3 → 1: no frame was skipped
        @test all(mod1(a + 1, WS.Nfiles) == b for (a, b) in zip(shown, shown[2:end]))
    end
end

@testset "play / pause" begin
    with_dashboard() do d
        d.nfile.value[] = 2
        play = d.player.button
        play.value[] = true
        @test waitfor(() -> play.content[] == "❚❚")
        @test waitfor(() -> d.nfile.value[] == 3; timeout=10)     # continues from the current frame
        @test d.nfile.index[] == 3                                  # the browser's slider moves
        @test waitfor(() -> d.nfile.value[] == 1; timeout=10)     # wraps around
        play.value[] = true
        @test waitfor(() -> play.content[] == "▶")
        frozen = d.nfile.value[]
        sleep(1.0)
        @test d.nfile.value[] == frozen
    end
end

@testset "reset" begin
    with_dashboard() do d
        d.menus[].heatmap.value[] = "v"
        @test waitfor(() -> heat_is(d, vnorm(1, 1)))
        d.renderer.active = true                       # simulate a stuck render loop
        DV.show!(d, Bonito.DOM.div("stale"))
        d.nfile.value[] = 2                            # would be swallowed by the stuck loop
        sleep(0.3)
        @test plot_msg(d) == "stale"
        d.reset.value[] = true
        @test waitfor(() -> heat_is(d, vnorm(1, 2)))
        @test d.live[] isa DV.LiveFigure && d.live[].data[]["v"] == frame_fields(1, 2)["v"]

        # Reset while a figure is live must rebuild it, not update one that isn't shown
        old = plot_fig(d)
        d.reset.value[] = true
        @test waitfor(() -> plot_fig(d) !== nothing && plot_fig(d) !== old)
        @test !d.renderer.active
    end
end

@testset "save all + PNG mode" begin
    root = make_dataset()
    ws   = DataWorkspace(joinpath(root, "DF.csv"), ".jld")
    with_dashboard(ws) do d
        figs = DV.fig_dir(d.pathdir[])

        d.png.value[] = true
        @test waitfor(() -> d.png.content[] == "⚙ Use Field")
        @test waitfor(() -> occursin("No Fig/ folder", plot_msg(d)))

        d.save.value[] = true
        @test waitfor(() -> startswith(dom_text(d.status[]), "✓ Saved 3 files"); timeout=120)
        @test all(t -> isfile(joinpath(figs, "t000$t.png")), 1:3)

        d.nfile.value[] = 2
        @test waitfor(() -> img_src(d) == DV.png_data_uri(joinpath(figs, "t0002.png")))
        @test d.live[] isa DV.LiveImage

        # next frame: same <img>, new src (the browser swaps the picture in place)
        img = d.plot[]
        d.nfile.value[] = 1
        @test waitfor(() -> img_src(d) == DV.png_data_uri(joinpath(figs, "t0001.png")))
        @test d.plot[] === img

        rm(joinpath(figs, "t0003.png"))
        d.nfile.value[] = 3
        @test waitfor(() -> occursin("PNG not found", plot_msg(d)))
        @test isnothing(d.live[])

        d.png.value[] = true
        @test waitfor(() -> d.png.content[] == "🖼 Use PNG")
        @test waitfor(() -> plot_kinds(d) == [Makie.heatmap])
    end

    @testset "status reports failures" begin
        with_dashboard(ws) do d
            d.menus[].heatmap.value[] = "not_a_field"
            DV.save_all!(d)
            @test startswith(dom_text(d.status[]), "⚠ Saved 0 / 3 files")
            d.pathdir[] = joinpath(root, "nope")
            DV.save_all!(d)
            @test startswith(dom_text(d.status[]), "Nothing to save")
        end
    end
end

@testset "unreadable run is reported, not fatal" begin
    with_dashboard() do d
        bad = joinpath(mktempdir(), "Data")
        mkpath(bad)
        write(joinpath(bad, frame_name(1)), "not a JLD2 file")
        # the warning comes from an @async task created inside the block,
        # which inherits the test logger
        @test_logs (:warn, r"Could not read keys") match_mode=:any begin
            d.pathdir[] = bad
            @test waitfor(() -> startswith(plot_msg(d), "Error"))
        end
        @test d.current_keys[] == WS.all_keys            # unchanged
    end
end

@testset "movie and PDF buttons" begin
    root = make_dataset()
    ws   = DataWorkspace(joinpath(root, "DF.csv"), ".jld")
    with_dashboard(ws) do d
        figs = DV.fig_dir(d.pathdir[])
        d.movie.value[] = true
        @test waitfor(() -> startswith(dom_text(d.status[]), "✓ Movie saved"); timeout=120)
        @test isfile(joinpath(figs, "Q_2D.mp4"))
        d.pdf.value[] = true
        @test waitfor(() -> startswith(dom_text(d.status[]), "✓ PDF saved"); timeout=60)
        @test isfile(joinpath(figs, "t0001_Q_2D.pdf"))

        # one export at a time
        d.exporting[] = true
        DV.save_pdf!(d)
        @test startswith(dom_text(d.status[]), "An export is already running")
        d.exporting[] = false
        d.pathdir[] = joinpath(root, "nope")
        DV.save_movie!(d)
        @test startswith(dom_text(d.status[]), "No directory")
        DV.save_pdf!(d)
        @test startswith(dom_text(d.status[]), "No directory")
        @test !d.exporting[]
        d.pathdir[] = DV.run_path(ws, 1)                       # an error is reported, not lost
        d.heatmap[] = "not_a_field"
        DV.save_movie!(d)
        @test startswith(dom_text(d.status[]), "⚠ Export failed")
        @test !d.exporting[]
    end
end
