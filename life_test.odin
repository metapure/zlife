package main

import "core:testing"

@(test)
test_life_b3_s23 :: proc(t: ^testing.T) {
	life: Life
	life_clear(&life)
	life_paint(&life, 23, 24, true)
	life_paint(&life, 24, 24, true)
	life_paint(&life, 25, 24, true)

	life_step(&life)
	current := life_layer_at_age(&life, 0)
	previous := life_layer_at_age(&life, 1)

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
	life: Life
	life_clear(&life)
	life_paint(&life, GRID - 1, 0, true)
	life_paint(&life, 0, 0, true)
	life_paint(&life, 1, 0, true)

	life_step(&life)
	current := life_layer_at_age(&life, 0)
	testing.expect(t, current[GRID - 1][0] != 0)
	testing.expect(t, current[0][0] != 0)
	testing.expect(t, current[1][0] != 0)
}

@(test)
test_life_ring_history_expires_oldest :: proc(t: ^testing.T) {
	life: Life
	life_clear(&life)
	life_paint(&life, 10, 10, true)

	for _ in 0 ..< DEPTH + 3 {
		life_step(&life)
	}

	testing.expect_value(t, life.history_count, DEPTH)
	testing.expect_value(t, life.generation, u64(DEPTH + 3))
	testing.expect(t, life_layer_at_age(&life, DEPTH - 1) != nil)
	testing.expect(t, life_layer_at_age(&life, DEPTH) == nil)
}

@(test)
test_randomize_is_deterministic :: proc(t: ^testing.T) {
	a, b: Life
	life_randomize(&a, 42)
	life_randomize(&b, 42)
	testing.expect_value(t, a.layers[a.head], b.layers[b.head])
	testing.expect_value(t, a.live_count, b.live_count)
}

@(test)
test_pattern_load_and_paint_metadata :: proc(t: ^testing.T) {
	life: Life
	pattern_load(&life, .R_Pentomino)
	testing.expect_value(t, life.live_count, 5)

	life_toggle(&life, GRID / 2, GRID / 2)
	testing.expect_value(t, life.live_count, 4)
	life_clear(&life)
	testing.expect_value(t, life.live_count, 0)
	testing.expect_value(t, life.history_count, 1)
}

@(test)
test_curated_pattern_sizes :: proc(t: ^testing.T) {
	expected := [?]int{25, 48, 5, 7, 7}
	for kind_index in 0 ..< PATTERN_COUNT {
		life: Life
		kind := Pattern_Kind(kind_index)
		pattern_load(&life, kind)
		testing.expect_value(t, life.live_count, expected[kind_index])
	}
}
