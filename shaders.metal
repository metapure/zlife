using namespace metal;

struct Vertex {
	packed_float3 position;
	packed_float3 normal;
};

struct Instance {
	packed_float3 center;
	float age;
	float scale;
	float glow;
	float occlusion;
	float sun; // 0..1 ray-marched visibility toward the sun
};

struct Uniforms {
	float4x4 view_proj;
	float4 params;     // time, selected age, history depth, tick phase (-1 when paused)
	float4 resolution; // drawable width, height, unused, unused
	float4 eye;        // camera world position
};

struct V2F {
	float4 position [[position]];
	float3 normal;
	float3 world_pos;
	float age;
	float glow;
	float occlusion;
	float sun;
	float pulse;
	float hash;  // stable per-voxel random
	float shaft; // 0..1 membership in the current cyan data-shaft columns
	float spark; // 0..1 sparse residual per-cell sparkle
};

static float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

static float hash13(float3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

// Global breath shared by vertex swell and fragment gain: ~6 s cycle,
// shaped so the wall inhales slowly and exhales faster.
static float breath01(float time) {
	return smoothstep(-1.0, 0.7, sin(time * 1.05));
}

vertex V2F vertex_main(
	uint vid [[vertex_id]],
	uint iid [[instance_id]],
	constant Vertex   *vertices  [[buffer(0)]],
	constant Instance *instances [[buffer(1)]],
	constant Uniforms &uniforms  [[buffer(2)]]
) {
	Vertex   v = vertices[vid];
	Instance i = instances[iid];

	float time = uniforms.params.x;
	float phase = max(uniforms.params.w, 0.0);
	float3 center = i.center;
	float3 scale = float3(i.scale);
	if (i.glow < 1.5) {
		// Continuous waterfall: the whole tower glides down between ticks.
		center.y -= phase;
		if (i.age < 0.001 && uniforms.params.w >= 0.0) {
			// Newborn cells crystallize in instead of popping.
			float grow = smoothstep(0.0, 0.3, phase);
			scale *= mix(0.6, 1.0, grow);
		}
		// Rare time-hashed glitch streaks: a voxel briefly stretches into a
		// vertical smear and shears sideways, like data tearing on the wall.
		float gslot = floor(time * 7.0);
		float g = hash13(center + gslot * 11.17);
		if (g > 0.99) {
			float k = (g - 0.99) * 100.0;
			scale.y *= 1.0 + 2.5 * k;
			center.x += (fract(g * 149.31) - 0.5) * 0.5 * k;
		}
		// The wall physically dilates in phase with the global breath.
		scale *= 1.0 + 0.03 * breath01(time);
	}
	float3 world = center + v.position * scale;

	V2F out;
	out.position  = uniforms.view_proj * float4(world, 1.0);
	out.normal    = v.normal;
	out.world_pos = world;
	out.age       = i.age;
	out.glow      = i.glow;
	out.occlusion = i.occlusion;
	out.sun       = i.sun;
	out.pulse     = 1.0 + 0.06 * sin(time * 2.1);
	out.hash      = hash13(i.center * 0.371);

	// Cyan data-shafts: rare full-height columns (hash on xz only) burn
	// cold blue top to bottom. The selection migrates slowly, crossfading
	// into the next set at the end of each ~8 s slot.
	float2 col = float2(i.center.x, i.center.z);
	float slot = time / 8.0;
	float s0 = floor(slot);
	float shaft_a = smoothstep(0.978, 0.985, hash13(float3(col.x, col.y, s0 * 13.7)));
	float shaft_b = smoothstep(0.978, 0.985, hash13(float3(col.x, col.y, (s0 + 1.0) * 13.7)));
	out.shaft = mix(shaft_a, shaft_b, smoothstep(0.75, 1.0, fract(slot)));

	// Sparse residual per-cell sparkle as secondary texture.
	float sslot = floor(time * 1.5);
	out.spark = smoothstep(0.992, 1.0, hash13(i.center + sslot * 19.19));
	return out;
}

// HDR emission ramp down the timeline: searing red-orange at the present,
// through magenta and crimson, into ember red, dissolving to black. The
// wall is monochromatic red; heat is expressed by intensity, not whiteness.
static float3 blackwall_ramp(float age) {
	float3 core    = float3(3.40, 0.45, 0.30);
	float3 magenta = float3(1.90, 0.12, 1.05);
	float3 crimson = float3(1.05, 0.03, 0.22);
	float3 ember   = float3(0.30, 0.008, 0.05);
	float3 c = mix(core, magenta, smoothstep(0.0, 0.05, age));
	c = mix(c, crimson, smoothstep(0.05, 0.30, age));
	c = mix(c, ember, smoothstep(0.30, 0.78, age));
	c = mix(c, float3(0.0), smoothstep(0.78, 1.0, age));
	return c;
}

fragment float4 fragment_main(
	V2F in [[stage_in]],
	constant Uniforms &uniforms [[buffer(0)]]
) {
	float3 n = normalize(in.normal);
	float time = uniforms.params.x;
	float age = saturate(in.age);

	float3 emission = blackwall_ramp(age);

	// The voxels are emissive, but the marched sun term, per-voxel
	// occlusion, and a fixed key direction still modulate the emission so
	// the tower reads as a 3D structure instead of a flat glow.
	float3 key_dir = normalize(float3(0.8025, 0.3883, 0.4530));
	float face = 0.70 + 0.30 * saturate(dot(n, key_dir));
	float shade = (0.30 + 0.70 * in.sun) * (1.0 - in.occlusion * 0.65) * face;
	emission *= shade;

	// Every cell carries a subtle data-flicker.
	float flick = 0.82 + 0.18 * sin(time * 9.0 + in.hash * 50.265);
	emission *= flick;

	// Layered breathing: a slow global inhale/exhale, a brightness wave
	// rolling down the tower with the timeline, and a roaming hotspot
	// that wanders the wall like a pressure point behind the firewall.
	float breath = 0.85 + 0.33 * breath01(time);
	float wave = 1.0 + 0.10 * sin(in.world_pos.y * 0.08 + time * 0.9);
	float3 hotspot = float3(
		36.0 * sin(time * 0.13),
		-42.0 + 34.0 * sin(time * 0.071),
		36.0 * cos(time * 0.097)
	);
	float3 hd = in.world_pos - hotspot;
	float hot = exp(-dot(hd, hd) / (20.0 * 20.0));
	emission *= breath * wave * (1.0 + 1.0 * hot);

	// Cyan data-shafts: full-height cold columns with a soft brightness
	// scroll running down them, fading out near the dissolve.
	float tail = 1.0 - smoothstep(0.80, 1.0, age);
	float3 shaft_color = float3(0.55, 2.10, 2.80);
	float scroll = 0.70 + 0.30 * sin(in.world_pos.y * 0.5 - time * 4.0 + in.hash * 6.0);
	emission = mix(emission, shaft_color * shade * scroll, in.shaft * tail);

	// Sparse residual sparkles as secondary texture.
	float3 cyan = float3(0.30, 1.30, 1.90);
	float sparkle = 0.5 * in.spark * tail;
	emission = mix(
		emission,
		cyan * shade * (0.65 + 0.35 * sin(time * 17.0 + in.hash * 40.0)),
		sparkle
	);

	if (age < 0.001) {
		// Present layer breathes and burns hottest.
		emission *= in.pulse * 1.25;
	} else if (in.glow > 0.0 && in.glow < 1.5) {
		// Selected historical slice: a cyan scan band.
		emission = mix(emission, float3(0.30, 1.50, 2.20) * shade, 0.55 * in.glow);
		emission = max(emission, float3(0.02));
	}

	if (in.glow > 1.5) {
		// Hover / pattern preview cursor: bright cyan emissive.
		emission = float3(0.50, 2.40, 3.20);
	}

	return float4(emission, 1.0);
}

struct LineVertex {
	float4 position;
	float4 color;
};

struct LineV2F {
	float4 position [[position]];
	float4 color;
};

vertex LineV2F line_vertex(
	uint vid [[vertex_id]],
	constant LineVertex *vertices [[buffer(0)]],
	constant Uniforms &uniforms [[buffer(1)]]
) {
	LineV2F out;
	out.position = uniforms.view_proj * vertices[vid].position;
	out.color = vertices[vid].color;
	return out;
}

fragment float4 line_fragment(LineV2F in [[stage_in]]) {
	return in.color;
}

struct UIVertex {
	float4 position;
	float4 color;
};

struct UIV2F {
	float4 position [[position]];
	float4 color;
};

vertex UIV2F ui_vertex(
	uint vid [[vertex_id]],
	constant UIVertex *vertices [[buffer(0)]]
) {
	UIV2F out;
	out.position = vertices[vid].position;
	out.color = vertices[vid].color;
	return out;
}

fragment float4 ui_fragment(UIV2F in [[stage_in]]) {
	return in.color;
}

struct PostV2F {
	float4 position [[position]];
	float2 uv;
};

constexpr sampler post_sampler(filter::linear, address::clamp_to_edge);

vertex PostV2F post_vertex(uint vid [[vertex_id]]) {
	// Fullscreen triangle without a vertex buffer.
	float2 uv = float2((vid << 1) & 2, vid & 2);
	PostV2F out;
	out.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);
	out.uv = float2(uv.x, 1.0 - uv.y);
	return out;
}

