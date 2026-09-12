extends SceneTree
## Sample pack colorize: catalog primary+secondary on from_genes. 123 lime ≠ 922 pale.
## Headless: godot --headless --path . -s tests/test_sample_colorize.gd

const Initializer := preload("res://addons/axie_mixer_3d/runtime/axie_mixer_initializer.gd")
const Character := preload("res://addons/axie_mixer_3d/runtime/axie_character_3d.gd")
const Params := preload("res://addons/axie_mixer_3d/core/axie_instantiation_params.gd")
const PACK := "res://tests/goldens/sample_axies.json"
const BODY_TEX := "res://addons/axie_mixer_3d_assets/textures/b6cae95eb7d3d4b689913a4cf3477c88_2800000.png"
const EYE_TEX := "res://addons/axie_mixer_3d_assets/textures/afb9b5f23a59e47fbb7132b7b25cddfb_2800000.png"


func _init() -> void:
	var errs: Array = run(self)
	if errs.is_empty():
		print("ok  sample_colorize")
		quit(0)
	else:
		for e in errs:
			print("FAIL sample_colorize: %s" % e)
		quit(1)


static func run(tree: SceneTree = null) -> Array:
	var errs: Array = []
	if tree == null:
		errs.append("need SceneTree")
		return errs
	if not FileAccess.file_exists(PACK):
		errs.append("missing %s" % PACK)
		return errs
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PACK))
	if typeof(parsed) != TYPE_DICTIONARY:
		errs.append("pack not a dict")
		return errs
	var boot = Initializer.new()
	boot.catalog_path = "res://addons/axie_mixer_3d_assets/catalog.json"
	boot.persist_across_scenes = false
	boot.combine_meshes = true
	tree.root.add_child(boot)
	if AxieFactory.default_factory == null and boot.has_method("_assign_factory"):
		boot.call("_assign_factory")
	var factory = AxieFactory.default_factory
	if factory == null or factory.catalog == null:
		errs.append("no factory catalog")
		boot.queue_free()
		return errs
	var n := 0
	var hex_123 := ""
	var hex_922 := ""
	for row in (parsed as Dictionary).get("ids", []):
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var id := str(row.get("id", ""))
		var genes := str(row.get("genes", ""))
		if bool(row.get("skip", false)) or genes.length() < 40:
			continue
		var cat_row: Dictionary = factory.catalog.color_for(int(row.get("color", -1)))
		if cat_row.is_empty():
			errs.append("%s catalog missing color %s" % [id, row.get("color")])
			continue
		var p_html := str(row.get("primary1", ""))
		var s_html := str(row.get("primary2", ""))
		if p_html != str(cat_row.get("primary1", "")):
			errs.append("%s pack primary1 %s != catalog %s" % [id, p_html, cat_row.get("primary1")])
		if s_html != str(cat_row.get("primary2", "")):
			errs.append("%s pack primary2 %s != catalog %s" % [id, s_html, cat_row.get("primary2")])
		if id == "123":
			hex_123 = p_html
			if p_html != "afdb1b":
				errs.append("123 primary1 %s expected afdb1b" % p_html)
		if id == "922":
			hex_922 = p_html
			if p_html != "f4fff4":
				errs.append("922 primary1 %s expected f4fff4" % p_html)
			if s_html != "3ca1d9":
				errs.append("922 primary2 %s expected 3ca1d9" % s_html)
		for combine in [true, false]:
			errs.append_array(_check_spawn(tree, id, genes, p_html, s_html, combine))
		n += 1
	if n != 9:
		errs.append("colorize n=%s expected 9" % n)
	if hex_123.is_empty() or hex_922.is_empty():
		errs.append("missing 123/922 pack rows")
	elif hex_123 == hex_922:
		errs.append("123 and 922 share primary %s" % hex_123)
	errs.append_array(_check_v5_alpha_bands())
	boot.queue_free()
	return errs


