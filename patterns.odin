package main

Pattern_Kind :: enum {
	Glider_Fleet,
	Pulsar,
	R_Pentomino,
	Acorn,
	Diehard,
}

PATTERN_COUNT :: int(len(Pattern_Kind))

pattern_name :: proc(kind: Pattern_Kind) -> string {
	switch kind {
	case .Glider_Fleet:
		return "GLIDER FLEET"
	case .Pulsar:
		return "PULSAR"
	case .R_Pentomino:
		return "R-PENTOMINO"
	case .Acorn:
		return "ACORN"
	case .Diehard:
		return "DIEHARD"
	}
	return "UNKNOWN"
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
	count := 0
	switch kind {
	case .Glider_Fleet:
		glider := [?][2]i8{{0, -1}, {1, 0}, {-1, 1}, {0, 1}, {1, 1}}
		offsets := [?][2]i8{{-12, -12}, {10, -10}, {-10, 10}, {12, 12}, {0, 0}}
		for offset in offsets {
			for point in glider {
				pattern_add_point(
					out,
					&count,
					center_x + int(offset.x) + int(point.x),
					center_y + int(offset.y) + int(point.y),
				)
			}
		}
	case .Pulsar:
		// One quadrant mirrored around the center creates the 48-cell oscillator.
		arms := [?][2]i8{{2, 1}, {3, 1}, {4, 1}, {1, 2}, {6, 2}, {1, 3}, {6, 3}, {1, 4}, {6, 4}, {2, 6}, {3, 6}, {4, 6}}
		signs := [?]int{-1, 1}
		for point in arms {
			for sx in signs {
				for sy in signs {
					x := center_x + sx * int(point.x)
					y := center_y + sy * int(point.y)
					pattern_add_point(out, &count, x, y)
				}
			}
		}
	case .R_Pentomino:
		points := [?][2]i8{{0, -1}, {1, -1}, {-1, 0}, {0, 0}, {0, 1}}
		for point in points {
			pattern_add_point(out, &count, center_x + int(point.x), center_y + int(point.y))
		}
	case .Acorn:
		points := [?][2]i8{{-3, 0}, {-2, 0}, {-2, -2}, {0, -1}, {1, 0}, {2, 0}, {3, 0}}
		for point in points {
			pattern_add_point(out, &count, center_x + int(point.x), center_y + int(point.y))
		}
	case .Diehard:
		points := [?][2]i8{{-3, 0}, {-2, 0}, {-2, 1}, {2, 1}, {3, -1}, {3, 1}, {4, 1}}
		for point in points {
			pattern_add_point(out, &count, center_x + int(point.x), center_y + int(point.y))
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
