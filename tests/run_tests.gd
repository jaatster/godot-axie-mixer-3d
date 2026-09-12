extends SceneTree
## Headless: godot --headless --path . -s tests/run_tests.gd

const CATALOG_PATH := "res://addons/axie_mixer_3d_assets/catalog.json"


func _init() -> void:
	# Run once the main loop is live so suites can add nodes to `root` (initializers, characters).
	_run_all.call_deferred()


func _run_all() -> void:
	var failed := 0
	failed += _run("descriptor", _test_descriptor)
	failed += _run("part_resolver", _test_part_resolver)
	failed += _run("part_fallback", _test_part_fallback)
	failed += _run("instantiation_merge", _test_instantiation_merge)
	failed += _run("rig_to_part", _test_rig_to_part)
	failed += _run("blend_weights", _test_blend)
	failed += _run("mesh_combiner", _test_mesh_combiner)
	failed += _run("clip_resolve", _test_clip_resolve)
	failed += _run("addon_name", _test_addon_name)
	failed += _run("class_colors", _test_class_colors)
	failed += _run("weapon_attach", _test_weapon_attach)
	failed += _run("outline", _test_outline)
	failed += _run("public_api", _test_public_api)
	failed += _run("sample_pack", _test_sample_pack)
	failed += _run("sample_loco", _test_sample_loco)
	failed += _run("sample_colorize", _test_sample_colorize)
	failed += _run("catalog_integrity", _test_catalog_integrity)
	failed += _run_if_exists("outline_v2", "res://tests/test_outline_v2.gd")
	failed += _run_if_exists("avatar_v2", "res://tests/test_avatar_v2.gd")
	failed += _run_if_exists("weapon_anims_v2", "res://tests/test_weapon_anims_v2.gd")
	failed += _run_if_exists("clip_coverage_v2", "res://tests/test_clip_coverage_v2.gd")
	failed += _run_if_exists("mystic_v2", "res://tests/test_mystic_v2.gd")
	failed += _run_if_exists("mystic_vfx", "res://tests/test_mystic_vfx.gd")
	print("note  numeric oracle: godot --headless --path . -s tests/oracle_compare.gd")
	print("note  playable oracle: godot --headless --path . -s tests/playable_oracle_compare.gd")
	print("note  pixel oracle: tools/render_compare.sh")
	if failed == 0:
		print("ALL TESTS PASSED")
		quit(0)
	else:
		print("TESTS FAILED: %d suite(s)" % failed)
		quit(1)


func _run(name: String, fn: Callable) -> int:
	var errs: Array = fn.call()
	if errs.is_empty():
		print("ok  %s" % name)
		return 0
	for e in errs:
		print("FAIL %s: %s" % [name, e])
	return 1


func _run_if_exists(name: String, path: String) -> int:
	if not FileAccess.file_exists(path):
		return 0
	var script = load(path)
	if script == null or not script.has_method("run"):
		print("FAIL %s: %s failed to load or has no run()" % [name, path])
		return 1
	return _run(name, script.run)


func _test_descriptor() -> Array:
	var errs: Array = []
	var empty := AxieDescriptor.from_genes("")
	if empty.body != AxieTypes.Body.NORMAL:
		errs.append("empty body %s" % empty.body)
	if empty.color_variant != 0:
		errs.append("empty color %s" % empty.color_variant)
	if empty.parts.size() != 6:
		errs.append("empty parts %s" % empty.parts.size())
	for p in empty.parts:
		if p.part_class != "Beast" or p.level != 1 or p.skin != 0:
			errs.append("empty part %s" % p.to_dict())
	var d := AxieDescriptor.new()
	d.body = AxieTypes.Body.SUMO
	d.color_variant = 30
	for t in [
		AxieTypes.Part.EYE, AxieTypes.Part.MOUTH, AxieTypes.Part.EAR,
		AxieTypes.Part.HORN, AxieTypes.Part.BACK, AxieTypes.Part.TAIL
	]:
		d.parts.append(AxiePartDescriptor.new(t, 2, "Reptile", 6, 2))
	var g := d.to_genes()
	if not g.begins_with("0x") or g.length() != 130:
		errs.append("to_genes length %s" % g)
	var round := AxieDescriptor.from_genes(g)
	if not d.equals(round):
		errs.append("roundtrip mismatch %s vs genes %s" % [round.color_variant, g])
	var g2 := round.to_genes()
	if g != g2:
		errs.append("double roundtrip genes differ")
	var frosty := AxieDescriptor.new()
	frosty.body = AxieTypes.Body.FROSTY
	frosty.color_variant = 48
	for t2 in [
		AxieTypes.Part.EYE, AxieTypes.Part.MOUTH, AxieTypes.Part.EAR,
		AxieTypes.Part.HORN, AxieTypes.Part.BACK, AxieTypes.Part.TAIL
	]:
		frosty.parts.append(AxiePartDescriptor.new(t2, 1, "Aquatic", 2, 2))
	var fd := AxieDescriptor.from_genes(frosty.to_genes())
	if fd.body != AxieTypes.Body.FROSTY or fd.color_variant != 48:
		errs.append("frosty %s %s" % [fd.body, fd.color_variant])
	var fixture := AxieDescriptor.new()
	fixture.body = AxieTypes.Body.NORMAL
	fixture.color_variant = 3
	for t3 in [
		AxieTypes.Part.EYE, AxieTypes.Part.MOUTH, AxieTypes.Part.EAR,
		AxieTypes.Part.HORN, AxieTypes.Part.BACK, AxieTypes.Part.TAIL
	]:
		fixture.parts.append(AxiePartDescriptor.new(t3, 0, "Beast", 2, 1))
	var fg := fixture.to_genes()
	var back := AxieDescriptor.from_genes(fg)
	if not fixture.equals(back):
		errs.append("fixture Beast-02 roundtrip mismatch")
	if AxieDescriptor.from_genes(back.to_genes()).to_genes() != fg:
		errs.append("fixture hex not stable")
	return errs


