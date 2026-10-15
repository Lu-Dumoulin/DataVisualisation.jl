# ==============================================================================
# State.jl — the Dashboard: all widgets and observables of one session, and
# the operations on them as plain functions of `d::Dashboard`.
# ==============================================================================

const DEFAULT_CMAP = "RdPu"


# ── Debouncer ─────────────────────────────────────────────────────────────────
# Runs `f` in an @async loop. Triggers that arrive while it is busy collapse
# into one more run, so slider drags and play ticks never queue up work, and
# the last trigger is never lost.

mutable struct Debouncer
    f       ::Function
    pending ::Bool
    active  ::Bool
end
Debouncer(f=() -> nothing) = Debouncer(f, false, false)

function schedule!(db::Debouncer)
    db.pending = true
    db.active && return
    db.active = true
    task = @async try
        while db.pending
            db.pending = false
            db.f()
        end
    finally
        db.active = false
    end
    Base.errormonitor(task)
    return
end

# Forget pending work and a possibly stuck loop (Reset button).
reset!(db::Debouncer) = (db.pending = false; db.active = false; nothing)


# ── Dashboard ─────────────────────────────────────────────────────────────────

struct Player
    button     ::Bonito.Button
    playing    ::Threads.Atomic{Bool}
    frame_time ::Threads.Atomic{Float64}
end
Player() = Player(Bonito.Button("▶"; style=button_style),
                  Threads.Atomic{Bool}(false), Threads.Atomic{Float64}(1/4))

# Field dropdowns, rebuilt by field_menus_dom! whenever the key list changes.
struct FieldMenus
    heatmap  ::Bonito.Dropdown
    colormap ::Bonito.Dropdown
    overlays ::Vector{Bonito.Dropdown}
end

struct Dashboard
    ws      ::DataWorkspace
    session ::Session

    # What is plotted. The selections are plain observables so they survive
    # dropdown rebuilds; rendering reads these, never the dropdowns.
    pathdir      ::Observable{String}            # current run's Data/ folder
    current_keys ::Observable{Vector{String}}    # fields available in that run
    heatmap      ::Observable{String}
    colormap     ::Observable{String}
    overlays     ::Vector{OverlayControls}
    use_png      ::Observable{Bool}

    # Stable widgets — created once, never rebuilt
    dim      ::Bonito.Dropdown
    fig_base ::Bonito.Slider{Int}
    nfile    ::Bonito.Slider{Int}
    params   ::Vector{Any}                       # sidebar: one widget per changing parameter
    pins     ::Vector{Bonito.Checkbox}
    keys_1D  ::Vector{Bonito.Checkbox}
    player   ::Player
    reset    ::Bonito.Button
    save     ::Bonito.Button
    png      ::Bonito.Button
    menus    ::Base.RefValue{FieldMenus}         # current field dropdowns
    row      ::Base.RefValue{Int}                # DataFrame row of the current run

    # Outputs
    plot   ::Observable{Any}                     # Figure or message div
    top    ::Observable{Any}                     # top bar (depends on dimension)
    status ::Observable{Any}                     # save progress

    # Background loops
    renderer ::Debouncer
    snapper  ::Debouncer
end

# Keys of the run's first frame; the workspace keys if the run has no frames.
function initial_keys(ws, path)
    first = frame_path(path, 1, ws.ext)
    isnothing(first) ? copy(ws.all_keys) : field_keys(first)
end

function Dashboard(ws::DataWorkspace, session::Session)
    path = run_path(ws, 1)                       # the run the sidebar starts on
    keys = initial_keys(ws, path)
    d = Dashboard(ws, session,
        Observable(path),
        Observable(keys),
        Observable(keys[1]),
        Observable(DEFAULT_CMAP in ws.all_cmaps ? DEFAULT_CMAP : ws.all_cmaps[1]),
        [OverlayControls(), OverlayControls()],
        Observable(false),

        Bonito.Dropdown(["1D", "2D", "3D"]; index=2),
        Bonito.Slider(200:100:1600; value=800),
        Bonito.Slider(1:ws.Nfiles; value=1),
        filter(!isnothing, [make_widget_df(ws.tab_list[i], ws.df[1, ws.var_list[i]])
                            for i in eachindex(ws.tab_list)]),
        [Bonito.Checkbox(false; style=cb_style) for _ in 1:ws.N_changing],
        [Bonito.Checkbox(true;  style=cb_style) for _ in ws.all_keys],
        Player(),
        Bonito.Button("↺ Reset";    style=button_style),
        Bonito.Button("💾 Save all"; style=button_style),
        Bonito.Button("🖼 Use PNG";  style=button_style),
        Ref{FieldMenus}(),
        Ref(1),

        Observable{Any}(DOM.div("Loading…")),
        Observable{Any}(DOM.div()),
        Observable{Any}(DOM.div("")),

        Debouncer(),
        Debouncer(),
    )
    d.renderer.f = () -> render!(d)
    d.snapper.f  = () -> snap!(d)
    d.top[]      = top_dom(d)
    return d
end

# Dashboard with all listeners connected and the first render started.
function dashboard(ws::DataWorkspace, session::Session)
    d = Dashboard(ws, session)
    connect!(d)
    start_player!(d)
    schedule!(d.renderer)        # on() listeners don't fire on initial values
    return d
end


# ── Reading state ─────────────────────────────────────────────────────────────

# Single place that reads widget values into a PlotConfig.
plot_config(d::Dashboard; nfile=d.nfile.value[]) = PlotConfig(;
    Ndim     = d.dim.value[],
    nfile    = Int(nfile),
    cmap     = d.colormap[],
    heatmap  = d.heatmap[],
    overlays = OverlayConfig.(d.overlays),
    fig_base = Int(d.fig_base.value[]),
)

