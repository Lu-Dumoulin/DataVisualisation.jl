# ==============================================================================
# dev/browser_check.jl — drive the real app in headless Chrome
# ==============================================================================
#
#   julia dev/browser_check.jl [scenario] [path/to/DF.csv] [outdir]
#
# Starts the dashboard on port 8081, opens it in headless Chrome through the
# DevTools protocol, plays a scenario like a user would, and prints the
# Julia-side state, the browser's widget state and the browser console.
# Screenshots go to outdir (default: a temp dir, printed at the end).
#
# Scenarios:
#   load      just load the page
#   polar     select orientation = polar in the sidebar
#   play      press play for 10 s, report frames shown per second and
#             whether WGLMakie recreated its canvas (it shouldn't, per frame).
#             Optional 4th argument: fps slider value (1,2,4,8,12,24; default 4)
#   png-play  same, in "Use PNG" mode (run "Save all .png" first)
#   3d        switch to 3D, show the first 3D field, drag the slice slider;
#             reports whether slice changes update the figure in place
#   drag      show the first vector field as Overlay 1, then drag its arrow-size
#             slider fast (60 moves, 25 ms apart); reports renders, rebuilt
#             canvases and browser errors
#   hover     move the mouse over the plot (real browser mouse events) and read
#             the value-under-cursor line; then play 2 s with the mouse still
#   range     tick "Run range", play while the range is computed in the
#             background; reports progress, the range and frames shown meanwhile
#   1d        switch to 1D, move the 2D cut, switch its axis, play 3 s;
#             reports whether the figure is updated in place
#
# Needs Google Chrome in /Applications. Not part of the test suite.

import Pkg
Pkg.activate(dirname(@__DIR__); io=devnull)
using DataVisualisation, Bonito, Base64
using Bonito.Observables: on, off
const DV   = DataVisualisation
const HTTP = Bonito.HTTP
const JSON = Bonito.JSON

const SCENARIO = get(ARGS, 1, "load")
const CSV_PATH = get(ARGS, 2, normpath(joinpath(homedir(), "Data/PQ_FFT/DF.csv")))
const OUT      = mkpath(get(ARGS, 3, mktempdir()))
const CHROME   = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const T0       = time()
t() = round(time() - T0; digits=1)

# ── App, with a handle on the Dashboard and a render counter ──────────────────

const EXT     = isempty(DV.get_all_dir_ext(dirname(CSV_PATH); ext=".jld")) ? ".jld2" : ".jld"
const ws      = DataWorkspace(CSV_PATH, EXT)
const DREF    = Ref{Any}(nothing)
const RENDERS   = Float64[]                    # start time of each render
const DURATIONS = Float64[]                    # how long each render took in Julia
const app = App() do s
    d  = DV.dashboard(ws, s)
    f0 = d.renderer.f
    d.renderer.f = () -> (push!(RENDERS, time()); f0(); push!(DURATIONS, time() - RENDERS[end]))
    DREF[] = d
    DV.layout(d)
end
server = Bonito.Server(app, "127.0.0.1", 8081)

chrome = run(`$CHROME --headless=new --remote-debugging-port=9223 --user-data-dir=$(mktempdir())
              --use-angle=swiftshader --enable-unsafe-swiftshader --window-size=1600,1300
              about:blank`; wait=false)
sleep(3)
pages = JSON.parse(String(HTTP.get("http://127.0.0.1:9223/json").body))
wsurl = first(p for p in pages if p["type"] == "page")["webSocketDebuggerUrl"]

const LOGS    = String[]
const REPLIES = Dict{Int,Any}()
const NEXTID  = Ref(0)

