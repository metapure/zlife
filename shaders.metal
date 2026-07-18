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
	float2 padding;
};

struct Uniforms {
	float4x4 view_proj;
	float4 params; // time, selected age, history depth, unused
};

struct V2F {
	float4 position [[position]];
	float3 normal;
	float age;
	float glow;
	float world_z;
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

	float3 world = i.center + v.position * i.scale;

	V2F out;
	out.position = uniforms.view_proj * float4(world, 1.0);
	out.normal   = v.normal;
	out.age      = i.age;
	out.glow     = i.glow;
	out.world_z  = world.z;
	out.pulse    = 1.0 + 0.07 * sin(uniforms.params.x * 3.2);
	return out;
}

fragment float4 fragment_main(V2F in [[stage_in]]) {
	float3 n = normalize(in.normal);
	float3 light = normalize(float3(0.35, 0.85, 0.4));
	float ndotl = saturate(dot(n, light));
	float ambient = 0.28;
	float lighting = ambient + (1.0 - ambient) * ndotl;

	float age = saturate(in.age);
	float3 present = float3(1.0, 0.68, 0.18);
	float3 middle  = float3(0.72, 0.20, 0.92);
	float3 ancient = float3(0.08, 0.38, 0.86);
	float3 color = age < 0.48
		? mix(present, middle, age / 0.48)
		: mix(middle, ancient, (age - 0.48) / 0.52);
	color *= mix(1.15, 0.34, age);
	if (age < 0.001) {
		color *= in.pulse;
	}
	color += color * in.glow * 0.48;
	if (in.glow > 1.5) {
		color = float3(0.18, 0.95, 1.0) * (0.75 + 0.25 * lighting);
	}
	color *= lighting;
	color = mix(color, float3(0.04, 0.05, 0.08), age * 0.42);

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
