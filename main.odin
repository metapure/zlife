package main

import NS "core:sys/darwin/Foundation"
import SDL "vendor:sdl2"

import "core:fmt"
import "core:os"
import "core:time"

DEFAULT_TICK_HZ :: 60.0
TARGET_FRAME_TIME :: time.Second / 60

App :: struct {
	window: ^SDL.Window,
	native_window: ^NS.Window,
	renderer: Renderer,
	life: Life,
	camera: Camera,
	instances: [GRID * GRID * DEPTH]Instance,
	instance_count: int,
	preview_instances: [64]Instance,
	preview_count: int,
	ui_vertices: [UI_MAX_VERTICES]UI_Vertex,
	ui_count: int,

	running: bool,
	paused: bool,
	minimized: bool,
	painting: bool,
	paint_alive: bool,
	orbiting: bool,
	panning: bool,
	show_grid: bool,
	show_hud: bool,
	isolate_selected: bool,
	pattern_preview_active: bool,
	scene_dirty: bool,

	selected_age: int,
	selected_pattern: Pattern_Kind,
	tick_hz: f64,
	tick_accum: f64,
	elapsed: f64,
	fps_accum: f64,
	fps: f64,
	frame_count: int,

	last_mx, last_my: i32,
	hover_x, hover_y: int,
	hover_valid: bool,
	screen_w, screen_h: f32,
}

update_drawable_size :: proc(app: ^App) {
	w, h: i32
	SDL.GetWindowSize(app.window, &w, &h)
	if w <= 0 || h <= 0 {
		app.minimized = true
		return
	}
	app.minimized = false
	scale := f32(app.native_window->backingScaleFactor())
	app.screen_w = f32(w)
	app.screen_h = f32(h)
	app.camera.aspect = f32(w) / f32(h)
	renderer_set_drawable_size(&app.renderer, f64(w) * f64(scale), f64(h) * f64(scale))
}

update_hover :: proc(app: ^App, mx, my: i32) {
	old_x, old_y, old_valid := app.hover_x, app.hover_y, app.hover_valid
	app.hover_x, app.hover_y, app.hover_valid = camera_pick_cell(
		app.camera,
		f32(mx),
		f32(my),
		app.screen_w,
		app.screen_h,
	)
	if old_x != app.hover_x || old_y != app.hover_y || old_valid != app.hover_valid {
		app.scene_dirty = true
	}
}

handle_paint_at :: proc(app: ^App, mx, my: i32, toggle: bool) {
	update_hover(app, mx, my)
	if !app.hover_valid {
		return
	}
	if toggle {
		life_toggle(&app.life, app.hover_x, app.hover_y)
		layer := life_layer_at_age(&app.life, 0)
		app.paint_alive = layer[app.hover_y][app.hover_x] != 0
	} else {
		life_paint(&app.life, app.hover_x, app.hover_y, app.paint_alive)
	}
	app.scene_dirty = true
}

build_hud :: proc(app: ^App) {
	app.ui_count = 0
	if !app.show_hud || app.screen_w < 420 || app.screen_h < 220 {
		return
	}

	primary := [4]f32{0.74, 0.92, 1.0, 0.92}
	accent := [4]f32{1.0, 0.68, 0.22, 0.98}
	muted := [4]f32{0.42, 0.64, 0.78, 0.82}
	status := "PAUSED" if app.paused else "RUNNING"
	mode := "ISOLATED" if app.isolate_selected else "FULL VOLUME"
	slice_buffer: [32]u8
	slice_label := "PRESENT" if app.selected_age == 0 else fmt.bprintf(slice_buffer[:], "T-%d", app.selected_age)

	line1_buffer, line2_buffer, line3_buffer: [256]u8
	line1 := fmt.bprintf(
		line1_buffer[:],
		"ZLIFE // %s // GEN %d // LIVE %d",
		status,
		app.life.generation,
		app.life.live_count,
	)
	line2 := fmt.bprintf(
		line2_buffer[:],
		"%.0f HZ // %.0f FPS // HISTORY %d/%d // %s",
		app.tick_hz,
		app.fps,
		app.selected_age,
		max(app.life.history_count - 1, 0),
		mode,
	)
	line3 := fmt.bprintf(
		line3_buffer[:],
		"SLICE %s // PATTERN %s // SEED %X",
		slice_label,
		pattern_name(app.selected_pattern),
		app.life.seed,
	)

	ui_text(app.ui_vertices[:], &app.ui_count, line1, 18, 18, 2, app.screen_w, app.screen_h, accent)
	ui_text(app.ui_vertices[:], &app.ui_count, line2, 18, 38, 2, app.screen_w, app.screen_h, primary)
	ui_text(app.ui_vertices[:], &app.ui_count, line3, 18, 58, 2, app.screen_w, app.screen_h, primary)
	ui_text(
		app.ui_vertices[:],
		&app.ui_count,
		"SPACE PLAY // N STEP // [ ] SCRUB // H ISOLATE // TAB PATTERN // P LOAD",
		18,
		app.screen_h - 38,
		1.5,
		app.screen_w,
		app.screen_h,
		muted,
	)
	ui_text(
		app.ui_vertices[:],
		&app.ui_count,
		"LMB PAINT // RMB ORBIT // MMB PAN // WHEEL ZOOM // F RESET // U HUD",
		18,
		app.screen_h - 20,
		1.5,
		app.screen_w,
		app.screen_h,
		muted,
	)
}

