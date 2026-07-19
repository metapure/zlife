package main

Pattern_Kind :: enum {
	Gosper_Gun,
	R_Pentomino,
	Acorn,
	Rabbits,
	Lidka,
	Switch_Engine,
	Puffer_Train,
}

PATTERN_COUNT :: int(len(Pattern_Kind))

Pattern_Def :: struct {
	name: string,
	rows: []string, // 'O' = alive, anything else = dead
}

// Curated for long, interesting evolutions on the 256x256 torus. Cell maps
// transcribed from LifeWiki reference RLEs.
@(rodata)
PATTERNS := [Pattern_Kind]Pattern_Def {
	// Bill Gosper, 1970: the first known infinite-growth pattern. Emits a
	// glider every 30 generations; on the torus the stream wraps around and
	// eventually crashes back into the gun, cascading into open-ended chaos.
	.Gosper_Gun = {
		name = "GOSPER GUN",
		rows = {
			"........................O...........",
			"......................O.O...........",
			"............OO......OO............OO",
			"...........O...O....OO............OO",
			"OO........O.....O...OO..............",
			"OO........O...O.OO....O.O...........",
			"..........O.....O.......O...........",
			"...........O...O....................",
			"............OO......................",
		},
	},
	// Conway's classic methuselah: 5 cells, stabilizes after 1103
	// generations, throwing gliders along the way.
	.R_Pentomino = {
		name = "R-PENTOMINO",
		rows = {
			".OO",
			"OO.",
			".O.",
		},
	},
	// 7 cells that boil for 5206 generations and colonize most of the grid.
	.Acorn = {
		name = "ACORN",
		rows = {
			".O.....",
			"...O...",
			"OO..OOO",
		},
	},
	// Andrew Trevorrow, 1986: 9 cells, 17331 generations of growth.
	.Rabbits = {
		name = "RABBITS",
		rows = {
			"O...OOO",
			"OOO..O.",
			".O.....",
		},
	},
	// Andrzej Okrasinski / David Bell: 13 cells, 29055 generations - one of
	// the longest-lived small methuselahs known.
	.Lidka = {
		name = "LIDKA",
		rows = {
			"......O..",
			"......OOO",
			".........",
			"...OO...O",
			"...O....O",
			"OOO.....O",
		},
	},
	// Paul Callahan, 1997: the minimal infinite-growth pattern (10 cells).
	// Becomes a block-laying switch engine that plows diagonally across the
	// torus, eventually colliding with its own block trail.
	.Switch_Engine = {
		name = "SWITCH ENGINE",
		rows = {
			"......O.",
			"....O.OO",
			"....O.O.",
			"....O...",
			"..O.....",
			"O.O.....",
		},
	},
	// Bill Gosper, 1971: a B-heptomino escorted by two lightweight
	// spaceships. Travels at c/2 forever, leaving a dirty debris trail that
	// only settles thousands of generations behind the engine.
	.Puffer_Train = {
		name = "PUFFER TRAIN",
		rows = {
			"...O.",
			"....O",
			"O...O",
			".OOOO",
			".....",
			".....",
			".....",
			"O....",
			".OO..",
			"..O..",
			"..O..",
			".O...",
			".....",
			".....",
			"...O.",
			"....O",
			"O...O",
			".OOOO",
		},
	},
}

pattern_name :: proc(kind: Pattern_Kind) -> string {
	return PATTERNS[kind].name
}

pattern_next :: proc(kind: Pattern_Kind, direction: int = 1) -> Pattern_Kind {
	index := (int(kind) + direction + PATTERN_COUNT) % PATTERN_COUNT
	return Pattern_Kind(index)
}

@(private)
pattern_add_point :: proc(out: [][2]int, count: ^int, x, y: int) {
	if count^ >= len(out) {
		return
	}
	out[count^] = {(x + GRID) % GRID, (y + GRID) % GRID}
	count^ += 1
}

pattern_collect_points :: proc(kind: Pattern_Kind, center_x, center_y: int, out: [][2]int) -> int {
	rows := PATTERNS[kind].rows
	width := 0
	for row in rows {
		width = max(width, len(row))
	}
	origin_x := center_x - width / 2
	origin_y := center_y - len(rows) / 2
	count := 0
	for row, y in rows {
		for cell, x in row {
			if cell == 'O' {
				pattern_add_point(out, &count, origin_x + x, origin_y + y)
			}
		}
	}
	return count
}

pattern_stamp :: proc(life: ^Life, kind: Pattern_Kind, center_x, center_y: int) {
	points: [64][2]int
	count := pattern_collect_points(kind, center_x, center_y, points[:])
	for point in points[:count] {
		life_paint(life, point.x, point.y, true)
	}
}

pattern_load :: proc(life: ^Life, kind: Pattern_Kind) {
	life_clear(life)
	pattern_stamp(life, kind, GRID / 2, GRID / 2)
}
