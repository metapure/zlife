package main

import "core:strings"

Pattern_Kind :: enum {
	Gosper_Gun,
	R_Pentomino,
	Acorn,
	Rabbits,
	Lidka,
	Switch_Engine,
	Puffer_Train,
	Space_Rake,
	Noahs_Ark,
	Frothing_Puffer,
	Max_Spacefiller,
	Breeder,
}

PATTERN_COUNT :: int(len(Pattern_Kind))

Pattern_Def :: struct {
	name: string,
	rle:  string, // standard RLE; '#' and 'x = ...' header lines are ignored
}

// Curated for long, interesting evolutions on the 2048x2048 torus. Small
// starters are inline RLE bodies; the big ones are embedded LifeWiki
// pattern files (via Alan Hensel's / copy.sh collections).
@(rodata)
PATTERNS := [Pattern_Kind]Pattern_Def {
	// Bill Gosper, 1970: the first known infinite-growth pattern. Emits a
	// glider every 30 generations, forever.
	.Gosper_Gun = {
		name = "GOSPER GUN",
		rle  = "24bo$22bobo$12b2o6b2o12b2o$11bo3bo4b2o12b2o$2o8bo5bo3b2o$2o8bo3bob2o4bobo$10bo5bo7bo$11bo3bo$12b2o!",
	},
	// Conway's classic methuselah: 5 cells, stabilizes after 1103
	// generations, throwing gliders along the way.
	.R_Pentomino = {
		name = "R-PENTOMINO",
		rle  = "b2o$2o$bo!",
	},
	// 7 cells that boil for 5206 generations.
	.Acorn = {
		name = "ACORN",
		rle  = "bo$3bo$2o2b3o!",
	},
	// Andrew Trevorrow, 1986: 9 cells, 17331 generations of growth.
	.Rabbits = {
		name = "RABBITS",
		rle  = "o3b3o$3o2bo$bo!",
	},
	// Andrzej Okrasinski / David Bell: 13 cells, 29055 generations - one of
	// the longest-lived small methuselahs known.
	.Lidka = {
		name = "LIDKA",
		rle  = "6bo$6b3o2$3b2o3bo$3bo4bo$3o5bo!",
	},
	// Paul Callahan, 1997: the minimal infinite-growth pattern (10 cells).
	// Becomes a block-laying switch engine plowing diagonally across the grid.
	.Switch_Engine = {
		name = "SWITCH ENGINE",
		rle  = "6bo$4bob2o$4bobo$4bo$2bo$obo!",
	},
	// Bill Gosper, 1971: a B-heptomino escorted by two lightweight
	// spaceships; travels at c/2 forever behind a dirty debris trail.
	.Puffer_Train = {
		name = "PUFFER TRAIN",
		rle  = "3bo$4bo$o3bo$b4o4$o$b2o$2bo$2bo$bo3$3bo$4bo$o3bo$b4o!",
	},
	// A period-20 c/2 rake: a spaceship convoy that fires a continuous
	// stream of gliders while flying, seeding activity across the torus.
	.Space_Rake = {
		name = "SPACE RAKE",
		rle  = string(#load("patterns/spacerake.rle")),
	},
	// Charles Corderman, 1971: two switch engines forming a diagonal c/12
	// puffer that strews blocks, blinkers, and ash along the grid diagonal.
	.Noahs_Ark = {
		name = "NOAH'S ARK",
		rle  = string(#load("patterns/noahsark.rle")),
	},
	// Paul Tooke, 2001: a wide c/2 puffer whose frothing, seemingly
	// unstable wake somehow never destroys the engine.
	.Frothing_Puffer = {
		name = "FROTHING PUFFER",
		rle  = string(#load("patterns/frothingpuffer.rle")),
	},
	// Tim Coe's "Max": the classic spacefiller. Grows at the maximum
	// possible speed in all four directions, painting the plane with zebra
	// stripes until it swallows the whole 2048x2048 torus.
	.Max_Spacefiller = {
		name = "MAX SPACEFILLER",
		rle  = string(#load("patterns/max.rle")),
	},
	// Bill Gosper's Breeder 1: the first quadratic-growth pattern ever
	// found. A puffer flotilla that lays down Gosper guns, each of which
	// then fires gliders forever. 4060 cells, 749x338.
	.Breeder = {
		name = "BREEDER 1",
		rle  = string(#load("patterns/breeder1.rle")),
	},
}

pattern_name :: proc(kind: Pattern_Kind) -> string {
	return PATTERNS[kind].name
}

pattern_next :: proc(kind: Pattern_Kind, direction: int = 1) -> Pattern_Kind {
	index := (int(kind) + direction + PATTERN_COUNT) % PATTERN_COUNT
	return Pattern_Kind(index)
}

// Streaming RLE decoder: yields live-cell coordinates relative to the
// pattern's top-left corner, one cell per call.
Pattern_Iter :: struct {
	body:      string,
	i:         int,
	x, y:      int,
	emit_left: int,
}

@(private)
pattern_rle_body :: proc(rle: string) -> string {
	rest := rle
	for len(rest) > 0 {
		line_end := strings.index_byte(rest, '\n')
		line := rest if line_end < 0 else rest[:line_end]
		trimmed := strings.trim_space(line)
		if len(trimmed) > 0 && trimmed[0] != '#' && trimmed[0] != 'x' {
			break
		}
		if line_end < 0 {
			return ""
		}
		rest = rest[line_end + 1:]
	}
	return rest
}

pattern_iter_make :: proc(kind: Pattern_Kind) -> Pattern_Iter {
	return {body = pattern_rle_body(PATTERNS[kind].rle)}
}

pattern_iter_next :: proc(it: ^Pattern_Iter) -> (cx, cy: int, ok: bool) {
	if it.emit_left > 0 {
		it.emit_left -= 1
		cx, cy, ok = it.x, it.y, true
		it.x += 1
		return
	}
	run := 0
	for it.i < len(it.body) {
		ch := it.body[it.i]
		it.i += 1
		switch {
		case ch >= '0' && ch <= '9':
			run = run * 10 + int(ch - '0')
		case ch == 'b' || ch == 'B':
			it.x += max(run, 1)
			run = 0
		case ch == 'o' || ch == 'O':
			it.emit_left = max(run, 1) - 1
			cx, cy, ok = it.x, it.y, true
			it.x += 1
			return
		case ch == '$':
			it.y += max(run, 1)
			it.x = 0
			run = 0
		case ch == '!':
			return 0, 0, false
		// Whitespace: RLE bodies wrap at 70 columns; runs stay pending.
		}
	}
	return 0, 0, false
}

@(private)
pattern_extent :: proc(kind: Pattern_Kind) -> (width, height: int) {
	it := pattern_iter_make(kind)
	for {
		x, y, ok := pattern_iter_next(&it)
		if !ok {
			break
		}
		width = max(width, x + 1)
		height = max(height, y + 1)
	}
	return
}

pattern_collect_points :: proc(kind: Pattern_Kind, center_x, center_y: int, out: [][2]int) -> int {
	width, height := pattern_extent(kind)
	origin_x := center_x - width / 2
	origin_y := center_y - height / 2
	count := 0
	it := pattern_iter_make(kind)
	for count < len(out) {
		x, y, ok := pattern_iter_next(&it)
		if !ok {
			break
		}
		out[count] = {(origin_x + x + GRID) % GRID, (origin_y + y + GRID) % GRID}
		count += 1
	}
	return count
}

pattern_stamp :: proc(life: ^Life, kind: Pattern_Kind, center_x, center_y: int) {
	width, height := pattern_extent(kind)
	origin_x := center_x - width / 2
	origin_y := center_y - height / 2
	it := pattern_iter_make(kind)
	for {
		x, y, ok := pattern_iter_next(&it)
		if !ok {
			break
		}
		life_paint(life, (origin_x + x + GRID) % GRID, (origin_y + y + GRID) % GRID, true)
	}
}

pattern_load :: proc(life: ^Life, kind: Pattern_Kind) {
	life_clear(life)
	pattern_stamp(life, kind, GRID / 2, GRID / 2)
}
