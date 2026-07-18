# zlife

A living sculpture of Conway's Game of Life, built with **Odin + Metal** for
macOS.

This is regular, toroidal B3/S23 Life on a 48×48 grid. The third axis is not
another simulation dimension: **Z is time**. The warm, luminous layer at
`z = 0` is the present; up to 47 earlier generations trail behind it as
contiguous violet and blue voxels with no gaps in space or time.

The scene includes:

- a luminous present generation and depth-faded, gapless history
- a luminous editing grid and timeline volume bounds
- full-history and isolated-slice views
- direct painting with a cyan hover preview
- five curated pattern presets
- an in-app bitmap HUD with simulation and rendering statistics

## Requirements

- macOS with Metal
- [Odin](https://odin-lang.org/)
- SDL2 (`brew install sdl2`)

## Build & run

```bash
odin run . -out:zlife
```

Or:

```bash
odin build . -out:zlife
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
- **Middle drag** — pan
- **Scroll** — zoom
- **F** — reset the camera

Editing always affects the present (`z = 0`) generation.

### Simulation and history

- **Space** — pause or play
- **N** — step one generation
- **- / =** — halve or double simulation speed (1–64 Hz, default 60 Hz)
- **[ / ]** — scrub the highlighted historical slice
- **H** — isolate the highlighted slice or restore the full volume
- **R** — create a newly seeded random world
- **C** — clear the timeline

### Patterns and display

- **Tab / Shift+Tab** — select the next or previous pattern
- **P** — replace the world with the selected pattern
- **Hold Shift** — preview the selected pattern under the cursor
- **Shift+P** — stamp that preview into the present
- **G** — toggle the editing grid and volume bounds
- **U** — toggle the HUD
- **Esc** — quit

Included patterns are Glider Fleet, Pulsar, R-pentomino, Acorn, and Diehard.

Starts **paused** with a random seed so you can paint before pressing Space.

## Implementation notes

- Generation history is stored as a ring buffer, so stepping overwrites only
  the expired oldest slice instead of shifting the full 3D volume.
- Cells, grid lines, and HUD glyphs use separate Metal render passes.
- Voxel instance data is uploaded only when simulation, editing, selection, or
  preview state changes.
- Rendering is paced at 60 FPS.
- The renderer reports Metal/shader failures and releases all resources it
  owns during shutdown.
