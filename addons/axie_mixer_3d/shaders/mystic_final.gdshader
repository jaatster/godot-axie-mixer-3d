// Port of AxieMixer3D/Mystic_Final.shader (Amplify URP Unlit, Opaque + clip 0.5).
// ExtraPrePass (object-space inflate, Cull Front, _outlinecolor) is mystic_outline.gdshader
// attached as Material.next_pass — see _build_mystic.
//
// Color space (same convention as s_axie_mixer_v5.gdshader):
//   Unity project is Gamma, so the HLSL does all math on sRGB-encoded values and writes them
//   straight to an LDR sRGB target (allowHDR=false on the oracle camera).
//   - Textures: NO source_color → raw sRGB bytes (the texels Unity samples).
//   - primary/secondary: source_color (Godot linearises Color params) → linear_to_srgb() here.
//   - HDR / raw colors (_RimColor, _Color0, _Top, _Mid, _Color3, _Color_UV2, _Color1): no hint,
//     uploaded as Unity authored floats.
//   - Final RGB is clamped to 0..1 (LDR) then srgb_to_linear() into EMISSION.
//
// Matcap: (mul(UNITY_MATRIX_V, float4(worldN, 0)).xyz * 0.5 + 0.5).xy — no extra normalize.
// Fragment NORMAL is view-space (post-skin); .xy remap matches the HLSL (Z-handedness unused).
// UV / UV2: exporter already flipped V; do not flip again. Unity TEXCOORD1 = Godot UV2 (has_uv2).
// Top/Mid height: Unity uses positionOS.y = the skinned position in the SkinnedMeshRenderer's
// root-bone space (unity_ObjectToWorld is rootBone.localToWorld without scale; parts sit in their
// `*_Offsets` joint frame, merged renderers in the body root bone). Godot only has the world
// position here, so AxieMysticRootTracker feeds row Y of inverse(root-bone world) as root_inv_y.
// _Time.y = Godot TIME (see mystic_time below for the oracle's t = 0 pin).
shader_type spatial;
render_mode cull_back, depth_draw_opaque, specular_disabled, ambient_light_disabled, shadows_disabled, fog_disabled;

uniform vec4 primary_color : source_color = vec4(1.0); // _PrimaryColor
uniform vec4 secondary_color : source_color = vec4(1.0); // _SecondaryColor

uniform sampler2D main_tex : filter_linear_mipmap, repeat_enable, hint_default_white; // _Main_tex
uniform sampler2D matcap : filter_linear_mipmap, repeat_disable, hint_default_white; // _Matcap (Unity wrap Clamp)
uniform sampler2D matcap_uv2 : filter_linear_mipmap, repeat_disable, hint_default_white; // _Matcap_UV2
uniform sampler2D uv2_texture : filter_linear_mipmap, repeat_enable, hint_default_white; // _UV2_texture
uniform sampler2D mask_map : filter_linear_mipmap, repeat_enable, hint_default_white; // _Mask_MAP
uniform sampler2D maskmap_color_body1 : filter_linear_mipmap, repeat_enable, hint_default_white; // _maskmapcolorbody1
uniform sampler2D noise_map_view_dir : filter_linear_mipmap, repeat_enable, hint_default_white; // _NoiseMap_ViewDir
uniform sampler2D noise_map_2nd : filter_linear_mipmap, repeat_enable, hint_default_white; // _NoiseMap_2nd
uniform sampler2D noise_3 : filter_linear_mipmap, repeat_enable, hint_default_white; // _Noise_3
// _Time.y. Default < 0 → Godot TIME (in-game scroll, like Unity play mode). The Unity render
// oracle zeroes every panner speed (AxieGltfExporter.FreezeShaderTime), which equals t = 0;
// tests/render_compare.gd sets mystic_time = 0 on every mystic material to match.
uniform float mystic_time = -1.0;
// Row Y of inverse(root-bone world transform): positionOS.y = dot(root_inv_y, vec4(world_pos, 1)).
// Default = world Y; AxieMysticRootTracker updates it per frame.
uniform vec4 root_inv_y = vec4(0.0, 1.0, 0.0, 0.0);

uniform float matcap_intensity = 1.2; // _matcap
uniform float matcap_uv2_intensity = 1.2; // _matcap_UV2
uniform vec4 color_uv2 = vec4(1.0, 0.6320756, 0.0, 1.0); // [HDR] _Color_UV2
uniform vec2 uv2_speed = vec2(0.05, 0.0); // _UV2_speed
uniform float uv2_threshold_alpha : hint_range(0.0, 1.0) = 0.6970711; // _UV2_thresholdalpha
uniform float alpha_uv1 : hint_range(0.0, 1.0) = 0.6353748; // _Alpha_UV1
uniform bool has_uv2 = false; // factory: ARRAY_TEX_UV2 == Unity GetUVs(1)

uniform vec4 rim_color = vec4(0.0, 0.5549643, 1.0, 0.0); // [HDR] _RimColor
uniform float rim_offset = 0.24; // _RimOffset
uniform vec2 rim_falloff = vec2(0.0, 0.0); // _RimFalloff
uniform float rim_shadow : hint_range(0.0, 1.0) = 0.0; // _RimShadow