func _test_part_resolver() -> Array:
	var errs: Array = []
	var shipped := {"S00_Beast02_L1_Horn": true, "S01_Beast02_L1_Horn": true, "S00_Beast02_L2_Horn": true}
	var has := func(n: String) -> bool: return shipped.has(n)
	var exact := AxiePartDescriptor.new(AxieTypes.Part.HORN, 1, "Beast", 2, 1)
	var r0 := AxiePartResolver.resolve(exact, has)
	if not r0["ok"] or r0["name"] != "S01_Beast02_L1_Horn" or int(r0["skin"]) != 1 or int(r0["level"]) != 1:
		errs.append("exact %s" % r0)
	var part := AxiePartDescriptor.new(AxieTypes.Part.HORN, 1, "Beast", 2, 2)
	var r := AxiePartResolver.resolve(part, has)
	if not r["ok"] or r["name"] != "S01_Beast02_L1_Horn" or r["level"] != 1:
		errs.append("fallback level %s" % r)
	var skin_fb := AxiePartDescriptor.new(AxieTypes.Part.HORN, 1, "Beast", 2, 2)
	var shipped_s00_l2 := {"S00_Beast02_L2_Horn": true}
	var has_s00 := func(n: String) -> bool: return shipped_s00_l2.has(n)
	var r_skin := AxiePartResolver.resolve(skin_fb, has_s00)
	if not r_skin["ok"] or r_skin["name"] != "S00_Beast02_L2_Horn" or int(r_skin["skin"]) != 0:
		errs.append("fallback skin %s" % r_skin)
	var base := AxiePartDescriptor.new(AxieTypes.Part.HORN, 12, "Beast", 2, 2)
	var shipped_base := {"S00_Beast02_L1_Horn": true}
	var has_base := func(n: String) -> bool: return shipped_base.has(n)
	var r_base := AxiePartResolver.resolve(base, has_base)
	if not r_base["ok"] or r_base["name"] != "S00_Beast02_L1_Horn" or int(r_base["skin"]) != 0 or int(r_base["level"]) != 1:
		errs.append("fallback base %s" % r_base)
	var clamp := AxiePartDescriptor.new(AxieTypes.Part.HORN, -3, "Beast", 2, 0)
	var r_clamp := AxiePartResolver.resolve(clamp, has)
	if not r_clamp["ok"] or r_clamp["name"] != "S00_Beast02_L1_Horn":
		errs.append("clamp %s" % r_clamp)
	var missing := AxiePartDescriptor.new(AxieTypes.Part.TAIL, 9, "Mech", 4, 2)
	var r2 := AxiePartResolver.resolve(missing, has)
	if r2["ok"]:
		errs.append("expected miss %s" % r2)
	return errs


func _test_part_fallback() -> Array:
	var script = load("res://tests/test_part_fallback.gd")
	if script == null or not script.has_method("run"):
		return ["test_part_fallback.gd failed to load"]
	return script.run() as Array


func _test_instantiation_merge() -> Array:
	var errs: Array = []
	var a := AxieInstantiationParams.new()
	a.combine_meshes = true
	a.part_layer_overrides = [{"type": AxieTypes.Part.HORN, "layer": 2}]
	var b := AxieInstantiationParams.new()
	b.combine_meshes = false
	b.part_layer_overrides = [{"type": AxieTypes.Part.HORN, "layer": 4}, {"type": AxieTypes.Part.BACK, "layer": 4}]
	var m := a.merge(b)
	if m.combine_meshes != false:
		errs.append("combine not overridden")
	if m.find_layer_override(AxieTypes.Part.HORN) != 4:
		errs.append("horn layer")
	if m.find_layer_override(AxieTypes.Part.BACK) != 4:
		errs.append("back layer")
	return errs


