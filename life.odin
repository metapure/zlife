package main

import "core:math"
import "core:os"
import "core:thread"

GRID :: 2048
DEPTH :: 16

// Worst-case instance storage for the full volume would be ~2 GB, so the
// CPU and GPU buffers are capped at a realistic density instead (~18% of
// the volume). Right after a reseed the 22%-fill present layer dominates
// all 16 layers, so the cap must cover that transient; steady state is
// ~4-5%. Collection truncates gracefully if the cap is ever hit.
MAX_INSTANCES :: 12_000_000

// Workers for the threaded sim step and instance collection: the M4 Max
// has 12 performance cores; both workloads are memory-bound past that.
MAX_SIM_WORKERS :: 12

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
	scratch: [GRID][GRID]u8, // next-generation buffer; too big for the stack
	layer_hashes: [DEPTH]u64, // ring-aligned with layers
	head: int,
	history_count: int,
	generation: u64,
	live_count: int,
	seed: u64,
	rng: u64, // perturbation randomness, independent of the world seed
	cycle_period: int, // 0 = evolving; otherwise period detected by the last step
	injection_count: u64,
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

// Layer hashes are built from per-row FNV-1a hashes folded together, so
// workers can hash disjoint row ranges in parallel and the serial combine
// stays O(GRID). Hashes are only ever compared to each other.
@(private)
life_row_hash :: proc(row: ^[GRID]u8) -> u64 {
	h := u64(0xCBF2_9CE4_8422_2325)
	for x in 0 ..< GRID {
		h = (h ~ u64(row[x])) * 0x0000_0100_0000_01B3
	}
	return h
}

@(private)
life_combine_row_hashes :: proc(row_hashes: ^[GRID]u64) -> u64 {
	h := u64(0xCBF2_9CE4_8422_2325)
	for rh in row_hashes {
		h = (h ~ rh) * 0x0000_0100_0000_01B3
	}
	return h
}

@(private)
Step_Shared :: struct {
	cur, next:     ^[GRID][GRID]u8,
	row_hash_cur:  ^[GRID]u64,
	row_hash_next: ^[GRID]u64,
	live:          ^[MAX_SIM_WORKERS]int,
	worker_count:  int,
}

@(private)
Step_Worker :: struct {
	shared: ^Step_Shared,
	index:  int,
}

// Compute the next generation for a contiguous row range: cur is read-only
// and each worker writes disjoint rows of next, so no locking is needed.
// Row hashes for both the (possibly painted) current layer and the next
// one fall out of the same pass.
@(private)
step_worker :: proc(w: ^Step_Worker) {
	s := w.shared
	cur, next := s.cur, s.next
	y0 := w.index * GRID / s.worker_count
	y1 := (w.index + 1) * GRID / s.worker_count
	live := 0
	for y in y0 ..< y1 {
		up := &cur[(y + GRID - 1) % GRID]
		mid := &cur[y]
		down := &cur[(y + 1) % GRID]
		s.row_hash_cur[y] = life_row_hash(mid)
		nrow := &next[y]
		for x in 0 ..< GRID {
			xm := (x + GRID - 1) % GRID
			xp := (x + 1) % GRID
			neighbors :=
				int(up[xm]) + int(up[x]) + int(up[xp]) +
				int(mid[xm]) + int(mid[xp]) +
				int(down[xm]) + int(down[x]) + int(down[xp])
			cell: u8
			if mid[x] != 0 {
				cell = 1 if (neighbors == 2 || neighbors == 3) else 0
			} else {
				cell = 1 if neighbors == 3 else 0
			}
			nrow[x] = cell
			live += int(cell)
		}
		s.row_hash_next[y] = life_row_hash(nrow)
	}
	s.live[w.index] = live
}

@(private)
step_run_workers :: proc(shared: ^Step_Shared) {
	workers: [MAX_SIM_WORKERS]Step_Worker
	threads: [MAX_SIM_WORKERS]^thread.Thread
	n := shared.worker_count
	for i in 0 ..< n {
		workers[i] = Step_Worker{shared = shared, index = i}
	}
	for i in 1 ..< n {
		threads[i] = thread.create_and_start_with_poly_data(&workers[i], step_worker)
	}
	step_worker(&workers[0])
	for i in 1 ..< n {
		thread.destroy(threads[i]) // waits for the thread to finish, then frees it
	}
}

