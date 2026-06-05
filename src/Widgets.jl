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
function make_widget_df(tab)
    length(tab) > 1 || return nothing
    isa(tab[1], AbstractString) ? Bonito.Dropdown(tab; index=1) :
                                   Bonito.Slider(tab)
end

# Card containing controls for one overlay field.
function overlay_card(label, drop_over, sl_alpha, sl_stepp, sl_arsize, cb_nematic)
    Card(Grid(Row(
        Col(
            Row("$label: ",         drop_over),
            Row("Min brightness: ", Labeled(sl_alpha, sl_alpha.value)),
        ),
        Col(
            Row("Arrows step: ", Labeled(sl_stepp,  sl_stepp.value)),
            Row("Arrow size: ",  Labeled(sl_arsize, sl_arsize.value)),
            Row("Nematic? ",     cb_nematic),
        )
    )))
end
