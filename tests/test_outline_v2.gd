extends SceneTree
## Draw-Objects hulls + PostProcess defaults vs Unity Outline_RenderObjects / PostProcess.
## Headless: godot --headless --path . -s tests/test_outline_v2.gd

const CATALOG := "res://addons/axie_mixer_3d_assets/catalog.json"
const INFLATE_MAT := "res://addons/axie_mixer_3d/materials/outline_inflate.tres"
const POST_MAT := "res://addons/axie_mixer_3d/materials/outline_postprocess.tres"
const POST_SCRIPT := "res://addons/axie_mixer_3d/outline/outline_post_process.gd"
const HULL := "AxieOutlineHull"


func _init() -> void:
	var errs: Array = run()
	if errs.is_empty():
		print("ok  outline_v2")
		quit(0)
	else:
		for e in errs:
			print("FAIL outline_v2: %s" % e)
		quit(1)


static func run() -> Array:
	var errs: Array = []
	errs.append_array(_check_unity_defaults())
	errs.append_array(_check_excluded_types())
	var factory := _bootstrap()
	if factory == null:
		errs.append("v2 catalog/factory failed")
		return errs
	errs.append_array(_check_draw_objects(factory, true))
	errs.append_array(_check_draw_objects(factory, false))
	errs.append_array(_check_postprocess_attach())
	_teardown()
	return errs


static func _check_unity_defaults() -> Array:
	var errs: Array = []
	var inflate := load(INFLATE_MAT) as ShaderMaterial
	if inflate == null:
		errs.append("missing outline_inflate.tres")
	else:
		var th: float = inflate.get_shader_parameter("thickness")
		if absf(th - 0.02) > 1e-6:
			errs.append("inflate thickness %s expected 0.02 (Unity _Thickness)" % th)
		var col: Color = inflate.get_shader_parameter("base_color")
		if col.r > 0.001 or col.g > 0.001 or col.b > 0.001:
			errs.append("inflate color %s expected black (Unity _BaseColor)" % col)
	var post := load(POST_MAT) as ShaderMaterial
	if post == null:
		errs.append("missing outline_postprocess.tres")
	else:
		if absf(float(post.get_shader_parameter("thickness")) - 2.0) > 1e-6:
			errs.append("post thickness %s expected 2" % post.get_shader_parameter("thickness"))
		if absf(float(post.get_shader_parameter("depth_scale")) - 50.0) > 1e-6:
			errs.append("post depth_scale %s expected 50" % post.get_shader_parameter("depth_scale"))
		if absf(float(post.get_shader_parameter("depth_bias")) - 50.0) > 1e-6:
			errs.append("post depth_bias %s expected 50" % post.get_shader_parameter("depth_bias"))
		if absf(float(post.get_shader_parameter("normal_scale")) - 0.7) > 1e-6:
			errs.append("post normal_scale %s expected 0.7" % post.get_shader_parameter("normal_scale"))
		if absf(float(post.get_shader_parameter("normal_bias")) - 10.0) > 1e-6:
			errs.append("post normal_bias %s expected 10" % post.get_shader_parameter("normal_bias"))
	var fx: Variant = (load(POST_SCRIPT) as GDScript).new()
	if fx.thickness != 2 or absf(fx.depth_scale - 50.0) > 1e-6 or absf(fx.depth_bias - 50.0) > 1e-6:
		errs.append("CompositorEffect defaults thickness=%s depth_scale=%s depth_bias=%s" % [fx.thickness, fx.depth_scale, fx.depth_bias])
	if absf(fx.normal_scale - 0.7) > 1e-6 or absf(fx.normal_bias - 10.0) > 1e-6:
		errs.append("CompositorEffect defaults normal_scale=%s normal_bias=%s" % [fx.normal_scale, fx.normal_bias])
	if fx.outline_color != Color(0, 0, 0, 1):
		errs.append("CompositorEffect outline_color %s" % fx.outline_color)
	return errs


static func _check_excluded_types() -> Array:
	var errs: Array = []
	var types: Array = AxieCharacter3D.OUTLINE_EXCLUDED_PART_TYPES
	if types.size() != 2:
		errs.append("OUTLINE_EXCLUDED_PART_TYPES size %s expected 2 (Eye, Mouth)" % types.size())
	if AxieTypes.Part.EYE not in types or AxieTypes.Part.MOUTH not in types:
		errs.append("OUTLINE_EXCLUDED_PART_TYPES %s expected Eye+Mouth" % types)
	if AxieDefaults.outline_base_layer != 1:
		errs.append("outline_base_layer %s expected 1 (Unity Default=0 → Godot layer 1)" % AxieDefaults.outline_base_layer)
	return errs