life_step :: proc(life: ^Life) {
	cur := &life.layers[life.head]
	next := &life.scratch

	row_hash_cur, row_hash_next: [GRID]u64
	live: [MAX_SIM_WORKERS]int
	shared := Step_Shared {
		cur           = cur,
		next          = next,
		row_hash_cur  = &row_hash_cur,
		row_hash_next = &row_hash_next,
		live          = &live,
		worker_count  = clamp(os.get_processor_core_count(), 1, MAX_SIM_WORKERS),
	}
	step_run_workers(&shared)

	// Painting edits the head layer in place, so its cached hash may be stale.
	life.layer_hashes[life.head] = life_combine_row_hashes(&row_hash_cur)
	next_hash := life_combine_row_hashes(&row_hash_next)

	next_live_count := 0
	for i in 0 ..< shared.worker_count {
		next_live_count += live[i]
	}

	// Life is deterministic, so if the new state matches any stored
	// generation the world will repeat forever with that period. Matching
	// age a (relative to before this step) means period a + 1; scanning
	// ages in ascending order finds the shortest period.
	life.cycle_period = 0
	for age in 0 ..< life.history_count {
		idx := (life.head + age) % DEPTH
		if life.layer_hashes[idx] == next_hash && life.layers[idx] == next^ {
			life.cycle_period = age + 1
			break
		}
	}

	// Move the head backward and overwrite only the expired oldest layer.
	life.head = (life.head + DEPTH - 1) % DEPTH
	life.layers[life.head] = next^
	life.layer_hashes[life.head] = next_hash
	life.history_count = min(life.history_count + 1, DEPTH)
	life.generation += 1
	life.live_count = next_live_count
}

SOUP_SIZE :: 96
SOUP_FILL :: f32(0.35)