fragment float4 bg_fragment(
	PostV2F in [[stage_in]],
	constant Uniforms &uniforms [[buffer(0)]]
) {
	// Pure black void: the wall floats in nothing. Composite grain keeps
	// the field from reading as dead flat.
	return float4(float3(0.002), 1.0);
}

fragment float4 bright_fragment(
	PostV2F in [[stage_in]],
	texture2d<float> scene [[texture(0)]]
) {
	// Soft-knee threshold: only genuinely hot HDR pixels feed the bloom,
	// so the crimson body of the wall stays crisp. Rec.709 luminance
	// undervalues pure red, so hot red is keyed on the red channel too.
	float3 c = scene.sample(post_sampler, in.uv).rgb;
	float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
	float key = max(lum, c.r * 0.55);
	float w = smoothstep(1.10, 2.40, key);
	return float4(c * w, 1.0);
}

constant float blur_weights[5] = {0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216};

fragment float4 blur_h_fragment(
	PostV2F in [[stage_in]],
	texture2d<float> src [[texture(0)]]
) {
	float texel = 1.0 / max(float(src.get_width()), 1.0);
	float3 c = src.sample(post_sampler, in.uv).rgb * blur_weights[0];
	for (int t = 1; t < 5; t++) {
		float2 offset = float2(texel * float(t), 0.0);
		c += src.sample(post_sampler, in.uv + offset).rgb * blur_weights[t];
		c += src.sample(post_sampler, in.uv - offset).rgb * blur_weights[t];
	}
	return float4(c, 1.0);
}

