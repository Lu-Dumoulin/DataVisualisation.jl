# DataVisualisation.jl

Interactive parameter-space explorer for 1D, 2D and 3D simulation ensembles.
Built on [Bonito](https://github.com/SimonDanisch/Bonito.jl) and [WGLMakie](https://docs.makie.org/stable/), it works both as a standalone web app and embedded in a [Pluto](https://plutojl.org/) notebook.

---

## Features

- **Parameter-space navigation** — sliders and dropdowns reflect every varying parameter in your simulation ensemble; the app snaps to the nearest available run, keeping the parameter you just changed
- **Pin checkboxes** — lock any parameter to prevent it from being snapped away while you sweep another
- **2D heatmap** — any scalar or vector field (norm displayed for vector), with free colormap selection
- **Two independent overlays** — arrows for vector fields (polar or nematic/headless), normalized by the field's max norm (shown above the plot), black or white, with per-overlay transparency mask and step/size controls
- **3D** — one z-slice at a time with a **Slice z** slider, for 3D fields and stacks of 2D fields
- **1D** — profiles, kymograph or times overlaid, for 1D fields and for cuts through 2D fields
- **Smooth animation** — frames, slices and cuts update the figure in place; play/pause with an fps limit, never skipping a frame; large heatmaps are downscaled to the canvas
- **Aspect-ratio-aware figures** — canvas size is computed from the field's `(Nx, Ny)` dimensions, with a tunable base size slider
- **Export** — save every frame of the current run as a PNG via CairoMakie in one click, and replay the PNGs
- **Demo data** — a generated ensemble to try the app without simulations (`julia demo.jl`)
- **Pluto embedding** — `scale` kwarg shrinks the whole UI to fit inside a notebook cell

---

## Installation

```julia
]add https://github.com/Lu-Dumoulin/DataVisualisation.jl
```

Or, from a clone of this repository, `julia run.jl` (edit the `DF.csv` path inside) runs the dashboard from the checkout itself, whatever your global environment holds.

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

Each `.jld` file must contain the field arrays keyed by name (e.g. `"vx"`, `"vy"`, `"pressure"`); anything that isn't a numeric array (metadata such as a JLD2 `_creator` group) is ignored. Field shapes:

| Shape | Meaning | In the **3D** view |
|---|---|---|
| `(Nx, Ny)` | 2D scalar | shown as is |
| `(Nx, Ny, 2)` | 2D vector | shown as is |
| `(Nx, Ny, Nz)`, `Nz ≠ 2` | 3D scalar, or a stack of 2D fields (e.g. phase fields) | one z-slice, chosen with the **Slice z** slider |
| `(Nx, Ny, Nz, c)` | 3D vector | one z-slice: heatmap = full norm, arrows = in-plane (x, y) components |

Changing the slice updates the figure in place, like changing the frame; *Save all* exports the current slice.

### 1D view

Choose **Dimension: 1D** (selected automatically when a run only has 1D fields `(Nx,)`):

- **Fields** — one panel per ticked field.
- **View** — *Profiles* (the current frame), *Kymograph* (x–t heatmap of the whole run, a line marks the current frame) or *Times overlaid* (curves coloured by time, the current one in black). Frame files named by a number (e.g. `0000000025.jld`) give the time axis; otherwise frames are numbered.
- **2D fields** are cut into profiles *along x* or *along y*, at a position of the other axis, or averaged over it (2D vectors through their norm).

### Single-file runs

Runs stored as one file holding `data = (points, fields, times)` — e.g. `PS_FFT_P_1D/1/Data/data_2.jld` — are converted to the standard layout first (into a temporary folder; the source is not modified). Each file becomes a run, selectable from the sidebar:

```julia
ws = DataWorkspace(unstack_runs(expanduser("~/Data/PS_FFT_P_1D"); fields=["rho", "v", "P"]), ".jld")
```

---

## Try it without simulation data

```
julia demo.jl 2        # or 1, 3
```

generates a demo ensemble (`demo_dataset`) in a temporary folder and opens the dashboard on it. Runs are a dense **sphere** or **cube** (disc / square in 2D) of three radii, with **polar**, **nematic** or **nemato-polar** order and **normal** or **tangential** anchoring — an aster or a vortex — breathing and drifting in time. The grid is non-square and the object off-centre, so a swapped axis or a flipped arrow is easy to spot. From Julia:

```julia
csv = demo_dataset(dims=3)                       # or demo_dataset("some/folder"; dims=3) to keep it
explor_app(DataWorkspace(csv, ".jld"))
```

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
| `path_to_csv` | `String` | Path to the CSV file                     |
| `ext`         | `String` | File extension of output files (`.jld`)  |

### `explor_app(ws; width, height, scale)`

Returns a Bonito `App` displaying the full dashboard.

| Keyword  | Default    | Description                                      |
|----------|------------|--------------------------------------------------|
| `width`  | `"100%"`   | CSS width of the root container                  |
| `height` | `"auto"`   | CSS height of the root container; `"auto"` grows with the figure, a fixed value (e.g. `"800px"`) scrolls inside |
| `scale`  | `1.0`      | CSS zoom applied to the whole UI (e.g. `0.75`)   |

The **Fig size** slider inside the app (200 – 1600 px) controls the Makie canvas base dimension; the canvas aspect ratio is always derived from the plotted field's `(Nx, Ny)`.

### `unstack_runs(src, dest=mktempdir(); fields, key="data")`

Converts runs stored as one file each (`key` = `(points, fields, times)` array) to the standard layout and returns the new `DF.csv` path — see [Single-file runs](#single-file-runs).

### `demo_dataset(dest=mktempdir(); dims=2, …)`

Writes the demo ensemble and returns its `DF.csv` path — see [Try it without simulation data](#try-it-without-simulation-data). Keyword arguments set the grid, number of frames, radii, shapes, orders and anchorings; `layout=:stacked` (1D) writes single-file runs for `unstack_runs`. The default temporary folder is deleted when Julia exits.

---

## UI overview

```
┌──────────────┬───────────────────────────────────────────┐
│ Dimension    │ Heatmap | Colormap | Overlay 1 | Overlay 2│
│ Fig size     │ (3D: + Slice z)   (1D: View, Fields, cut) │
│              ├───────────────────────────────────────────┤
├──────────────┤                                           │
│ Parameter 1  │                                           │
│ Parameter 2  │              Plot                         │
│  ...         │                                           │
│              │                                           │
├──────────────┴───────────────────────────────────────────┤
│  Time ──●──  ▶  fps ──●──  ↺ Reset  💾 Save all  🖼 Use PNG│
└──────────────────────────────────────────────────────────┘
```

- **Overlay controls**: field selector, min-brightness slider (transparency mask), arrows step, arrow size, **Color** switch (black / white; overlay 1 black and overlay 2 white by default) and **Nematic?** (headless doubled-angle arrows). Arrows are normalized by the field's maximum norm (|Q| for nematic fields), which is shown above the plot for every frame — the longest arrow spans one arrow spacing at size 5. Fields whose max norm is below 1e-6 (numerical noise) get no arrows.
- **Save all**: exports every frame of the current run to a `../Fig/` folder as PNG using CairoMakie
- **Use PNG / Use Field**: toggles between recomputing from raw data and displaying pre-saved PNGs (shown as plain images: the fastest way to animate)
- **▶ / fps**: plays the run at up to `fps` frames per second; a frame is never skipped — if drawing is slower, playback slows down instead. In field mode, frames update the figure in place, and heatmaps larger than the Fig size are block-averaged down to it (exported PNGs keep full resolution)

---

## Development

```
julia --project=. -e 'using Pkg; Pkg.test()'          # full test suite (~40 s)
julia dev/browser_check.jl play path/to/DF.csv out/ 24 # drive the app in headless Chrome
```

`dev/browser_check.jl` (needs Google Chrome) opens the dashboard in a real browser through the DevTools protocol and reports what the tests can't see: browser console errors, frames per second, whether figures are rebuilt or updated in place, and screenshots. Scenarios: `load`, `polar`, `play`, `png-play`, `3d`, `1d`.
