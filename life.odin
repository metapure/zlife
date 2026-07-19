package main

import "core:math"

GRID :: 96
DEPTH :: 256

// Toward-the-sun direction in world space (x, y-up, z), normalized.
// Must match sun_dir in shaders.metal. Mostly lateral so columns cast long
// sideways shadows across the tower; slightly upward so the march escapes
// past the present plane instead of running forever.
SUN_X :: f32(0.8025)
SUN_Y :: f32(0.3883)
SUN_Z :: f32(0.4530)
SHADOW_STEPS :: 24
DEFAULT_SEED :: u64(0x5A17_1FE5_D00D_BAAD)

Life :: struct {
	layers: [DEPTH][GRID][GRID]u8,
	head: int,
	history_count: int,
	generation: u64,
	live_count: int,
	seed: u64,
}

life_clear :: proc(life: ^Life) {
	life^ = {}
	life.history_count = 1
}

@(private)
life_random_u64 :: proc(state: ^u64) -> u64 {
	// SplitMix64 gives repeatable seeds without relying on global RNG state.
	state^ += 0x9E37_79B9_7F4A_7C15
	z := state^
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

life_randomize :: proc(life: ^Life, seed: u64 = DEFAULT_SEED, fill: f32 = 0.22) {
	life_clear(life)
	life.seed = seed
	state := seed
	for y in 0 ..< GRID {
		for x in 0 ..< GRID {
			sample := f32(life_random_u64(&state) >> 40) / f32(1 << 24)
			if sample < fill {
				life.layers[life.head][y][x] = 1
				life.live_count += 1
			}
		}
	}
}

life_paint :: proc(life: ^Life, x, y: int, alive: bool) {
	if x < 0 || x >= GRID || y < 0 || y >= GRID {
		return
	}
	was_alive := life.layers[life.head][y][x] != 0
	if was_alive == alive {
		return
	}
	life.layers[life.head][y][x] = 1 if alive else 0
	life.live_count += 1 if alive else -1
}

life_toggle :: proc(life: ^Life, x, y: int) {
	if x < 0 || x >= GRID || y < 0 || y >= GRID {
		return
	}
	life_paint(life, x, y, life.layers[life.head][y][x] == 0)
}

life_layer_at_age :: proc(life: ^Life, age: int) -> ^[GRID][GRID]u8 {
	if age < 0 || age >= life.history_count {
		return nil
	}
	return &life.layers[(life.head + age) % DEPTH]
}

@(private)
life_count_neighbors :: proc(layer: ^[GRID][GRID]u8, x, y: int) -> int {
	n := 0
	for dy in -1 ..= 1 {
		for dx in -1 ..= 1 {
			if dx == 0 && dy == 0 {
				continue
			}
			nx := (x + dx + GRID) % GRID
			ny := (y + dy + GRID) % GRID
			n += int(layer[ny][nx])
		}
	}
	return n
}

life_step :: proc(life: ^Life) {
	next: [GRID][GRID]u8
	cur := &life.layers[life.head]
	next_live_count := 0

	for y in 0 ..< GRID {
		for x in 0 ..< GRID {
			neighbors := life_count_neighbors(cur, x, y)
			alive := cur[y][x] != 0
			if alive {
				next[y][x] = 1 if (neighbors == 2 || neighbors == 3) else 0
			} else {
				next[y][x] = 1 if neighbors == 3 else 0
			}
			next_live_count += int(next[y][x])
		}
	}

	// Move the head backward and overwrite only the expired oldest layer.
	life.head = (life.head + DEPTH - 1) % DEPTH
	life.layers[life.head] = next
	life.history_count = min(life.history_count + 1, DEPTH)
	life.generation += 1
	life.live_count = next_live_count
}

Shadow_Step :: struct {
	dx, dy, dz: int,
	dim: f32, // how strongly an occluder at this distance dims the light
}

// Integer sample offsets along the sun ray, shared by every voxel.
@(private)
shadow_steps_build :: proc() -> [SHADOW_STEPS]Shadow_Step {
	steps: [SHADOW_STEPS]Shadow_Step
	STEP :: f32(1.35)
	for s in 0 ..< SHADOW_STEPS {
		t := f32(s + 1) * STEP
		steps[s] = Shadow_Step {
			dx  = int(math.round(SUN_X * t)),
			dy  = int(math.round(SUN_Z * t)),
			dz  = int(math.round(-SUN_Y * t)),
			dim = 0.30 + 0.40 * (f32(s + 1) / f32(SHADOW_STEPS)),
		}
	}
	return steps
}

// March from a voxel toward the sun through the volume and return how much
// light survives. Hits near the voxel darken harder than distant ones, so
// shadows have a soft penumbra. Escaping above the present plane or off the
// grid edge counts as reaching open sky.
@(private)
life_sun_visibility :: proc(
	layers: []^[GRID][GRID]u8,
	steps: []Shadow_Step,
	x, y, z: int,
) -> f32 {
	vis := f32(1.0)
	for step in steps {
		px := x + step.dx
		py := y + step.dy
		pz := z + step.dz
		if pz < 0 {
			break // escaped above the present plane: open sky
		}
		if px < 0 || px >= GRID || py < 0 || py >= GRID || pz >= len(layers) {
			break
		}
		if layers[pz][py][px] != 0 {
			vis *= step.dim
			if vis < 0.04 {
				return 0.04
			}
		}
	}
	return vis
}

life_collect_instances :: proc(
	life: ^Life,
	out: []Instance,
	selected_age: int = 0,
	isolate_selected: bool = false,
) -> int {
	count := 0
	half_w := f32(GRID) * 0.5
	half_h := f32(GRID) * 0.5

	// Resolve the ring buffer once so the shadow march can index layers
	// directly by age instead of doing modular arithmetic per step.
	layer_ptrs: [DEPTH]^[GRID][GRID]u8
	for z in 0 ..< life.history_count {
		layer_ptrs[z] = life_layer_at_age(life, z)
	}
	layers := layer_ptrs[:life.history_count]
	shadow_steps := shadow_steps_build()

	for z in 0 ..< life.history_count {
		if isolate_selected && z != selected_age {
			continue
		}
		layer := life_layer_at_age(life, z)
		// Adjacent layers in time shadow this cell from above and below.
		above, below: ^[GRID][GRID]u8
		if !isolate_selected {
			if z > 0 {
				above = life_layer_at_age(life, z - 1)
			}
			if z < life.history_count - 1 {
				below = life_layer_at_age(life, z + 1)
			}
		}
		age := f32(z) / f32(max(DEPTH - 1, 1))
		for y in 0 ..< GRID {
			for x in 0 ..< GRID {
				if layer[y][x] == 0 {
					continue
				}
				if count >= len(out) {
					return count
				}
				// Face-neighbor occupancy, non-wrapping: the sculpture
				// visually ends at the grid edges.
				occupied := 0
				if x > 0 && layer[y][x - 1] != 0 do occupied += 1
				if x < GRID - 1 && layer[y][x + 1] != 0 do occupied += 1
				if y > 0 && layer[y - 1][x] != 0 do occupied += 1
				if y < GRID - 1 && layer[y + 1][x] != 0 do occupied += 1
				if above != nil && above[y][x] != 0 do occupied += 1
				if below != nil && below[y][x] != 0 do occupied += 1

				// An isolated slice floats alone in space; nothing shadows it.
				sun := f32(1.0)
				if !isolate_selected {
					sun = life_sun_visibility(layers, shadow_steps[:], x, y, z)
				}

				// Time flows downward: the present sits at y = 0, history below it.
				out[count] = Instance {
					center = {
						f32(x) - half_w + 0.5,
						-f32(z),
						f32(y) - half_h + 0.5,
					},
					age       = age,
					scale     = 1.0,
					glow      = 1.0 if z == 0 else (0.35 if z == selected_age else 0.0),
					occlusion = f32(occupied) / 6.0,
					sun       = sun,
				}
				count += 1
			}
		}
	}
	return count
}
