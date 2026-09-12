// Shared by the mystic VFX particle shaders (vfx_dissolve / vfx_star).
//
// Unity ParticleSystem semantics reproduced on a GPUParticles3D quad:
//   * Billboard (view-aligned, keeps hierarchy scale) with the per-particle start rotation
//     (INSTANCE_CUSTOM.x) plus rotation-over-lifetime.
//   * Emission cadence: Godot spawns `amount` particles evenly over its `lifetime`, which we set to
//     the Unity system *duration* (`cycle_seconds`). Each particle then only lives its Unity
//     lifetime (`life_min..life_max`, random per particle) inside that cycle: `age` is the Unity
//     normalised age and the quad collapses once it exceeds 1.
//   * Size over lifetime / colour over lifetime / Custom1 vertex stream curves are sampled by `age`.
//   * Texture-sheet animation in Sprites mode: `sprite_rect` remaps UV0 to the sprite's atlas rect
//     (Godot UV space, V down).
// AxieMysticGlow fills these uniforms from the pack's addons/*.json dump.

uniform vec4 sprite_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec4 start_color = vec4(1.0);                      // Unity start colour (raw gamma-space values)
uniform float cycle_seconds = 1.0;                         // = GPUParticles3D.lifetime = Unity duration
uniform float life_min = 1.0;                              // Unity start lifetime range
uniform float life_max = 1.0;
uniform float rot_speed = 0.0;                             // rotation over lifetime, rad/s (Unity Z)
uniform bool use_size_curve = false;
uniform sampler2D size_curve : hint_default_white;         // size over lifetime, sampled by age
uniform bool use_color_ramp = false;
uniform sampler2D color_ramp : hint_default_white;         // colour over lifetime, sampled by age
uniform vec4 custom1_const = vec4(0.0);                    // Custom1 constants (x, y, z, w)
uniform bool custom1_z_is_curve = false;
uniform sampler2D custom1_curve_z : hint_default_black;
uniform bool custom1_w_is_curve = false;
uniform sampler2D custom1_curve_w : hint_default_black;

varying vec2 v_uv0;
varying vec4 v_custom1;
varying vec4 v_color;
varying float v_age;


vec3 vfx_srgb_to_linear(vec3 c) {
	return mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), lessThan(c, vec3(0.04045)));
}


float vfx_hash(int id) {
	return fract(sin(float(id) * 12.9898 + 78.233) * 43758.5453);
}


// Unity normalised age of this particle inside the Godot cycle (>1 once it should be dead).
float vfx_age(vec4 inst_custom, int id, out float life) {
	life = mix(life_min, life_max, vfx_hash(id));
	return inst_custom.y * cycle_seconds / max(life, 1e-4);
}


vec4 vfx_custom1(float age) {
	vec4 c = custom1_const;
	float a = clamp(age, 0.0, 1.0);
	if (custom1_z_is_curve) {
		c.z = texture(custom1_curve_z, vec2(a, 0.5)).r;
	}
	if (custom1_w_is_curve) {
		c.w = texture(custom1_curve_w, vec2(a, 0.5)).r;
	}
	return c;
}


vec4 vfx_color(float age) {
	vec4 c = start_color;
	if (use_color_ramp) {
		c *= texture(color_ramp, vec2(clamp(age, 0.0, 1.0), 0.5));
	}
	return c;
}


float vfx_size(float age) {
	if (age > 1.0) {
		return 0.0;
	}
	return use_size_curve ? texture(size_curve, vec2(clamp(age, 0.0, 1.0), 0.5)).r : 1.0;
}


// View-aligned billboard keeping the model's (hierarchy) scale, rotated by `angle` about the view axis.
mat4 vfx_billboard(mat4 model, mat4 inv_view, mat4 view, float angle, float size) {
	mat4 world = mat4(normalize(inv_view[0]), normalize(inv_view[1]), normalize(inv_view[2]), model[3]);
	float c = cos(angle);
	float s = sin(angle);
	world = world * mat4(vec4(c, -s, 0.0, 0.0), vec4(s, c, 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	mat4 mv = view * world;
	vec3 sc = vec3(length(model[0].xyz), length(model[1].xyz), length(model[2].xyz)) * size;
	return mv * mat4(vec4(sc.x, 0.0, 0.0, 0.0), vec4(0.0, sc.y, 0.0, 0.0), vec4(0.0, 0.0, sc.z, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
}


// Shared vertex body. Godot forbids writing varyings/built-ins from a function, so this is a macro.
#define vfx_vertex(VERT, UVIN, MODEL, INV_VIEW, VIEW, INST_CUSTOM, INST_ID, MV_OUT) \
	{ \
		float life_; \
		float age_ = vfx_age(INST_CUSTOM, INST_ID, life_); \
		v_age = age_; \
		v_custom1 = vfx_custom1(age_); \
		v_color = vfx_color(age_); \
		v_uv0 = sprite_rect.xy + UVIN * sprite_rect.zw; \
		float angle_ = INST_CUSTOM.x + rot_speed * clamp(age_, 0.0, 1.0) * life_; \
		MV_OUT = vfx_billboard(MODEL, INV_VIEW, VIEW, angle_, vfx_size(age_)); \
	}
