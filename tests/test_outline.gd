extends SceneTree
## DrawObjects hulls on non-excluded meshes; PostProcess compositor attaches.
## Headless: godot --headless --path . -s tests/test_outline.gd

const AxieCatalog := preload("res://addons/axie_mixer_3d/runtime/axie_catalog.gd")
const AxieFactory := preload("res://addons/axie_mixer_3d/runtime/axie_factory.gd")
const AxieCharacter3D := preload("res://addons/axie_mixer_3d/runtime/axie_character_3d.gd")
const AxieDescriptor := preload("res://addons/axie_mixer_3d/core/axie_descriptor.gd")
const AxiePartDescriptor := preload("res://addons/axie_mixer_3d/core/axie_part_descriptor.gd")
const AxieTypes := preload("res://addons/axie_mixer_3d/core/axie_types.gd")
const AxieDefaults := preload("res://addons/axie_mixer_3d/core/axie_defaults.gd")
const AxieInstantiationParams := preload("res://addons/axie_mixer_3d/core/axie_instantiation_params.gd")


func _init() -> void:
	var errs: Array = run()
	if errs.is_empty():
		print("ok  outline")
		quit(0)
	else:
		for e in errs:
			print("FAIL outline: %s" % e)
		quit(1)


static func run() -> Array:
	var errs: Array = []
	var cat = AxieCatalog.load_json("res://addons/axie_mixer_3d_assets/catalog.json")
	var factory = AxieFactory.new()
	factory.catalog = cat
	AxieFactory.default_factory = factory
	AxieDefaults.factory = factory
	AxieDefaults.outline_layer = -1
	var desc = AxieDescriptor.new()
	desc.body = AxieTypes.Body.NORMAL
	desc.color_variant = 3
	for t in [
		AxieTypes.Part.EYE, AxieTypes.Part.MOUTH, AxieTypes.Part.EAR,
		AxieTypes.Part.HORN, AxieTypes.Part.BACK, AxieTypes.Part.TAIL,
	]:
		desc.parts.append(AxiePartDescriptor.new(t, 0, "Beast", 2, 1))
	var params = AxieInstantiationParams.new()
	params.combine_meshes = true
	var ch = AxieCharacter3D.from_descriptor(desc, params)
	if ch == null or ch.root == null:
		errs.append("from_descriptor failed")
		return errs
	if _count_hulls(ch.root) != 0:
		errs.append("hulls present before set_outline_layer")
	ch.set_outline_layer(2, 1)
	var hulls := _count_hulls(ch.root)
	if hulls < 1:
		errs.append("DrawObjects spawned no hulls")
	var excluded_meshes: Dictionary = {}
	for part in ch._outline_excluded_parts:
		_collect_meshes(part, excluded_meshes)
	if excluded_meshes.is_empty():
		errs.append("no outline-excluded meshes")
	var bad := [0]
	_count_excluded_hulls(ch.root, excluded_meshes, bad)
	if int(bad[0]) != 0:
		errs.append("eyes/mouth hulled count=%s" % bad[0])
	ch.set_outline_layer(1, 1)
	if _count_hulls(ch.root) != 0:
		errs.append("hulls left after outline off")
	ch.dispose()
	AxieFactory.default_factory = null
	AxieDefaults.factory = null
	return errs


static func _count_hulls(n: Node) -> int:
	if n == null:
		return 0
	var c := 1 if n is MeshInstance3D and n.name == "AxieOutlineHull" else 0
	for ch in n.get_children():
		c += _count_hulls(ch)
	return c


static func _collect_meshes(n: Node, into: Dictionary) -> void:
	if n == null:
		return
	if n is MeshInstance3D and n.name != "AxieOutlineHull" and (n as MeshInstance3D).mesh:
		into[(n as MeshInstance3D).mesh] = true
	for c in n.get_children():
		_collect_meshes(c, into)


static func _count_excluded_hulls(n: Node, excluded_meshes: Dictionary, acc: Array) -> void:
	if n is MeshInstance3D and n.name == "AxieOutlineHull":
		var mesh: Mesh = (n as MeshInstance3D).mesh
		if mesh and excluded_meshes.has(mesh):
			acc[0] = int(acc[0]) + 1
	for c in n.get_children():
		_count_excluded_hulls(c, excluded_meshes, acc)
