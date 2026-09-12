// Outline/RenderObjects.shadergraph → Godot spatial (Draw-Objects hull).
// Unity: _Thickness 0.02, _BaseColor black, Render Face = Back (cull front).
// Separate MeshInstance3D (not next_pass — mystic ExtraPrePass owns that).
// Unity Render Face = Back: draw inflated backfaces so only the rim shows past the color mesh.
// Opaque — do not write ALPHA.
shader_type spatial;
render_mode unshaded, cull_front, depth_draw_opaque, shadows_disabled, specular_disabled, ambient_light_disabled;

uniform float thickness = 0.02; // _Thickness
uniform vec4 base_color : source_color = vec4(0.0, 0.0, 0.0, 1.0); // _BaseColor

void vertex() {
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 world_n = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	world_pos += world_n * thickness;
	VERTEX = (inverse(MODEL_MATRIX) * vec4(world_pos, 1.0)).xyz;
}

void fragment() {
	ALBEDO = base_color.rgb;
}
