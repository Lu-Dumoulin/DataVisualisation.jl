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
        d.dim.value[] = "1D"
        @test waitfor(() -> count(w -> w isa Bonito.Checkbox, collect_widgets(d.top[])) == length(WS.all_keys))
        @test waitfor(() -> plot_fig(d) !== nothing && isempty(plot_fig(d).content))

        d.dim.value[] = "3D"
        @test waitfor(() -> isempty(collect_widgets(d.top[])))
        @test waitfor(() -> plot_msg(d) == "3D view not implemented yet")

        d.dim.value[] = "2D"
        @test waitfor(() -> plot_kinds(d) == [Makie.heatmap])
        @test contains_obj(collect_widgets(d.top[]), d.menus[].heatmap)
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
        d.plot[] = Bonito.DOM.div("stale")
        d.nfile.value[] = 2                            # would be swallowed by the stuck loop
        sleep(0.3)
        @test plot_msg(d) == "stale"
        d.reset.value[] = true
        @test waitfor(() -> heat_is(d, vnorm(1, 2)))
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
        @test waitfor(() -> plot_kinds(d) == [Makie.image])

        rm(joinpath(figs, "t0003.png"))
        d.nfile.value[] = 3
        @test waitfor(() -> occursin("PNG not found", plot_msg(d)))

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
