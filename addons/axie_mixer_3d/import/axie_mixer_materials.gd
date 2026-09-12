class_name AxieMixerMaterials
extends Object
## Builds Godot ShaderMaterials from the pack's Unity material dumps (`materials/<id>.json`).
##
## Unity shader → Godot shader:
##   Shader Graphs/S_Axie_Mixer_V5       → shaders/s_axie_mixer_v5.gdshader
##   AxieMixer3D/Mystic_Final (+trans)  → shaders/mystic_final.gdshader
##   AxieMixer3D/ProjectT_VFX/disslove_mobile(_stencil) → shaders/vfx_dissolve.gdshader
##   AxieMixer3D/Star                    → shaders/vfx_star.gdshader   (docs/design.md §3)
##   anything else                       → StandardMaterial3D with the main texture

const SHADER_V5 := preload("res://addons/axie_mixer_3d/shaders/s_axie_mixer_v5.gdshader")
const SHADER_MYSTIC := preload("res://addons/axie_mixer_3d/shaders/mystic_final.gdshader")
const MYSTIC_OUTLINE_PASS := preload("res://addons/axie_mixer_3d/materials/mystic_outline.tres")
const SHADER_VFX_DISSOLVE := preload("res://addons/axie_mixer_3d/shaders/vfx_dissolve.gdshader")
const SHADER_VFX_STAR := preload("res://addons/axie_mixer_3d/shaders/vfx_star.gdshader")

const MYSTIC_TEXTURES := {
	"_Main_tex": "main_tex",
	"_MainTex": "main_tex",
	"_Matcap": "matcap",
	"_Matcap_UV2": "matcap_uv2",
	"_UV2_texture": "uv2_texture",
	"_Mask_MAP": "mask_map",
	"_maskmapcolorbody1": "maskmap_color_body1",
	"_NoiseMap_ViewDir": "noise_map_view_dir",
	"_NoiseMap_2nd": "noise_map_2nd",
	"_Noise_3": "noise_3",
}
const MYSTIC_COLORS := {
	"_PrimaryColor": "primary_color",
	"_SecondaryColor": "secondary_color",
	"_Color_UV2": "color_uv2",
	"_RimColor": "rim_color",
	"_Color0": "color0",
	"_Color1": "color1",
	"_Color3": "color3",
	"_Top": "top_color",
	"_Mid": "mid_color",
	"_outlinecolor": "outline_color",
}
const MYSTIC_FLOATS := {
	"_matcap": "matcap_intensity",
	"_matcap_UV2": "matcap_uv2_intensity",
	"_UV2_thresholdalpha": "uv2_threshold_alpha",
	"_Alpha_UV1": "alpha_uv1",
	"_RimOffset": "rim_offset",
	"_RimShadow": "rim_shadow",
	"_TopMid_Offset": "top_mid_offset",
	"_Color_Time": "color_time",
	"_Emiss": "emiss",
	"_Scale_Noisemap": "scale_noisemap",
	"_outline": "outline",
}
## Uniforms declared with `source_color` (typed Color); every other MYSTIC_COLORS entry is a raw vec4.
const MYSTIC_SOURCE_COLOR_UNIFORMS := ["primary_color", "secondary_color"]
const MYSTIC_BOOLS := {"_Color_switch": "color_switch"}
const MYSTIC_VEC2 := {
	"_RimFalloff": "rim_falloff",
	"_UV2_speed": "uv2_speed",
	"_TopMid_Step": "top_mid_step",
}
const MYSTIC_VEC4 := {
	"_NoiseMap_ViewDIr": "noise_map_view_dir_st",
	"_NoiseMap_2": "noise_map_2",
	"_Noise3_UVSPEED": "noise3_uv_speed",
}

static var _cache: Dictionary = {} ## "<base_dir>|<id>" -> Material
static var _json_cache: Dictionary = {} ## path -> Dictionary
static var _tex_cache: Dictionary = {} ## path -> Texture2D


static func clear_cache() -> void:
	_cache.clear()
	_json_cache.clear()
	_tex_cache.clear()


## Shared (uncolorized) material for a pack material id. Callers clone before mutating.
static func from_id(catalog: AxieCatalog, id: String) -> Material:
	if catalog == null or id.is_empty():
		return null
	var key := "%s|%s" % [catalog.base_dir, id]
	if _cache.has(key):
		return _cache[key]
	var d := material_json(catalog, id)
	if d.is_empty():
		return null
	var mat := _build(catalog, d)
	if mat != null:
		mat.resource_name = id
	_cache[key] = mat
	return mat


static func material_json(catalog: AxieCatalog, id: String) -> Dictionary:
	var path := catalog.material_json_path(id)
	if path.is_empty():
		return {}
	if _json_cache.has(path):
		return _json_cache[path]
	var d: Dictionary = {}
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(parsed) == TYPE_DICTIONARY:
			d = parsed
	_json_cache[path] = d
	return d


