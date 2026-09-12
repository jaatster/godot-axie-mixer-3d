class_name AxieOutlineDrawObjects
extends Object
## Unity URP Render-Objects analogue: inverted-hull redraw of outlined meshes.
## Eyes/mouth stay on the base layer and are not hulled.

const HULL_NAME := "AxieOutlineHull"
const InflateMat := preload("res://addons/axie_mixer_3d/materials/outline_inflate.tres")


static func sync(root: Node, excluded_parts: Array, enabled: bool) -> void:
	_clear(root)
	if not enabled or root == null:
		return
	var excluded: Dictionary = {}
	for part in excluded_parts:
		if part:
			_collect_meshes(part, excluded)
	for mi in _mesh_list(root):
		if excluded.has(mi):
			continue
		if mi.name == HULL_NAME:
			continue
		if mi.mesh == null:
			continue
		if not mi.visible:
			continue
		_add_hull(mi)


static func _add_hull(src: MeshInstance3D) -> void:
	var hull := MeshInstance3D.new()
	hull.name = HULL_NAME
	hull.mesh = src.mesh
	hull.skin = src.skin
	hull.material_override = InflateMat
	hull.layers = src.layers
	hull.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	hull.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	var parent := src.get_parent()
	if parent:
		parent.add_child(hull)
		hull.transform = src.transform
	else:
		src.add_child(hull)
	if src.skin != null and src.skeleton != NodePath():
		var skel := src.get_node_or_null(src.skeleton)
		if skel:
			hull.skeleton = hull.get_path_to(skel)


static func _clear(root: Node) -> void:
	if root == null:
		return
	var doomed: Array[Node] = []
	_find_hulls(root, doomed)
	for n in doomed:
		var p := n.get_parent()
		if p:
			p.remove_child(n)
		n.free()


static func _find_hulls(n: Node, out: Array) -> void:
	if n is MeshInstance3D and n.name == HULL_NAME:
		out.append(n)
	for c in n.get_children():
		_find_hulls(c, out)


static func _collect_meshes(n: Node, into: Dictionary) -> void:
	if n is MeshInstance3D:
		into[n] = true
	for c in n.get_children():
		_collect_meshes(c, into)


static func _mesh_list(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_mesh_list(c))
	return out