func _test_blend() -> Array:
	return load("res://tests/test_blend_weights.gd").run() as Array


func _test_mesh_combiner() -> Array:
	return load("res://tests/test_mesh_combiner.gd").run() as Array


func _test_clip_resolve() -> Array:
	return load("res://tests/test_clip_resolve.gd").run() as Array


func _test_addon_name() -> Array:
	var errs: Array = []
	var n := AxiePartResolver.addon_name("Beast", 2, 1, 1, "Horn_L")
	if n != "Beast-Horn-02-S01-LV1/Horn_L":
		errs.append("addon_name %s" % n)
	var n2 := AxiePartResolver.addon_name("Aquatic", 2, 1, 2, "Back_M")
	if n2 != "Aquatic-Back-02-S01-LV2/Back_M":
		errs.append("addon_name aquatic %s" % n2)
	return errs


func _test_class_colors() -> Array:
	var errs: Array = []
	var expect := {
		"Beast": 3, "Plant": 9, "Aquatic": 14, "Bug": 20, "Bird": 25, "Reptile": 30,
	}
	for cls in expect.keys():
		var got: int = AxieDescriptor._color_variant(str(cls), 3)
		if got != int(expect[cls]):
			errs.append("%s color3 index %s expected %s" % [cls, got, expect[cls]])
	if AxieTypes.CLASS_NAMES[0] != "Beast" or AxieTypes.CLASS_NAMES[5] != "Reptile":
		errs.append("CLASS_NAMES order %s" % AxieTypes.CLASS_NAMES)
	return errs


func _test_weapon_attach() -> Array:
	return load("res://tests/test_weapon_attach.gd").run() as Array


func _test_outline() -> Array:
	return load("res://tests/test_outline.gd").run() as Array


func _test_public_api() -> Array:
	var script = load("res://tests/test_public_api.gd")
	if script == null or not script.has_method("run"):
		return ["test_public_api.gd failed to load"]
	return script.run(self) as Array


func _test_sample_pack() -> Array:
	var script = load("res://tests/test_sample_pack.gd")
	if script == null or not script.has_method("run"):
		return ["test_sample_pack.gd failed to load"]
	return script.run() as Array


func _test_sample_loco() -> Array:
	var script = load("res://tests/test_sample_loco.gd")
	if script == null or not script.has_method("run"):
		return ["test_sample_loco.gd failed to load"]
	return script.run(self) as Array


func _test_sample_colorize() -> Array:
	var script = load("res://tests/test_sample_colorize.gd")
	if script == null or not script.has_method("run"):
		return ["test_sample_colorize.gd failed to load"]
	return script.run(self) as Array


func _test_rig_to_part() -> Array:
	var errs: Array = []
	if AxieTypes.rig_to_part(AxieTypes.Rig.HORN_T) != AxieTypes.Part.HORN:
		errs.append("Horn_T")
	if AxieTypes.rig_to_part(AxieTypes.Rig.EAR_L) != AxieTypes.Part.EAR:
		errs.append("Ear_L")
	if AxieTypes.rig_from_name("Weapon_R") != -1:
		errs.append("Weapon_R should not be a rig enum")
	return errs