fragment float4 blur_v_fragment(
	PostV2F in [[stage_in]],
	texture2d<float> src [[texture(0)]]
) {
	float texel = 1.0 / max(float(src.get_height()), 1.0);
	float3 c = src.sample(post_sampler, in.uv).rgb * blur_weights[0];
	for (int t = 1; t < 5; t++) {
		float2 offset = float2(0.0, texel * float(t));
		c += src.sample(post_sampler, in.uv + offset).rgb * blur_weights[t];
		c += src.sample(post_sampler, in.uv - offset).rgb * blur_weights[t];
	}
	return float4(c, 1.0);
}

fragment float4 composite_fragment(
	PostV2F in [[stage_in]],
	constant Uniforms &uniforms [[buffer(0)]],
	texture2d<float> scene [[texture(0)]],
	texture2d<float> bloom [[texture(1)]]
) {
	float time = uniforms.params.x;
	float2 uv = in.uv;

	// Occasional glitch bursts displace horizontal bands of the frame.
	float burst = hash11(floor(time * 1.9) * 0.713);
	float glitch = smoothstep(0.90, 1.0, burst);
	if (glitch > 0.0) {
		float band = floor(uv.y * 36.0);
		float bh = hash11(band * 7.13 + floor(time * 23.0) * 3.1);
		float shift = (bh - 0.5) * 0.06 * glitch * step(0.7, bh);
		uv.x = fract(uv.x + shift);
	}

	// Radial chromatic aberration, red and blue pulled apart; kept subtle
	// at rest so the frame stays sharp, spiking during glitch bursts.
	float2 dir = uv - 0.5;
	float ca = 0.0012 + 0.010 * glitch;
	float3 color;
	color.r = scene.sample(post_sampler, uv + dir * ca).r;
	color.g = scene.sample(post_sampler, uv).g;
	color.b = scene.sample(post_sampler, uv - dir * ca).b;

	// Light unsharp mask crisps voxel edges before the bloom halo lands.
	float2 texel = 1.0 / float2(scene.get_width(), scene.get_height());
	float3 neighbors =
		scene.sample(post_sampler, uv + float2(texel.x, 0.0)).rgb +
		scene.sample(post_sampler, uv - float2(texel.x, 0.0)).rgb +
		scene.sample(post_sampler, uv + float2(0.0, texel.y)).rgb +
		scene.sample(post_sampler, uv - float2(0.0, texel.y)).rgb;
	float k = 0.2;
	color = max(color * (1.0 + 4.0 * k) - neighbors * k, 0.0);

	color += bloom.sample(post_sampler, uv).rgb * 0.55;

	// Scanlines and vignette; the pure-black background hides the
	// vignette's edge, so it can sink a little deeper.
	float scan = 0.93 + 0.07 * sin(in.position.y * 1.7);
	float vig = 1.0 - 0.45 * smoothstep(0.35, 0.95, length(in.uv - 0.5) * 1.35);
	color *= scan * vig;

	// Animated grain also dithers the long smooth gradients.
	float2 seed = in.position.xy + float2(fract(time * 61.7) * 289.0, fract(time * 97.3) * 173.0);
	float noise = fract(sin(dot(seed, float2(12.9898, 78.233))) * 43758.5453);
	color += (noise - 0.5) * 0.018;

	// ACES-ish tonemap back to LDR; the sRGB drawable handles encoding.
	color = max(color, 0.0);
	color = saturate((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14));

	return float4(color, 1.0);
}