static func is_v5(material: Material) -> bool:
	if material is ShaderMaterial:
		var sh := (material as ShaderMaterial).shader
		return sh == SHADER_V5
	return false


static func is_mystic(material: Material) -> bool:
	return material is ShaderMaterial and (material as ShaderMaterial).shader == SHADER_MYSTIC


static func _build(catalog: AxieCatalog, d: Dictionary) -> Material:
	var shader_name := str(d.get("shader", ""))
	if shader_name.contains("S_Axie_Mixer_V5"):
		return _build_v5(catalog, d)
	if shader_name.contains("Mystic"):
		return _build_mystic(catalog, d)
	if shader_name.contains("disslove_mobile"):
		return _build_vfx_dissolve(catalog, d)
	if shader_name.ends_with("/Star"):
		return _build_vfx_star(catalog, d)
	return _build_fallback(catalog, d)


static func is_vfx(material: Material) -> bool:
	if material is ShaderMaterial:
		var sh := (material as ShaderMaterial).shader
		return sh == SHADER_VFX_DISSOLVE or sh == SHADER_VFX_STAR
	return false


## Unity `_Ztest` enum on the VFX shaders: 0 Equal, 1 NotEqual, 2 LessEqual. URP never depth-prepasses
## transparent queues, so a ZTest Equal particle passes nowhere and is invisible in Unity.
static func vfx_is_invisible(d: Dictionary) -> bool:
	var floats: Dictionary = d.get("floats", {})
	return floats.has("_Ztest") and int(floats["_Ztest"]) == 0


static func _build_vfx_dissolve(catalog: AxieCatalog, d: Dictionary) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = SHADER_VFX_DISSOLVE
	for pair in [["_MainTex", "main_tex"], ["_DissolveTex", "dissolve_tex"], ["_Mask_alpha", "mask_alpha"]]:
		var tex := _texture(catalog, d, pair[0])
		if tex != null:
			mat.set_shader_parameter(pair[1], tex)
	var colors: Dictionary = d.get("colors", {})
	if colors.has("_BaseColor"):
		mat.set_shader_parameter("base_color", _vec4(colors["_BaseColor"]))
	var vectors: Dictionary = d.get("vectors", {})
	if vectors.has("_maintexUV"):
		mat.set_shader_parameter("maintex_uv", _vec4(vectors["_maintexUV"]))
	if vectors.has("_DissolveUV"):
		mat.set_shader_parameter("dissolve_uv", _vec4(vectors["_DissolveUV"]))
	var floats: Dictionary = d.get("floats", {})
	# `_alphamaintex` drives the _ALPHAMAINTEX_ON keyword on the stencil variant.
	mat.set_shader_parameter("alpha_main_tex", float(floats.get("_alphamaintex", 0.0)) >= 0.5)
	return mat


static func _build_vfx_star(catalog: AxieCatalog, d: Dictionary) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = SHADER_VFX_STAR
	var tex := _texture(catalog, d, "_TextureSample0")
	if tex != null:
		mat.set_shader_parameter("texture_sample0", tex)
	var colors: Dictionary = d.get("colors", {})
	for pair in [["_Color0", "color0"], ["_Color1", "color1"]]:
		if colors.has(pair[0]):
			mat.set_shader_parameter(pair[1], _vec4(colors[pair[0]]))
	var floats: Dictionary = d.get("floats", {})
	if floats.has("_EdgeWidth"):
		mat.set_shader_parameter("edge_width", float(floats["_EdgeWidth"]))
	var vectors: Dictionary = d.get("vectors", {})
	if vectors.has("_Vector0"):
		mat.set_shader_parameter("vector0", _vec4(vectors["_Vector0"]))
	return mat


static func _build_v5(catalog: AxieCatalog, d: Dictionary) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = SHADER_V5
	var tex := _texture(catalog, d, "_MainTex")
	if tex != null:
		mat.set_shader_parameter("main_tex", tex)
	var colors: Dictionary = d.get("colors", {})
	mat.set_shader_parameter("primary_color", _color(colors.get("_PrimaryColor", [1, 1, 1, 1])))
	mat.set_shader_parameter("secondary_color", _color(colors.get("_SecondaryColor", [1, 1, 1, 1])))
	return mat


