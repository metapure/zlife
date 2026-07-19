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

// Local stagnation detection: the global cycle detector needs the entire
// grid to repeat, so a single chaotic pocket can keep the rest of the wall
// frozen forever. Tiles that keep repeating with a small period while the
// world as a whole evolves are locally stuck and become breach targets.
TILE_SIZE :: 16
TILE_COUNT :: GRID / TILE_SIZE
// Longest oscillator period the tile detector can recognize (covers still
// lifes, blinkers, pulsars, and most common small oscillators).
LOCAL_PERIOD_MAX :: 6
// Generations a live tile must stay cyclic before it counts as stuck.
LOCAL_STAGNATION_GENS :: 64

Life :: struct {
	layers: [DEPTH][GRID][GRID]u8,
	// Blackwall corruption per cell, ring-aligned with layers. 255 = a cell
	// that just breached through the wall; descendants inherit a decayed
	// dose, so infections spread with the cells and cool back to zero.
	corruption: [DEPTH][GRID][GRID]u8,
	layer_hashes: [DEPTH]u64, // ring-aligned with layers
	head: int,
	history_count: int,
	generation: u64,
	live_count: int,
	seed: u64,
	rng: u64, // perturbation randomness, independent of the world seed
	cycle_period: int, // 0 = evolving; otherwise period detected by the last step
	injection_count: u64,
	tile_hashes: [LOCAL_PERIOD_MAX][TILE_COUNT][TILE_COUNT]u64, // ring by generation
	tile_stagnant: [TILE_COUNT][TILE_COUNT]int, // generations each tile has stayed cyclic
	tile_live: [TILE_COUNT][TILE_COUNT]int, // live cells per tile in the head layer
}

