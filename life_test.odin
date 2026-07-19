package main

import "core:testing"

@(test)
test_life_b3_s23 :: proc(t: ^testing.T) {
	// Life is ~300 KB with the 128-deep ring buffer; keep it off the stack.
	life := new(Life)
	defer free(life)
	life_clear(life)
	life_paint(life, 23, 24, true)
	life_paint(life, 24, 24, true)
	life_paint(life, 25, 24, true)

	life_step(life)
	current := life_layer_at_age(life, 0)
	previous := life_layer_at_age(life, 1)

	testing.expect_value(t, life.live_count, 3)
	testing.expect(t, current[23][24] != 0)
	testing.expect(t, current[24][24] != 0)
	testing.expect(t, current[25][24] != 0)
	testing.expect(t, previous[24][23] != 0)
	testing.expect(t, previous[24][24] != 0)
	testing.expect(t, previous[24][25] != 0)
}

@(test)
test_life_wraps_at_edges :: proc(t: ^testing.T) {
	life := new(Life)
	defer free(life)
	life_clear(life)
	life_paint(life, GRID - 1, 0, true)
	life_paint(life, 0, 0, true)
	life_paint(life, 1, 0, true)

	life_step(life)
	current := life_layer_at_age(life, 0)
	testing.expect(t, current[GRID - 1][0] != 0)
	testing.expect(t, current[0][0] != 0)
	testing.expect(t, current[1][0] != 0)
}

@(test)
test_life_ring_history_expires_oldest :: proc(t: ^testing.T) {
	life := new(Life)
	defer free(life)
	life_clear(life)
	life_paint(life, 10, 10, true)

	for _ in 0 ..< DEPTH + 3 {
		life_step(life)
	}

	testing.expect_value(t, life.history_count, DEPTH)
	testing.expect_value(t, life.generation, u64(DEPTH + 3))
	testing.expect(t, life_layer_at_age(life, DEPTH - 1) != nil)
	testing.expect(t, life_layer_at_age(life, DEPTH) == nil)
}

@(test)
test_randomize_is_deterministic :: proc(t: ^testing.T) {
	a := new(Life)
	b := new(Life)
	defer free(a)
	defer free(b)
	life_randomize(a, 42)
	life_randomize(b, 42)
	testing.expect_value(t, a.layers[a.head], b.layers[b.head])
	testing.expect_value(t, a.live_count, b.live_count)
}

@(test)
test_cycle_detection :: proc(t: ^testing.T) {
	life := new(Life)
	defer free(life)

	// Blinker: period 2.
	life_clear(life)
	life_paint(life, 23, 24, true)
	life_paint(life, 24, 24, true)
	life_paint(life, 25, 24, true)
	life_step(life)
	testing.expect_value(t, life.cycle_period, 0) // no history to match yet
	life_step(life)
	testing.expect_value(t, life.cycle_period, 2)

	// Block: period 1.
	life_clear(life)
	life_paint(life, 10, 10, true)
	life_paint(life, 11, 10, true)
	life_paint(life, 10, 11, true)
	life_paint(life, 11, 11, true)
	life_step(life)
	testing.expect_value(t, life.cycle_period, 1)

	// Empty world: extinction reads as period 1.
	life_clear(life)
	life_step(life)
	testing.expect_value(t, life.cycle_period, 1)

	// R-pentomino is still growing after a few steps: no cycle.
	life_clear(life)
	pattern_load(life, .R_Pentomino)
	for _ in 0 ..< 8 {
		life_step(life)
		testing.expect_value(t, life.cycle_period, 0)
	}
}

@(test)
test_inject_soup :: proc(t: ^testing.T) {
	a := new(Life)
	b := new(Life)
	defer free(a)
	defer free(b)

	life_clear(a)
	life_clear(b)
	a.rng = 7
	b.rng = 7

	life_inject_soup(a)
	testing.expect(t, a.live_count > 0)
	testing.expect_value(t, a.injection_count, u64(1))
	testing.expect_value(t, a.cycle_period, 0)

	// live_count stays consistent with the actual grid contents.
	counted := 0
	layer := life_layer_at_age(a, 0)
	for y in 0 ..< GRID {
		for x in 0 ..< GRID {
			counted += int(layer[y][x])
		}
	}
	testing.expect_value(t, a.live_count, counted)

	// Deterministic for a fixed rng seed.
	life_inject_soup(b)
	testing.expect_value(t, a.layers[a.head], b.layers[b.head])
	testing.expect_value(t, a.live_count, b.live_count)
}

@(test)
test_breach_corruption_spreads_and_decays :: proc(t: ^testing.T) {
	life := new(Life)
	defer free(life)
	life_clear(life)
	life.rng = 7

	life_inject_soup(life)

	// Every injected patch cell is marked fully corrupted.
	max_corruption := u8(0)
	for y in 0 ..< GRID {
		for x in 0 ..< GRID {
			max_corruption = max(max_corruption, life.corruption[life.head][y][x])
		}
	}
	testing.expect_value(t, max_corruption, u8(255))

	// Descendants inherit a strictly decayed dose while cells survive.
	life_step(life)
	next_max := u8(0)
	live_corrupted := 0
	head := &life.layers[life.head]
	head_corruption := &life.corruption[life.head]
	for y in 0 ..< GRID {
		for x in 0 ..< GRID {
			c := head_corruption[y][x]
			next_max = max(next_max, c)
			if head[y][x] != 0 && c > 0 {
				live_corrupted += 1
			}
		}
	}
	if life.live_count > 0 {
		testing.expect(t, live_corrupted > 0)
		testing.expect(t, next_max > 0)
	}
	testing.expect(t, next_max < 255)
	testing.expect_value(t, next_max, u8((255 * CORRUPTION_DECAY_NUM) >> 8))

	// The infection eventually cools back to nothing: the wall heals.
	for _ in 0 ..< 64 {
		life_step(life)
	}
	healed := true
	for y in 0 ..< GRID {
		for x in 0 ..< GRID {
			if life.corruption[life.head][y][x] != 0 {
				healed = false
			}
		}
	}
	testing.expect(t, healed)
}

@(test)
test_pattern_load_and_paint_metadata :: proc(t: ^testing.T) {
	life := new(Life)
	defer free(life)
	pattern_load(life, .R_Pentomino)
	testing.expect_value(t, life.live_count, 5)

	life_toggle(life, GRID / 2, GRID / 2)
	testing.expect_value(t, life.live_count, 4)
	life_clear(life)
	testing.expect_value(t, life.live_count, 0)
	testing.expect_value(t, life.history_count, 1)
}

@(test)
test_curated_pattern_sizes :: proc(t: ^testing.T) {
	expected := [?]int{25, 48, 5, 7, 7}
	life := new(Life)
	defer free(life)
	for kind_index in 0 ..< PATTERN_COUNT {
		kind := Pattern_Kind(kind_index)
		pattern_load(life, kind)
		testing.expect_value(t, life.live_count, expected[kind_index])
	}
}
