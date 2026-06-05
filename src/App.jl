# ==============================================================================
# App.jl — Bonito App definition
# ==============================================================================
#
# Scope map (see dashboard scope diagram for the full picture):
#
#   explor_app(ws)
#   └── App do session
#       ├── Core observables       pathdir, current_keys
#       ├── Persistent observables val_heatmap, val_colormap, val_over, val_over_2
#       ├── Stable widgets         sliders, checkboxes, dropdowns (never rebuilt)
#       ├── Sidebar widgets        wid_all_df, cb_all_df
#       ├── Flags                  use_png, updating, plot_scheduled, plot_loop_active
#       ├── Functions (closures)
#       │   ├── current_config()   builds PlotConfig from current widget state
#       │   ├── build_2D_dom()     rebuilds only field dropdowns when keys change
#       │   ├── update_plot()      renders and sets plot_obs[]
#       │   └── schedule_plot_update()  debounce wrapper around update_plot()
#       └── on() listeners         reactive wiring


# ── Play button ───────────────────────────────────────────────────────────────
# Defined outside App so it doesn't capture session prematurely.
# schedule_plot_update is injected as an argument so the button can trigger
# renders without directly referencing App-internal state.

function PlayButton(slider, range, session, schedule_plot_update)
    button         = Bonito.Button("▶"; style=button_style)
    playing        = Threads.Atomic{Bool}(false)
    time_per_frame = Threads.Atomic{Float64}(1/4)

    task = @async let i = first(range)
        while !Bonito.isclosed(session)
            yield()
            t = time()
            if playing[]
                i = mod1(i + 1, last(range))
                slider.value[] = i
                schedule_plot_update()
                yield()
            end
            elapsed = time() - t
            sleep(max(0.05, time_per_frame[] - elapsed))
        end
    end
    Base.errormonitor(task)

    on(session, button.value) do _
        # @async: defer state update outside current Bonito message cycle
        @async begin
            if playing[]
                playing[]        = false
                button.content[] = "▶"
            else
                playing[]        = true
                button.content[] = "❚❚"
            end
        end
    end
    return button
end


# ── App ───────────────────────────────────────────────────────────────────────

