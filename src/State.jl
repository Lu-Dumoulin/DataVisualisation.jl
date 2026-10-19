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
    button  ::Bonito.Button
    playing ::Threads.Atomic{Bool}
    fps     ::Bonito.Slider{Int}         # maximum speed; never skips frames
end
Player() = Player(Bonito.Button("▶"; style=button_style),
                  Threads.Atomic{Bool}(false),
                  Bonito.Slider([1, 2, 4, 8, 12, 24]; value=4))

# What the plot panel currently shows, when it can be updated in place.
struct LiveFigure                        # Makie figure reading from `data`
    key   ::Any                          # layout it was built for (see layout_key)
    data  ::Observable{Dict{String,Any}}
    style ::Observable{PlotConfig}       # in-place settings (arrow sizes)
end

# A rebuild replaces the WebGL canvas. Replacing it again before the browser has
# set the previous one up makes WGLMakie throw (setup_scene_init on a removed
# canvas) — what a fast drag on a layout control used to do. So a rebuild waits
# until the controls have been still for REBUILD_SETTLE s, and at least
# MIN_REBUILD_GAP s after the previous one.
const REBUILD_SETTLE  = 0.2
const MIN_REBUILD_GAP = 0.6
struct LiveImage                         # <img> showing an exported PNG
    src ::Observable{String}
end
struct LiveRun                           # 1D whole-run view; `frame` moves its marker
    key   ::Any
    frame ::Observable{Int}
end

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
    z            ::Observable{Int}               # 3D: selected slice
    nz           ::Base.RefValue{Int}            # 3D: number of slices in the current run
    fields1d     ::Observable{Vector{String}}    # 1D: fields shown as profiles
    cut_axis     ::Observable{String}            # 1D from 2D: "x" or "y"
    cut_pos      ::Observable{Int}               #   position on the other axis (0: not set yet)
    cut_mean     ::Observable{Bool}              #   or average over it
    view1d       ::Observable{String}            # 1D: Profiles / Kymograph / Times overlaid
    shapes       ::Base.RefValue{Dict{String,Tuple}}   # field sizes in the current run

    # Stable widgets — created once, never rebuilt
    dim      ::Bonito.Dropdown
    fixed_range ::Bonito.Checkbox                # heatmap colour range over the whole run
    fig_base ::Bonito.Slider{Int}
    nfile    ::Bonito.Slider{Int}
    params   ::Vector{Any}                       # sidebar: one widget per changing parameter
    pins     ::Vector{Bonito.Checkbox}
    player   ::Player
    reset    ::Bonito.Button
    save     ::Bonito.Button
    png      ::Bonito.Button
    movie    ::Bonito.Button
    pdf      ::Bonito.Button
    menus    ::Base.RefValue{FieldMenus}         # current field dropdowns
    zslider  ::Base.RefValue{Any}                # current 3D slice slider (or nothing)
    menus1d  ::Base.RefValue{Any}                # current 1D controls (NamedTuple) or nothing
    row      ::Base.RefValue{Int}                # DataFrame row of the current run
    live     ::Base.RefValue{Any}                # LiveFigure, LiveImage or nothing
    last_rebuild ::Base.RefValue{Float64}        # time of the last figure rebuild
    exporting    ::Base.RefValue{Bool}           # an export (Save all .png, movie, PDF) is running

    # Outputs
    plot   ::Observable{Any}                     # Figure or message div
    top    ::Observable{Any}                     # top bar (depends on dimension)
    status ::Observable{Any}                     # save progress
    cursor ::Observable{String}                  # value under the mouse

    # Background loops
    renderer ::Debouncer
    snapper  ::Debouncer
end

# Only 1D fields: start in the 1D view; only 3D fields: in the 3D view.
all_1d(shapes) = !isnothing(shapes) && !isempty(shapes) && all(sz -> length(sz) == 1, values(shapes))
all_3d(shapes) = !isnothing(shapes) && !isempty(shapes) && all(sz -> depth(sz) > 1, values(shapes))