handle_key :: proc(app: ^App, key: SDL.Keycode, mods: SDL.Keymod) {
	shift := mods & SDL.KMOD_SHIFT != {}
	#partial switch key {
	case .ESCAPE:
		app.running = false
	case .SPACE:
		app.paused = !app.paused
		app.tick_accum = 0
	case .N:
		life_step(&app.life)
		app.selected_age = 0
		app.scene_dirty = true
	case .R:
		life_randomize(&app.life, u64(time.to_unix_nanoseconds(time.now())))
		app.selected_age = 0
		app.scene_dirty = true
	case .C:
		life_clear(&app.life)
		app.selected_age = 0
		app.scene_dirty = true
	case .P:
		if shift && app.hover_valid {
			pattern_stamp(&app.life, app.selected_pattern, app.hover_x, app.hover_y)
		} else {
			pattern_load(&app.life, app.selected_pattern)
		}
		app.selected_age = 0
		app.scene_dirty = true
	case .TAB:
		app.selected_pattern = pattern_next(app.selected_pattern, -1 if shift else 1)
		app.scene_dirty = true
	case .LEFTBRACKET:
		app.selected_age = max(app.selected_age - 1, 0)
		app.scene_dirty = true
	case .RIGHTBRACKET:
		app.selected_age = min(app.selected_age + 1, max(app.life.history_count - 1, 0))
		app.scene_dirty = true
	case .H:
		app.isolate_selected = !app.isolate_selected
		app.scene_dirty = true
	case .G:
		app.show_grid = !app.show_grid
	case .U:
		app.show_hud = !app.show_hud
	case .F:
		camera_reset(&app.camera)
		update_hover(app, app.last_mx, app.last_my)
		app.scene_dirty = true
	case .MINUS:
		app.tick_hz = max(app.tick_hz / 2, 1)
		app.tick_accum = 0
	case .EQUALS:
		app.tick_hz = min(app.tick_hz * 2, 64)
		app.tick_accum = 0
	}
}

