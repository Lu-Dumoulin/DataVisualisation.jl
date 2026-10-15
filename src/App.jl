# ==============================================================================
# App.jl — Bonito App: wiring (connect!) and page layout
# ==============================================================================
#
#   explor_app(ws)
#   └── App do session
#       ├── dashboard(ws, session)   State.jl: Dashboard + connect! + player + first render
#       └── layout(d)                page structure, built once
#
# Listeners only schedule work; the work itself is a plain function of the
# Dashboard (render!, snap!, save_all!, …) in State.jl.
# Observable writes from a listener go through @async (or a Debouncer, which
# is @async too) — writing to JS-synced observables while Bonito is still
# processing the current message causes "notify on null".


function connect!(d::Dashboard)
    s = d.session

    # Buttons
    on(_ -> @async(toggle_play!(d)), s, d.player.button.value)
    on(_ -> @async(reset_view!(d)),  s, d.reset.value)
    on(_ -> @async(save_all!(d)),    s, d.save.value)
    on(_ -> @async(toggle_png!(d)),  s, d.png.value)

    # Top bar follows the dimension
    on(_ -> @async(d.top[] = top_dom(d)), s, d.dim.value)

    # New run → update the fields (and dropdowns) first, then render once.
    # Rendering on the path change and again on the key change replaced the
    # WGLMakie figure twice within ~0.1 s, which can leave the browser stuck
    # on the loading spinner.
    on(s, d.pathdir) do path
        @async begin
            try
                reload_keys!(d, path)
            catch e
                @warn "Could not read keys from $path: $e"
            end
            schedule!(d.renderer)
        end
    end

    # Any plot-relevant change → render (debounced)
    for obs in plot_triggers(d)
        on(_ -> schedule!(d.renderer), s, obs)
    end

    # Sidebar → nearest run (debounced)
    for w in [d.params; d.pins]
        on(_ -> schedule!(d.snapper), s, w.value)
    end
    return d
end


# height="auto" lets the page grow with the figure; a fixed height (e.g. "800px"
# for a Pluto cell) scrolls inside the box instead.
function layout(d::Dashboard; width="100%", height="auto", scale=1.0)
    ws = d.ws

    # Outer Observable{Any} wrappers are built once and never replaced —
    # avoids "notify on null" from orphaned Bonito observables.
    sidebar = Observable{Any}(DOM.div(Col([
        Row(string(name, " :"), Labeled(w, w.value), pin)
        for (name, w, pin) in zip(ws.changing_variable_list, d.params, d.pins)
    ]...)))

    time_bar = Card(Col(
        Row("Time: ", Labeled(d.nfile, d.nfile.value),
            d.player.button, d.reset, d.save, d.png),
    ))
    main = Observable{Any}(Col(Card(d.plot), time_bar))

    grid = Grid(
        Card(Col(
            Row("Dimension: ", d.dim),
            Row("Fig size: ", Labeled(d.fig_base, d.fig_base.value)));
            style=Styles("grid-column" => "1", "grid-row" => "1")),
        Card(sidebar;
            style=Styles("grid-column" => "1", "grid-row" => "2 / 3")),
        Card(d.top;
            style=Styles("grid-column" => "2", "grid-row" => "1")),
        Card(main;
            style=Styles("grid-column" => "2", "grid-row" => "2")),
        Card(DOM.div(d.status);
            style=Styles("grid-column" => "1 / 3", "grid-row" => "3",
                         "padding" => "4px 12px"));
        columns = "2fr 5fr",
        rows    = "200px 1fr auto",
    )

    # padding + border-box: the 20px gutter counts inside `width`, so
    # width="100%" doesn't overflow the window on the right.
    return DOM.div(grid; style=Styles("width"      => width,
                                      "height"     => height,
                                      "box-sizing" => "border-box",
                                      "padding"    => "20px",
                                      "zoom"       => string(scale),
                                      "overflow"   => height == "auto" ? "visible" : "auto",
                                      "position"   => :relative))
end


function explor_app(ws::DataWorkspace; width="100%", height="auto", scale=1.0)
    return App(title="Parameter Space Explorer") do session::Session
        layout(dashboard(ws, session); width, height, scale)
    end
end
