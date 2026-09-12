// Port of S_Axie_Mixer_V5.shadergraph (URP Unlit target, Opaque, AlphaClip 0.5, Render Face Front).
// Unity properties: _MainTex, _PrimaryColor, _SecondaryColor.
//
// Graph:  A = MainTex.a
//         tint      = lerp(Secondary, Primary, step(0.7, A))
//         colorized = lerp(RGB, RGB * tint, step(A, 0.975))      -- Blend(Multiply), opacity = A <= 0.975
//         shaded    = lerp(colorized, colorized * 0.75, step(dot(mainLight.dir, worldNormal), -0.25))
//         clip(A - 0.5)
//
// The reference Unity project (axieinfinity/unity-axie-mixer3d) runs in Gamma color space, so the
// multiplies happen on sRGB-encoded values; we reproduce that and only convert to linear at the end.
// Set `unity_linear_color_space = true` to mimic a Linear-space Unity project instead.
//
// The main light comes from the scene's DirectionalLight3D through light(): its direction is the
// only thing the graph uses (GetMainLight() without shadow coords), colour/energy/shadows are ignored.
shader_type spatial;
render_mode cull_back, depth_draw_opaque, specular_disabled, ambient_light_disabled, shadows_disabled, fog_disabled;

uniform sampler2D main_tex : filter_linear_mipmap, repeat_enable, hint_default_white; // _MainTex (raw sRGB bytes)
uniform vec4 primary_color : source_color = vec4(1.0, 1.0, 1.0, 1.0); // _PrimaryColor
uniform vec4 secondary_color : source_color = vec4(1.0, 1.0, 1.0, 1.0); // _SecondaryColor
uniform bool unity_linear_color_space = false;

// Graph constants.
const float PRIMARY_ALPHA_EDGE = 0.7;
const float COLORIZE_ALPHA_EDGE = 0.975;
const float ALPHA_CLIP_THRESHOLD = 0.5;
const vec3 SHADOW_COLOR = vec3(0.75);
const float SHADOW_N_DOT_L = -0.25;

vec3 srgb_to_linear(vec3 c) {
	return mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), lessThan(c, vec3(0.04045)));
}

vec3 linear_to_srgb(vec3 c) {
	return mix(1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, c * 12.92, lessThan(c, vec3(0.0031308)));
}

// Colour math in the reference project's working space; returns the value the Unity graph would
// hand to the (sRGB) frame buffer.
vec3 unity_working_color(vec4 tex) {
	// source_color uniforms arrive linear; the texture is sampled raw (sRGB-encoded bytes).
	vec3 rgb = tex.rgb;
	vec3 prim = primary_color.rgb;
	vec3 sec = secondary_color.rgb;
	if (unity_linear_color_space) {
		rgb = srgb_to_linear(rgb);
	} else {
		prim = linear_to_srgb(prim);
		sec = linear_to_srgb(sec);
	}
	vec3 tint = mix(sec, prim, step(PRIMARY_ALPHA_EDGE, tex.a));
	return mix(rgb, rgb * tint, step(tex.a, COLORIZE_ALPHA_EDGE));
}

vec3 to_linear(vec3 working) {
	return unity_linear_color_space ? working : srgb_to_linear(working);
}

void fragment() {
	vec4 tex = texture(main_tex, UV);
	// Opaque + AlphaClip: A is a mask, not coverage.
	if (tex.a < ALPHA_CLIP_THRESHOLD) {
		discard;
	}
	vec3 working = unity_working_color(tex);
	// Unlit: the whole unshaded result is emission; light() subtracts the shadow band.
	ALBEDO = working;
	EMISSION = to_linear(working);
}

void light() {
	if (LIGHT_IS_DIRECTIONAL) {
		// NORMAL and LIGHT are both view-space here; the dot product is what the graph computes in world space.
		float in_shadow = step(dot(normalize(NORMAL), normalize(LIGHT)), SHADOW_N_DOT_L);
		vec3 shaded = ALBEDO * mix(vec3(1.0), SHADOW_COLOR, in_shadow);
		DIFFUSE_LIGHT = to_linear(shaded) - to_linear(ALBEDO);
	}
}