uniform vec4 color0 = vec4(1.0, 0.5759467, 0.0, 0.0); // [HDR] _Color0
uniform vec4 color1 = vec4(0.754717, 0.0, 0.0, 1.0); // _Color1 (gamma, uploaded raw)
uniform vec4 color3 = vec4(1.0, 1.0, 1.0, 0.0); // [HDR] _Color3
uniform vec4 top_color = vec4(1.0); // [HDR] _Top
uniform vec4 mid_color = vec4(0.3238292, 0.6415094, 0.2824255, 1.0); // [HDR] _Mid
uniform vec2 top_mid_step = vec2(-0.04, 1.0); // _TopMid_Step
uniform float top_mid_offset = 0.22; // _TopMid_Offset
uniform bool color_switch = true; // _Color_switch — Beast S01 mats set 0
uniform float color_time = 0.5; // _Color_Time
uniform float emiss = 1.0; // _Emiss
uniform float scale_noisemap = 1.0; // _Scale_Noisemap
uniform vec4 noise_map_view_dir_st = vec4(1.0, 1.0, 0.0, 0.0); // _NoiseMap_ViewDIr (xy scale, zw speed)
uniform vec4 noise_map_2 = vec4(1.0, 1.0, 0.0, 0.0); // _NoiseMap_2
uniform vec4 noise3_uv_speed = vec4(0.0); // _Noise3_UVSPEED
uniform float outline = 0.02; // _outline (consumed by next_pass)
uniform vec4 outline_color = vec4(0.0); // _outlinecolor (consumed by next_pass)

vec3 srgb_to_linear(vec3 c) {
	return mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), lessThan(c, vec3(0.04045)));
}

vec3 linear_to_srgb(vec3 c) {
	return mix(1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, c * 12.92, lessThan(c, vec3(0.0031308)));
}

