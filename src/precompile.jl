# ==============================================================================
# precompile.jl — run the app's main paths once at precompile time
# ==============================================================================
#
# Without this, the first page load spends seconds compiling, and so does the
# first frame change after pressing play. The workload builds a dashboard on a
# tiny generated ensemble (2D, 3D and 1D fields), renders it to a page, and
# renders every view, including in-place updates. It skips connect! and the
# player: they start background tasks, which precompilation must not leave
# running.

using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    root = mktempdir()
    CSV.write(joinpath(root, "DF.csv"), DataFrame(a=[1.0, 2.0], m=["p", "q"], fn=["r1", "r2"]))
    for (r, fn) in enumerate(["r1", "r2"]), t in 1:2
        dir = joinpath(root, fn, "Data")
        mkpath(dir)
        jldsave(joinpath(dir, "000$t.jld");
                rho = fill(Float64(r + t), 8, 6), v = rand(8, 6, 2),
                s3  = rand(8, 6, 3), v3 = rand(8, 6, 3, 3), u = rand(8))
    end

    @compile_workload begin
        ws = DataWorkspace(joinpath(root, "DF.csv"), ".jld")
        s  = Bonito.Session()
        d  = Dashboard(ws, s)
        Bonito.session_dom(s, layout(d))            # the page, with every widget

        d.overlays[1].field[] = "v"
        d.overlays[1].alpha.value[] = 0.5
        for Ndim in ("2D", "3D", "1D")
            d.dim.value[] = Ndim
            d.top[] = top_dom(d)
            for nfile in (1, 2, 1)                  # build, then update in place
                d.nfile.value[] = nfile
                render!(d)
            end
        end
        d.heatmap[] = "v3"; d.dim.value[] = "3D"; render!(d)
        d.dim.value[] = "1D"
        for view in VIEWS_1D
            d.view1d[] = view
            render!(d); d.nfile.value[] = 2; render!(d)
        end
        set_value!(d.params[1], 2.0)
        snap!(d)
        d.use_png[] = true; render!(d)
        close(s)
    end
end
