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
};

vertex V2F vertex_main(
	uint vid [[vertex_id]],
	uint iid [[instance_id]],
	constant Vertex   *vertices  [[buffer(0)]],
	constant Instance *instances [[buffer(1)]],
	constant Uniforms &uniforms  [[buffer(2)]]
) {
	Vertex   v = vertices[vid];
	Instance i = instances[iid];

	float phase = max(uniforms.params.w, 0.0);
	float3 center = i.center;
	float scale = i.scale;
	if (i.glow < 1.5) {
		// Continuous waterfall: the whole tower glides down between ticks.
		center.y -= phase;
		if (i.age < 0.001 && uniforms.params.w >= 0.0) {
			// Newborn cells crystallize in instead of popping.
			float grow = smoothstep(0.0, 0.3, phase);
			scale *= mix(0.6, 1.0, grow);
		}
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
	out.pulse     = 1.0 + 0.05 * sin(uniforms.params.x * 2.1);
	return out;
}

fragment float4 fragment_main(
	V2F in [[stage_in]],
	constant Uniforms &uniforms [[buffer(0)]]
) {
	float3 n = normalize(in.normal);

	// One hard sun, high contrast. Direction must match SUN_X/Y/Z in
	// life.odin, where the per-voxel shadow term (in.sun) is marched.
	float3 sun_dir = normalize(float3(0.8025, 0.3883, 0.4530));
	float ndl = saturate(dot(n, sun_dir));
	float direct = ndl * in.sun;

	// Near-black ambient so shadowed regions genuinely sink into the dark;
	// a whisper of sky from above keeps top faces readable inside shadow.
	float sky = n.y * 0.5 + 0.5;
	float ambient = 0.030 + 0.075 * sky * mix(0.6, 1.0, in.sun);

	float light = ambient + direct * 1.25;

	// Monochrome bone-white sculpture; age only dims it slightly until the
	// terminal dissolve, so shadow shapes carry the composition.
	float age = saturate(in.age);
	float albedo = mix(0.92, 0.55, smoothstep(0.0, 1.0, age));
	float3 tint = float3(0.985, 0.995, 1.02); // barely-there cool cast

	if (age < 0.001) {
		// Present layer breathes gently in luminance only.
		albedo *= in.pulse * 1.06;
	} else if (in.glow > 0.0 && in.glow < 1.5) {
		// Selected historical slice: a lifted, whiter band.
		albedo = mix(albedo, 1.0, 0.45 * in.glow);
		light = max(light, 0.30);
	}

	// Per-voxel ambient occlusion darkens crevices.
	light *= 1.0 - in.occlusion * 0.55;

	float3 color = tint * (albedo * light);

	// Faint fresnel lift separates dark silhouettes from the background.
	float3 view_dir = normalize(uniforms.eye.xyz - in.world_pos);
	float rim = pow(1.0 - saturate(dot(n, view_dir)), 4.0);
	color += float3(0.5, 0.52, 0.56) * rim * 0.10 * (1.0 - age * 0.8);

	// Gentle filmic-ish shoulder keeps bright faces from clipping flat.
	color = color / (1.0 + color * 0.25);

	// Dissolve into black over the last stretch of history.
	color = mix(color, float3(0.0), smoothstep(0.72, 1.0, age));

	if (in.glow > 1.5) {
		// Hover / pattern preview cursor: warm-white emissive.
		color = float3(1.0, 0.96, 0.86) * (0.80 + 0.20 * light);
	}

	return float4(color, 1.0);
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
};

vertex PostV2F post_vertex(uint vid [[vertex_id]]) {
	// Fullscreen triangle without a vertex buffer.
	float2 uv = float2((vid << 1) & 2, vid & 2);
	PostV2F out;
	out.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);
	return out;
}

fragment float4 bg_fragment(
	PostV2F in [[stage_in]],
	constant Uniforms &uniforms [[buffer(0)]]
) {
	float2 res = uniforms.resolution.xy;
	float2 uv = in.position.xy / max(res, float2(1.0));

	// Charcoal studio backdrop: a soft glow high behind the sculpture,
	// falling off to near-black toward the edges and the floor.
	float2 p = uv - float2(0.5, 0.34);
	p.x *= res.x / max(res.y, 1.0);
	float glow = exp(-dot(p, p) * 4.5);

	float3 bg = mix(float3(0.012, 0.012, 0.014), float3(0.115, 0.118, 0.125), glow);
	bg *= mix(1.0, 0.30, smoothstep(0.45, 1.05, uv.y));

	return float4(bg, 1.0);
}

fragment float4 post_fragment(
	PostV2F in [[stage_in]],
	constant Uniforms &uniforms [[buffer(0)]]
) {
	float2 px = in.position.xy;
	float time = uniforms.params.x;

	// Faint animated grain; also dithers the long smooth gradients.
	float2 seed = px + float2(fract(time * 61.7) * 289.0, fract(time * 97.3) * 173.0);
	float noise = fract(sin(dot(seed, float2(12.9898, 78.233))) * 43758.5453);

	return float4(float3(noise), 0.03);
}