func _test_catalog_integrity() -> Array:
	var errs: Array = []
	if not FileAccess.file_exists(CATALOG_PATH):
		return ["missing %s" % CATALOG_PATH]
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOG_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		return ["catalog.json is not a dict"]
	var pack: Dictionary = parsed
	if int(pack.get("format_version", 0)) != 2:
		errs.append("format_version %s expected 2" % pack.get("format_version"))
	var base := CATALOG_PATH.get_base_dir()
	var tex_path := base.path_join("textures.json")
	var textures: Dictionary = {}
	if FileAccess.file_exists(tex_path):
		var tparsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(tex_path))
		if typeof(tparsed) == TYPE_DICTIONARY:
			textures = tparsed
		else:
			errs.append("textures.json is not a dict")
	else:
		errs.append("missing %s" % tex_path)

	var bodies: Array = pack.get("bodies", [])
	if bodies.size() != 8:
		errs.append("bodies %s expected 8" % bodies.size())
	var body_attach: Dictionary = {}
	for row in bodies:
		if typeof(row) != TYPE_DICTIONARY:
			errs.append("body row not a dict")
			continue
		var bname := str(row.get("type", ""))
		if AxieTypes.body_from_name(bname) < 0 and bname != AxieTypes.body_name(0):
			pass
		if AxieTypes.BODY_NAMES.find(bname) < 0:
			errs.append("unknown body type %s" % bname)
		_require_file(errs, base, str(row.get("glb", "")), "body %s glb" % bname)
		var wglb := str(row.get("weapon_anims_glb", ""))
		if not wglb.is_empty():
			_require_file(errs, base, wglb, "body %s weapon glb" % bname)
		for mid in row.get("materials", []):
			var mid_s := str(mid).strip_edges()
			if mid_s.is_empty():
				continue
			_require_material(errs, base, mid_s, textures, "body %s" % bname)
		var attach: Array = row.get("attach_points", [])
		body_attach[bname] = attach

	var parts: Dictionary = pack.get("parts", {})
	if parts.is_empty():
		errs.append("catalog parts empty")
	for pname in parts.keys():
		var entry: Dictionary = parts[pname]
		var rigs: Array = entry.get("rigs", [])
		if rigs.is_empty():
			errs.append("part %s has no rigs" % pname)
		for rig in rigs:
			if typeof(rig) != TYPE_DICTIONARY:
				errs.append("part %s rig not a dict" % pname)
				continue
			var rtype := str(rig.get("type", ""))
			if AxieTypes.rig_from_name(rtype) < 0:
				errs.append("part %s unknown rig %s" % [pname, rtype])
			_require_file(errs, base, str(rig.get("glb", "")), "part %s %s glb" % [pname, rtype])
			for mid in rig.get("materials", []):
				var mid_s := str(mid).strip_edges()
				if mid_s.is_empty():
					continue
				_require_material(errs, base, mid_s, textures, "part %s" % pname)
			var want := "Root_%s_JNT" % rtype
			for bname in body_attach.keys():
				var attach: Array = body_attach[bname]
				if not attach.has(want):
					errs.append("part %s rig %s missing on body %s" % [pname, rtype, bname])
					break

	var addons: Dictionary = pack.get("addons", {})
	for aname in addons.keys():
		var addon: Dictionary = addons[aname]
		for mat_row in addon.get("materials", []):
			if typeof(mat_row) == TYPE_DICTIONARY:
				_require_material(errs, base, str(mat_row.get("material", "")), textures, "addon %s" % aname)
		for prefab in addon.get("prefabs", []):
			_require_file(errs, base, str(prefab), "addon %s prefab" % aname)

	var mat_dir := base.path_join("materials")
	var dir := DirAccess.open(mat_dir)
	if dir == null:
		errs.append("missing materials dir")
	else:
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			if not dir.current_is_dir() and fname.ends_with(".json"):
				var mpath := mat_dir.path_join(fname)
				var mparsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(mpath))
				if typeof(mparsed) == TYPE_DICTIONARY:
					_check_material_textures(errs, mparsed, textures, fname)
			fname = dir.get_next()
		dir.list_dir_end()
	return errs


func _require_file(errs: Array, base: String, rel: String, label: String) -> void:
	if rel.is_empty():
		errs.append("%s empty path" % label)
		return
	var path := rel if rel.begins_with("res://") else base.path_join(rel)
	if not FileAccess.file_exists(path) and not ResourceLoader.exists(path):
		errs.append("%s missing %s" % [label, path])


func _require_material(errs: Array, base: String, material_id: String, textures: Dictionary, label: String) -> void:
	if material_id.is_empty():
		errs.append("%s empty material id" % label)
		return
	var path := base.path_join("materials/%s.json" % material_id)
	if not FileAccess.file_exists(path):
		errs.append("%s missing material %s" % [label, path])
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) == TYPE_DICTIONARY:
		_check_material_textures(errs, parsed, textures, material_id)


func _check_material_textures(errs: Array, material: Dictionary, textures: Dictionary, label: String) -> void:
	var slots: Variant = material.get("textures", {})
	if typeof(slots) != TYPE_DICTIONARY:
		return
	for slot_name in (slots as Dictionary).keys():
		var slot: Variant = slots[slot_name]
		var tid := ""
		if typeof(slot) == TYPE_DICTIONARY:
			tid = str(slot.get("texture", slot.get("id", "")))
		else:
			tid = str(slot)
		if tid.is_empty() or tid == "<null>" or tid == "null":
			continue
		if not textures.has(tid):
			errs.append("%s texture id %s not in textures.json" % [label, tid])
			continue
		var info: Dictionary = textures[tid]
		var file := str(info.get("file", ""))
		if file.is_empty():
			errs.append("%s texture %s has no file" % [label, tid])
			continue
		var tpath := CATALOG_PATH.get_base_dir().path_join(file)
		if not FileAccess.file_exists(tpath) and not ResourceLoader.exists(tpath):
			errs.append("%s texture file missing %s" % [label, tpath])