static func _check_draw_objects(factory: AxieFactory, combined: bool) -> Array:
	var errs: Array = []
	var tag := "combined" if combined else "loose"
	var ch := _make_character(factory, AxieTypes.Body.NORMAL, combined)
	if ch == null or ch.root == null:
		errs.append("%s create_character failed" % tag)
		return errs
	if _count_hulls(ch.root) != 0:
		errs.append("%s hulls present before set_outline_layer" % tag)
	ch.set_outline_layer(2, 1)
	var hulls := _count_hulls(ch.root)
	if hulls < 1:
		errs.append("%s DrawObjects spawned no hulls" % tag)
	var outline_mask := 1 << (2 - 1)
	var base_mask := 1 << (1 - 1)
	var excluded: Dictionary = {}
	for part in ch._outline_excluded_parts:
		if part == null:
			continue
		_collect_meshes(part, excluded)
		_assert_layers(part, base_mask, errs, "%s excluded part not on base layer" % tag)
	if excluded.is_empty():
		errs.append("%s no outline-excluded meshes (eyes/mouth)" % tag)
	var bad_hulls := [0]
	_count_excluded_hulls(ch.root, excluded, bad_hulls)
	if int(bad_hulls[0]) != 0:
		errs.append("%s eyes/mouth hulled count=%s" % [tag, bad_hulls[0]])
	var outlined := 0
	for mi in _mesh_list(ch.root):
		if mi.name == HULL:
			if mi.layers != outline_mask:
				errs.append("%s hull layers=%s expected %s" % [tag, mi.layers, outline_mask])
			if mi.material_override == null:
				errs.append("%s hull missing inflate material" % tag)
			continue
		if excluded.has(mi):
			if mi.layers != base_mask:
				errs.append("%s excluded mesh %s layers=%s expected %s" % [tag, mi.name, mi.layers, base_mask])
		elif mi.mesh != null:
			if mi.layers != outline_mask:
				errs.append("%s outlined mesh %s layers=%s expected %s" % [tag, mi.name, mi.layers, outline_mask])
			outlined += 1
	if outlined < 1:
		errs.append("%s no outlined meshes" % tag)
	ch.set_outline_layer(1, 1)
	if _count_hulls(ch.root) != 0:
		errs.append("%s hulls left after SetOutlineLayer(base)" % tag)
	_assert_layers(ch.root, base_mask, errs, "%s after remove, not all on base" % tag)
	ch.dispose()
	return errs


static func _check_postprocess_attach() -> Array:
	var errs: Array = []
	var cam := Camera3D.new()
	var fx := AxieOutlinePostProcess.attach_to_camera(cam)
	if fx == null:
		errs.append("attach_to_camera returned null")
	elif cam.compositor == null or cam.compositor.compositor_effects.is_empty():
		errs.append("attach_to_camera did not set compositor_effects")
	var again := AxieOutlinePostProcess.attach_to_camera(cam)
	if again != fx:
		errs.append("attach_to_camera is not idempotent")
	cam.free()
	return errs


static func _bootstrap() -> AxieFactory:
	var catalog := AxieCatalog.load_json(CATALOG)
	if catalog == null:
		return null
	var factory := AxieFactory.new()
	factory.catalog = catalog
	AxieFactory.default_factory = factory
	AxieDefaults.factory = factory
	AxieDefaults.outline_layer = -1
	return factory


static func _teardown() -> void:
	AxieFactory.default_factory = null
	AxieDefaults.factory = null
	AxieDefaults.outline_layer = -1


static func _make_character(factory: AxieFactory, body: int, combined: bool) -> AxieCharacter3D:
	var desc := AxieDescriptor.new()
	desc.body = body
	desc.color_variant = 3
	desc.clear_parts()
	for p in [
		{"type": "Eye", "class": "Beast", "variant": 2, "skin": 0, "level": 1},
		{"type": "Mouth", "class": "Beast", "variant": 2, "skin": 0, "level": 1},
		{"type": "Ear", "class": "Beast", "variant": 2, "skin": 0, "level": 1},
		{"type": "Horn", "class": "Beast", "variant": 2, "skin": 0, "level": 1},
		{"type": "Back", "class": "Beast", "variant": 2, "skin": 0, "level": 1},
		{"type": "Tail", "class": "Beast", "variant": 2, "skin": 0, "level": 1},
	]:
		desc.parts.append(AxiePartDescriptor.from_dict(p))
	var params := AxieInstantiationParams.new()
	params.combine_meshes = combined
	return factory.create_character(desc, params)


static func _count_hulls(n: Node) -> int:
	if n == null:
		return 0
	var c := 1 if n is MeshInstance3D and n.name == HULL else 0
	for ch in n.get_children():
		c += _count_hulls(ch)
	return c


static func _collect_meshes(n: Node, into: Dictionary) -> void:
	if n == null:
		return
	if n is MeshInstance3D and n.name != HULL and (n as MeshInstance3D).mesh:
		into[n] = true
	for c in n.get_children():
		_collect_meshes(c, into)


static func _count_excluded_hulls(n: Node, excluded: Dictionary, acc: Array) -> void:
	if n is MeshInstance3D and n.name == HULL:
		if excluded.has(n) or _mesh_owned_by_excluded(n, excluded):
			acc[0] = int(acc[0]) + 1
	for c in n.get_children():
		_count_excluded_hulls(c, excluded, acc)


static func _mesh_owned_by_excluded(hull: MeshInstance3D, excluded: Dictionary) -> bool:
	var mesh: Mesh = hull.mesh
	if mesh == null:
		return false
	for mi in excluded.keys():
		if mi is MeshInstance3D and (mi as MeshInstance3D).mesh == mesh:
			return true
	return false


static func _mesh_list(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_mesh_list(c))
	return out


static func _assert_layers(n: Node, mask: int, errs: Array, msg: String) -> void:
	if n is VisualInstance3D and (n as VisualInstance3D).name != HULL:
		if ((n as VisualInstance3D).layers & mask) == 0:
			errs.append("%s (%s layers=%s)" % [msg, n.name, (n as VisualInstance3D).layers])
	for c in n.get_children():
		if c is MeshInstance3D and c.name == HULL:
			continue
		_assert_layers(c, mask, errs, msg)

