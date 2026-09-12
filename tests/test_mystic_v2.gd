extends SceneTree
## Mystic_Final plumbing: material dump → ShaderMaterial (raw vec4 params survive the per-character
## clone), AxieMysticRootTracker root-bone pick (part Offsets uncombined, Unity's first-renderer
## rootBone when combined), in-game shader clock default. Pixel parity is tools/render_compare.sh.
## Headless: godot --headless --path . -s tests/test_mystic_v2.gd

const CATALOG := "res://addons/axie_mixer_3d_assets/catalog.json"
const MixerMaterials := preload("res://addons/axie_mixer_3d/import/axie_mixer_materials.gd")
const TRACKER := "AxieMysticRootTracker"


func _init() -> void:
	# The tree-dependent checks need the main loop, which is not set yet inside _init.
	_start.call_deferred()


func _start() -> void:
	var errs: Array = run()
	if errs.is_empty():
		print("ok  mystic_v2")
		quit(0)
	else:
		for e in errs:
			print("FAIL mystic_v2: %s" % e)
		quit(1)


static func run() -> Array:
	var errs: Array = []
	var catalog := AxieCatalog.load_json(CATALOG)
	if catalog == null:
		return ["catalog failed to load"]
	var factory := AxieFactory.new()
	factory.catalog = catalog
	AxieFactory.default_factory = factory
	AxieDefaults.factory = factory
	errs.append_array(_check_material_dump(catalog))
	errs.append_array(_check_character(factory, false))
	errs.append_array(_check_character(factory, true))
	AxieFactory.default_factory = null
	AxieDefaults.factory = null
	return errs


static func _check_material_dump(catalog: AxieCatalog) -> Array:
	var errs: Array = []
	var addon: Dictionary = catalog.addons.get("Beast-Horn-02-S01-LV1/Horn_R", {})
	if addon.is_empty():
		return ["addon Beast-Horn-02-S01-LV1/Horn_R missing from catalog"]
	var mats: Array = addon.get("materials", [])
	if mats.is_empty():
		return ["addon has no materials"]
	var mat := MixerMaterials.from_id(catalog, str(mats[0].get("material", "")))
	if not MixerMaterials.is_mystic(mat):
		return ["Horn_R addon material is not Mystic_Final"]
	var sm := mat as ShaderMaterial
	# Unity dump: _Color1 (0.7107 gray), _TopMid_Step (0, 0.6), _TopMid_Offset 0.45, _Emiss 40.
	var color1 = sm.get_shader_parameter("color1")
	if not (color1 is Vector4) or absf(color1.x - 0.7106918) > 1e-4:
		errs.append("color1 not applied as Vector4: %s" % [color1])
	var step = sm.get_shader_parameter("top_mid_step")
	if not (step is Vector2) or step != Vector2(0.0, 0.6):
		errs.append("top_mid_step %s" % [step])
	if absf(float(sm.get_shader_parameter("top_mid_offset")) - 0.45) > 1e-5:
		errs.append("top_mid_offset %s" % sm.get_shader_parameter("top_mid_offset"))
	if absf(float(sm.get_shader_parameter("emiss")) - 40.0) > 1e-5:
		errs.append("emiss %s" % sm.get_shader_parameter("emiss"))
	if sm.get_shader_parameter("mystic_time") != null:
		errs.append("mystic_time must stay at the shader default (TIME) for in-game materials")
	if sm.next_pass == null or not (sm.next_pass is ShaderMaterial):
		errs.append("ExtraPrePass outline next_pass missing")
	# The regression: a Color stored on a plain vec4 uniform is dropped by duplicate().
	var clone := sm.duplicate() as ShaderMaterial
	var c1 = clone.get_shader_parameter("color1")
	if not (c1 is Vector4) or absf(c1.x - 0.7106918) > 1e-4:
		errs.append("color1 lost by duplicate(): %s" % [c1])
	for p in ["top_color", "mid_color", "color0", "color3", "rim_color", "color_uv2"]:
		if clone.get_shader_parameter(p) == null:
			errs.append("%s lost by duplicate()" % p)
	return errs


static func _check_character(factory: AxieFactory, combined: bool) -> Array:
	var errs: Array = []
	var tag := "combined" if combined else "uncombined"
	var desc := AxieDescriptor.new()
	desc.body = AxieTypes.Body.NORMAL
	desc.color_variant = 3
	desc.clear_parts()
	for t in ["Back", "Ear", "Eye", "Horn", "Mouth", "Tail"]:
		desc.parts.append(AxiePartDescriptor.from_dict({"type": t, "class": "Beast", "variant": 2, "skin": 1, "level": 1}))
	var params := AxieInstantiationParams.new()
	params.combine_meshes = combined
	var ch := factory.create_character(desc, params)
	if ch == null or ch.root == null:
		return ["%s: factory returned no character" % tag]
	var tracker := ch.root.get_node_or_null(TRACKER)
	if tracker == null:
		ch.dispose()
		return ["%s: %s not attached" % [tag, TRACKER]]
	var entries: Array = tracker._entries
	if entries.is_empty():
		errs.append("%s: tracker has no entries" % tag)
	var mystic_count := 0
	for n in ch.root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var m := mi.get_active_material(s)
			if not MixerMaterials.is_mystic(m):
				continue
			mystic_count += 1
			var sm := m as ShaderMaterial
			var c1 = sm.get_shader_parameter("color1")
			if c1 == null:
				errs.append("%s: %s surface %d lost mystic params in the character clone" % [tag, mi.name, s])
			var tracked := false
			for e in entries:
				if e["material"] == sm:
					tracked = true
					var skel: Skeleton3D = e["skeleton"]
					var bone: int = e["bone"]
					if skel == null or bone < 0:
						errs.append("%s: %s has no root bone" % [tag, mi.name])
						continue
					var bone_name := skel.get_bone_name(bone)
					if combined:
						# Unity: rootBone of the first SkinnedMeshRenderer in hierarchy order = the Back part.
						if not bone_name.ends_with("Back_M_1_Offsets"):
							errs.append("%s: merged renderer root bone %s (want the Back Offsets)" % [tag, bone_name])
					elif not bone_name.ends_with("_Offsets"):
						errs.append("%s: %s root bone %s (want its *_Offsets)" % [tag, mi.name, bone_name])
			if not tracked:
				errs.append("%s: %s surface %d not tracked" % [tag, mi.name, s])
	if mystic_count < 8:
		errs.append("%s: expected >= 8 mystic surfaces, got %d" % [tag, mystic_count])
	# Tracker output: once in the tree, root_inv_y is written for every entry.
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		ch.dispose()
		errs.append("%s: no SceneTree (run deferred)" % tag)
		return errs
	tree.root.add_child(ch.root)
	tracker.update_now()
	for e in entries:
		var v = (e["material"] as ShaderMaterial).get_shader_parameter("root_inv_y")
		if not (v is Vector4):
			errs.append("%s: root_inv_y not written for %s" % [tag, e["mesh"].name])
		elif not combined:
			# A part's Offsets frame is not the world frame: row Y must carry a translation.
			if absf(v.w) < 1e-3:
				errs.append("%s: root_inv_y for %s has no offset (%s)" % [tag, e["mesh"].name, v])
	tree.root.remove_child(ch.root)
	ch.dispose()
	return errs
