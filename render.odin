package main

import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"

import "core:fmt"
import "core:mem"

Instance :: struct {
	center: [3]f32,
	age: f32,
	scale: f32,
	glow: f32,
	occlusion: f32,
	sun: f32, // 0..1 ray-marched visibility toward the sun
	corruption: f32, // 0..1 breach infection carried over from the simulation
}

Uniforms :: struct {
	view_proj: matrix[4, 4]f32,
	params: [4]f32,
	resolution: [4]f32,
	eye: [4]f32,
	breach: [4]f32, // xyz = world-space breach center, w = breach start time
}

Vertex :: struct {
	position: [3]f32,
	normal:   [3]f32,
}

Line_Vertex :: struct {
	position: [4]f32,
	color: [4]f32,
}

Renderer :: struct {
	device:         ^MTL.Device,
	swapchain:      ^CA.MetalLayer,
	queue:          ^MTL.CommandQueue,
	pso:            ^MTL.RenderPipelineState,
	line_pso:       ^MTL.RenderPipelineState,
	ui_pso:         ^MTL.RenderPipelineState,
	bg_pso:         ^MTL.RenderPipelineState,
	bright_pso:     ^MTL.RenderPipelineState,
	blur_h_pso:     ^MTL.RenderPipelineState,
	blur_v_pso:     ^MTL.RenderPipelineState,
	composite_pso:  ^MTL.RenderPipelineState,
	depth_state:    ^MTL.DepthStencilState,
	overlay_depth_state: ^MTL.DepthStencilState,
	depth_texture:  ^MTL.Texture,
	scene_tex:      ^MTL.Texture,
	bloom_a:        ^MTL.Texture,
	bloom_b:        ^MTL.Texture,
	vertex_buffer:  ^MTL.Buffer,
	instance_buffer:^MTL.Buffer,
	uniform_buffer: ^MTL.Buffer,
	grid_buffer:    ^MTL.Buffer,
	ui_buffer:      ^MTL.Buffer,
	depth_w:        int,
	depth_h:        int,
	max_instances:  int,
	grid_vertex_count: int,
	instance_count: int,
}

CUBE_VERTICES := [?]Vertex {
	// +Y
	{{ -0.5,  0.5, -0.5 }, { 0, 1, 0 }}, {{  0.5,  0.5, -0.5 }, { 0, 1, 0 }}, {{  0.5,  0.5,  0.5 }, { 0, 1, 0 }},
	{{ -0.5,  0.5, -0.5 }, { 0, 1, 0 }}, {{  0.5,  0.5,  0.5 }, { 0, 1, 0 }}, {{ -0.5,  0.5,  0.5 }, { 0, 1, 0 }},
	// -Y
	{{ -0.5, -0.5,  0.5 }, { 0,-1, 0 }}, {{  0.5, -0.5,  0.5 }, { 0,-1, 0 }}, {{  0.5, -0.5, -0.5 }, { 0,-1, 0 }},
	{{ -0.5, -0.5,  0.5 }, { 0,-1, 0 }}, {{  0.5, -0.5, -0.5 }, { 0,-1, 0 }}, {{ -0.5, -0.5, -0.5 }, { 0,-1, 0 }},
	// +Z
	{{ -0.5, -0.5,  0.5 }, { 0, 0, 1 }}, {{ -0.5,  0.5,  0.5 }, { 0, 0, 1 }}, {{  0.5,  0.5,  0.5 }, { 0, 0, 1 }},
	{{ -0.5, -0.5,  0.5 }, { 0, 0, 1 }}, {{  0.5,  0.5,  0.5 }, { 0, 0, 1 }}, {{  0.5, -0.5,  0.5 }, { 0, 0, 1 }},
	// -Z
	{{  0.5, -0.5, -0.5 }, { 0, 0,-1 }}, {{  0.5,  0.5, -0.5 }, { 0, 0,-1 }}, {{ -0.5,  0.5, -0.5 }, { 0, 0,-1 }},
	{{  0.5, -0.5, -0.5 }, { 0, 0,-1 }}, {{ -0.5,  0.5, -0.5 }, { 0, 0,-1 }}, {{ -0.5, -0.5, -0.5 }, { 0, 0,-1 }},
	// +X
	{{  0.5, -0.5,  0.5 }, { 1, 0, 0 }}, {{  0.5,  0.5,  0.5 }, { 1, 0, 0 }}, {{  0.5,  0.5, -0.5 }, { 1, 0, 0 }},
	{{  0.5, -0.5,  0.5 }, { 1, 0, 0 }}, {{  0.5,  0.5, -0.5 }, { 1, 0, 0 }}, {{  0.5, -0.5, -0.5 }, { 1, 0, 0 }},
	// -X
	{{ -0.5, -0.5, -0.5 }, {-1, 0, 0 }}, {{ -0.5,  0.5, -0.5 }, {-1, 0, 0 }}, {{ -0.5,  0.5,  0.5 }, {-1, 0, 0 }},
	{{ -0.5, -0.5, -0.5 }, {-1, 0, 0 }}, {{ -0.5,  0.5,  0.5 }, {-1, 0, 0 }}, {{ -0.5, -0.5,  0.5 }, {-1, 0, 0 }},
}

