package main

GRID :: 48
DEPTH :: 48
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

life_collect_instances :: proc(
	life: ^Life,
	out: []Instance,
	selected_age: int = 0,
	isolate_selected: bool = false,
) -> int {
	count := 0
	half_w := f32(GRID) * 0.5
	half_h := f32(GRID) * 0.5

	for z in 0 ..< life.history_count {
		if isolate_selected && z != selected_age {
			continue
		}
		layer := life_layer_at_age(life, z)
		age := f32(z) / f32(max(DEPTH - 1, 1))
		for y in 0 ..< GRID {
			for x in 0 ..< GRID {
				if layer[y][x] == 0 {
					continue
				}
				if count >= len(out) {
					return count
				}
				out[count] = Instance {
					center = {
						f32(x) - half_w + 0.5,
						f32(y) - half_h + 0.5,
						f32(z),
					},
					age   = age,
					scale = 1.0,
					glow  = 1.0 if z == 0 else (0.35 if z == selected_age else 0.0),
				}
				count += 1
			}
		}
	}
	return count
}
