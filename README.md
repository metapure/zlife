# zlife

A living sculpture of Conway's Game of Life, built with **Odin + Metal** for
macOS.

This is regular, toroidal B3/S23 Life on a 96×96 grid. The third axis is not
another simulation dimension: **time flows downward**. The searing red plane
on top is the present; up to 255 earlier generations hang beneath it as a
wall of emissive voxels burning from magenta through crimson into ember red
and finally dissolving into black, with no gaps in space or time. The tower
glides downward continuously between generations instead of stepping.

The look is modeled on the Blackwall from Cyberpunk 2077: a breathing
firewall of red data pierced by cold cyan shafts, seen through a glitchy,
chromatically fringed lens, floating in a pure black void.

The scene includes:

- a pulsing searing-red present generation atop a crimson-and-magenta history
- a breathing wall: a slow global inhale/exhale (the voxels physically
  dilate), brightness waves rolling down the timeline, and a roaming
  hotspot wandering the structure
- rare full-height cyan data-shaft columns that slowly migrate, with a
  brightness scroll running down them, plus sparse cyan sparkles and
  per-voxel data flicker
- rare glitch streaks that briefly smear individual voxels vertically
- an HDR post pipeline: bloom, chromatic aberration, scanlines, glitch band
  displacement, vignette, and film grain over a pure black background
- per-voxel ambient occlusion and a ray-marched shading term that keep the
  emissive wall reading as a 3D structure
- a slow ambient camera drift after a few seconds of inactivity
- an editing grid that appears only while the cursor is over the present plane
- full-history and isolated-slice views
- direct painting with a bright cyan hover preview
- five curated pattern presets
- a minimal bitmap HUD in Cyberpunk yellow and red that expands to full
  statistics on demand

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

## Live wallpaper mode

```bash
./zlife --wallpaper   # or -w
./zlife --wallpaper --fps 30
```

Pins the sculpture to the desktop as a live wallpaper: a fullscreen
borderless window at the desktop window level, behind the icons, on every
Space, click-through, and hidden from the Dock and Cmd+Tab. The simulation
starts running immediately with the HUD hidden, and the ambient camera
drift takes over since no input reaches the window.

The wallpaper lives only as long as the process: run it from a terminal and
stop it with **Ctrl+C** (or `kill`) there — keyboard shortcuts do not work in
this mode because the window never receives input.

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
- The frame is built in five passes: the scene (background, grid, cells,
  HUD) renders into a full-resolution RGBA16Float HDR texture; a soft-knee
  bright pass downsamples the hot pixels into a half-resolution texture; a
  separable Gaussian blur ping-pongs it twice; and a composite pass applies
  glitch band displacement, chromatic aberration, bloom, scanlines,
  vignette, grain, and an ACES-style tonemap onto the drawable.
- The downward glide is purely a vertex-shader offset driven by the
  fractional progress toward the next generation; the simulation itself
  still steps discretely.
- Voxel instance data is uploaded only when simulation, editing, selection, or
  preview state changes.
- Rendering is paced at 60 FPS.
- The renderer reports Metal/shader failures and releases all resources it
  owns during shutdown.