static func _check_spawn(
	tree: SceneTree, id: String, genes: String, p_html: String, s_html: String, combine: bool
) -> Array:
	var errs: Array = []
	var params = Params.new()
	params.combine_meshes = combine
	var ch = Character.from_genes(genes, params)
	var tag := "%s combine_%s" % [id, "on" if combine else "off"]
	if ch == null or ch.root == null:
		errs.append("%s from_genes null" % tag)
		return errs
	tree.root.add_child(ch.root)
	var want_p := _html_color(p_html)
	var want_s := _html_color(s_html)
	if want_p.is_equal_approx(Color.WHITE):
		errs.append("%s primary %s is white" % [tag, p_html])
	var hit_p := 0
	var hit_s := 0
	for mi in _meshes(ch.root):
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var mat: Material = mi.get_surface_override_material(s)
			if mat == null:
				mat = mi.mesh.surface_get_material(s)
			if not (mat is ShaderMaterial):
				continue
			var sm := mat as ShaderMaterial
			var pv: Variant = sm.get_shader_parameter("primary_color")
			var sv: Variant = sm.get_shader_parameter("secondary_color")
			if pv is Color and (pv as Color).is_equal_approx(want_p):
				hit_p += 1
			if sv is Color and (sv as Color).is_equal_approx(want_s):
				hit_s += 1
	if hit_p < 1:
		errs.append("%s primary %s not on materials" % [tag, p_html])
	if hit_s < 1:
		errs.append("%s secondary %s not on materials" % [tag, s_html])
	ch.root.queue_free()
	ch.dispose()
	return errs


static func _check_v5_alpha_bands() -> Array:
	var errs: Array = []
	var body := _tex_image(BODY_TEX)
	if body == null:
		errs.append("missing %s" % BODY_TEX)
		return errs
	var body_bands := _alpha_bands(body)
	if int(body_bands["primary"]) < 1000:
		errs.append("Normal body primary A-band %s expected >=1000" % body_bands["primary"])
	# Normal body atlas is A≈0.8 (all primary). Secondary is not a rest-camera island.
	if int(body_bands["secondary"]) > int(body_bands["primary"]) / 5:
		errs.append("Normal body unexpected secondary-dominant mask %s" % body_bands)
	var eye := _tex_image(EYE_TEX)
	if eye == null:
		errs.append("missing %s" % EYE_TEX)
		return errs
	var eye_bands := _alpha_bands(eye)
	if int(eye_bands["secondary"]) < 50:
		errs.append("Plant02 Eye secondary A-band %s expected >=50" % eye_bands["secondary"])
		return errs
	var primary := _html_color("f4fff4")
	var secondary := _html_color("3ca1d9")
	var differ := 0
	for y in eye.get_height():
		for x in eye.get_width():
			var c := eye.get_pixel(x, y)
			if c.a <= 0.5 or c.a > 0.7:
				continue
			var tp := Color(c.r * primary.r, c.g * primary.g, c.b * primary.b)
			var ts := Color(c.r * secondary.r, c.g * secondary.g, c.b * secondary.b)
			if absf(tp.r - ts.r) + absf(tp.g - ts.g) + absf(tp.b - ts.b) > 0.08:
				differ += 1
	if differ < 50:
		errs.append("922 primary vs secondary tint on Eye A-band differ=%s" % differ)
	return errs


static func _tex_image(path: String) -> Image:
	if ResourceLoader.exists(path):
		var tex: Texture2D = load(path)
		if tex != null:
			var img: Image = tex.get_image()
			if img != null:
				if img.is_compressed():
					img.decompress()
				return img
	if FileAccess.file_exists(path):
		var loaded := Image.new()
		if loaded.load(path) == OK:
			return loaded
	return null


static func _alpha_bands(img: Image) -> Dictionary:
	var clip := 0
	var secondary := 0
	var primary := 0
	var skip := 0
	for y in img.get_height():
		for x in img.get_width():
			var a := img.get_pixel(x, y).a
			if a < 0.5:
				clip += 1
			elif a <= 0.7:
				secondary += 1
			elif a <= 0.975:
				primary += 1
			else:
				skip += 1
	return {"clip": clip, "secondary": secondary, "primary": primary, "skip": skip}


static func _html_color(html: String) -> Color:
	var hex := html if html.begins_with("#") else ("#" + html)
	if hex.is_valid_html_color():
		return Color.html(hex)
	return Color.WHITE


static func _meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_meshes(c))
	return out
