@testset "make_widget_df" begin
    @test isnothing(DV.make_widget_df([1.0], 1.0))           # constant parameter → no widget

    sl = DV.make_widget_df([10.0, 20.0, 50.0], 20.0)
    @test sl isa Bonito.Slider{Float64}
    @test sl.values[] == [10.0, 20.0, 50.0]
    @test sl.value[] == 20.0

    dd = DV.make_widget_df(["nematic", "polar"], "polar")
    @test dd isa Bonito.Dropdown
    @test dd.options[] == ["nematic", "polar"]
    @test dd.value[] == "polar"

    # unknown initial string → falls back to the first option
    @test DV.make_widget_df(["a", "b"], "zzz").value[] == "a"
end

@testset "make_alpha_slider" begin
    s = DV.make_alpha_slider()
    @test s isa Bonito.StylableSlider
    @test s.value[] == 1.0                                   # default: no transparency mask
end

@testset "OverlayControls" begin
    o = DV.OverlayControls()
    @test o.field[] == "None"
    cfg = DV.OverlayConfig(o)
    @test cfg == DV.OverlayConfig(; field="None", alpha=1.0, stepp=20, arrowsize=5.0, nematic=false)

    o.field[] = "v"; o.alpha.value[] = 0.3; o.stepp.value[] = 10
    o.arrowsize.value[] = 7; o.nematic.value[] = true
    @test DV.OverlayConfig(o) == DV.OverlayConfig(; field="v", alpha=0.3, stepp=10, arrowsize=7.0, nematic=true)

    @test length(DV.plot_triggers(o)) == 5
    @test contains_obj(DV.plot_triggers(o), o.field)
end

@testset "overlay_card" begin
    o     = DV.OverlayControls()
    drop  = Bonito.Dropdown(["None", "v"])
    card  = DV.overlay_card("Overlay 1", drop, o)
    found = collect_widgets(card)
    @test all(w -> contains_obj(found, w), (drop, o.alpha, o.stepp, o.arrowsize, o.nematic))
    s = Bonito.Session()
    @test occursin("Overlay 1", string(Bonito.session_dom(s, card)))
    close(s)
end

@testset "set_value! moves what the browser shows" begin
    # The browser follows .index / .option_index; .value alone is Julia-only.
    sl = Bonito.Slider([0.0, 0.1, 0.2])
    DV.set_value!(sl, 0.2)
    @test sl.index[] == 3 && sl.value[] == 0.2
    DV.set_value!(sl, 0.5)                                   # not an option → no-op
    @test sl.index[] == 3 && sl.value[] == 0.2

    dd = Bonito.Dropdown(["nematopolar", "none", "polar"]; index=2)
    DV.set_value!(dd, "polar")
    @test dd.option_index[] == 3 && dd.value[] == "polar"
    DV.set_value!(dd, "zzz")
    @test dd.option_index[] == 3

    # no-op writes don't notify (avoids needless snaps/renders)
    hits = Ref(0)
    on(_ -> hits[] += 1, dd.option_index)
    DV.set_value!(dd, "polar")
    @test hits[] == 0
end

@testset "styles" begin
    @test DV.cb_style isa Bonito.Styles
    @test DV.button_style isa Bonito.Styles
end
