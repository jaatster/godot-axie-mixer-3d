@tool
extends CompositorEffect
class_name AxieOutlinePostProcess
## URP OutlinePostProcessRendererFeature analogue.
## Unity: _Color, _Thickness, _DepthScale (50), _DepthBias (50), _NormalScale (0.7), _NormalBias (10).
## Add this resource to a Camera3D / WorldEnvironment Compositor.
## Fullscreen quad alternative: shaders/outline_postprocess.gdshader (not a 2D ColorRect —
## canvas_item cannot sample the 3D depth/normal buffers).

const _COMPUTE := """
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 1, binding = 0) uniform sampler2D depth_tex;
layout(set = 2, binding = 0) uniform sampler2D normal_tex;

layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	float thickness;
	float depth_scale;
	float depth_bias;
	float normal_scale;
	float normal_bias;
	float is_ortho;
	vec4 outline_color;
	vec4 extra; // x = z_far
	mat4 inv_projection;
} params;

vec4 normal_roughness_compatibility(vec4 p_normal_roughness) {
	float roughness = p_normal_roughness.w;
	if (roughness > 0.5) {
		roughness = 1.0 - roughness;
	}
	roughness /= (127.0 / 255.0);
	return vec4(normalize(p_normal_roughness.xyz * 2.0 - 1.0) * 0.5 + 0.5, roughness);
}

float linear01_depth(float z, vec2 uv) {
	if (params.is_ortho > 0.5) {
		return 1.0 - z;
	}
	vec4 ndc = vec4(uv * 2.0 - 1.0, z, 1.0);
	vec4 view = params.inv_projection * ndc;
	float eye = abs(view.z / max(view.w, 1e-8));
	return clamp(eye / max(params.extra.x, 1e-8), 0.0, 1.0);
}

float sample_linear_depth(vec2 uv) {
	return linear01_depth(textureLod(depth_tex, uv, 0.0).r, uv);
}

vec3 sample_normal(vec2 uv) {
	vec3 n01 = normal_roughness_compatibility(textureLod(normal_tex, uv, 0.0)).xyz;
	return normalize(n01 * 2.0 - 1.0);
}

float sobel_depth(vec2 uv, vec2 off) {
	float dc = sample_linear_depth(uv);
	vec4 d = vec4(
		sample_linear_depth(uv + vec2(off.x, 0.0)),
		sample_linear_depth(uv - vec2(off.x, 0.0)),
		sample_linear_depth(uv + vec2(0.0, off.y)),
		sample_linear_depth(uv - vec2(0.0, off.y))
	);
	return pow(length(d - dc) * params.depth_scale, params.depth_bias);
}

float sobel_normal(vec2 uv, vec2 off) {
	vec3 nc = sample_normal(uv);
	vec3 nt = sample_normal(uv + vec2(off.x, 0.0)) - nc;
	vec3 nb = sample_normal(uv - vec2(off.x, 0.0)) - nc;
	vec3 nr = sample_normal(uv + vec2(0.0, off.y)) - nc;
	vec3 nl = sample_normal(uv - vec2(0.0, off.y)) - nc;
	float n = sqrt(dot(nt, nt) + dot(nb, nb) + dot(nr, nr) + dot(nl, nl));
	return pow(n * params.normal_scale, params.normal_bias);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}
	vec2 uv = (vec2(pixel) + 0.5) / params.raster_size;
	vec2 off = vec2(params.thickness) / params.raster_size;
	float alpha = clamp(max(sobel_depth(uv, off), sobel_normal(uv, off)), 0.0, 1.0);
	vec4 color = imageLoad(color_image, pixel);
	color.rgb = mix(color.rgb, params.outline_color.rgb, alpha * params.outline_color.a);
	imageStore(color_image, pixel, color);
}
"""

@export var outline_color: Color = Color(0, 0, 0, 1)
@export_range(1, 10, 1) var thickness: int = 2
@export var depth_scale: float = 50.0
@export var depth_bias: float = 50.0
@export var normal_scale: float = 0.7
@export var normal_bias: float = 10.0

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var sampler_rid: RID
var dummy_normal: RID
var _shader_ok: bool = false
var _tried_init: bool = false


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	needs_normal_roughness = true
	rd = RenderingServer.get_rendering_device()


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	# RenderingServer.free_rid is thread-safe; do not call methods on a dying instance.
	if rd == null:
		return
	if shader.is_valid():
		rd.free_rid(shader)
	shader = RID()
	pipeline = RID()
	if sampler_rid.is_valid():
		rd.free_rid(sampler_rid)
	sampler_rid = RID()
	if dummy_normal.is_valid():
		rd.free_rid(dummy_normal)
	dummy_normal = RID()
	_shader_ok = false


