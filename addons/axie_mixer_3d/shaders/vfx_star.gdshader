shader_type spatial;
// Port of Unity `AxieMixer3D/Star` — the mystic addon sparkle particle material. A procedural
// four-point star built from the quad UVs; the fill threshold comes from the Custom1.z vertex
// stream (a curve over lifetime, so the star shrinks as the particle ages). Unlit, alpha-blended
// with alpha clip 0.5, ZWrite On, Cull Off.
render_mode unshaded, cull_disabled, blend_mix, depth_draw_always, depth_test_default,
	shadows_disabled, fog_disabled, specular_disabled, ambient_light_disabled;

#include "vfx_particle_common.gdshaderinc"

uniform vec4 color0 = vec4(1.0, 0.0, 0.0, 1.0);     // _Color0 (HDR, raw) — edge tint × particle colour
uniform vec4 color1 = vec4(1.0);                    // _Color1 (HDR, raw) — inner fill
uniform float edge_width = 1.2;                     // _EdgeWidth
uniform vec4 vector0 = vec4(1.0, 1.0, 0.0, 0.0);    // _Vector0: screen-space tiling.xy / pan.zw of the fill texture
uniform sampler2D texture_sample0 : filter_linear, repeat_enable, hint_default_white;   // _TextureSample0


void vertex() {
	vfx_vertex(VERTEX, UV, MODEL_MATRIX, INV_VIEW_MATRIX, VIEW_MATRIX, INSTANCE_CUSTOM, INSTANCE_ID, MODELVIEW_MATRIX);
}


float color_dodge(float src, float dst) {
	return clamp(dst / max(1.0 - src, 0.00001), 0.0, 1.0);
}


void fragment() {
	// The star function is symmetric under v -> 1 - v, so Godot's V-down UV can be used directly.
	vec2 uv = UV;
	float a = clamp(abs(uv.x - uv.y), 0.0, 1.0);
	float b = clamp(abs(uv.x - (1.0 - uv.y)), 0.0, 1.0);
	float m = color_dodge(a, b) * color_dodge(b, a);
	float thr = (1.0 - 0.9) * v_custom1.z;
	float inner = step(m, thr);
	float edge = step(pow(m, edge_width), thr) - inner;
	vec2 ss = SCREEN_UV * vector0.xy + TIME * vector0.zw;
	vec4 fill = texture(texture_sample0, ss);
	vec4 o = fill * inner * color1 + edge * (color0 * v_color);
	// Keep the authored HDR edge intensity available to viewport glow.
	ALBEDO = min(vfx_srgb_to_linear(max(o.rgb, vec3(0.0))), vec3(65504.0));
	ALPHA = clamp(o.r, 0.0, 1.0);
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
