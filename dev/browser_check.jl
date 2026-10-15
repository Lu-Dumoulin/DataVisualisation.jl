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
#   png-play  same, in "Use PNG" mode (run Save all first)
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

const ws      = DataWorkspace(CSV_PATH, ".jld")
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
            d = m["params"]["exceptionDetails"]
            push!(LOGS, "$(t())s EXCEPTION: $(get(get(d, "exception", Dict()), "description", d["text"]))")
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
    cdp("Page.navigate", Dict("url" => "http://127.0.0.1:8081"))
    sleep(15)
    state("loaded"); println("      screenshot: ", shot("1_loaded"))

    if SCENARIO == "polar"
        select_option("polar"); sleep(5)
        state("after polar"); println("      screenshot: ", shot("2_polar"))

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