SHADER_SRC :: string(#load("shaders.metal"))

@(private)
line_push :: proc(
	vertices: []Line_Vertex,
	count: ^int,
	a, b: [3]f32,
	color: [4]f32,
) {
	if count^ + 2 > len(vertices) {
		return
	}
	vertices[count^] = {position = {a.x, a.y, a.z, 1}, color = color}
	count^ += 1
	vertices[count^] = {position = {b.x, b.y, b.z, 1}, color = color}
	count^ += 1
}

@(private)
renderer_create_grid :: proc(r: ^Renderer) {
	vertices: [512]Line_Vertex
	count := 0
	half := f32(GRID) * 0.5
	// Editing plane floats just above the present layer; history hangs below.
	y0 := f32(0.52)

	for i in 0 ..= GRID {
		p := f32(i) - half
		alpha: f32 = 0.04
		if i % 8 == 0 || i == GRID / 2 {
			alpha = 0.10
		}
		color := [4]f32{0.70, 0.05, 0.04, alpha}
		line_push(vertices[:], &count, {-half, y0, p}, {half, y0, p}, color)
		line_push(vertices[:], &count, {p, y0, -half}, {p, y0, half}, color)
	}
	r.grid_vertex_count = count
	r.grid_buffer = r.device->newBufferWithSlice(vertices[:count], {})
}

renderer_init :: proc(native_window: ^NS.Window) -> (r: Renderer, ok: bool) {
	r.device = MTL.CreateSystemDefaultDevice()
	if r.device == nil {
		fmt.eprintln("No Metal device")
		return {}, false
	}
	fmt.println("Metal:", r.device->name()->odinString())

	r.swapchain = CA.MetalLayer.layer()
	r.swapchain->setDevice(r.device)
	r.swapchain->setPixelFormat(.BGRA8Unorm_sRGB)
	r.swapchain->setFramebufferOnly(true)
	r.swapchain->setDisplaySyncEnabled(true)
	r.swapchain->setFrame(native_window->frame())

	view := native_window->contentView()
	view->setWantsLayer(true)
	view->setLayer(r.swapchain)
	native_window->setOpaque(true)
	native_window->setBackgroundColor(nil)

	r.queue = r.device->newCommandQueue()

	compile_options := NS.new(MTL.CompileOptions)
	defer compile_options->release()

	shader_src := NS.String.alloc()->initWithOdinString(SHADER_SRC)
	defer shader_src->release()
	library, library_error := r.device->newLibraryWithSource(shader_src, compile_options)
	if library_error != nil {
		fmt.eprintln(library_error->localizedDescription()->odinString())
		renderer_destroy(&r)
		return {}, false
	}
	defer library->release()

	vert_fn := library->newFunctionWithName(NS.AT("vertex_main"))
	frag_fn := library->newFunctionWithName(NS.AT("fragment_main"))
	line_vert_fn := library->newFunctionWithName(NS.AT("line_vertex"))
	line_frag_fn := library->newFunctionWithName(NS.AT("line_fragment"))
	ui_vert_fn := library->newFunctionWithName(NS.AT("ui_vertex"))
	ui_frag_fn := library->newFunctionWithName(NS.AT("ui_fragment"))
	post_vert_fn := library->newFunctionWithName(NS.AT("post_vertex"))
	bg_frag_fn := library->newFunctionWithName(NS.AT("bg_fragment"))
	bright_frag_fn := library->newFunctionWithName(NS.AT("bright_fragment"))
	blur_h_frag_fn := library->newFunctionWithName(NS.AT("blur_h_fragment"))
	blur_v_frag_fn := library->newFunctionWithName(NS.AT("blur_v_fragment"))
	composite_frag_fn := library->newFunctionWithName(NS.AT("composite_fragment"))
	if vert_fn == nil || frag_fn == nil ||
	   line_vert_fn == nil || line_frag_fn == nil ||
	   ui_vert_fn == nil || ui_frag_fn == nil ||
	   post_vert_fn == nil || bg_frag_fn == nil ||
	   bright_frag_fn == nil || blur_h_frag_fn == nil ||
	   blur_v_frag_fn == nil || composite_frag_fn == nil {
		fmt.eprintln("Metal shader entry point missing")
		renderer_destroy(&r)
		return {}, false
	}
	defer vert_fn->release()
	defer frag_fn->release()
	defer line_vert_fn->release()
	defer line_frag_fn->release()
	defer ui_vert_fn->release()
	defer ui_frag_fn->release()
	defer post_vert_fn->release()
	defer bg_frag_fn->release()
	defer bright_frag_fn->release()
	defer blur_h_frag_fn->release()
	defer blur_v_frag_fn->release()
	defer composite_frag_fn->release()

	// The scene renders into a full-resolution HDR texture; post passes
	// then shape it into the final Blackwall frame on the drawable.
	pso_desc := NS.new(MTL.RenderPipelineDescriptor)
	defer pso_desc->release()
	pso_desc->colorAttachments()->object(0)->setPixelFormat(.RGBA16Float)
	pso_desc->setDepthAttachmentPixelFormat(.Depth32Float)
	pso_desc->setVertexFunction(vert_fn)
	pso_desc->setFragmentFunction(frag_fn)

	pipeline_error: ^NS.Error
	r.pso, pipeline_error = r.device->newRenderPipelineState(pso_desc)
	if pipeline_error != nil {
		fmt.eprintln(pipeline_error->localizedDescription()->odinString())
		renderer_destroy(&r)
		return {}, false
	}

	line_desc := NS.new(MTL.RenderPipelineDescriptor)
	defer line_desc->release()
	line_attachment := line_desc->colorAttachments()->object(0)
	line_attachment->setPixelFormat(.RGBA16Float)
	line_attachment->setBlendingEnabled(true)
	line_attachment->setSourceRGBBlendFactor(.SourceAlpha)
	line_attachment->setDestinationRGBBlendFactor(.OneMinusSourceAlpha)
	line_attachment->setSourceAlphaBlendFactor(.One)
	line_attachment->setDestinationAlphaBlendFactor(.OneMinusSourceAlpha)
	line_desc->setDepthAttachmentPixelFormat(.Depth32Float)
	line_desc->setVertexFunction(line_vert_fn)
	line_desc->setFragmentFunction(line_frag_fn)
	r.line_pso, pipeline_error = r.device->newRenderPipelineState(line_desc)
	if pipeline_error != nil {
		fmt.eprintln(pipeline_error->localizedDescription()->odinString())
		renderer_destroy(&r)
		return {}, false
	}

	ui_desc := NS.new(MTL.RenderPipelineDescriptor)
	defer ui_desc->release()
	ui_attachment := ui_desc->colorAttachments()->object(0)
	ui_attachment->setPixelFormat(.RGBA16Float)
	ui_attachment->setBlendingEnabled(true)
	ui_attachment->setSourceRGBBlendFactor(.SourceAlpha)
	ui_attachment->setDestinationRGBBlendFactor(.OneMinusSourceAlpha)
	ui_attachment->setSourceAlphaBlendFactor(.One)
	ui_attachment->setDestinationAlphaBlendFactor(.OneMinusSourceAlpha)
	ui_desc->setDepthAttachmentPixelFormat(.Depth32Float)
	ui_desc->setVertexFunction(ui_vert_fn)
	ui_desc->setFragmentFunction(ui_frag_fn)
	r.ui_pso, pipeline_error = r.device->newRenderPipelineState(ui_desc)
	if pipeline_error != nil {
		fmt.eprintln(pipeline_error->localizedDescription()->odinString())
		renderer_destroy(&r)
		return {}, false
	}

	bg_desc := NS.new(MTL.RenderPipelineDescriptor)
	defer bg_desc->release()
	bg_desc->colorAttachments()->object(0)->setPixelFormat(.RGBA16Float)
	bg_desc->setDepthAttachmentPixelFormat(.Depth32Float)
	bg_desc->setVertexFunction(post_vert_fn)
	bg_desc->setFragmentFunction(bg_frag_fn)
	r.bg_pso, pipeline_error = r.device->newRenderPipelineState(bg_desc)
	if pipeline_error != nil {
		fmt.eprintln(pipeline_error->localizedDescription()->odinString())
		renderer_destroy(&r)
		return {}, false
	}

	// Fullscreen post pipelines: bright pass and blurs write half-res HDR
	// bloom textures; the composite resolves everything onto the drawable.
	bright_desc := NS.new(MTL.RenderPipelineDescriptor)
	defer bright_desc->release()
	bright_desc->colorAttachments()->object(0)->setPixelFormat(.RGBA16Float)
	bright_desc->setVertexFunction(post_vert_fn)
	bright_desc->setFragmentFunction(bright_frag_fn)
	r.bright_pso, pipeline_error = r.device->newRenderPipelineState(bright_desc)
	if pipeline_error != nil {
		fmt.eprintln(pipeline_error->localizedDescription()->odinString())
		renderer_destroy(&r)
		return {}, false
	}

	blur_h_desc := NS.new(MTL.RenderPipelineDescriptor)
	defer blur_h_desc->release()
	blur_h_desc->colorAttachments()->object(0)->setPixelFormat(.RGBA16Float)
	blur_h_desc->setVertexFunction(post_vert_fn)
	blur_h_desc->setFragmentFunction(blur_h_frag_fn)
	r.blur_h_pso, pipeline_error = r.device->newRenderPipelineState(blur_h_desc)
	if pipeline_error != nil {
		fmt.eprintln(pipeline_error->localizedDescription()->odinString())
		renderer_destroy(&r)
		return {}, false
	}

	blur_v_desc := NS.new(MTL.RenderPipelineDescriptor)
	defer blur_v_desc->release()
	blur_v_desc->colorAttachments()->object(0)->setPixelFormat(.RGBA16Float)
	blur_v_desc->setVertexFunction(post_vert_fn)
	blur_v_desc->setFragmentFunction(blur_v_frag_fn)
	r.blur_v_pso, pipeline_error = r.device->newRenderPipelineState(blur_v_desc)
	if pipeline_error != nil {
		fmt.eprintln(pipeline_error->localizedDescription()->odinString())
		renderer_destroy(&r)
		return {}, false
	}

	composite_desc := NS.new(MTL.RenderPipelineDescriptor)
	defer composite_desc->release()
	composite_desc->colorAttachments()->object(0)->setPixelFormat(.BGRA8Unorm_sRGB)
	composite_desc->setVertexFunction(post_vert_fn)
	composite_desc->setFragmentFunction(composite_frag_fn)
	r.composite_pso, pipeline_error = r.device->newRenderPipelineState(composite_desc)
	if pipeline_error != nil {
		fmt.eprintln(pipeline_error->localizedDescription()->odinString())
		renderer_destroy(&r)
		return {}, false
	}

	ds_desc := MTL.DepthStencilDescriptor.alloc()->init()
	defer ds_desc->release()
	ds_desc->setDepthCompareFunction(.Less)
	ds_desc->setDepthWriteEnabled(true)
	r.depth_state = r.device->newDepthStencilState(ds_desc)

	overlay_ds_desc := MTL.DepthStencilDescriptor.alloc()->init()
	defer overlay_ds_desc->release()
	overlay_ds_desc->setDepthCompareFunction(.Always)
	overlay_ds_desc->setDepthWriteEnabled(false)
	r.overlay_depth_state = r.device->newDepthStencilState(overlay_ds_desc)

	r.vertex_buffer = r.device->newBufferWithSlice(CUBE_VERTICES[:], {})
	r.max_instances = GRID * GRID * DEPTH + 64
	r.instance_buffer = r.device->newBufferWithLength(NS.UInteger(r.max_instances * size_of(Instance)), {})
	r.uniform_buffer = r.device->newBufferWithLength(NS.UInteger(size_of(Uniforms)), {})
	r.ui_buffer = r.device->newBufferWithLength(NS.UInteger(UI_MAX_VERTICES * size_of(UI_Vertex)), {})
	renderer_create_grid(&r)

	if r.queue == nil || r.pso == nil || r.depth_state == nil ||
	   r.bright_pso == nil || r.blur_h_pso == nil ||
	   r.blur_v_pso == nil || r.composite_pso == nil ||
	   r.vertex_buffer == nil || r.instance_buffer == nil ||
	   r.uniform_buffer == nil || r.grid_buffer == nil || r.ui_buffer == nil {
		fmt.eprintln("Metal resource allocation failed")
		renderer_destroy(&r)
		return {}, false
	}
	return r, true
}

renderer_resize_depth :: proc(r: ^Renderer, width, height: int) {
	if width <= 0 || height <= 0 {
		return
	}
	if r.depth_texture != nil && r.depth_w == width && r.depth_h == height {
		return
	}
	if r.depth_texture != nil {
		r.depth_texture->release()
		r.depth_texture = nil
	}
	if r.scene_tex != nil {
		r.scene_tex->release()
		r.scene_tex = nil
	}
	if r.bloom_a != nil {
		r.bloom_a->release()
		r.bloom_a = nil
	}
	if r.bloom_b != nil {
		r.bloom_b->release()
		r.bloom_b = nil
	}

	desc := MTL.TextureDescriptor.texture2DDescriptorWithPixelFormat(
		.Depth32Float,
		NS.UInteger(width),
		NS.UInteger(height),
		false,
	)
	desc->setStorageMode(.Private)
	desc->setUsage({.RenderTarget})
	r.depth_texture = r.device->newTextureWithDescriptor(desc)

	scene_desc := MTL.TextureDescriptor.texture2DDescriptorWithPixelFormat(
		.RGBA16Float,
		NS.UInteger(width),
		NS.UInteger(height),
		false,
	)
	scene_desc->setStorageMode(.Private)
	scene_desc->setUsage({.RenderTarget, .ShaderRead})
	r.scene_tex = r.device->newTextureWithDescriptor(scene_desc)

	bloom_w := max(width / 2, 1)
	bloom_h := max(height / 2, 1)
	bloom_desc := MTL.TextureDescriptor.texture2DDescriptorWithPixelFormat(
		.RGBA16Float,
		NS.UInteger(bloom_w),
		NS.UInteger(bloom_h),
		false,
	)
	bloom_desc->setStorageMode(.Private)
	bloom_desc->setUsage({.RenderTarget, .ShaderRead})
	r.bloom_a = r.device->newTextureWithDescriptor(bloom_desc)
	r.bloom_b = r.device->newTextureWithDescriptor(bloom_desc)

	r.depth_w = width
	r.depth_h = height
}

renderer_set_drawable_size :: proc(r: ^Renderer, width, height: f64) {
	if r.swapchain == nil {
		return
	}
	r.swapchain->setDrawableSize(NS.Size{width = NS.Float(width), height = NS.Float(height)})
	renderer_resize_depth(r, int(width + 0.5), int(height + 0.5))
}

renderer_draw :: proc(
	r: ^Renderer,
	instances: []Instance,
	view_proj: matrix[4, 4]f32,
	eye: [3]f32,
	elapsed: f32,
	tick_phase: f32,
	breach: [4]f32,
	selected_age: int,
	show_editing_grid: bool,
	previews: []Instance,
	ui_vertices: []UI_Vertex,
	upload_instances: bool,
) {
	NS.scoped_autoreleasepool()

	drawable := r.swapchain->nextDrawable()
	if drawable == nil || r.depth_texture == nil || r.scene_tex == nil {
		return
	}

	inst_count := r.instance_count
	if upload_instances {
		preview_count := min(len(previews), r.max_instances)
		inst_count = min(len(instances), r.max_instances - preview_count)
		dst := r.instance_buffer->contentsAsSlice([]Instance)
		if inst_count > 0 {
			mem.copy(&dst[0], &instances[0], inst_count * size_of(Instance))
		}
		if preview_count > 0 {
			mem.copy(&dst[inst_count], &previews[0], preview_count * size_of(Instance))
			inst_count += preview_count
		}
		r.instance_count = inst_count
	}

	uniforms := r.uniform_buffer->contentsAsSlice([]Uniforms)
	uniforms[0].view_proj = view_proj
	uniforms[0].params = {elapsed, f32(selected_age), f32(DEPTH), tick_phase}
	uniforms[0].resolution = {f32(r.depth_w), f32(r.depth_h), 0, 0}
	uniforms[0].eye = {eye.x, eye.y, eye.z, 0}
	uniforms[0].breach = breach

	ui_count := min(len(ui_vertices), UI_MAX_VERTICES)
	if ui_count > 0 {
		ui_dst := r.ui_buffer->contentsAsSlice([]UI_Vertex)
		mem.copy(&ui_dst[0], &ui_vertices[0], ui_count * size_of(UI_Vertex))
	}

	// Pass 1: render the scene into the full-resolution HDR texture.
	pass := MTL.RenderPassDescriptor.renderPassDescriptor()
	color := pass->colorAttachments()->object(0)
	color->setClearColor(MTL.ClearColor{0.0, 0.0, 0.0, 1.0})
	color->setLoadAction(.Clear)
	color->setStoreAction(.Store)
	color->setTexture(r.scene_tex)

	depth := pass->depthAttachment()
	depth->setTexture(r.depth_texture)
	depth->setClearDepth(1.0)
	depth->setLoadAction(.Clear)
	depth->setStoreAction(.DontCare)

	cmd := r.queue->commandBuffer()
	enc := cmd->renderCommandEncoderWithDescriptor(pass)

	// Charcoal gradient backdrop, drawn behind everything.
	enc->setRenderPipelineState(r.bg_pso)
	enc->setDepthStencilState(r.overlay_depth_state)
	enc->setFragmentBuffer(r.uniform_buffer, 0, 0)
	enc->drawPrimitives(.Triangle, 0, 3)

	if show_editing_grid {
		enc->setRenderPipelineState(r.line_pso)
		enc->setDepthStencilState(r.depth_state)
		enc->setVertexBuffer(r.grid_buffer, 0, 0)
		enc->setVertexBuffer(r.uniform_buffer, 0, 1)
		enc->drawPrimitives(.Line, 0, NS.UInteger(r.grid_vertex_count))
	}

	enc->setRenderPipelineState(r.pso)
	enc->setDepthStencilState(r.depth_state)
	enc->setFrontFacingWinding(.CounterClockwise)
	enc->setCullMode(.Back)
	enc->setVertexBuffer(r.vertex_buffer, 0, 0)
	enc->setVertexBuffer(r.instance_buffer, 0, 1)
	enc->setVertexBuffer(r.uniform_buffer, 0, 2)
	enc->setFragmentBuffer(r.uniform_buffer, 0, 0)

	if inst_count > 0 {
		enc->drawPrimitivesWithInstanceCount(.Triangle, 0, NS.UInteger(len(CUBE_VERTICES)), NS.UInteger(inst_count))
	}

	if ui_count > 0 {
		enc->setRenderPipelineState(r.ui_pso)
		enc->setDepthStencilState(r.overlay_depth_state)
		enc->setVertexBuffer(r.ui_buffer, 0, 0)
		enc->drawPrimitives(.Triangle, 0, NS.UInteger(ui_count))
	}

	enc->endEncoding()

	// Pass 2: bright-pass threshold, downsampled into the half-res bloom
	// texture. Pass 3/4: separable Gaussian blur ping-ponged across the
	// two bloom textures.
	bright_pass := MTL.RenderPassDescriptor.renderPassDescriptor()
	bright_color := bright_pass->colorAttachments()->object(0)
	bright_color->setLoadAction(.DontCare)
	bright_color->setStoreAction(.Store)
	bright_color->setTexture(r.bloom_a)
	enc = cmd->renderCommandEncoderWithDescriptor(bright_pass)
	enc->setRenderPipelineState(r.bright_pso)
	enc->setFragmentTexture(r.scene_tex, 0)
	enc->drawPrimitives(.Triangle, 0, 3)
	enc->endEncoding()

	blur_h_pass := MTL.RenderPassDescriptor.renderPassDescriptor()
	blur_h_color := blur_h_pass->colorAttachments()->object(0)
	blur_h_color->setLoadAction(.DontCare)
	blur_h_color->setStoreAction(.Store)
	blur_h_color->setTexture(r.bloom_b)
	enc = cmd->renderCommandEncoderWithDescriptor(blur_h_pass)
	enc->setRenderPipelineState(r.blur_h_pso)
	enc->setFragmentTexture(r.bloom_a, 0)
	enc->drawPrimitives(.Triangle, 0, 3)
	enc->endEncoding()

	blur_v_pass := MTL.RenderPassDescriptor.renderPassDescriptor()
	blur_v_color := blur_v_pass->colorAttachments()->object(0)
	blur_v_color->setLoadAction(.DontCare)
	blur_v_color->setStoreAction(.Store)
	blur_v_color->setTexture(r.bloom_a)
	enc = cmd->renderCommandEncoderWithDescriptor(blur_v_pass)
	enc->setRenderPipelineState(r.blur_v_pso)
	enc->setFragmentTexture(r.bloom_b, 0)
	enc->drawPrimitives(.Triangle, 0, 3)
	enc->endEncoding()

	// Pass 5: composite onto the drawable — glitch displacement, chromatic
	// aberration, bloom, scanlines, vignette, grain, and tonemap.
	composite_pass := MTL.RenderPassDescriptor.renderPassDescriptor()
	composite_color := composite_pass->colorAttachments()->object(0)
	composite_color->setLoadAction(.DontCare)
	composite_color->setStoreAction(.Store)
	composite_color->setTexture(drawable->texture())
	enc = cmd->renderCommandEncoderWithDescriptor(composite_pass)
	enc->setRenderPipelineState(r.composite_pso)
	enc->setFragmentBuffer(r.uniform_buffer, 0, 0)
	enc->setFragmentTexture(r.scene_tex, 0)
	enc->setFragmentTexture(r.bloom_a, 1)
	enc->drawPrimitives(.Triangle, 0, 3)
	enc->endEncoding()

	cmd->presentDrawable(drawable)
	cmd->commit()
}

renderer_destroy :: proc(r: ^Renderer) {
	if r.bloom_b != nil do r.bloom_b->release()
	if r.bloom_a != nil do r.bloom_a->release()
	if r.scene_tex != nil do r.scene_tex->release()
	if r.depth_texture != nil do r.depth_texture->release()
	if r.ui_buffer != nil do r.ui_buffer->release()
	if r.grid_buffer != nil do r.grid_buffer->release()
	if r.uniform_buffer != nil do r.uniform_buffer->release()
	if r.instance_buffer != nil do r.instance_buffer->release()
	if r.vertex_buffer != nil do r.vertex_buffer->release()
	if r.overlay_depth_state != nil do r.overlay_depth_state->release()
	if r.depth_state != nil do r.depth_state->release()
	if r.composite_pso != nil do r.composite_pso->release()
	if r.blur_v_pso != nil do r.blur_v_pso->release()
	if r.blur_h_pso != nil do r.blur_h_pso->release()
	if r.bright_pso != nil do r.bright_pso->release()
	if r.bg_pso != nil do r.bg_pso->release()
	if r.ui_pso != nil do r.ui_pso->release()
	if r.line_pso != nil do r.line_pso->release()
	if r.pso != nil do r.pso->release()
	if r.queue != nil do r.queue->release()
	if r.device != nil do r.device->release()
	r^ = {}
}