// HLSL smoothstep: saturate((x-e0)/(e1-e0)) then hermite. GLSL smoothstep is undefined for e1<=e0
// (Beast S01 _TopMid_Step is (0.6, 0) / (2, 0)).
float smoothstep_unity(float e0, float e1, float x) {
	float denom = e1 - e0;
	float t = abs(denom) < 1e-8 ? step(e0, x) : clamp((x - e0) / denom, 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

// ASE NewGradient (type 0 / blend) in UNITY_COLORSPACE_GAMMA — keys stay authored, no SRGBToLinear.
vec3 sample_gradient(float t) {
	vec3 c0 = vec3(1.0, 0.1970911, 0.0);
	vec3 c1 = vec3(1.0, 0.8276376, 0.0);
	vec3 c2 = vec3(0.4292929, 1.0, 0.0);
	vec3 c3 = vec3(0.3527098, 0.0, 1.0);
	vec3 c4 = vec3(1.0, 0.1960784, 0.0);
	float p0 = 0.0;
	float p1 = 0.1566033;
	float p2 = 0.3773556;
	float p3 = 0.6490577;
	float p4 = 1.0;
	vec3 c = c0;
	c = mix(c, c1, clamp((t - p0) / max(p1 - p0, 1e-5), 0.0, 1.0));
	c = mix(c, c2, clamp((t - p1) / max(p2 - p1, 1e-5), 0.0, 1.0));
	c = mix(c, c3, clamp((t - p2) / max(p3 - p2, 1e-5), 0.0, 1.0));
	c = mix(c, c4, clamp((t - p3) / max(p4 - p3, 1e-5), 0.0, 1.0));
	return c;
}

void fragment() {
	float t = mystic_time < 0.0 ? TIME : mystic_time;
	// View-space NORMAL is the reliable post-skin interpolator; world_normal from vertex()
	// can be bone-local on these glTFs. Matcap uses unnormalized view .xy like the HLSL.
	vec3 n_view = NORMAL;
	vec3 n_world = (INV_VIEW_MATRIX * vec4(n_view, 0.0)).xyz;
	vec3 n_world_n = normalize(n_world);
	vec3 view_dir_world = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	// VERTEX is view-space; positionOS.y is recovered through root_inv_y (see header).
	vec3 world_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float position_os_y = dot(root_inv_y, vec4(world_pos, 1.0));

	// IsGammaSpace() constants (reference Unity project is Gamma).
	vec3 overlay_src = vec3(0.7106918);
	float overlay_a = 0.6980392;
	vec3 shadow_mul = vec3(0.7490196);
	vec3 rainbow_scale = vec3(11.98431);

	vec3 prim = linear_to_srgb(primary_color.rgb);
	vec3 sec = linear_to_srgb(secondary_color.rgb);
	vec3 tint = mix(prim, sec, vec3(0.0)); // lerp(_Primary, _Secondary, 0)
	float ndotl_fake = dot(vec3(-15.0, 80.0, -30.0), n_world);
	float shadow_ss = smoothstep_unity(-0.25, 0.55, ndotl_fake);
	// Blend Multiply: lerp(dest, src * dest, 1 - shadow_ss)
	vec3 mul_shadow = clamp(mix(tint, shadow_mul * tint, 1.0 - shadow_ss), 0.0, 1.0);

	// Amplify Fresnel: 0 + 0.2 * pow(1 - N·V, 5) on the unnormalized interpolator (no saturate).
	float fres = 0.2 * pow(1.0 - dot(n_world, view_dir_world), 5.0);
	float overlay_w = overlay_a * clamp(smoothstep_unity(0.9, 1.0, ndotl_fake * fres), 0.0, 1.0);
	// Blend Overlay
	vec3 overlay_blend = mix(
			mul_shadow + 2.0 * (overlay_src - 0.5),
			mul_shadow + 2.0 * overlay_src - 1.0,
			step(0.5, overlay_src));
	vec3 overlay = clamp(mix(mul_shadow, overlay_blend, overlay_w), 0.0, 1.0);

	// Matcap: (mul(UNITY_MATRIX_V, float4(worldN,0)).xyz * 0.5 + 0.5).xy. Unity samples with V up
	// (v = 1 is the top row of the image); the pack PNGs are stored top-down, so flip V here — the
	// exporter only flips the mesh UV channels, not UVs computed in the shader.
	vec2 mc = vec2(n_view.x, -n_view.y) * 0.5 + 0.5;
	vec4 matcap_s = texture(matcap, mc) * matcap_intensity;

	float rim_w = mix(1.0, 0.0, rim_shadow);
	float n_v = 1.0 - clamp(dot(view_dir_world, n_world_n) + rim_offset, 0.0, 1.0);
	vec3 rim = rim_w * smoothstep_unity(rim_falloff.x, rim_falloff.y, n_v) * rim_color.rgb;

	// Screen NDC * _Scale_Noisemap (Unity: remap ScreenPos/w from 0..1 → -1..1, then scale).
	// V convention: Unity's screen V and texture V both point up, Godot's SCREEN_UV.y and texture V
	// both point down, so the position term keeps its sign while the time term (authored in Unity's
	// texture space) flips in V (repeat wrap: 1 - v ≡ -v). Same for the UV2 panner below.
	vec2 nuv = (SCREEN_UV * 2.0 - 1.0) * scale_noisemap;
	const vec2 FLIP_V = vec2(1.0, -1.0);
	vec2 pan_view = nuv * noise_map_view_dir_st.xy + t * noise_map_view_dir_st.zw * FLIP_V;
	vec2 pan_2 = nuv * noise_map_2.xy + t * noise_map_2.zw * FLIP_V;
	vec4 noise_col = texture(noise_map_view_dir, pan_view) * emiss * texture(noise_map_2nd, pan_2);
	vec4 lerp247 = mix(vec4(0.0), color0, noise_col);
	vec4 lerp252 = mix(color1, lerp247, lerp247);

	// triangle((-1..1) from _Time.y * _Color_Time) remapped to 0..1 for the gradient.
	float tri = (t * color_time - floor(t * color_time + 0.5)) * 2.0;
	float grad_t = (tri + 1.0) * 0.5;
	vec3 mid_or_rainbow = color_switch ? sample_gradient(grad_t) * rainbow_scale : mid_color.rgb;
	// InverseLerp(positionOS.y, (0,1)) + _TopMid_Offset, then smoothstep(_TopMid_Step).
	float h = position_os_y + top_mid_offset;
	float top_mid = smoothstep_unity(top_mid_step.x, top_mid_step.y, h);
	vec4 lerp276 = mix(top_color, vec4(mid_or_rainbow, 1.0), top_mid);

	vec2 pan3 = nuv * noise3_uv_speed.xy + t * noise3_uv_speed.zw * FLIP_V;
	vec4 noise3_s = vec4(color3.rgb, 0.0) * texture(noise_3, pan3);

	vec2 uv1 = has_uv2 ? UV2 : UV;
	vec2 pan_uv2 = uv1 + t * uv2_speed * FLIP_V;
	float uv2_r = texture(uv2_texture, pan_uv2).r;
	float gold_w = 1.0 - step(uv2_r, uv2_threshold_alpha);
	vec3 gold = texture(matcap_uv2, mc).rgb * matcap_uv2_intensity * color_uv2.rgb;

	vec4 mystic_fx = mix(lerp252 * lerp276 * matcap_s + vec4(rim, 0.0) + noise3_s, vec4(gold, 0.0), gold_w);
	vec4 lit_tex = texture(main_tex, UV) * matcap_s + vec4(rim, 0.0);
	vec4 masked = mix(lit_tex, mystic_fx, texture(mask_map, UV).r);
	vec4 body = mix(vec4(overlay, 0.0), masked, texture(maskmap_color_body1, UV).r);

	float alpha = mix(alpha_uv1, 1.0, uv2_r);
	if (alpha < 0.5) {
		discard;
	}
	vec3 working = clamp(body.rgb, 0.0, 1.0);
	// Unlit: do not write ALBEDO (Forward+ would add directional lighting on top of emission).
	ALBEDO = vec3(0.0);
	EMISSION = srgb_to_linear(working);
}