try
HTTP.WebSockets.open(wsurl; suppress_close_error=true) do sock
    @async for msg in sock
        m = JSON.parse(String(msg))
        if haskey(m, "id")
            REPLIES[m["id"]] = m
        elseif m["method"] == "Runtime.consoleAPICalled"
            m["params"]["type"] == "debug" && continue                  # Bonito pings
            args = join([get(a, "value", get(a, "description", "?")) for a in m["params"]["args"]], " ")
            push!(LOGS, "$(t())s console.$(m["params"]["type"]): $args")
        elseif m["method"] == "Runtime.exceptionThrown"
            ex = m["params"]["exceptionDetails"]
            push!(LOGS, "$(t())s EXCEPTION: $(get(get(ex, "exception", Dict()), "description", ex["text"]))")
        elseif m["method"] == "Log.entryAdded"
            occursin("GL Driver", m["params"]["entry"]["text"]) && continue
            push!(LOGS, "$(t())s log.$(m["params"]["entry"]["level"]): $(m["params"]["entry"]["text"])")
        end
    end

    function cdp(method, params=Dict())
        id = (NEXTID[] += 1)
        HTTP.WebSockets.send(sock, JSON.json(Dict("id" => id, "method" => method, "params" => params)))
        for _ in 1:600
            haskey(REPLIES, id) && return REPLIES[id]
            sleep(0.05)
        end
        error("no reply to $method")
    end
    js(code) = get(get(get(cdp("Runtime.evaluate",
                   Dict("expression" => code, "returnByValue" => true)), "result", Dict()), "result", Dict()), "value", nothing)
    shot(name) = (f = joinpath(OUT, "$name.png");
                  write(f, base64decode(cdp("Page.captureScreenshot")["result"]["data"])); f)
    function state(label)
        d = DREF[]
        println("$(t())s [$label] run=$(d.pathdir[]) frame=$(d.nfile.value[]) keys=$(d.current_keys[]) ",
                "plot=$(nameof(typeof(d.plot[]))) live=$(nameof(typeof(d.live[]))) renders=$(length(RENDERS))")
        println("      params  = ", [w.value[] for w in d.params])
        println("      browser selects = ", js("[...document.querySelectorAll('select')].map(s=>s.options[s.selectedIndex]?.text).join(', ')"))
    end
    click_button(text) = js("""[...document.querySelectorAll('button')].find(b => b.textContent.includes('$text')).click()""")
    select_option(text) = js("""(() => {
        const s = [...document.querySelectorAll('select')].find(s => [...s.options].some(o => o.text === '$text'));
        s.selectedIndex = [...s.options].findIndex(o => o.text === '$text');
        s.dispatchEvent(new Event('change')); })()""")
    context_resets() = count(l -> occursin("removing WGL context", l), LOGS)

    cdp("Runtime.enable"); cdp("Log.enable"); cdp("Page.enable")
    t_nav = time()
    cdp("Page.navigate", Dict("url" => "http://127.0.0.1:8081"))
    waited = 0.0
    while waited < 60 && !(DREF[] !== nothing && DREF[].live[] !== nothing && !isempty(DURATIONS))
        sleep(0.05); waited += 0.05
    end
    isempty(DURATIONS) || println("$(t())s first figure ready in Julia $(round(RENDERS[1] + DURATIONS[1] - t_nav; digits=2)) s ",
                                  "after the page request (first render itself: $(round(DURATIONS[1]; digits=2)) s)")
    sleep(10)
    state("loaded"); println("      screenshot: ", shot("1_loaded"))

    if SCENARIO == "polar"
        select_option("polar"); sleep(5)
        state("after polar"); println("      screenshot: ", shot("2_polar"))

    elseif SCENARIO == "3d"
        select_option("3D"); sleep(4)
        d = DREF[]
        f3 = findfirst(k -> occursin("3", k), d.current_keys[])     # first field named like a 3D one
        isnothing(f3) || (select_option(d.current_keys[][f3]); sleep(4))
        state("3D"); println("      slices: $(d.nz[])  screenshot: ", shot("2_3d"))
        resets0 = context_resets()
        set_slice(z) = js("""(() => {
            const box = [...document.querySelectorAll('div')].reverse().find(e => e.textContent.startsWith('Slice z:'));
            const s = box.querySelector('input[type=range]');
            s.value = $z; s.dispatchEvent(new Event('input')); return s.value })()""")
        for z in (d.nz[] ÷ 2, d.nz[])
            println("$(t())s slice → ", set_slice(z)); sleep(3)
            println("      Julia z=$(d.z[])  screenshot: ", shot("3_slice$z"))
        end
        println("      WGL canvas recreated while slicing: $(context_resets() - resets0)×")

    elseif SCENARIO == "range"
        d = DREF[]
        renders0 = length(RENDERS)
        js("""(() => { const rows = [...document.querySelectorAll('div')].filter(e =>
            e.textContent.trim().startsWith('Run range:') && e.querySelector('input[type=checkbox]') &&
            ![...e.children].some(c => c.textContent.trim().startsWith('Run range:')));
            rows[0].querySelector('input[type=checkbox]').click() })()""")
        click_button("▶")
        t_tick = time()
        status() = replace(string(d.status[]), r"<[^>]*>" => "")
        while time() - t_tick < 120 && !startswith(status(), "✓")
            println("$(t())s status: ", status(), "  (frame $(d.nfile.value[]))")
            sleep(1)
        end
        println("$(t())s ", status(), " after $(round(time() - t_tick; digits=1)) s; ",
                "$(length(RENDERS) - renders0) frames rendered meanwhile")
        sleep(3); click_button("❚❚"); sleep(1)
        live = d.live[]
        println("      colorrange on screen: ", live isa DV.LiveFigure ? live.style[].colorrange : "?",
                "  canvas recreated $(context_resets())× in total")
        println("      screenshot: ", shot("2_range"))

    elseif SCENARIO == "hover"
        d = DREF[]
        rect = js("""(() => { const c = [...document.querySelectorAll('canvas')].sort((a, b) =>
            b.width * b.height - a.width * a.height)[0].getBoundingClientRect();
            return [c.left, c.top, c.width, c.height] })()""")
        move(fx, fy) = cdp("Input.dispatchMouseEvent", Dict("type" => "mouseMoved",
                           "x" => rect[1] + fx * rect[3], "y" => rect[2] + fy * rect[4]))
        for (fx, fy) in ((0.3, 0.5), (0.45, 0.45), (0.6, 0.3))
            move(fx, fy); sleep(1.5)
            println("$(t())s mouse at ($fx, $fy) of the canvas → \"$(d.cursor[])\"")
        end
        println("      screenshot: ", shot("2_hover"))
        click_button("▶"); sleep(2); click_button("❚❚"); sleep(1)
        println("$(t())s after playing, mouse still → \"$(d.cursor[])\" (frame $(d.nfile.value[]))")
        move(0.99, 0.99); sleep(1.5)
        println("$(t())s mouse outside the axis → \"$(d.cursor[])\"")

    elseif SCENARIO == "drag"
        d = DREF[]
        vec = findfirst(k -> length(get(d.shapes[], k, ())) >= 3, d.current_keys[])
        d.overlays[1].field[] = d.current_keys[][something(vec, 1)]; sleep(4)
        # drag a slider of Overlay 1 fast: 60 moves, 25 ms apart (the first, innermost
        # row whose text starts with `label`)
        drag(label, n) = js("""(async () => {
            const rows = [...document.querySelectorAll('div')].filter(e =>
                e.textContent.trim().startsWith('$label') && e.querySelector('input[type=range]') &&
                ![...e.children].some(c => c.textContent.trim().startsWith('$label')));
            const s = rows[0].querySelector('input[type=range]');
            for (let k = 0; k < 60; k++) {
                s.value = 1 + (k % $n); s.dispatchEvent(new Event('input'));
                await new Promise(r => setTimeout(r, 25));
            } })()""")
        nerr() = count(l -> occursin(r"EXCEPTION|error"i, l), LOGS)
        for (label, n, what) in (("Arrow size:", 15, "size (in place)"), ("Arrows step:", 5, "step (rebuilds)"))
            resets0, renders0, errs0 = context_resets(), length(RENDERS), nerr()
            println("$(t())s dragging arrow $what of overlay 1 ($(d.overlays[1].field[]))")
            drag(label, n); sleep(8)
            println("$(t())s after drag: $(length(RENDERS) - renders0) renders, canvas recreated ",
                    "$(context_resets() - resets0)×, new browser errors: $(nerr() - errs0), ",
                    "arrowsize=$(d.overlays[1].arrowsize.value[]) step=$(d.overlays[1].stepp.value[])")
        end
        state("after drag"); println("      screenshot: ", shot("2_drag"))

    elseif SCENARIO == "1d"
        d = DREF[]
        d.dim.value[] == "1D" || (select_option("1D"); sleep(4))
        state("1D"); println("      fields=$(d.fields1d[]) cut=$(d.cut_axis[])@$(d.cut_pos[])  screenshot: ", shot("2_1d"))
        resets0 = context_resets()
        if d.menus1d[].pos !== nothing
            js("""(() => {
                const box = [...document.querySelectorAll('div')].reverse().find(e => e.textContent.startsWith('2D fields: profile'));
                const s = box.querySelector('input[type=range]'); s.value = 1; s.dispatchEvent(new Event('input')); })()""")
            sleep(3); println("$(t())s cut moved: Julia cut_pos=$(d.cut_pos[])  screenshot: ", shot("3_cut1"))
            select_option("along y"); sleep(4)
            println("$(t())s axis y: Julia cut=$(d.cut_axis[])@$(d.cut_pos[])  screenshot: ", shot("4_axis_y"))
        end
        r0 = context_resets(); click_button("▶"); sleep(3); click_button("❚❚"); sleep(1)
        println("$(t())s played to frame $(d.nfile.value[]); WGL canvas recreated while cutting: $(r0 - resets0)×, while playing: $(context_resets() - r0)×")
        for v in ("Kymograph", "Times overlaid")
            select_option(v); sleep(6)
            r1 = context_resets(); click_button("▶"); sleep(3); click_button("❚❚"); sleep(1)
            println("$(t())s $v: live=$(nameof(typeof(d.live[]))), canvas recreated while playing: $(context_resets() - r1)×  screenshot: ", shot("5_$(replace(v, ' ' => '_'))"))
        end

    elseif SCENARIO in ("play", "png-play")
        SCENARIO == "png-play" && (click_button("Use PNG"); sleep(3))
        length(ARGS) >= 4 && DV.set_value!(DREF[].player.fps, parse(Int, ARGS[4]))
        resets0, renders0, frame0 = context_resets(), length(RENDERS), DREF[].nfile.value[]
        frames = Int[]
        fr = on(v -> (isempty(frames) || frames[end] != v) && push!(frames, v), DREF[].nfile.value)
        click_button("▶"); t_play = time(); sleep(10)
        click_button("❚❚"); dt = time() - t_play; sleep(1)
        n = length(RENDERS) - renders0
        off(fr)
        println("$(t())s played $(round(dt; digits=1)) s: $(length(frames)) frames ≈ $(round(length(frames) / dt; digits=1)) frames/s, $n renders",
                " (fps slider = $(DREF[].player.fps.value[])), frame $frame0 → $(DREF[].nfile.value[]), ",
                "WGL canvas recreated $(context_resets() - resets0)×")
        gaps = diff(RENDERS[renders0+1:end])
        isempty(gaps) || println("      time between frames: median $(round(1000 * sort(gaps)[cld(end, 2)]; digits=0)) ms, ",
                                 "min $(round(1000 * minimum(gaps); digits=0)) ms, max $(round(1000 * maximum(gaps); digits=0)) ms (gap #$(argmax(gaps)) of $(length(gaps)))")
        durs = DURATIONS[renders0+1:end]
        isempty(durs) || println("      render time in Julia: first $(round(1000 * durs[1]; digits=0)) ms, ",
                                 "then median $(round(1000 * sort(durs[2:end])[cld(end, 2)]; digits=0)) ms")
        state("after play"); println("      screenshot: ", shot("2_$SCENARIO"))
    end
    close(sock)
end
finally
    println("---- browser console ----"); foreach(println, LOGS)
    println("screenshots in $OUT")
    kill(chrome); close(server)
end
exit()
