extends SceneTree
## Factory TryResolvePart / HasPart / skip-missing on the shipped catalog.
## Headless: godot --headless --path . -s tests/test_part_fallback.gd

const Catalog := preload("res://addons/axie_mixer_3d/runtime/axie_catalog.gd")
const Factory := preload("res://addons/axie_mixer_3d/runtime/axie_factory.gd")
const Character := preload("res://addons/axie_mixer_3d/runtime/axie_character_3d.gd")
const Descriptor := preload("res://addons/axie_mixer_3d/core/axie_descriptor.gd")
const PartDesc := preload("res://addons/axie_mixer_3d/core/axie_part_descriptor.gd")
const Types := preload("res://addons/axie_mixer_3d/core/axie_types.gd")
const Defaults := preload("res://addons/axie_mixer_3d/core/axie_defaults.gd")
const Params := preload("res://addons/axie_mixer_3d/core/axie_instantiation_params.gd")
const ExampleOptions := preload("res://examples/example_options.gd")


func _init() -> void:
	var errs: Array = run()
	if errs.is_empty():
		print("ok  part_fallback")
		quit(0)
	else:
		for e in errs:
			print("FAIL part_fallback: %s" % e)
		quit(1)


static func run() -> Array:
	var errs: Array = []
	var cat = Catalog.load_json("res://addons/axie_mixer_3d_assets/catalog.json")
	var factory = Factory.new()
	factory.catalog = cat
	Factory.default_factory = factory
	Defaults.factory = factory
	errs.append_array(_check_has_part(factory))
	errs.append_array(_check_resolve(factory))
	errs.append_array(_check_fallback_spawn(factory))
	errs.append_array(_check_skip_missing())
	errs.append_array(_check_invalid_body(factory))
	errs.append_array(_check_empty_parts())
	errs.append_array(_check_combo_omit(factory))
	Factory.default_factory = null
	Defaults.factory = null
	return errs


static func _params(combine: bool) -> AxieInstantiationParams:
	var p = Params.new()
	p.combine_meshes = combine
	return p


static func _check_has_part(factory) -> Array:
	var errs: Array = []
	if not factory.has_part("Beast", 2, 0, 1, Types.Part.HORN):
		errs.append("HasPart Beast02 S00 L1 Horn")
	if not factory.has_part("Beast", 2, 1, 1, Types.Part.HORN):
		errs.append("HasPart Beast02 S01 L1 Horn")
	if factory.has_part("Aquatic", 4, 1, 1, Types.Part.HORN):
		errs.append("HasPart Aquatic04 S01 must be false")
	if factory.has_part("Mech", 2, 0, 1, Types.Part.TAIL):
		errs.append("HasPart Mech must be false")
	if factory.has_part("Beast", 2, -1, 1, Types.Part.HORN):
		errs.append("HasPart does not clamp negative skin")
	return errs


static func _check_resolve(factory) -> Array:
	var errs: Array = []
	var aquatic := PartDesc.new(Types.Part.HORN, 1, "Aquatic", 4, 1)
	var r = factory.resolve_part(aquatic)
	if not r["ok"] or r["name"] != "S00_Aquatic04_L1_Horn" or int(r["skin"]) != 0:
		errs.append("Aquatic04 S01 → S00 %s" % r)
	var l3 := PartDesc.new(Types.Part.HORN, 1, "Beast", 2, 3)
	var r3 = factory.resolve_part(l3)
	if not r3["ok"] or r3["name"] != "S01_Beast02_L1_Horn" or int(r3["level"]) != 1:
		errs.append("Beast02 S01 L3 → L1 %s" % r3)
	var s12 := PartDesc.new(Types.Part.HORN, 12, "Beast", 2, 2)
	var r12 = factory.resolve_part(s12)
	if not r12["ok"] or r12["name"] != "S00_Beast02_L2_Horn" or int(r12["skin"]) != 0 or int(r12["level"]) != 2:
		errs.append("Beast02 S12 L2 → S00 L2 %s" % r12)
	var mech := PartDesc.new(Types.Part.TAIL, 0, "Mech", 2, 1)
	var rm = factory.resolve_part(mech)
	if rm["ok"]:
		errs.append("Mech should miss %s" % rm)
	return errs