func _init_compute() -> void:
	if _tried_init:
		return
	_tried_init = true
	if rd == null:
		rd = RenderingServer.get_rendering_device()
	if rd == null:
		return
	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = _COMPUTE
	var spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		push_error("AxieOutlinePostProcess: " + spirv.compile_error_compute)
		_shader_ok = false
		return
	shader = rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		_shader_ok = false
		return
	pipeline = rd.compute_pipeline_create(shader)
	var st := RDSamplerState.new()
	st.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	st.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	st.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	st.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	st.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	st.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_rid = rd.sampler_create(st)
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	fmt.width = 1
	fmt.height = 1
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	dummy_normal = rd.texture_create(fmt, RDTextureView.new(), [PackedByteArray([128, 128, 255, 127])])
	_shader_ok = pipeline.is_valid()


func _projection_floats(p: Projection) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(16)
	for i in 4:
		var col: Vector4 = p[i]
		a[i * 4 + 0] = col.x
		a[i * 4 + 1] = col.y
		a[i * 4 + 2] = col.z
		a[i * 4 + 3] = col.w
	return a


func _render_callback(p_effect_callback_type: int, p_render_data: RenderData) -> void:
	if rd == null:
		rd = RenderingServer.get_rendering_device()
	if not _shader_ok:
		_init_compute()
	if not _shader_ok or rd == null:
		return
	if p_effect_callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		return
	var buffers: RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()
	if buffers == null:
		return
	var size: Vector2i = buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return
	var scene: RenderSceneData = p_render_data.get_render_scene_data()
	var proj := Projection()
	var z_far := 4000.0
	var is_ortho := 0.0
	if scene:
		proj = scene.get_cam_projection()
		z_far = maxf(proj.get_z_far(), 0.001)
		is_ortho = 1.0 if proj.is_orthogonal() else 0.0
	var inv_proj := proj.inverse()

	var push := PackedFloat32Array()
	push.resize(32)
	push[0] = float(size.x)
	push[1] = float(size.y)
	push[2] = float(thickness)
	push[3] = depth_scale
	push[4] = depth_bias
	push[5] = normal_scale
	push[6] = normal_bias
	push[7] = is_ortho
	push[8] = outline_color.r
	push[9] = outline_color.g
	push[10] = outline_color.b
	push[11] = outline_color.a
	push[12] = z_far
	push[13] = 0.0
	push[14] = 0.0
	push[15] = 0.0
	var inv_f := _projection_floats(inv_proj)
	for i in 16:
		push[16 + i] = inv_f[i]

	var x_groups := (size.x - 1) / 8 + 1
	var y_groups := (size.y - 1) / 8 + 1
	var view_count := buffers.get_view_count()
	for view in view_count:
		var color_tex: RID = buffers.get_color_layer(view)
		var depth_tex: RID = buffers.get_depth_layer(view)
		var normal_tex := dummy_normal
		if buffers.has_texture("forward_clustered", "normal_roughness"):
			normal_tex = buffers.get_texture_slice("forward_clustered", "normal_roughness", view, 0, 1, 1)
		if not color_tex.is_valid() or not depth_tex.is_valid():
			continue

		var u_color := RDUniform.new()
		u_color.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u_color.binding = 0
		u_color.add_id(color_tex)

		var u_depth := RDUniform.new()
		u_depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u_depth.binding = 0
		u_depth.add_id(sampler_rid)
		u_depth.add_id(depth_tex)

		var u_normal := RDUniform.new()
		u_normal.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u_normal.binding = 0
		u_normal.add_id(sampler_rid)
		u_normal.add_id(normal_tex)

		var set0: RID = UniformSetCacheRD.get_cache(shader, 0, [u_color])
		var set1: RID = UniformSetCacheRD.get_cache(shader, 1, [u_depth])
		var set2: RID = UniformSetCacheRD.get_cache(shader, 2, [u_normal])

		var compute_list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
		rd.compute_list_bind_uniform_set(compute_list, set0, 0)
		rd.compute_list_bind_uniform_set(compute_list, set1, 1)
		rd.compute_list_bind_uniform_set(compute_list, set2, 2)
		rd.compute_list_set_push_constant(compute_list, push.to_byte_array(), push.size() * 4)
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
		rd.compute_list_end()


static func attach_to_camera(camera: Camera3D, effect: CompositorEffect = null) -> CompositorEffect:
	if camera == null:
		return null
	if effect == null:
		effect = (load("res://addons/axie_mixer_3d/outline/outline_post_process.gd") as GDScript).new()
	var compositor: Compositor = camera.compositor
	if compositor == null:
		compositor = Compositor.new()
		camera.compositor = compositor
	var effects: Array = compositor.compositor_effects.duplicate()
	for existing in effects:
		if existing.get_script() == (effect as Object).get_script():
			return existing
	effects.append(effect)
	compositor.compositor_effects = effects
	return effect
