# zlife

A living sculpture of Conway's Game of Life, built with **Odin + Metal** for
macOS.

This is regular, toroidal B3/S23 Life on a 96×96 grid. The third axis is not
another simulation dimension: **time flows downward**. The luminous ice-white
plane on top is the present; up to 255 earlier generations hang beneath it as
a monolith of blue-white voxels deepening into slate and finally dissolving
into black, with no gaps in space or time. The tower glides downward
continuously between generations instead of stepping.

The scene includes:

- a gently pulsing present generation atop a luminous ice-blue history
- per-voxel ambient occlusion and an icy rim light
- a subtle film-grain overlay on an otherwise clean, pure-black frame
- a slow ambient camera drift after a few seconds of inactivity
- an editing grid that appears only while the cursor is over the present plane
- full-history and isolated-slice views
- direct painting with a warm-white hover preview
- five curated pattern presets
- a minimal bitmap HUD that expands to full statistics on demand

## Requirements

- macOS with Metal
- [Odin](https://odin-lang.org/)
- SDL2 (`brew install sdl2`)

## Build & run

```bash
odin run . -out:zlife
odin run . -out:zlife -o:aggressive
```

Or:

```bash
odin build . -out:zlife -o:aggressive
./zlife
```

Run the tests with:

```bash
odin test .
```

## Controls

### Camera and editing

- **Left drag** — toggle a cell, then continue painting the same state
- **Shift + left drag** — erase cells
- **Right drag** — orbit the sculpture
- **Shift + right drag** or **middle drag** — pan (translate the view)
- **Scroll** — zoom
- **F** — reset the camera
- **V** — print the current camera values to the terminal (the full HUD also
  shows them live), ready to paste into `camera_default`

Editing always affects the present (top) generation. The fine editing grid
fades in only while the cursor is over the present plane.

### Simulation and history

- **Space** — pause or play
- **N** — step one generation
- **- / =** — halve or double simulation speed (1–64 Hz, default 8 Hz)
- **[ / ]** — scrub the highlighted historical slice
- **H** — isolate the highlighted slice or restore the full volume
- **R** — create a newly seeded random world
- **C** — clear the timeline

While running, the simulation watches for stagnation: Life is deterministic,
so if a generation exactly matches any of the up-to-255 stored earlier
generations, the world would repeat forever (still lifes, oscillators, or
extinction). When that happens, a few small random soup patches are crashed
into the present layer to keep the sculpture evolving. The full HUD shows the
detected period and how many soups have been injected. Manual stepping with
**N** detects cycles but never injects.

### Patterns and display

- **Tab / Shift+Tab** — select the next or previous pattern
- **P** — replace the world with the selected pattern
- **Hold Shift** — preview the selected pattern under the cursor
- **Shift+P** — stamp that preview into the present
- **G** — toggle the hover editing grid
- **U** — cycle the HUD: minimal, full statistics, hidden
- **Esc** — quit

Included patterns are Glider Fleet, Pulsar, R-pentomino, Acorn, and Diehard.

Starts **paused** with a random seed so you can paint before pressing Space.

## Implementation notes

- Generation history is stored as a ring buffer, so stepping overwrites only
  the expired oldest slice instead of shifting the full 3D volume.
- Cells, grid lines, HUD glyphs, and the film-grain overlay use separate
  Metal pipelines within a single render pass.
- The downward glide is purely a vertex-shader offset driven by the
  fractional progress toward the next generation; the simulation itself
  still steps discretely.
- Voxel instance data is uploaded only when simulation, editing, selection, or
  preview state changes.
- Rendering is paced at 60 FPS.
- The renderer reports Metal/shader failures and releases all resources it
  owns during shutdown.