function explor_app(ws::DataWorkspace; width="100%", height="1000px", scale=1.0)
    return App(title="Parameter Space Explorer") do session::Session

        # ── Core observables ──────────────────────────────────────────────────
        pathdir      = Observable{Any}(ws.all_dir[1] * "/")
        current_keys = Observable{Vector{String}}(copy(ws.all_keys))

        # ── Persistent field observables ──────────────────────────────────────
        # Survive dropdown rebuilds — the plot always reads from these, not from
        # the dropdown widgets directly. Updated silently via setfield! inside
        # build_2D_dom to avoid reactive cascade before JS registration completes.
        val_heatmap  = Observable{String}(ws.all_keys[1])
        val_colormap = Observable{String}(ws.all_cmaps[288])
        val_over     = Observable{String}("None")
        val_over_2   = Observable{String}("None")

        # ── Flags — defined early so all closures below can capture them ──────
        use_png          = Observable{Bool}(false)
        updating         = Ref(false)      # sidebar re-entrancy guard
        plot_scheduled   = Ref(false)      # debounce: a render is waiting
        plot_loop_active = Ref(false)      # debounce: the @async loop is alive

        # ── Stable widgets — created once, never rebuilt ──────────────────────
        sl_alpha     = make_alpha_slider()
        sl_alpha_2   = make_alpha_slider()
        sl_stepp     = Bonito.Slider([5,10,15,20,25]; value=20)
        sl_stepp_2   = Bonito.Slider([5,10,15,20,25]; value=20)
        sl_arsize    = Bonito.Slider(1:15; value=5)
        sl_arsize_2  = Bonito.Slider(1:15; value=5)
        cb_nematic   = Bonito.Checkbox(false; style=cb_style)
        cb_nematic_2 = Bonito.Checkbox(false; style=cb_style)
        drop_dim     = Bonito.Dropdown(["1D","2D","3D"]; index=2)
        sl_fig_base  = Bonito.Slider(200:100:1600; value=800)
        sl_nfiles    = Bonito.Slider(1:ws.Nfiles; value=1)
        cb_all_1D    = [Bonito.Checkbox(true; style=cb_style) for _ in ws.all_keys]

        # ── Sidebar widgets ───────────────────────────────────────────────────
        wid_all_df = filter(!isnothing, [make_widget_df(tab) for tab in ws.tab_list])
        cb_all_df  = [Bonito.Checkbox(false; style=cb_style) for _ in wid_all_df]

        widget_side = Observable{Any}(DOM.div(Col([
            Row(string(ws.changing_variable_list[i], " :"),
                Labeled(wid_all_df[i], wid_all_df[i].value),
                cb_all_df[i])
            for i in eachindex(ws.changing_variable_list)
        ]...)))

        # ── current_config ────────────────────────────────────────────────────
        # Single place that reads all widget values and builds a PlotConfig.
        # Used by both update_plot() and the save callback.
        # nfile can be overridden (e.g. in the save loop).
        function current_config(; nfile=sl_nfiles.value[])
            PlotConfig(;
                Ndim               = drop_dim.value[],
                nfile,
                cmap               = val_colormap[],
                first_field_key    = val_heatmap[],
                second_field_key   = val_over[],
                alpha              = Float64(sl_alpha.value[]),
                stepp              = Int(sl_stepp.value[]),
                arrowsize_factor   = Float64(sl_arsize.value[]),
                is_nematic         = cb_nematic.value[],
                third_field_key    = val_over_2[],
                alpha_2            = Float64(sl_alpha_2.value[]),
                stepp_2            = Int(sl_stepp_2.value[]),
                arrowsize_factor_2 = Float64(sl_arsize_2.value[]),
                is_nematic_2       = cb_nematic_2.value[],
                fig_base           = Int(sl_fig_base.value[]),
            )
        end

        # ── build_2D_dom ──────────────────────────────────────────────────────
        # Rebuilds only field dropdowns when the key list changes.
        # setfield! updates val_* silently (no listeners fired) to avoid a reactive
        # cascade before the new dropdowns are registered on the JS side.
        function build_2D_dom(field_keys)
            hk  = val_heatmap[] in field_keys ? val_heatmap[] : field_keys[1]
            ok  = val_over[]    in field_keys ? val_over[]    : "None"
            ok2 = val_over_2[]  in field_keys ? val_over_2[]  : "None"

            setfield!(val_heatmap, :val, hk)
            setfield!(val_over,    :val, ok)
            setfield!(val_over_2,  :val, ok2)

            drop_heatmap  = Bonito.Dropdown(field_keys;
                                index = findfirst(==(hk), field_keys))
            drop_colormap = Bonito.Dropdown(ws.all_cmaps;
                                index = findfirst(==(val_colormap[]), ws.all_cmaps))
            drop_over     = Bonito.Dropdown(vcat(["None"], field_keys);
                                index = findfirst(==(ok),  vcat(["None"], field_keys)))
            drop_over_2   = Bonito.Dropdown(vcat(["None"], field_keys);
                                index = findfirst(==(ok2), vcat(["None"], field_keys)))

            on(session, drop_heatmap.value)  do v; val_heatmap[]  = v end
            on(session, drop_colormap.value) do v; val_colormap[] = v end
            on(session, drop_over.value)     do v; val_over[]     = v end
            on(session, drop_over_2.value)   do v; val_over_2[]   = v end

            return DOM.div(Row(
                Card(Col(
                    Row("Heatmap: ",  drop_heatmap),
                    Row("Colormap: ", drop_colormap);
                    gap="0px"
                )),
                overlay_card("Overlay 1", drop_over,   sl_alpha,   sl_stepp,   sl_arsize,   cb_nematic),
                overlay_card("Overlay 2", drop_over_2, sl_alpha_2, sl_stepp_2, sl_arsize_2, cb_nematic_2),
            ))
        end

        widget_top = Observable{Any}(build_2D_dom(ws.all_keys))

        # ── update_plot ───────────────────────────────────────────────────────
        # plot_obs is set here; time_bar and main_obs are built once below and
        # never recreated — avoids "notify on null" from orphaned Bonito observables.
        plot_obs = Observable{Any}(DOM.div("Loading…"))

        function update_plot()
            cfg = current_config()
            if use_png[]
                path     = pathdir[]
                fig_dir  = joinpath(path, "..", "Fig")
                list_jld = filter(endswith(ws.ext), readdir(path))
                if !isdir(fig_dir) || isempty(list_jld)
                    plot_obs[] = DOM.div("No Fig/ folder found — save images first")
                    return
                end
                png_path = joinpath(fig_dir, splitext(list_jld[clamp(cfg.nfile,1,end)])[1]*".png")
                if !isfile(png_path)
                    plot_obs[] = DOM.div("PNG not found — save images first")
                    return
                end
                img = FileIO.load(png_path)
                fig = Figure(size=(900,900))
                image!(Makie.Axis(fig[1,1]; aspect=DataAspect()), rotr90(img))
                plot_obs[] = fig
            else
                plot_obs[] = make_plot(pathdir[], cfg, ws.ext)
            end
        end

        # ── schedule_plot_update ──────────────────────────────────────────────
        # Debounce: collapses rapid triggers (slider drag, play) into at most one
        # pending render. The @async loop exits only when no more renders are queued.
        function schedule_plot_update()
            plot_scheduled[] = true
            plot_loop_active[] && return
            plot_loop_active[] = true
            @async begin
                while plot_scheduled[]
                    plot_scheduled[] = false
                    try
                        update_plot()
                    catch e
                        @warn "update_plot failed: $e"
                        plot_obs[] = DOM.div("Error: $e")
                    end
                end
                plot_loop_active[] = false
            end
        end

        # ── Buttons ───────────────────────────────────────────────────────────

        # Play
        play_button = PlayButton(sl_nfiles, 1:ws.Nfiles, session, schedule_plot_update)

        # Reset — clears all pending renders, forces a fresh render
        reset_button = Bonito.Button("↺ Reset"; style=button_style)
        on(session, reset_button.value) do _
            @async begin
                plot_scheduled[]   = false
                plot_loop_active[] = false
                updating[]         = false
                sleep(0.1)
                plot_obs[] = DOM.div("Reloading…")
                try
                    update_plot()
                catch e
                    @warn "Reset render failed: $e"
                    plot_obs[] = DOM.div("Error after reset: $e")
                end
            end
        end

        # Save all — saves every .jld in pathdir as .png using CairoMakie
        save_button = Bonito.Button("💾 Save all"; style=button_style)
        save_status = Observable{Any}(DOM.div(""))
        on(session, save_button.value) do _
            @async begin
                path     = pathdir[]
                !isdir(path) && return
                list_jld = filter(endswith(ws.ext), readdir(path))
                isempty(list_jld) && return

                fig_dir = joinpath(path, "..", "Fig")
                mkpath(fig_dir)
                N = length(list_jld)

                # Snapshot current widget state once — prevents mid-save widget
                # changes from affecting later frames
                snap = current_config()

                for (i, fname) in enumerate(list_jld)
                    try
                        fig = make_plot_cairo(path, PlotConfig(;
                                Ndim               = snap.Ndim,
                                nfile              = i,
                                cmap               = snap.cmap,
                                first_field_key    = snap.first_field_key,
                                second_field_key   = snap.second_field_key,
                                alpha              = snap.alpha,
                                stepp              = snap.stepp,
                                arrowsize_factor   = snap.arrowsize_factor,
                                is_nematic         = snap.is_nematic,
                                third_field_key    = snap.third_field_key,
                                alpha_2            = snap.alpha_2,
                                stepp_2            = snap.stepp_2,
                                arrowsize_factor_2 = snap.arrowsize_factor_2,
                                is_nematic_2       = snap.is_nematic_2), ws.ext)
                        fig isa Cairo.Figure || continue
                        Cairo.save(joinpath(fig_dir, splitext(fname)[1]*".png"), fig)
                    catch e
                        @warn "Could not save $fname: $e"
                    end
                    save_status[] = DOM.div("Saving $i / $N…")
                end
                save_status[] = DOM.div("✓ Saved $N files to $(fig_dir)")
            end
        end

        # PNG/Field switch
        switch_button = Bonito.Button("🖼 Use PNG"; style=button_style)
        on(session, switch_button.value) do _
            @async begin
                use_png[] = !use_png[]
                switch_button.content[] = use_png[] ? "⚙ Use Field" : "🖼 Use PNG"
                schedule_plot_update()
            end
        end

        # ── Static layout pieces (built once) ─────────────────────────────────
        time_bar = Card(Col(
            Row("Time: ", Labeled(sl_nfiles, sl_nfiles.value),
                play_button, reset_button, save_button, switch_button),
        ))
        main_obs = Observable{Any}(Col(Card(plot_obs), time_bar))

        # ── on() listeners ────────────────────────────────────────────────────

        # Rebuild top bar when dimension changes
        on(session, drop_dim.value) do Ndim
            @async widget_top[] = if Ndim == "1D"
                DOM.div(Grid(cb_all_1D...; columns="repeat(2, 1fr)"))
            elseif Ndim == "2D"
                build_2D_dom(current_keys[])
            else
                DOM.div()
            end
        end

        # Reload keys when simulation path changes
        on(session, pathdir) do path
            @async try
                isdir(path) || return
                files    = filter(endswith(ws.ext), readdir(path))
                isempty(files) && return
                new_keys = sort(collect(Base.keys(FileIO.load(joinpath(path, files[1])))))
                new_keys != current_keys[] && (current_keys[] = new_keys)
            catch e
                @warn "Could not read keys from $path: $e"
            end
        end

        # Rebuild field dropdowns when keys change
        on(session, current_keys) do new_keys
            drop_dim.value[] == "2D" || return
            @async begin
                widget_top[] = build_2D_dom(new_keys)
                schedule_plot_update()
            end
        end

        # Plot triggers — any relevant observable change schedules a render
        for obs in [drop_dim.value, sl_nfiles.value, sl_fig_base.value,
                    val_colormap, val_heatmap,
                    val_over,   sl_alpha.value,   sl_stepp.value,   sl_arsize.value,   cb_nematic.value,
                    val_over_2, sl_alpha_2.value, sl_stepp_2.value, sl_arsize_2.value, cb_nematic_2.value,
                    pathdir, use_png]
            on(session, obs) do _
                schedule_plot_update()
            end
        end

        # Sidebar: nearest-row search
        # ALL observable writes inside @async — avoids "notify on null" from
        # writing to JS observables while the current message is still processing.
        for wid in [wid_all_df..., cb_all_df...]
            on(session, wid.value) do _
                updating[] && return
                updating[] = true

                widget_vals  = [wid_all_df[c].value[] for c in 1:ws.N_changing]
                pinned       = [cb_all_df[c].value[]  for c in 1:ws.N_changing]
                idx          = find_closest_row(ws.df, ws.changing_variable_list, ws.ranges, widget_vals, pinned)
                new_path     = string(ws.dir, ws.df[idx, :fn], "/Data/")
                snapped_vals = [convert(typeof(wid_all_df[c].value[]), ws.df[idx, varname])
                                for (c, varname) in enumerate(ws.changing_variable_list)]

                @async try
                    pathdir[] = new_path
                    for (c, _) in enumerate(ws.changing_variable_list)
                        v = snapped_vals[c]
                        wid_all_df[c].value[] != v && (wid_all_df[c].value[] = v)
                    end
                finally
                    updating[] = false
                end
            end
        end

        # Initial render — on() listeners don't fire on initial values
        @async try
            update_plot()
        catch e
            @warn "Initial render failed: $e"
            plot_obs[] = DOM.div("Error: $e")
        end

        # ── Layout ────────────────────────────────────────────────────────────
        grid = Grid(
            Card(Col(
                Row("Dimension: ", drop_dim),
                Row("Fig size: ", Labeled(sl_fig_base, sl_fig_base.value)));
                style=Styles("grid-column" => "1", "grid-row" => "1")),
            Card(widget_side;
                style=Styles("grid-column" => "1", "grid-row" => "2 / 3")),
            Card(widget_top;
                style=Styles("grid-column" => "2", "grid-row" => "1")),
            Card(main_obs;
                style=Styles("grid-column" => "2", "grid-row" => "2")),
            Card(DOM.div(save_status);
                style=Styles("grid-column" => "1 / 3", "grid-row" => "3",
                             "padding" => "4px 12px"));
            columns = "2fr 5fr",
            rows    = "200px 1fr auto",
        )

        return DOM.div(grid; style=Styles("width"    => width,
                                          "height"   => height,
                                          "zoom"     => string(scale),
                                          "margin"   => "20px",
                                          "overflow" => "auto",
                                          "position" => :relative))
    end
end
