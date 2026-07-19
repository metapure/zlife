package main

import "core:math"
import "core:math/linalg"

Camera :: struct {
	yaw:      f32,
	pitch:    f32,
	distance: f32,
	target:   [3]f32,
	aspect:   f32,
}

camera_default :: proc() -> Camera {
	// History hangs downward from the present plane, so the reference-style
	// "spires rising into the dark" reads from BELOW: eye near the base of
	// the sculpture, negative pitch looking up, dissolving tips overhead.
	// Scaled up from the hand-tuned 96 x 96 x 256 framing (V key snapshot)
	// for the 256 x 256 x 1024 tower; re-tune with V as needed.
	return Camera {
		yaw      = 8.027,
		pitch    = 1.198,
		distance = 1600.0,
		target   = {82.95, -333.92, -20.88},
		aspect   = 16.0 / 9.0,
	}
}

camera_reset :: proc(cam: ^Camera) {
	aspect := cam.aspect
	cam^ = camera_default()
	cam.aspect = aspect
}

camera_eye :: proc(cam: Camera) -> [3]f32 {
	cp := math.cos(cam.pitch)
	sp := math.sin(cam.pitch)
	cy := math.cos(cam.yaw)
	sy := math.sin(cam.yaw)
	offset := [3]f32{cp * sy, sp, cp * cy} * cam.distance
	return cam.target + offset
}

// Metal NDC z in [0, 1].
metal_perspective :: proc(fovy, aspect, near, far: f32) -> matrix[4, 4]f32 {
	t := math.tan(fovy * 0.5)
	sx := 1.0 / (aspect * t)
	sy := 1.0 / t
	m: matrix[4, 4]f32
	m[0, 0] = sx
	m[1, 1] = sy
	m[2, 2] = far / (far - near)
	m[2, 3] = (-near * far) / (far - near)
	m[3, 2] = 1
	return m
}

camera_view_proj :: proc(cam: Camera) -> matrix[4, 4]f32 {
	eye := camera_eye(cam)
	view := linalg.matrix4_look_at_f32(eye, cam.target, {0, 1, 0}, false)
	proj := metal_perspective(math.to_radians_f32(40), cam.aspect, 0.1, 3500)
	return proj * view
}

camera_orbit :: proc(cam: ^Camera, dx, dy: f32) {
	cam.yaw += dx
	cam.pitch = math.clamp(cam.pitch + dy, -1.35, 1.35)
}

camera_zoom :: proc(cam: ^Camera, delta: f32) {
	cam.distance = math.clamp(cam.distance * math.pow(0.9, delta), 20, 1600)
}

camera_pan :: proc(cam: ^Camera, dx, dy: f32) {
	cp := math.cos(cam.pitch)
	sp := math.sin(cam.pitch)
	cy := math.cos(cam.yaw)
	sy := math.sin(cam.yaw)
	right := [3]f32{cy, 0, -sy}
	up := [3]f32{-sp * sy, cp, -sp * cy}
	speed := cam.distance * 0.0015
	cam.target += (right * -dx + up * dy) * speed
}

// Raycast mouse onto the y=0 plane (current generation). Returns grid coords if hit.
camera_pick_cell :: proc(cam: Camera, mx, my: f32, fb_w, fb_h: f32) -> (x, y: int, ok: bool) {
	if fb_w <= 0 || fb_h <= 0 {
		return 0, 0, false
	}

	ndc_x := (2 * mx / fb_w) - 1
	ndc_y := 1 - (2 * my / fb_h)

	vp := camera_view_proj(cam)
	inv := linalg.matrix4_inverse_f32(vp)

	p_near := inv * [4]f32{ndc_x, ndc_y, 0, 1}
	p_far := inv * [4]f32{ndc_x, ndc_y, 1, 1}
	if p_near.w == 0 || p_far.w == 0 {
		return 0, 0, false
	}
	near := p_near.xyz / p_near.w
	far := p_far.xyz / p_far.w

	dir := far - near
	if abs(dir.y) < 1e-6 {
		return 0, 0, false
	}
	t := -near.y / dir.y
	if t < 0 {
		return 0, 0, false
	}
	hit := near + dir * t

	half_w := f32(GRID) * 0.5
	half_h := f32(GRID) * 0.5
	gx := int(math.floor(hit.x + half_w))
	gy := int(math.floor(hit.z + half_h))
	if gx < 0 || gx >= GRID || gy < 0 || gy >= GRID {
		return 0, 0, false
	}
	return gx, gy, true
}