life_clear :: proc(life: ^Life) {
	life^ = {}
	life.history_count = 1
	life.rng = DEFAULT_SEED
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
	life.rng = seed
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

@(private)
life_layer_hash :: proc(layer: ^[GRID][GRID]u8) -> u64 {
	// FNV-1a over the raw cell bytes.
	h := u64(0xCBF2_9CE4_8422_2325)
	for y in 0 ..< GRID {
		for x in 0 ..< GRID {
			h = (h ~ u64(layer[y][x])) * 0x0000_0100_0000_01B3
		}
	}
	return h
}

life_step :: proc(life: ^Life) {
	next: [GRID][GRID]u8
	next_corruption: [GRID][GRID]u8
	cur := &life.layers[life.head]
	cur_corruption := &life.corruption[life.head]
	next_live_count := 0

	tile_hashes: [TILE_COUNT][TILE_COUNT]u64
	tile_live: [TILE_COUNT][TILE_COUNT]int
	for ty in 0 ..< TILE_COUNT {
		for tx in 0 ..< TILE_COUNT {
			tile_hashes[ty][tx] = 0xCBF2_9CE4_8422_2325 // FNV-1a offset basis
		}
	}

	// Painting edits the head layer in place, so its cached hash may be stale.
	life.layer_hashes[life.head] = life_layer_hash(cur)

	for y in 0 ..< GRID {
		ty := y / TILE_SIZE
		for x in 0 ..< GRID {
			neighbors := life_count_neighbors(cur, x, y)
			alive := cur[y][x] != 0
			if alive {
				next[y][x] = 1 if (neighbors == 2 || neighbors == 3) else 0
			} else {
				next[y][x] = 1 if neighbors == 3 else 0
			}
			next_live_count += int(next[y][x])

			tx := x / TILE_SIZE
			tile_hashes[ty][tx] = (tile_hashes[ty][tx] ~ u64(next[y][x])) * 0x0000_0100_0000_01B3
			tile_live[ty][tx] += int(next[y][x])

			// A surviving or newborn cell catches the strongest corruption
			// in its 3x3 neighborhood, decayed one notch, so the infection
			// travels with the population and fades over ~20 generations.
			if next[y][x] != 0 {
				strongest := u8(0)
				for dy in -1 ..= 1 {
					for dx in -1 ..= 1 {
						nx := (x + dx + GRID) % GRID
						ny := (y + dy + GRID) % GRID
						strongest = max(strongest, cur_corruption[ny][nx])
					}
				}
				next_corruption[y][x] = u8((int(strongest) * CORRUPTION_DECAY_NUM) >> 8)
			}
		}
	}

	// Life is deterministic, so if the new state matches any stored
	// generation the world will repeat forever with that period. Matching
	// age a (relative to before this step) means period a + 1; scanning
	// ages in ascending order finds the shortest period.
	next_hash := life_layer_hash(&next)
	life.cycle_period = 0
	for age in 0 ..< life.history_count {
		idx := (life.head + age) % DEPTH
		if life.layer_hashes[idx] == next_hash && life.layers[idx] == next {
			life.cycle_period = age + 1
			break
		}
	}

	// Move the head backward and overwrite only the expired oldest layer.
	life.head = (life.head + DEPTH - 1) % DEPTH
	life.layers[life.head] = next
	life.corruption[life.head] = next_corruption
	life.layer_hashes[life.head] = next_hash
	life.history_count = min(life.history_count + 1, DEPTH)
	life.generation += 1
	life.live_count = next_live_count

	// A tile whose contents match itself 1..LOCAL_PERIOD_MAX generations ago
	// is repeating with a small period. Anything moving through (a glider,
	// a growing edge) changes the hash and resets the counter, so only
	// genuinely settled regions accumulate stagnation.
	slot := int(life.generation % LOCAL_PERIOD_MAX)
	for ty in 0 ..< TILE_COUNT {
		for tx in 0 ..< TILE_COUNT {
			cyclic := false
			for k in 1 ..= LOCAL_PERIOD_MAX {
				if life.generation <= u64(k) {
					break
				}
				if life.tile_hashes[(int(life.generation) - k) % LOCAL_PERIOD_MAX][ty][tx] == tile_hashes[ty][tx] {
					cyclic = true
					break
				}
			}
			life.tile_stagnant[ty][tx] = life.tile_stagnant[ty][tx] + 1 if cyclic else 0
			life.tile_hashes[slot][ty][tx] = tile_hashes[ty][tx]
			life.tile_live[ty][tx] = tile_live[ty][tx]
		}
	}
}

SOUP_SIZE :: 12
SOUP_FILL :: f32(0.35)
// Per-generation corruption decay as a /256 fixed-point factor (~0.98),
// so a breach cools from 255 to nothing in roughly 240 generations —
// about as long as the visible history wall is deep.
CORRUPTION_DECAY_NUM :: 253

// Stamp one fully corrupted soup patch centered at (cx, cy), OR-ed over
// the existing cells. The world is toroidal, so patches wrap at the edges.
@(private)
life_stamp_soup_patch :: proc(life: ^Life, cx, cy: int) {
	head := &life.layers[life.head]
	head_corruption := &life.corruption[life.head]
	for dy in 0 ..< SOUP_SIZE {
		for dx in 0 ..< SOUP_SIZE {
			sample := f32(life_random_u64(&life.rng) >> 40) / f32(1 << 24)
			if sample >= SOUP_FILL {
				continue
			}
			x := (cx - SOUP_SIZE / 2 + dx + GRID) % GRID
			y := (cy - SOUP_SIZE / 2 + dy + GRID) % GRID
			if head[y][x] == 0 {
				head[y][x] = 1
				life.live_count += 1
			}
			head_corruption[y][x] = 255
		}
	}
}

// Break a detected global cycle by letting something crash through the
// weakened wall: 2-3 small random soup patches, marked fully corrupted.
// Returns the grid coordinates of the first patch so the app can stage
// the breach shockwave there.
life_inject_soup :: proc(life: ^Life) -> (breach_x, breach_y: int) {
	patch_count := 2 + int(life_random_u64(&life.rng) & 1)
	for patch in 0 ..< patch_count {
		cx := int(life_random_u64(&life.rng) % GRID)
		cy := int(life_random_u64(&life.rng) % GRID)
		if patch == 0 {
			breach_x, breach_y = cx, cy
		}
		life_stamp_soup_patch(life, cx, cy)
	}
	life.injection_count += 1
	life.cycle_period = 0
	// The head hash is now stale; life_step recomputes it before comparing.
	return breach_x, breach_y
}

// Pick a breach target among locally stuck tiles: live tiles that have
// been repeating with a small period for LOCAL_STAGNATION_GENS
// generations. When several qualify, a random one is chosen so repeated
// breaches wander across the calcified regions instead of hammering one
// corner. Returns the grid coordinates of the tile center.
life_find_stagnant_tile :: proc(life: ^Life) -> (cx, cy: int, found: bool) {
	candidates: [TILE_COUNT * TILE_COUNT][2]int
	count := 0
	for ty in 0 ..< TILE_COUNT {
		for tx in 0 ..< TILE_COUNT {
			if life.tile_stagnant[ty][tx] >= LOCAL_STAGNATION_GENS && life.tile_live[ty][tx] > 0 {
				candidates[count] = {tx, ty}
				count += 1
			}
		}
	}
	if count == 0 {
		return 0, 0, false
	}
	pick := candidates[int(life_random_u64(&life.rng) % u64(count))]
	return pick[0] * TILE_SIZE + TILE_SIZE / 2, pick[1] * TILE_SIZE + TILE_SIZE / 2, true
}

// A localized breach: a single soup patch punched into a locally stuck
// tile while the rest of the world keeps evolving.
life_inject_local_soup :: proc(life: ^Life, cx, cy: int) {
	life_stamp_soup_patch(life, cx, cy)
	life.injection_count += 1
	// The patch rewrites the tile, so its stagnation restarts immediately
	// instead of waiting for the next step's hash comparison.
	life.tile_stagnant[cy / TILE_SIZE][cx / TILE_SIZE] = 0
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
		layer_corruption := &life.corruption[(life.head + z) % DEPTH]
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
					age        = age,
					scale      = 1.0,
					glow       = 1.0 if z == 0 else (0.35 if z == selected_age else 0.0),
					occlusion  = f32(occupied) / 6.0,
					sun        = sun,
					corruption = f32(layer_corruption[y][x]) / 255.0,
				}
				count += 1
			}
		}
	}
	return count
}