static func _check_fallback_spawn(factory) -> Array:
	var errs: Array = []
	var s00 := _class_desc("Aquatic", 4, 0, 1)
	var s01 := _class_desc("Aquatic", 4, 1, 1)
	var off = _params(false)
	var a = Character.from_descriptor(s00, off)
	var b = Character.from_descriptor(s01, off)
	if a == null or a.root == null or b == null or b.root == null:
		errs.append("Aquatic04 spawn null")
		if a:
			a.dispose()
		if b:
			b.dispose()
		return errs
	var names_a := _collect_names(a.root)
	var names_b := _collect_names(b.root)
	if not _has_prefix(names_b, "S00_Aquatic04"):
		errs.append("Aquatic04 S01 did not instantiate S00 fallback names %s" % names_b)
	if _has_prefix(names_b, "S01_Aquatic04"):
		errs.append("Aquatic04 S01 must not keep S01 names")
	if _count_mystic(b.root) != 0:
		errs.append("Aquatic04 S01 fallback must not apply mystic addon")
	var va := _vert_count(a.root)
	var vb := _vert_count(b.root)
	if va < 200 or vb != va:
		errs.append("Aquatic04 S01 verts %s vs S00 %s" % [vb, va])
	var mystic_horn := _mixed_mystic_and_fallback()
	var m = Character.from_descriptor(mystic_horn, off)
	if m == null or m.root == null:
		errs.append("mixed mystic+fallback spawn null")
	else:
		if _count_mystic(m.root) < 1:
			errs.append("mixed Beast02 S01 horn must keep mystic")
		if not _has_prefix(_collect_names(m.root), "S00_Aquatic04"):
			errs.append("mixed Aquatic04 slots must fall back to S00")
		m.dispose()
	var on = _params(true)
	var c = Character.from_descriptor(s01, on)
	if c == null or c.root == null:
		errs.append("Aquatic04 S01 combine-on null")
	else:
		if _vert_count(c.root) < 200:
			errs.append("Aquatic04 S01 combine-on verts")
		c.dispose()
	a.dispose()
	b.dispose()
	return errs


static func _check_skip_missing() -> Array:
	var errs: Array = []
	var d := Descriptor.new()
	d.body = Types.Body.NORMAL
	d.color_variant = 46
	d.clear_parts()
	for t in [
		Types.Part.EYE, Types.Part.MOUTH, Types.Part.EAR,
		Types.Part.HORN, Types.Part.BACK, Types.Part.TAIL,
	]:
		d.parts.append(PartDesc.new(t, 0, "Mech", 2, 1))
	var ch = Character.from_descriptor(d, _params(true))
	if ch == null or ch.root == null:
		errs.append("Mech skip returned null")
		return errs
	var names := _collect_names(ch.root)
	if _has_substr(names, "Mech"):
		errs.append("Mech parts were not skipped %s" % names)
	if _vert_count(ch.root) < 50:
		errs.append("Mech skip body verts too low")
	if ch.playable == null or ch.playable.play("Idle", "", true) == null:
		errs.append("Mech skip Idle failed")
	ch.dispose()
	var genes := d.to_genes()
	var gch = Character.from_genes(genes, _params(true))
	if gch == null or gch.root == null:
		errs.append("Mech from_genes null")
	else:
		if _has_substr(_collect_names(gch.root), "Mech"):
			errs.append("Mech from_genes did not skip")
		gch.dispose()
	return errs


static func _check_invalid_body(factory) -> Array:
	var errs: Array = []
	var d := Descriptor.new()
	d.body = 99
	d.color_variant = 3
	d.clear_parts()
	d.parts.append(PartDesc.new(Types.Part.HORN, 0, "Beast", 2, 1))
	var ch = Character.from_descriptor(d, _params(true))
	if ch != null:
		errs.append("invalid body should return null")
		if ch:
			ch.dispose()
	if not factory.catalog.body_entry(99).is_empty():
		errs.append("body_entry 99 should be empty")
	return errs