static func _build_mystic(catalog: AxieCatalog, d: Dictionary) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = SHADER_MYSTIC
	# Per-material ExtraPrePass: shared tres would pin every part to 0.02 / black.
	var outline_pass: ShaderMaterial = MYSTIC_OUTLINE_PASS.duplicate()
	var textures: Dictionary = d.get("textures", {})
	var seen: Dictionary = {}
	for unity_name in MYSTIC_TEXTURES.keys():
		var uniform: String = MYSTIC_TEXTURES[unity_name]
		if seen.has(uniform) or not textures.has(unity_name):
			continue
		var tex := _texture(catalog, d, unity_name)
		if tex != null:
			mat.set_shader_parameter(uniform, tex)
			seen[uniform] = true
	var colors: Dictionary = d.get("colors", {})
	for unity_name in MYSTIC_COLORS.keys():
		if colors.has(unity_name):
			var uniform_name: String = MYSTIC_COLORS[unity_name]
			# Only the source_color uniforms are typed Color. The raw/HDR vec4 uniforms must be set
			# as Vector4: a Color stored on a plain vec4 uniform is dropped by Material.duplicate()
			# (the per-character clone made by AxieFactory._colorize), which reverted every mystic
			# tint to the shader defaults.
			if uniform_name in MYSTIC_SOURCE_COLOR_UNIFORMS:
				mat.set_shader_parameter(uniform_name, _color(colors[unity_name]))
			else:
				mat.set_shader_parameter(uniform_name, _vec4(colors[unity_name]))
	var floats: Dictionary = d.get("floats", {})
	for unity_name in MYSTIC_FLOATS.keys():
		if floats.has(unity_name):
			mat.set_shader_parameter(MYSTIC_FLOATS[unity_name], float(floats[unity_name]))
	for unity_name in MYSTIC_BOOLS.keys():
		if floats.has(unity_name):
			mat.set_shader_parameter(MYSTIC_BOOLS[unity_name], float(floats[unity_name]) >= 0.5)
	var vectors: Dictionary = d.get("vectors", {})
	for unity_name in MYSTIC_VEC2.keys():
		if vectors.has(unity_name):
			var v: Array = vectors[unity_name]
			mat.set_shader_parameter(MYSTIC_VEC2[unity_name], Vector2(float(v[0]), float(v[1])))
	for unity_name in MYSTIC_VEC4.keys():
		if vectors.has(unity_name):
			var v: Array = vectors[unity_name]
			mat.set_shader_parameter(
				MYSTIC_VEC4[unity_name], Vector4(float(v[0]), float(v[1]), float(v[2]), float(v[3]))
			)
	if floats.has("_outline"):
		outline_pass.set_shader_parameter("outline", float(floats["_outline"]))
	if colors.has("_outlinecolor"):
		outline_pass.set_shader_parameter("outline_color", _vec4(colors["_outlinecolor"]))
	mat.next_pass = outline_pass
	mat.set_shader_parameter("has_uv2", false)
	return mat


static func _build_fallback(catalog: AxieCatalog, d: Dictionary) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var tex := _texture(catalog, d, "_MainTex")
	if tex == null:
		tex = _texture(catalog, d, "_BaseMap")
	if tex != null:
		mat.albedo_texture = tex
	var colors: Dictionary = d.get("colors", {})
	if colors.has("_Color"):
		mat.albedo_color = _color(colors["_Color"])
	elif colors.has("_BaseColor"):
		mat.albedo_color = _color(colors["_BaseColor"])
	var shader_name := str(d.get("shader", "")).to_lower()
	if shader_name.contains("star") or shader_name.contains("vfx") or shader_name.contains("trans"):
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


static func _texture(catalog: AxieCatalog, d: Dictionary, unity_name: String) -> Texture2D:
	var textures: Dictionary = d.get("textures", {})
	var slot: Variant = textures.get(unity_name, null)
	if not (slot is Dictionary):
		return null
	var raw: Variant = (slot as Dictionary).get("texture", null)
	if raw == null:
		return null
	var id := str(raw)
	if id.is_empty() or id == "null":
		return null
	var path := catalog.texture_path(id)
	if path.is_empty():
		return null
	var info := catalog.texture_info(id)
	# Unity samples the imported texture; mirror its mipmap setting (the shaders declare
	# filter_linear_mipmap, which degrades to plain bilinear when the texture has no mipmaps).
	return load_texture(path, bool(info.get("mipmaps", true)))


static func load_texture(path: String, mipmaps: bool = true) -> Texture2D:
	if _tex_cache.has(path):
		return _tex_cache[path]
	var tex: Texture2D = null
	if FileAccess.file_exists(path):
		# Decode the pack PNG directly so sampling does not depend on per-project import settings.
		var img := Image.load_from_file(path)
		if img != null and not img.is_empty():
			if mipmaps:
				img.generate_mipmaps()
			tex = ImageTexture.create_from_image(img)
	if tex == null and ResourceLoader.exists(path, "Texture2D"):
		var loaded: Variant = ResourceLoader.load(path, "Texture2D")
		if loaded is Texture2D:
			tex = loaded
	_tex_cache[path] = tex
	return tex


static func _vec4(value: Variant) -> Vector4:
	if value is Array and (value as Array).size() >= 3:
		var a: Array = value
		var w := float(a[3]) if a.size() > 3 else 1.0
		return Vector4(float(a[0]), float(a[1]), float(a[2]), w)
	return Vector4(1.0, 1.0, 1.0, 1.0)


static func _color(value: Variant) -> Color:
	if value is Array and (value as Array).size() >= 3:
		var a: Array = value
		var alpha := float(a[3]) if a.size() > 3 else 1.0
		return Color(float(a[0]), float(a[1]), float(a[2]), alpha)
	return Color.WHITE