run :: proc() {
	SDL.SetHint(SDL.HINT_RENDER_DRIVER, "metal")
	SDL.setenv("METAL_DEVICE_WRAPPER_TYPE", "1", 0)
	if SDL.Init({.VIDEO}) != 0 {
		fmt.eprintln("SDL_Init:", SDL.GetError())
		os.exit(1)
	}
	defer SDL.Quit()

	app := new(App)
	defer free(app)
	app.window = SDL.CreateWindow(
		"zlife // living time sculpture",
		SDL.WINDOWPOS_CENTERED,
		SDL.WINDOWPOS_CENTERED,
		1280,
		800,
		{.ALLOW_HIGHDPI, .HIDDEN, .RESIZABLE},
	)
	if app.window == nil {
		fmt.eprintln("SDL_CreateWindow:", SDL.GetError())
		os.exit(1)
	}
	defer SDL.DestroyWindow(app.window)

	wm: SDL.SysWMinfo
	SDL.GetVersion(&wm.version)
	if !SDL.GetWindowWMInfo(app.window, &wm) || wm.subsystem != .COCOA {
		fmt.eprintln("zlife requires a Cocoa window and Metal")
		os.exit(1)
	}
	app.native_window = (^NS.Window)(wm.info.cocoa.window)

	renderer, renderer_ok := renderer_init(app.native_window)
	if !renderer_ok {
		fmt.eprintln("Failed to initialize Metal renderer")
		os.exit(1)
	}
	app.renderer = renderer
	defer renderer_destroy(&app.renderer)

	app.camera = camera_default()
	app.paused = true
	app.running = true
	app.show_grid = true
	app.show_hud = true
	app.scene_dirty = true
	app.tick_hz = DEFAULT_TICK_HZ
	app.selected_pattern = .Glider_Fleet
	life_randomize(&app.life, u64(time.to_unix_nanoseconds(time.now())))

	update_drawable_size(app)
	SDL.ShowWindow(app.window)

	fmt.println("zlife: Z is generation history. Controls are shown in the HUD.")
	prev := time.tick_now()

	for app.running {
		frame_start := time.tick_now()
		for e: SDL.Event; SDL.PollEvent(&e); {
			#partial switch e.type {
			case .QUIT:
				app.running = false
			case .WINDOWEVENT:
				#partial switch e.window.event {
				case .SIZE_CHANGED, .RESIZED, .RESTORED, .MINIMIZED:
					update_drawable_size(app)
					app.scene_dirty = true
				}
			case .KEYDOWN:
				if e.key.repeat == 0 {
					handle_key(app, e.key.keysym.sym, SDL.GetModState())
				}
			case .MOUSEBUTTONDOWN:
				app.last_mx, app.last_my = e.button.x, e.button.y
				if e.button.button == SDL.BUTTON_RIGHT {
					app.orbiting = true
				} else if e.button.button == SDL.BUTTON_MIDDLE {
					app.panning = true
				} else if e.button.button == SDL.BUTTON_LEFT {
					app.painting = true
					if SDL.GetModState() & SDL.KMOD_SHIFT != {} {
						app.paint_alive = false
						handle_paint_at(app, e.button.x, e.button.y, false)
					} else {
						handle_paint_at(app, e.button.x, e.button.y, true)
					}
				}
			case .MOUSEBUTTONUP:
				if e.button.button == SDL.BUTTON_RIGHT do app.orbiting = false
				if e.button.button == SDL.BUTTON_MIDDLE do app.panning = false
				if e.button.button == SDL.BUTTON_LEFT do app.painting = false
				update_hover(app, e.button.x, e.button.y)
				app.scene_dirty = true
			case .MOUSEMOTION:
				dx := e.motion.x - app.last_mx
				dy := e.motion.y - app.last_my
				if app.orbiting {
					camera_orbit(&app.camera, f32(dx) * 0.005, f32(dy) * 0.005)
					update_hover(app, e.motion.x, e.motion.y)
					app.scene_dirty = true
				} else if app.panning {
					camera_pan(&app.camera, f32(dx), f32(dy))
					update_hover(app, e.motion.x, e.motion.y)
					app.scene_dirty = true
				} else if app.painting {
					handle_paint_at(app, e.motion.x, e.motion.y, false)
				} else {
					update_hover(app, e.motion.x, e.motion.y)
				}
				app.last_mx, app.last_my = e.motion.x, e.motion.y
			case .MOUSEWHEEL:
				camera_zoom(&app.camera, f32(e.wheel.y))
				update_hover(app, app.last_mx, app.last_my)
				app.scene_dirty = true
			}
		}

		now := time.tick_now()
		dt := min(time.duration_seconds(time.tick_diff(prev, now)), 0.25)
		prev = now
		app.elapsed += dt
		app.fps_accum += dt
		app.frame_count += 1
		if app.fps_accum >= 0.5 {
			app.fps = f64(app.frame_count) / app.fps_accum
			app.frame_count = 0
			app.fps_accum = 0
		}

		if !app.paused {
			app.tick_accum += dt
			tick := 1.0 / app.tick_hz
			for app.tick_accum >= tick {
				life_step(&app.life)
				app.tick_accum -= tick
				app.scene_dirty = true
			}
			app.selected_age = min(app.selected_age, app.life.history_count - 1)
		}

		if app.minimized {
			SDL.Delay(16)
			continue
		}

		pattern_preview_active := app.hover_valid &&
			!app.painting &&
			SDL.GetModState() & SDL.KMOD_SHIFT != {}
		if pattern_preview_active != app.pattern_preview_active {
			app.pattern_preview_active = pattern_preview_active
			app.scene_dirty = true
		}

		upload_instances := app.scene_dirty
		if upload_instances {
			app.instance_count = life_collect_instances(
				&app.life,
				app.instances[:],
				app.selected_age,
				app.isolate_selected,
			)
			app.preview_count = 0
			if app.hover_valid && !app.orbiting && !app.panning {
				preview_cells: [64][2]int
				cell_count := 1
				preview_cells[0] = {app.hover_x, app.hover_y}
				if app.pattern_preview_active {
					cell_count = pattern_collect_points(
						app.selected_pattern,
						app.hover_x,
						app.hover_y,
						preview_cells[:],
					)
				}
				for cell in preview_cells[:cell_count] {
					app.preview_instances[app.preview_count] = Instance{
						center = {
							f32(cell.x) - f32(GRID) * 0.5 + 0.5,
							f32(cell.y) - f32(GRID) * 0.5 + 0.5,
							0,
						},
						age = 0,
						scale = 1.0,
						glow = 2,
					}
					app.preview_count += 1
				}
			}
		}

		build_hud(app)
		renderer_draw(
			&app.renderer,
			app.instances[:app.instance_count],
			camera_view_proj(app.camera),
			f32(app.elapsed),
			app.selected_age,
			app.show_grid,
			app.preview_instances[:app.preview_count],
			app.ui_vertices[:app.ui_count],
			upload_instances,
		)
		app.scene_dirty = false
		frame_time := time.tick_diff(frame_start, time.tick_now())
		if frame_time < TARGET_FRAME_TIME {
			time.sleep(TARGET_FRAME_TIME - frame_time)
		}
	}
}

main :: proc() {
	run()
}
