// Mystic_Final ExtraPrePass: positionOS += _outline * normalOS, Cull Front, Color = _outlinecolor.rgb.
// Attached as next_pass (after the fill). Unity draws this BEFORE the Forward pass; inverted-hull
// back faces still produce the silhouette after the fill because interior fragments fail the
// depth test against the already-drawn mesh.
//
// V5 is pixel-verified with cull_back, so exporter winding matches Unity. Unity Cull Front
// therefore maps to Godot cull_front (draw back faces). The previous cull_back + next_pass
// drew inflated front faces on top of the fill and painted the whole part black.
shader_type spatial;
render_mode cull_front, depth_draw_opaque, specular_disabled, ambient_light_disabled, shadows_disabled, fog_disabled;

uniform float outline = 0.02; // _outline
uniform vec4 outline_color = vec4(0.0, 0.0, 0.0, 1.0); // _outlinecolor (raw / HDR, no source_color)

vec3 srgb_to_linear(vec3 c) {
	return mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), lessThan(c, vec3(0.04045)));
}

void vertex() {
	VERTEX += NORMAL * outline;
}

void fragment() {
	// LDR oracle clips HDR outline colours the same way the Forward pass does.
	vec3 working = clamp(outline_color.rgb, 0.0, 1.0);
	ALBEDO = vec3(0.0);
	EMISSION = srgb_to_linear(working);
}
