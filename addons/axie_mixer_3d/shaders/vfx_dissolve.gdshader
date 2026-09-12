shader_type spatial;
// Port of Unity `AxieMixer3D/ProjectT_VFX/disslove_mobile` (+ `_stencil` variant) — the mystic
// addon "Glow" particle material. Unlit, alpha-blended (SrcAlpha/OneMinusSrcAlpha), ZWrite Off,
// Cull Off. Drawn on GPUParticles3D quads; the billboard, texture-sheet sprite rect, Unity lifetime
// (emission cadence), size-over-lifetime and Custom1 vertex stream are all reproduced here because
// Godot's process material cannot express a Unity duration/lifetime split or custom data curves.
//
// Colour math is gamma-space (the Unity project is Gamma): textures are sampled raw, colours arrive
// as raw vec4s, and the clamped result is linearised at the end (same convention as the V5 shader).
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, depth_test_default,
	shadows_disabled, fog_disabled, specular_disabled, ambient_light_disabled;

#include "vfx_particle_common.gdshaderinc"

uniform sampler2D main_tex : filter_linear, repeat_enable, hint_default_white;       // _MainTex (or the TSA sprite)
uniform sampler2D dissolve_tex : filter_linear, repeat_enable, hint_default_white;   // _DissolveTex
uniform sampler2D mask_alpha : filter_linear, repeat_enable, hint_default_white;     // _Mask_alpha
uniform vec4 base_color = vec4(0.6509434, 0.6509434, 0.6509434, 1.0);                // _BaseColor (HDR, raw)
uniform vec4 maintex_uv = vec4(1.0, 1.0, 0.0, 0.0);                                  // _maintexUV (xy tiling-1, zw pan)
uniform vec4 dissolve_uv = vec4(1.0, 1.0, 0.0, 0.0);                                 // _DissolveUV
uniform bool alpha_main_tex = false;                                                 // _ALPHAMAINTEX_ON (stencil variant)


void vertex() {
	vfx_vertex(VERTEX, UV, MODEL_MATRIX, INV_VIEW_MATRIX, VIEW_MATRIX, INSTANCE_CUSTOM, INSTANCE_ID, MODELVIEW_MATRIX);
}


void fragment() {
	vec2 uv = v_uv0;              // texture-sheet UV0.xy
	vec2 uv0zw = v_custom1.xy;    // Custom1.xy lands in TEXCOORD0.zw
	// Godot V runs down, Unity's up: negate V panning so time-scrolls move the same way on screen.
	vec2 pan_main = TIME * vec2(maintex_uv.z, -maintex_uv.w) + uv * (maintex_uv.xy - vec2(1.0));
	vec4 t = texture(main_tex, uv + uv0zw + pan_main);
	float lo = clamp(0.5 * v_custom1.w, 0.0, 0.5);
	float hi = 1.0 - lo;
	vec2 pan_d = TIME * vec2(dissolve_uv.z, -dissolve_uv.w) + uv * dissolve_uv.xy;
	vec4 d = texture(dissolve_tex, pan_d);
	float v = (d.r * d.a - 0.1) + (1.0 - v_custom1.z * 2.0);
	float s = smoothstep(lo, hi, v);
	// ( smoothstep(v + 0) - smoothstep(v) ) is identically zero in the source graph.
	vec3 col = (t * base_color * v_color).rgb;
	float mask = texture(mask_alpha, uv).r;
	float static_switch = alpha_main_tex ? t.r * t.a : 1.0;
	float alpha = mask * (t.a * v_color.a * s) * static_switch;
	ALBEDO = vfx_srgb_to_linear(clamp(col, vec3(0.0), vec3(1.0)));
	ALPHA = clamp(alpha, 0.0, 1.0);
}
