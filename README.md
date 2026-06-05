# DataVisualisation.jl

Interactive parameter-space explorer for 2D hydrodynamic simulations.
Built on [Bonito](https://github.com/SimonDanisch/Bonito.jl) and [WGLMakie](https://docs.makie.org/stable/), it works both as a standalone web app and embedded in a [Pluto](https://plutojl.org/) notebook.

---

## Features

- **Parameter-space navigation** — sliders and dropdowns reflect every varying parameter in your simulation ensemble; the app snaps to the nearest available run
- **Pin checkboxes** — lock any parameter to prevent it from being snapped away while you sweep another
- **2D heatmap** — any scalar or vector field (norm displayed for vector), with free colormap selection
- **Two independent overlays** — arrow glyphs for vector fields (polar or nematic/headless), with per-overlay transparency mask and step/size controls
- **Time animation** — slider over all output frames, play/pause button, configurable frame rate
- **Aspect-ratio-aware figures** — canvas size is computed from the field's `(Nx, Ny)` dimensions, with a tunable base size slider
- **Export** — save every frame of the current run as a PNG via CairoMakie in one click
- **Pluto embedding** — `scale` kwarg shrinks the whole UI to fit inside a notebook cell

---

## Installation

```julia
]add [https://github.com/Lu-Dumoulin/DataVisualisation.jl]
```

---

## Data format

The package expects one CSV file describing the ensemble and a directory tree of JLD2 output files:

```
/data_root/
├── DF.csv
├── run_001/
│   └── Data/
│       ├── t0001.jld
│       ├── t0002.jld
│       └── ...
├── run_002/
│   └── Data/
│       └── ...
└── ...
```

`DF.csv` has one row per simulation run. Every column is a parameter except `fn`, which gives the folder name for that run:

| Re   | Pe   | phi  | fn      |
|------|------|------|---------|
| 10.0 | 1.0  | 0.5  | run_001 |
| 10.0 | 5.0  | 0.5  | run_002 |
| 50.0 | 1.0  | 0.5  | run_003 |

Each `.jld` file must contain the field arrays keyed by name (e.g. `"vx"`, `"vy"`, `"pressure"`). Scalar fields have shape `(Nx, Ny)` and vector fields `(Nx, Ny, 2)`.

---

## Usage

### Standalone

```julia
using DataVisualisation, Bonito

ws  = DataWorkspace("/data_root/DF.csv", ".jld")
app = explor_app(ws)
Bonito.Server(app, "127.0.0.1", 8080)   # open localhost:8080 in a browser
```

### Pluto notebook

```julia
using DataVisualisation

ws = DataWorkspace("/data_root/DF.csv", ".jld")
explor_app(ws; scale=0.75)
```

The `scale` argument applies a CSS zoom to the whole UI, which is the easiest way to fit the app inside a notebook cell.

---

## API

### `DataWorkspace(path_to_csv, ext)`

Loads the ensemble descriptor and pre-computes the parameter ranges used for nearest-row snapping.

| Argument      | Type     | Description                              |
|---------------|----------|------------------------------------------|
| `path_to_csv` | `String` | Absolute path to the CSV file            |
| `ext`         | `String` | File extension of output files (`.jld`)  |

### `explor_app(ws; width, height, scale)`

Returns a Bonito `App` displaying the full dashboard.

| Keyword  | Default    | Description                                      |
|----------|------------|--------------------------------------------------|
| `width`  | `"100%"`   | CSS width of the root container                  |
| `height` | `"1000px"` | CSS height of the root container                 |
| `scale`  | `1.0`      | CSS zoom applied to the whole UI (e.g. `0.75`)   |

The **Fig size** slider inside the app (200 – 1600 px) controls the Makie canvas base dimension; the canvas aspect ratio is always derived from the plotted field's `(Nx, Ny)`.

---

## UI overview

```
┌──────────────┬──────────────────────────────────────────┐
│ Dimension    │  Heatmap | Colormap | Overlay 1 | Overlay 2│
│ Fig size     ├──────────────────────────────────────────┤
├──────────────┤                                          │
│ Parameter 1  │                                          │
│ Parameter 2  │              Plot                        │
│  ...         │                                          │
│              │                                          │
├──────────────┴──────────────────────────────────────────┤
│  Time ──●──────  ▶  ↺ Reset  💾 Save all  🖼 Use PNG    │
└─────────────────────────────────────────────────────────┘
```

- **Overlay controls**: field selector, min-brightness slider (transparency mask), arrows step, arrow size, nematic toggle (headless doubled-angle arrows)
- **Save all**: exports every frame of the current run to a `../Fig/` folder as PNG using CairoMakie
- **Use PNG / Use Field**: toggles between recomputing from raw data and displaying pre-saved PNGs