// Break a detected cycle by crashing fresh random soup into the present:
// 2-3 small patches at random locations, OR-ed over the existing cells.
life_inject_soup :: proc(life: ^Life) {
	head := &life.layers[life.head]
	patch_count := 2 + int(life_random_u64(&life.rng) & 1)
	for _ in 0 ..< patch_count {
		cx := int(life_random_u64(&life.rng) % GRID)
		cy := int(life_random_u64(&life.rng) % GRID)
		for dy in 0 ..< SOUP_SIZE {
			for dx in 0 ..< SOUP_SIZE {
				sample := f32(life_random_u64(&life.rng) >> 40) / f32(1 << 24)
				if sample >= SOUP_FILL {
					continue
				}
				// The world is toroidal, so patches wrap at the edges.
				x := (cx - SOUP_SIZE / 2 + dx + GRID) % GRID
				y := (cy - SOUP_SIZE / 2 + dy + GRID) % GRID
				if head[y][x] == 0 {
					head[y][x] = 1
					life.live_count += 1
				}
			}
		}
	}
	life.injection_count += 1
	life.cycle_period = 0
	// The head hash is now stale; life_step recomputes it before comparing.
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

// Work is split into row blocks within each layer rather than whole
// layers: with a shallow history there are too few layers to keep the
// workers balanced, while (layers x row blocks) stays fine-grained at
// any GRID/DEPTH shape.
COLLECT_ROW_BLOCK :: 64
COLLECT_BLOCKS_PER_LAYER :: (GRID + COLLECT_ROW_BLOCK - 1) / COLLECT_ROW_BLOCK

@(private)
Collect_Shared :: struct {
	layers:       []^[GRID][GRID]u8,
	steps:        []Shadow_Step,
	out:          []Instance,
	emit:         []int, // per-block live count, clamped to remaining capacity
	offsets:      []int, // per-block start index into out
	selected_age: int,
	worker_count: int,
}

@(private)
Collect_Worker :: struct {
	shared: ^Collect_Shared,
	index:  int,
}

@(private)
collect_block_span :: proc(block: int) -> (z, y0, y1: int) {
	z = block / COLLECT_BLOCKS_PER_LAYER
	y0 = (block % COLLECT_BLOCKS_PER_LAYER) * COLLECT_ROW_BLOCK
	y1 = min(y0 + COLLECT_ROW_BLOCK, GRID)
	return
}

// Blocks are interleaved across workers (block % worker_count) so denser
// regions spread evenly instead of piling onto one worker.
@(private)
collect_count_worker :: proc(w: ^Collect_Worker) {
	s := w.shared
	for b := w.index; b < len(s.emit); b += s.worker_count {
		z, y0, y1 := collect_block_span(b)
		layer := s.layers[z]
		n := 0
		for y in y0 ..< y1 {
			for x in 0 ..< GRID {
				n += int(layer[y][x])
			}
		}
		s.emit[b] = n
	}
}

@(private)
collect_fill_worker :: proc(w: ^Collect_Worker) {
	s := w.shared
	for b := w.index; b < len(s.emit); b += s.worker_count {
		if s.emit[b] > 0 {
			collect_fill_block(s, b)
		}
	}
}

@(private)
collect_fill_block :: proc(s: ^Collect_Shared, block: int) {
	z, y0, y1 := collect_block_span(block)
	layer := s.layers[z]
	// Adjacent layers in time shadow this cell from above and below.
	above, below: ^[GRID][GRID]u8
	if z > 0 {
		above = s.layers[z - 1]
	}
	if z < len(s.layers) - 1 {
		below = s.layers[z + 1]
	}
	age := f32(z) / f32(max(DEPTH - 1, 1))
	half := f32(GRID) * 0.5
	out := s.out[s.offsets[block]:][:s.emit[block]]
	count := 0
	for y in y0 ..< y1 {
		for x in 0 ..< GRID {
			if layer[y][x] == 0 {
				continue
			}
			if count >= len(out) {
				return
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

			sun := life_sun_visibility(s.layers, s.steps, x, y, z)

			// Time flows downward: the present sits at y = 0, history below it.
			out[count] = Instance {
				center = {
					f32(x) - half + 0.5,
					-f32(z),
					f32(y) - half + 0.5,
				},
				age       = age,
				scale     = 1.0,
				glow      = 1.0 if z == 0 else (0.35 if z == s.selected_age else 0.0),
				occlusion = f32(occupied) / 6.0,
				sun       = sun,
			}
			count += 1
		}
	}
}

// Run one phase across the workers. Worker 0 runs on the calling thread;
// the rest are spawned and joined. Collection only runs when the sim
// actually changed (tick rate, not frame rate), so spawn cost is noise
// next to the shadow-march work.
@(private)
collect_run_workers :: proc(
	shared: ^Collect_Shared,
	worker_proc: proc(w: ^Collect_Worker),
) {
	workers: [MAX_SIM_WORKERS]Collect_Worker
	threads: [MAX_SIM_WORKERS]^thread.Thread
	n := shared.worker_count
	for i in 0 ..< n {
		workers[i] = Collect_Worker{shared = shared, index = i}
	}
	for i in 1 ..< n {
		threads[i] = thread.create_and_start_with_poly_data(&workers[i], worker_proc)
	}
	worker_proc(&workers[0])
	for i in 1 ..< n {
		thread.destroy(threads[i]) // waits for the thread to finish, then frees it
	}
}

// An isolated slice floats alone in space: no above/below occlusion and
// nothing shadows it, so the volume machinery is skipped entirely.
@(private)
life_collect_isolated :: proc(life: ^Life, out: []Instance, selected_age: int) -> int {
	layer := life_layer_at_age(life, selected_age)
	if layer == nil {
		return 0
	}
	age := f32(selected_age) / f32(max(DEPTH - 1, 1))
	half := f32(GRID) * 0.5
	count := 0
	for y in 0 ..< GRID {
		for x in 0 ..< GRID {
			if layer[y][x] == 0 {
				continue
			}
			if count >= len(out) {
				return count
			}
			occupied := 0
			if x > 0 && layer[y][x - 1] != 0 do occupied += 1
			if x < GRID - 1 && layer[y][x + 1] != 0 do occupied += 1
			if y > 0 && layer[y - 1][x] != 0 do occupied += 1
			if y < GRID - 1 && layer[y + 1][x] != 0 do occupied += 1

			out[count] = Instance {
				center = {
					f32(x) - half + 0.5,
					-f32(selected_age),
					f32(y) - half + 0.5,
				},
				age       = age,
				scale     = 1.0,
				glow      = 1.0 if selected_age == 0 else 0.35,
				occlusion = f32(occupied) / 6.0,
				sun       = 1.0,
			}
			count += 1
		}
	}
	return count
}

life_collect_instances :: proc(
	life: ^Life,
	out: []Instance,
	selected_age: int = 0,
	isolate_selected: bool = false,
) -> int {
	if isolate_selected {
		return life_collect_isolated(life, out, selected_age)
	}

	// Resolve the ring buffer once so the shadow march can index layers
	// directly by age instead of doing modular arithmetic per step.
	layer_ptrs: [DEPTH]^[GRID][GRID]u8
	for z in 0 ..< life.history_count {
		layer_ptrs[z] = life_layer_at_age(life, z)
	}
	layers := layer_ptrs[:life.history_count]
	shadow_steps := shadow_steps_build()

	block_count := life.history_count * COLLECT_BLOCKS_PER_LAYER
	emit, offsets: [DEPTH * COLLECT_BLOCKS_PER_LAYER]int
	shared := Collect_Shared {
		layers       = layers,
		steps        = shadow_steps[:],
		out          = out,
		emit         = emit[:block_count],
		offsets      = offsets[:block_count],
		selected_age = selected_age,
		worker_count = clamp(
			min(os.get_processor_core_count(), block_count),
			1,
			MAX_SIM_WORKERS,
		),
	}

	// Phase 1 (parallel): live cells per row block.
	collect_run_workers(&shared, collect_count_worker)

	// Phase 2 (serial): prefix-sum offsets, clamped at capacity so each
	// block writes a disjoint range. Blocks are ordered by layer then row,
	// so output order stays z, then y, then x, identical to a serial scan.
	total := 0
	for b in 0 ..< block_count {
		offsets[b] = total
		emit[b] = min(emit[b], max(len(out) - total, 0))
		total += emit[b]
	}

	// Phase 3 (parallel): occupancy, shadow march, and instance write-out.
	collect_run_workers(&shared, collect_fill_worker)
	return total
}
