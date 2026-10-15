# ==============================================================================
# Widgets.jl — styles, widget factories, reusable UI components
# ==============================================================================


# ── Styles ────────────────────────────────────────────────────────────────────

const cb_style = Styles(
    CSS("font-weight" => "10"),
    CSS(":hover", "background-color" => "silver"),
    CSS(":focus", "box-shadow" => "rgba(0,0,0,0.5) 0px 0px 5px"),
    CSS("width"  => "14px"),
    CSS("height" => "14px"),
)

const button_style = Styles(
    "background"    => "white",
    "border"        => "1px solid black",
    "border-radius" => "4px",
    "cursor"        => "pointer",
    "padding"       => "2px 8px",
    "height"        => "2rem",
)


# ── Factories ─────────────────────────────────────────────────────────────────

function make_alpha_slider()
    StylableSlider(0.0:0.1:1.0; value=1.0, slider_height=20,
        track_color="white", track_active_color="#F0F8FF", thumb_color="black",
        style=Styles(CSS("border-radius" => "0px")),
        track_style=Styles("border-radius" => "3px", "border" => "1px solid black"),
        thumb_style=Styles("border-radius" => "3px", "border" => "1px solid black"),
    )
end

# Slider or Dropdown depending on the type of the parameter values.
# `init` is the starting value (e.g. the first DataFrame row's value for this variable).
function make_widget_df(tab, init)
    length(tab) > 1 || return nothing
    isa(tab[1], AbstractString) ?
        Bonito.Dropdown(tab; index=something(findfirst(==(init), tab), 1)) :
        Bonito.Slider(tab; value=init)
end

# Controls for one overlay. `field` is a plain observable, not a dropdown:
# the field dropdowns are rebuilt when the key list changes, the selection survives.
struct OverlayControls
    field     ::Observable{String}           # "None" = no overlay
    alpha     ::Bonito.StylableSlider
    stepp     ::Bonito.Slider{Int}
    arrowsize ::Bonito.Slider{Int}
    nematic   ::Bonito.Checkbox
end

OverlayControls() = OverlayControls(
    Observable("None"),
    make_alpha_slider(),
    Bonito.Slider([5, 10, 15, 20, 25]; value=20),
    Bonito.Slider(1:15; value=5),
    Bonito.Checkbox(false; style=cb_style),
)

OverlayConfig(o::OverlayControls) = OverlayConfig(;
    field     = o.field[],
    alpha     = Float64(o.alpha.value[]),
    stepp     = Int(o.stepp.value[]),
    arrowsize = Float64(o.arrowsize.value[]),
    nematic   = o.nematic.value[],
)

# Observables whose change requires a re-render.
plot_triggers(o::OverlayControls) =
    Any[o.field, o.alpha.value, o.stepp.value, o.arrowsize.value, o.nematic.value]

# Set a widget's value from Julia so that the browser follows. Bonito's Slider
# and Dropdown display their *index*; writing `.value` alone changes the label
# and the Julia side but leaves the thumb / selection where it was.
function set_value!(s::Bonito.Slider, v)
    i = findfirst(==(v), s.values[])
    isnothing(i) && return
    s.index[] != i && (s.index[] = i)
    s.value[] != v && (s.value[] = v)
    return
end

function set_value!(dd::Bonito.Dropdown, v)
    i = findfirst(==(v), dd.options[])
    isnothing(i) && return
    dd.option_index[] != i && (dd.option_index[] = i)      # also updates dd.value
    return
end

# Card containing controls for one overlay field.
function overlay_card(label, drop_over, o::OverlayControls)
    Card(Grid(Row(
        Col(
            Row("$label: ",         drop_over),
            Row("Min brightness: ", Labeled(o.alpha, o.alpha.value)),
        ),
        Col(
            Row("Arrows step: ", Labeled(o.stepp,     o.stepp.value)),
            Row("Arrow size: ",  Labeled(o.arrowsize, o.arrowsize.value)),
            Row("Nematic? ",     o.nematic),
        )
    )))
end