static func _check_empty_parts() -> Array:
	var errs: Array = []
	var d := Descriptor.new()
	d.body = Types.Body.NORMAL
	d.color_variant = 3
	d.clear_parts()
	var ch = Character.from_descriptor(d, _params(true))
	if ch == null or ch.root == null:
		errs.append("empty parts should still spawn body")
		return errs
	if _vert_count(ch.root) < 50:
		errs.append("empty parts body verts")
	ch.dispose()
	return errs


static func _check_combo_omit(factory) -> Array:
	var errs: Array = []
	var mystic := ExampleOptions.combo_descriptor(
		factory, Types.Body.NORMAL, "Beast", 2, 1, 1, 3
	)
	if mystic.parts.size() != 6:
		errs.append("combo Beast02 S01 should keep 6 parts got %s" % mystic.parts.size())
	var omit := ExampleOptions.combo_descriptor(
		factory, Types.Body.NORMAL, "Aquatic", 4, 1, 1, 14
	)
	if not omit.parts.is_empty():
		errs.append("combo Aquatic04 S01 should omit all, got %s" % omit.parts.size())
	var s00 := ExampleOptions.combo_descriptor(
		null, Types.Body.NORMAL, "Aquatic", 4, 0, 1, 14
	)
	if s00.parts.size() != 6:
		errs.append("combo S00 with null factory should include 6")
	return errs


static func _class_desc(axie_class: String, variant: int, skin: int, level: int) -> AxieDescriptor:
	var d := Descriptor.new()
	d.body = Types.Body.NORMAL
	d.color_variant = Descriptor._color_variant(axie_class, 3)
	d.clear_parts()
	for t in [
		Types.Part.EYE, Types.Part.MOUTH, Types.Part.EAR,
		Types.Part.HORN, Types.Part.BACK, Types.Part.TAIL,
	]:
		d.parts.append(PartDesc.new(t, skin, axie_class, variant, level))
	return d


static func _mixed_mystic_and_fallback() -> AxieDescriptor:
	var d := Descriptor.new()
	d.body = Types.Body.NORMAL
	d.color_variant = 3
	d.clear_parts()
	d.parts.append(PartDesc.new(Types.Part.EYE, 1, "Aquatic", 4, 1))
	d.parts.append(PartDesc.new(Types.Part.MOUTH, 1, "Aquatic", 4, 1))
	d.parts.append(PartDesc.new(Types.Part.EAR, 1, "Aquatic", 4, 1))
	d.parts.append(PartDesc.new(Types.Part.HORN, 1, "Beast", 2, 1))
	d.parts.append(PartDesc.new(Types.Part.BACK, 1, "Beast", 2, 1))
	d.parts.append(PartDesc.new(Types.Part.TAIL, 1, "Beast", 2, 1))
	return d


static func _collect_names(n: Node) -> PackedStringArray:
	var out := PackedStringArray()
	_walk_names(n, out)
	return out


static func _walk_names(n: Node, out: PackedStringArray) -> void:
	out.append(n.name)
	for c in n.get_children():
		_walk_names(c, out)


static func _has_prefix(names: PackedStringArray, prefix: String) -> bool:
	for n in names:
		if str(n).begins_with(prefix):
			return true
	return false


static func _has_substr(names: PackedStringArray, needle: String) -> bool:
	for n in names:
		if str(n).contains(needle):
			return true
	return false


static func _vert_count(n: Node) -> int:
	var verts := 0
	for mi in _meshes(n):
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			verts += mi.mesh.surface_get_array_len(s)
	return verts


static func _count_mystic(n: Node) -> int:
	var count := 0
	for mi in _meshes(n):
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var mat: Material = mi.get_surface_override_material(s)
			if mat == null:
				mat = mi.mesh.surface_get_material(s)
			if mat is ShaderMaterial:
				var sh: Shader = (mat as ShaderMaterial).shader
				if sh and str(sh.resource_path).contains("mystic_final"):
					count += 1
	return count


static func _meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_meshes(c))
	return out
