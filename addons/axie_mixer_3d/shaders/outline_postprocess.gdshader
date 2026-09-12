// Outline/PostProcess.shader (URP fullscreen Sobel) → Godot spatial fullscreen.
// Unity: _Color, _Thickness (pixels, 1–10), _DepthScale 50, _DepthBias 50,
//        _NormalScale 0.7, _NormalBias 10. Blend SrcAlpha OneMinusSrcAlpha.
// Assign this material to a camera-facing QuadMesh (size 2) as a ColorRect-style overlay,
// or use outline/outline_post_process.gd CompositorEffect (the URP Renderer Feature analogue).
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled, blend_mix, shadows_disabled, specular_disabled, ambient_light_disabled;

uniform vec4 outline_color : source_color = vec4(0.0, 0.0, 0.0, 1.0); // _Color
uniform float thickness = 2.0; // _Thickness (pixels)
uniform float depth_scale = 50.0; // _DepthScale
uniform float depth_bias = 50.0; // _DepthBias
uniform float normal_scale = 0.7; // _NormalScale
uniform float normal_bias = 10.0; // _NormalBias
uniform float z_far = 4000.0;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D normal_tex : hint_normal_roughness_texture, filter_nearest, repeat_disable;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

// Godot stores view-space normals in the roughness-packed buffer the same way the
// CompositorEffect path does (see outline/outline_post_process.gd).
vec4 _normal_roughness_compatibility(vec4 p_normal_roughness) {
	float roughness = p_normal_roughness.w;
	if (roughness > 0.5) {
		roughness = 1.0 - roughness;
	}
	roughness /= (127.0 / 255.0);
	return vec4(normalize(p_normal_roughness.xyz * 2.0 - 1.0) * 0.5 + 0.5, roughness);
}

float _linear01_depth(float z, vec2 uv, mat4 inv_proj, bool is_ortho, float far_plane) {
	if (is_ortho) {
		return 1.0 - z;
	}
	vec3 ndc = vec3(uv * 2.0 - 1.0, z);
	vec4 view = inv_proj * vec4(ndc, 1.0);
	float eye = abs(view.z / max(view.w, 1e-8));
	return clamp(eye / max(far_plane, 1e-8), 0.0, 1.0);
}

vec3 _sample_normal(vec2 uv) {
	vec3 n01 = _normal_roughness_compatibility(texture(normal_tex, uv)).xyz;
	return normalize(n01 * 2.0 - 1.0);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 off = vec2(thickness) / VIEWPORT_SIZE;
	mat4 inv_proj = INV_PROJECTION_MATRIX;
	bool is_ortho = PROJECTION_MATRIX[3][3] > 0.5;
	float far_plane = z_far;

	float dc = _linear01_depth(texture(depth_tex, uv).r, uv, inv_proj, is_ortho, far_plane);
	vec4 d = vec4(
		_linear01_depth(texture(depth_tex, uv + vec2(off.x, 0.0)).r, uv + vec2(off.x, 0.0), inv_proj, is_ortho, far_plane),
		_linear01_depth(texture(depth_tex, uv - vec2(off.x, 0.0)).r, uv - vec2(off.x, 0.0), inv_proj, is_ortho, far_plane),
		_linear01_depth(texture(depth_tex, uv + vec2(0.0, off.y)).r, uv + vec2(0.0, off.y), inv_proj, is_ortho, far_plane),
		_linear01_depth(texture(depth_tex, uv - vec2(0.0, off.y)).r, uv - vec2(0.0, off.y), inv_proj, is_ortho, far_plane)
	);
	float sobel_depth = pow(length(d - dc) * depth_scale, depth_bias);

	vec3 nc = _sample_normal(uv);
	vec3 nt = _sample_normal(uv + vec2(off.x, 0.0)) - nc;
	vec3 nb = _sample_normal(uv - vec2(off.x, 0.0)) - nc;
	vec3 nr = _sample_normal(uv + vec2(0.0, off.y)) - nc;
	vec3 nl = _sample_normal(uv - vec2(0.0, off.y)) - nc;
	float n = sqrt(dot(nt, nt) + dot(nb, nb) + dot(nr, nr) + dot(nl, nl));
	float sobel_normal = pow(n * normal_scale, normal_bias);

	float sobel_alpha = clamp(max(sobel_depth, sobel_normal), 0.0, 1.0);
	ALBEDO = outline_color.rgb;
	ALPHA = sobel_alpha * outline_color.a;
}