plot_triggers(d::Dashboard) = Any[
    d.dim.value, d.nfile.value, d.fig_base.value, d.colormap, d.heatmap,
    d.use_png,                   # (pathdir renders via its own listener, after reload_keys!)
    Iterators.flatten(plot_triggers.(d.overlays))...,
]


# ── Operations ────────────────────────────────────────────────────────────────

function render!(d::Dashboard)
    d.plot[] = try
        render_view(d.pathdir[], plot_config(d), d.ws.ext; use_png=d.use_png[])
    catch e
        @warn "Render failed: $e"
        DOM.div("Error: $e")
    end
    return
end

# Move to the run nearest the sidebar values, and snap the widgets onto it.
# Parameters the user moved away from the current run count as pinned, so the
# others adapt to them — otherwise picking a value that only exists together
# with other changes (e.g. orientation=polar) would snap straight back.
# Writing the snapped values back schedules one more snap, which finds
# nothing left to change.
function snap!(d::Dashboard)
    vals    = [w.value[] for w in d.params]
    current = [d.ws.df[d.row[], name] for name in d.ws.changing_variable_list]
    pinned  = [cb.value[] for cb in d.pins] .| (vals .!= current)
    idx, snapped = snap(d.ws, vals, pinned)
    d.row[] = idx
    path = run_path(d.ws, idx)
    path != d.pathdir[] && (d.pathdir[] = path)
    for (w, v) in zip(d.params, snapped)
        set_value!(w, v)
    end
    return
end

# Update the available fields after the run changed, rebuilding the field
# dropdowns if they differ. Does not render: the caller renders once after.
function reload_keys!(d::Dashboard, path)
    first = frame_path(path, 1, d.ws.ext)
    isnothing(first) && return
    new_keys = field_keys(first)
    new_keys == d.current_keys[] && return
    d.current_keys[] = new_keys
    d.dim.value[] == "2D" && (d.top[] = field_menus_dom!(d, new_keys))
    return
end

# Export every frame of the current run as PNG with the current settings.
function save_all!(d::Dashboard)
    path = d.pathdir[]
    cfg  = plot_config(d)        # snapshot: widget changes mid-save don't leak in
    saved, total = save_frames(path, cfg, d.ws.ext) do i, N
        d.status[] = DOM.div("Saving $i / $N…")
    end
    d.status[] = DOM.div(
        total == 0     ? "Nothing to save in $path" :
        saved == total ? "✓ Saved $total files to $(fig_dir(path))" :
                         "⚠ Saved $saved / $total files to $(fig_dir(path)) — see log")
    return
end

function toggle_png!(d::Dashboard)
    d.use_png[]       = !d.use_png[]
    d.png.content[]   = d.use_png[] ? "⚙ Use Field" : "🖼 Use PNG"
    return
end

# Drop pending work, then render again from scratch.
function reset_view!(d::Dashboard)
    reset!(d.renderer)
    reset!(d.snapper)
    sleep(0.1)
    d.plot[] = DOM.div("Reloading…")
    render!(d)
end

function toggle_play!(d::Dashboard)
    p = d.player
    p.playing[]        = !p.playing[]
    p.button.content[] = p.playing[] ? "❚❚" : "▶"
    return
end

# Advance one frame per frame_time while playing, until the session closes.
function start_player!(d::Dashboard)
    p    = d.player
    task = @async while !Bonito.isclosed(d.session)
        t = time()
        p.playing[] && set_value!(d.nfile, mod1(d.nfile.value[] + 1, d.ws.Nfiles))
        sleep(max(0.05, p.frame_time[] - (time() - t)))
    end
    Base.errormonitor(task)
end


# ── Top bar ───────────────────────────────────────────────────────────────────

function top_dom(d::Dashboard)
    Ndim = d.dim.value[]
    Ndim == "1D" && return DOM.div(Grid(d.keys_1D...; columns="repeat(2, 1fr)"))
    Ndim == "2D" && return field_menus_dom!(d, d.current_keys[])
    return DOM.div()
end

# Rebuild the field dropdowns for a new key list.
# setfield! updates the selections silently (no listeners fired) to avoid a
# reactive cascade before the new dropdowns are registered on the JS side.
function field_menus_dom!(d::Dashboard, field_keys)
    options = vcat(["None"], field_keys)
    keep(sel, fallback) = sel[] in field_keys ? sel[] : fallback

    setfield!(d.heatmap, :val, keep(d.heatmap, field_keys[1]))
    for o in d.overlays
        setfield!(o.field, :val, keep(o.field, "None"))
    end

    menus = FieldMenus(
        Bonito.Dropdown(field_keys;  index=findfirst(==(d.heatmap[]),  field_keys)),
        Bonito.Dropdown(d.ws.all_cmaps; index=findfirst(==(d.colormap[]), d.ws.all_cmaps)),
        [Bonito.Dropdown(options; index=findfirst(==(o.field[]), options)) for o in d.overlays],
    )
    d.menus[] = menus

    on(v -> d.heatmap[]  = v, d.session, menus.heatmap.value)
    on(v -> d.colormap[] = v, d.session, menus.colormap.value)
    for (o, menu) in zip(d.overlays, menus.overlays)
        on(v -> o.field[] = v, d.session, menu.value)
    end

    return DOM.div(Row(
        Card(Col(
            Row("Heatmap: ",  menus.heatmap),
            Row("Colormap: ", menus.colormap);
            gap="0px"
        )),
        [overlay_card("Overlay $i", menu, o)
         for (i, (o, menu)) in enumerate(zip(d.overlays, menus.overlays))]...,
    ))
end