# Field sizes in the run's first frame, or nothing if the run has no frames.
function run_shapes(ws, path)
    first = frame_path(path, 1, ws.ext)
    isnothing(first) ? nothing : field_shapes(first)
end

function Dashboard(ws::DataWorkspace, session::Session)
    path   = run_path(ws, 1)                     # the run the sidebar starts on
    shapes = run_shapes(ws, path)
    keys   = isnothing(shapes) ? copy(ws.all_keys) : sort!(collect(Base.keys(shapes)))
    d = Dashboard(ws, session,
        Observable(path),
        Observable(keys),
        Observable(keys[1]),
        Observable(DEFAULT_CMAP in ws.all_cmaps ? DEFAULT_CMAP : ws.all_cmaps[1]),
        [OverlayControls("black"), OverlayControls("white")],   # default arrow colours
        Observable(false),
        Observable(1),
        Ref(isnothing(shapes) ? 1 : nslices(shapes)),
        Observable(copy(keys)),
        Observable("x"),
        Observable(0),
        Observable(false),
        Observable("Profiles"),
        Ref(isnothing(shapes) ? Dict{String,Tuple}() : shapes),

        Bonito.Dropdown(["1D", "2D", "3D"]; index=all_1d(shapes) ? 1 : all_3d(shapes) ? 3 : 2),
        Bonito.Checkbox(false; style=cb_style),
        Bonito.Slider(200:100:1600; value=800),
        Bonito.Slider(1:ws.Nfiles; value=1),
        filter(!isnothing, [make_widget_df(ws.tab_list[i], ws.df[1, ws.var_list[i]])
                            for i in eachindex(ws.tab_list)]),
        [Bonito.Checkbox(false; style=cb_style) for _ in 1:ws.N_changing],
        Player(),
        Bonito.Button("↺ Reset";    style=button_style),
        Bonito.Button("💾 Save all .png"; style=button_style),
        Bonito.Button("🖼 Use PNG";  style=button_style),
        Bonito.Button("🎞 Movie";    style=button_style),
        Bonito.Button("📄 PDF";      style=button_style),
        Ref{FieldMenus}(),
        Ref{Any}(nothing),
        Ref{Any}(nothing),
        Ref(1),
        Ref{Any}(nothing),
        Ref(0.0),
        Ref(false),

        Observable{Any}(DOM.div("Loading…")),
        Observable{Any}(DOM.div()),
        Observable{Any}(DOM.div("")),
        Observable(""),

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
function plot_config(d::Dashboard; nfile=d.nfile.value[])
    cfg = PlotConfig(;
    Ndim     = d.dim.value[],
    nfile    = Int(nfile),
    cmap     = d.colormap[],
    heatmap  = d.heatmap[],
    overlays = OverlayConfig.(d.overlays),
    fig_base = Int(d.fig_base.value[]),
    zslice   = d.z[],
    fields1d = d.fields1d[],
    cut_axis = d.cut_axis[],
    cut_pos  = d.cut_pos[],
    cut_mean = d.cut_mean[],
    view1d   = d.view1d[],
    colorrange = nothing,
    )
    use_run_range(d, cfg) || return cfg
    c = d.ws.run_ranges
    r = lock(() -> get(c.values, range_key(d, cfg), nothing), c.lock)
    return r isa Tuple ? with(cfg; colorrange=r) : cfg
end

# Colour range over the run: asked for, and meaningful (2D / 3D heatmaps).
use_run_range(d::Dashboard, cfg) = d.fixed_range.value[] && cfg.Ndim in ("2D", "3D")

# The frame count is part of the key: new frames of a running simulation → recomputed.
range_key(d::Dashboard, cfg) =
    (d.pathdir[], cfg.heatmap, cfg.Ndim, length(frame_files(d.pathdir[], d.ws.ext)))

# Start computing the run range for cfg in the background (another thread when
# Julia has several), unless it is cached or already being computed. Progress
# and result go to the status line; when done, render again.
function request_range!(d::Dashboard, cfg)
    key = range_key(d, cfg)
    c   = d.ws.run_ranges
    lock(c.lock) do
        (haskey(c.values, key) || haskey(c.tasks, key)) && return
        dir, field, Ndim, n = key
        done = Threads.Atomic{Int}(0)
        task = Threads.@spawn run_range(dir, field, Ndim, d.ws.ext; progress=done)
        c.tasks[key] = task
        Base.errormonitor(@async begin
            while !istaskdone(task)
                d.status[] = DOM.div("Colour range of $field over the run: $(done[]) / $n frames…")
                sleep(0.3)
            end
            r, err = try
                fetch(task), nothing
            catch e
                cause = e isa TaskFailedException ? e.task.exception : e
                nothing, first(split(sprint(showerror, cause), '\n'))
            end
            isnothing(err) || @warn "Colour range of $field failed: $err"
            lock(c.lock) do
                delete!(c.tasks, key)
                c.values[key] = something(r, :none)          # :none — not retried for this key
            end
            d.status[] = DOM.div(
                !isnothing(err) ? "⚠ Colour range of $field failed ($err): colour range per frame" :
                isnothing(r)    ? "⚠ $field has no finite value: colour range per frame" :
                                  "✓ Colour range of $field over the run: [$(fmt(r[1])), $(fmt(r[2]))]")
            schedule!(d.renderer)
        end)
    end
    return
end

plot_triggers(d::Dashboard) = Any[
    d.dim.value, d.nfile.value, d.fig_base.value, d.colormap, d.heatmap,
    d.use_png, d.z, d.fields1d, d.cut_axis, d.cut_pos, d.cut_mean, d.view1d, d.fixed_range.value,                   # (pathdir renders via its own listener, after reload_keys!)
    Iterators.flatten(plot_triggers.(d.overlays))...,
]


# ── Operations ────────────────────────────────────────────────────────────────

function render!(d::Dashboard)
    try
        cfg = plot_config(d)
        use_run_range(d, cfg) && isnothing(cfg.colorrange) && request_range!(d, cfg)
        d.use_png[] ? render_png!(d, cfg) : render_fields!(d, cfg)
    catch e
        @warn "Render failed: $e"
        show!(d, DOM.div("Error: $e"))
    end
    return
end

# Replace the plot panel content; nothing left to update in place.
function show!(d::Dashboard, content)
    d.live[] = nothing
    d.plot[] = content
    isempty(d.cursor[]) || (d.cursor[] = "")
    return
end

# Value under the cursor. The browser forwards mouse moves to Julia; find the
# axis under the mouse, convert to data coordinates and let `text_at(k, p)`
# (k: index of that axis) read the value. Also refreshed when `triggers` change
# (a new frame under a still mouse).
function track_cursor!(d::Dashboard, fig, text_at, triggers...)
    axs = [c for c in fig.content if c isa Makie.Axis]
    isempty(axs) && return
    function update(_...)
        for (k, ax) in enumerate(axs)
            Makie.is_mouseinside(ax.scene) || continue
            d.cursor[] = text_at(k, Makie.mouseposition(ax.scene))
            return
        end
        isempty(d.cursor[]) || (d.cursor[] = "")
    end
    onany(update, Makie.events(fig).mouseposition, triggers...)
    return
end

# Everything that shapes the figure, i.e. everything but the frame (and the
# 3D slice / 1D cut position). While it stays the same, new data only replaces
# the data of the existing figure.
function layout_key(cfg::PlotConfig, data)
    sizes = sort!([k => size(v) for (k, v) in data])
    cfg.Ndim == "1D" && return ("1D", cfg.fields1d, cfg.cut_axis, cfg.cut_mean, cfg.fig_base, sizes)
    overlays = [(o.field, o.alpha, o.stepp, o.nematic, o.color) for o in cfg.overlays]  # not arrowsize
    run_range = !isnothing(cfg.colorrange)                    # the mode, not the values
    return (cfg.Ndim, cfg.cmap, cfg.heatmap, overlays, cfg.fig_base, run_range, sizes)
end

# Wait before a rebuild (see REBUILD_SETTLE). false: the controls moved again
# meanwhile — skip, the renderer runs again with the newer values.
function settle_before_rebuild(d::Dashboard)
    sleep(REBUILD_SETTLE)
    gap = d.last_rebuild[] + MIN_REBUILD_GAP - time()
    gap > 0 && sleep(gap)
    d.renderer.pending && return false
    d.last_rebuild[] = time()
    return true
end

function render_fields!(d::Dashboard, cfg)
    run_view(cfg) && return render_run!(d, cfg)
    data = load_frame(d.pathdir[], cfg, d.ws.ext)
    data isa AbstractString && return show!(d, DOM.div(data))
    data = reduce_frame(data, cfg)              # 3D → one z-slice, 1D → profiles; updated in place
    key  = layout_key(cfg, data)
    live = d.live[]
    if live isa LiveFigure && live.key == key
        s = live.style[]                        # arrow sizes, run colour range: in place
        (s.overlays != cfg.overlays || s.colorrange != cfg.colorrange) && (live.style[] = cfg)
        live.data[] = data                      # in place: only arrays go to the browser
    else
        settle_before_rebuild(d) || return
        obs   = Observable{Dict{String,Any}}(data)
        style = Observable(cfg)
        fig   = plot_frame(obs, cfg; max_cells=cfg.fig_base, style)
        fig isa AbstractString && return show!(d, DOM.div(fig))
        show!(d, fig)
        d.live[] = LiveFigure(key, obs, style)
        if cfg.Ndim == "1D"
            track_cursor!(d, fig, (_, p) -> cursor_text_1d(obs[], plot_config(d), p[1]), obs)
        else
            track_cursor!(d, fig, (_, p) -> cursor_text(obs[], plot_config(d), p), obs)
        end
    end
    return
end

# Kymograph / times overlaid: the whole run is loaded once per run, fields and
# cut; a new frame only moves the marker.
function render_run!(d::Dashboard, cfg)
    key  = (d.pathdir[], cfg.view1d, cfg.fields1d, cfg.cut_axis, cfg.cut_pos, cfg.cut_mean,
            cfg.fig_base, cfg.cmap)
    live = d.live[]
    if live isa LiveRun && live.key == key
        live.frame[] = cfg.nfile
    else
        settle_before_rebuild(d) || return
        frame = Observable(cfg.nfile)
        run   = run_profiles(d.pathdir[], cfg, d.ws.ext)
        fig   = plot_run(run, cfg; frame)
        fig isa AbstractString && return show!(d, DOM.div(fig))
        show!(d, fig)
        d.live[] = LiveRun(key, frame)
        kymo = cfg.view1d == "Kymograph"         # y is time there; overlaid: y is the value
        track_cursor!(d, fig, (k, p) -> cursor_text_run(run, run.names[k],
                      kymo ? p : (p[1], run.times[clamp(frame[], 1, length(run.times))])), frame)
    end
    return
end

function render_png!(d::Dashboard, cfg)
    png = png_file(d.pathdir[], cfg, d.ws.ext)
    isnothing(png.file) && return show!(d, DOM.div(png.msg))
    src  = png_data_uri(png.file)
    live = d.live[]
    if live isa LiveImage
        live.src[] = src                        # in place: the browser swaps the image
    else
        obs = Observable(src)
        show!(d, png_img(obs))
        d.live[] = LiveImage(obs)
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

# Update the available fields (and 3D slice count) after the run changed,
# rebuilding the top bar if they differ. Does not render: the caller renders
# once after.
function reload_keys!(d::Dashboard, path)
    shapes = run_shapes(d.ws, path)
    isnothing(shapes) && return
    shapes == d.shapes[] && return
    d.shapes[]       = shapes
    d.current_keys[] = sort!(collect(keys(shapes)))
    d.nz[]           = nslices(shapes)
    d.top[]          = top_dom(d)
    return
end

# Run one export at a time; a second click while one runs only says so.
# Errors end up in the status line, not only in the terminal.
function exclusive_export!(f, d::Dashboard)
    d.exporting[] && return (d.status[] = DOM.div("An export is already running — wait for it to finish"); nothing)
    d.exporting[] = true
    try
        f()
    catch e
        @warn "Export failed: $e"
        d.status[] = DOM.div("⚠ Export failed: $e")
    finally
        d.exporting[] = false
    end
end

# The current run as a movie, with the current view and settings, at the fps of the player.
function save_movie!(d::Dashboard)
    exclusive_export!(d) do
        res = save_movie(d.pathdir[], plot_config(d), d.ws.ext; framerate=d.player.fps.value[]) do i, N
            d.status[] = DOM.div("Recording movie: frame $i / $N…")
        end
        d.status[] = DOM.div(isnothing(res.file) ? res.msg : "✓ Movie saved to $(res.file)")
    end
end

# The current frame as a PDF.
function save_pdf!(d::Dashboard)
    exclusive_export!(d) do
        res = save_frame_pdf(d.pathdir[], plot_config(d), d.ws.ext)
        d.status[] = DOM.div(isnothing(res.file) ? res.msg : "✓ PDF saved to $(res.file)")
    end
end

# Export every frame of the current run as PNG with the current settings.
save_all!(d::Dashboard) = exclusive_export!(() -> save_all_pngs!(d), d)

function save_all_pngs!(d::Dashboard)
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

# ── Colormap choice, with Ludo's house rule ─────────────────────────────────
# YlOrRd (and its _3 … _8 variants) is refused: a message, and RdPu_8 instead.
# The swap happens before anything is drawn, so YlOrRd never reaches the screen.
# YlOrRd_9 is tolerated.
const BANNED_CMAP  = "YlOrRd"
const ALLOWED_CMAP = "YlOrRd_9"
const RESCUE_CMAP  = "RdPu_8"

function choose_colormap!(d::Dashboard, name)
    if startswith(name, BANNED_CMAP) && name != ALLOWED_CMAP
        d.status[] = DOM.div("⛔ $name is a horrible colormap — only someone as twisted as Alberto " *
                             "could like it. For your own good, switching to $RESCUE_CMAP.";
                             style=Styles("color" => "#b0306a", "font-weight" => "600"))
        name = RESCUE_CMAP
        @async foreach(dd -> set_value!(dd, RESCUE_CMAP), colormap_dropdowns(d))   # the browser follows
    end
    d.colormap[] = name
    return
end

# The colormap dropdowns currently on the page (2D/3D menus, 1D menus).
function colormap_dropdowns(d::Dashboard)
    dds = Bonito.Dropdown[]
    isassigned(d.menus) && push!(dds, d.menus[].colormap)
    m = d.menus1d[]
    m isa NamedTuple && push!(dds, m.cmap)
    return dds
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
    show!(d, DOM.div("Reloading…"))     # also forgets the live figure: rebuild from scratch
    render!(d)
end

function toggle_play!(d::Dashboard)
    p = d.player
    p.playing[]        = !p.playing[]
    p.button.content[] = p.playing[] ? "❚❚" : "▶"
    return
end

busy(db::Debouncer) = db.active || db.pending

# While playing, advance one frame at most `fps` times per second, and only once
# the previous frame is drawn — slow frames slow the animation down instead of
# being skipped. Runs until the session closes.
function start_player!(d::Dashboard)
    p    = d.player
    task = @async begin
        last = 0.0                                   # time of the last frame change
        while !Bonito.isclosed(d.session)
            pause = 0.005                            # poll while paused or drawing
            if p.playing[] && !busy(d.renderer)
                due = last + 1 / p.fps.value[]
                if time() >= due
                    set_value!(d.nfile, mod1(d.nfile.value[] + 1, d.ws.Nfiles))
                    last = time()
                else
                    pause = max(0.001, due - time())  # sleep exactly until the next frame
                end
            end
            sleep(pause)
        end
    end
    Base.errormonitor(task)
end


# ── Top bar ───────────────────────────────────────────────────────────────────

function top_dom(d::Dashboard)
    Ndim = d.dim.value[]
    Ndim == "1D" && return menus_1d_dom!(d)
    Ndim == "2D" && return field_menus_dom!(d, d.current_keys[])
    return DOM.div(field_menus_dom!(d, d.current_keys[]), slice_dom!(d))     # 3D
end

# 3D slice slider for the current run. The selection lives in d.z and is
# clamped (silently, like the field selections) when a run has fewer slices.
function slice_dom!(d::Dashboard)
    nz = d.nz[]
    if nz <= 1
        d.zslider[] = nothing
        return Card(DOM.div("No 3D fields in this run — showing 2D fields"))
    end
    setfield!(d.z, :val, clamp(d.z[], 1, nz))
    slider = Bonito.Slider(1:nz; value=d.z[])
    d.zslider[] = slider
    on(v -> d.z[] = v, d.session, slider.value)
    return Card(Row("Slice z: ", Labeled(slider, slider.value), "/ $nz"))
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
    on(v -> choose_colormap!(d, v), d.session, menus.colormap.value)
    for (o, menu) in zip(d.overlays, menus.overlays)
        on(v -> o.field[] = v, d.session, menu.value)
    end

    return DOM.div(Row(
        Card(Col(
            Row("Heatmap: ",  menus.heatmap),
            Row("Colormap: ", menus.colormap),
            Row("Run range: ", d.fixed_range);
            gap="0px"
        )),
        [overlay_card("Overlay $i", menu, o)
         for (i, (o, menu)) in enumerate(zip(d.overlays, menus.overlays))]...,
    ))
end

# 1D controls for the current run: one checkbox per field, and — when the run
# has 2D fields — where to cut them. Selections live in d.fields1d / d.cut_*
# and survive rebuilds (a new run, or a new cut axis changing the slider length).
function menus_1d_dom!(d::Dashboard)
    keys = d.current_keys[]
    sel  = filter(in(keys), d.fields1d[])
    isempty(sel) && (sel = copy(keys))
    setfield!(d.fields1d, :val, sel)

    boxes = [Bonito.Checkbox(k in sel; style=cb_style) for k in keys]
    for (k, cb) in zip(keys, boxes)
        on(d.session, cb.value) do checked
            cur = d.fields1d[]
            d.fields1d[] = [kk for kk in keys if kk == k ? checked : kk in cur]
        end
    end
    fields = Card(Row("Fields: ", [Row(k, cb; gap="2px") for (k, cb) in zip(keys, boxes)]...))

    view = Bonito.Dropdown(VIEWS_1D; index=something(findfirst(==(d.view1d[]), VIEWS_1D), 1))
    cmap = Bonito.Dropdown(d.ws.all_cmaps; index=findfirst(==(d.colormap[]), d.ws.all_cmaps))
    on(v -> d.view1d[]   = v, d.session, view.value)
    on(v -> choose_colormap!(d, v), d.session, cmap.value)
    views = Card(Row("View: ", view, "Colormap (kymograph): ", cmap))

    n = cut_length(d.shapes[], d.cut_axis[])
    if n == 0                                    # only 1D fields: nothing to cut
        d.menus1d[] = (fields=boxes, view, cmap, axis=nothing, pos=nothing, mean=nothing)
        return DOM.div(views, fields)
    end
    setfield!(d.cut_pos, :val, d.cut_pos[] < 1 ? cld(n, 2) : clamp(d.cut_pos[], 1, n))
    axis = Bonito.Dropdown(["x", "y"]; index=d.cut_axis[] == "x" ? 1 : 2,
                           option_to_string=a -> "along $a")
    pos  = Bonito.Slider(1:n; value=d.cut_pos[])
    mean = Bonito.Checkbox(d.cut_mean[]; style=cb_style)
    on(v -> d.cut_axis[] = v, d.session, axis.value)
    on(v -> d.cut_pos[]  = v, d.session, pos.value)
    on(v -> d.cut_mean[] = v, d.session, mean.value)
    d.menus1d[] = (fields=boxes, view, cmap, axis, pos, mean)
    other = d.cut_axis[] == "x" ? "y" : "x"
    cut = Card(Row("2D fields: profile ", axis, " at $other = ", Labeled(pos, pos.value),
                   " or mean over $other ", mean))
    return DOM.div(views, fields, cut)
end
