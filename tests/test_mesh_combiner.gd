extends SceneTree
## Combiner must flip winding from the local-transform chain, not Node3D.global_transform.
## Headless: godot --headless --path . -s tests/test_mesh_combiner.gd

const Combiner := preload("res://addons/axie_mixer_3d/runtime/axie_mesh_combiner.gd")


func _init() -> void:
	var errs: Array = run()
	if errs.is_empty():
		print("ok  mesh_combiner")
		quit(0)
	else:
		for e in errs:
			print("FAIL mesh_combiner: %s" % e)
		quit(1)


static func run() -> Array:
	var errs: Array = []
	_check_indices(errs, "no_mirror", Vector3.ONE, PackedInt32Array([0, 1, 2]))
	_check_indices(errs, "mirror_x", Vector3(-1, 1, 1), PackedInt32Array([0, 2, 1]))
	_check_indices(errs, "double_mirror_cancels", Vector3(-1, -1, 1), PackedInt32Array([0, 1, 2]))
	_check_affine_nested(errs)
	_check_bind_union(errs)
	_check_sources_removed(errs)
	_check_uv2_missing_pads_uv0(errs)
	_check_uv2_omitted_when_all_missing(errs)
	_check_per_surface_compact(errs)
	_check_same_material_concatenates(errs)
	return errs


static func _check_indices(errs: Array, label: String, scale: Vector3, expected: PackedInt32Array) -> void:
	var got := _combine_indices(scale)
	if got != expected:
		errs.append("%s indices %s expected %s" % [label, got, expected])


static func _check_affine_nested(errs: Array) -> void:
	var parent := Node3D.new()
	parent.scale = Vector3(-2.0, 1.0, 1.0)
	parent.position = Vector3(1.0, 2.0, 3.0)
	var child := Node3D.new()
	child.position = Vector3(4.0, 0.0, 0.0)
	parent.add_child(child)
	var world: Transform3D = Combiner.affine_world_transform(child)
	var expected := parent.transform * child.transform
	if not world.is_equal_approx(expected):
		errs.append("affine nested got %s expected %s" % [world, expected])
	if world.basis.determinant() >= 0.0:
		errs.append("affine nested det %s should be negative" % world.basis.determinant())
	parent.free()


static func _check_bind_union(errs: Array) -> void:
	var root := Node3D.new()
	var a := _make_skinned_tri()
	a.skin.set_bind_name(0, "BoneA")
	var b := _make_skinned_tri()
	b.skin.set_bind_count(2)
	b.skin.set_bind_name(0, "BoneA")
	b.skin.set_bind_pose(0, Transform3D.IDENTITY)
	b.skin.set_bind_name(1, "BoneB")
	b.skin.set_bind_pose(1, Transform3D(Basis.IDENTITY, Vector3(1, 0, 0)))
	root.add_child(a)
	root.add_child(b)
	var result: Array = Combiner.combine(root, [])
	if result.is_empty():
		errs.append("bind_union produced no mesh")
		root.free()
		return
	var skin: Skin = result[0].skin
	if skin.get_bind_count() != 2:
		errs.append("bind_union count %s" % skin.get_bind_count())
	else:
		var names := PackedStringArray()
		for i in 2:
			names.append(str(skin.get_bind_name(i)))
		if not names.has("BoneA") or not names.has("BoneB"):
			errs.append("bind_union names %s" % names)
	root.free()


static func _check_sources_removed(errs: Array) -> void:
	var root := Node3D.new()
	var holder := Node3D.new()
	root.add_child(holder)
	holder.add_child(_make_skinned_tri())
	var result: Array = Combiner.combine(root, [])
	if result.is_empty():
		errs.append("sources_removed no result")
		root.free()
		return
	if holder.get_child_count() != 0:
		errs.append("sources still live under holder %s" % holder.get_child_count())
	if result[0].renderer.get_parent() != root:
		errs.append("merged renderer not under root")
	root.free()


static func _check_uv2_missing_pads_uv0(errs: Array) -> void:
	var root := Node3D.new()
	var with_uv2 := _make_skinned_tri()
	var arrays := with_uv2.mesh.surface_get_arrays(0)
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0.1, 0.2), Vector2(0.3, 0.4), Vector2(0.5, 0.6)])
	arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([Vector2(0.7, 0.8), Vector2(0.7, 0.8), Vector2(0.7, 0.8)])
	var mesh2 := ArrayMesh.new()
	mesh2.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh2.surface_set_material(0, with_uv2.mesh.surface_get_material(0))
	with_uv2.mesh = mesh2
	var no_uv2 := _make_skinned_tri()
	var a0 := no_uv2.mesh.surface_get_arrays(0)
	a0[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0.11, 0.22), Vector2(0.33, 0.44), Vector2(0.55, 0.66)])
	var mesh0 := ArrayMesh.new()
	mesh0.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a0)
	mesh0.surface_set_material(0, with_uv2.mesh.surface_get_material(0))
	no_uv2.mesh = mesh0
	root.add_child(with_uv2)
	root.add_child(no_uv2)
	var result: Array = Combiner.combine(root, [])
	if result.is_empty():
		errs.append("uv2_pad no result")
		root.free()
		return
	var got = result[0].mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
	if not (got is PackedVector2Array) or (got as PackedVector2Array).size() != 6:
		errs.append("uv2_pad size %s" % (got.size() if got is PackedVector2Array else got))
		root.free()
		return
	var uv2: PackedVector2Array = got
	if not uv2[0].is_equal_approx(Vector2(0.7, 0.8)):
		errs.append("uv2_pad kept source uv2 %s" % uv2[0])
	if not uv2[3].is_equal_approx(Vector2(0.11, 0.22)):
		errs.append("uv2_pad missing channel should copy uv0 got %s" % uv2[3])
	root.free()


static func _check_uv2_omitted_when_all_missing(errs: Array) -> void:
	var root := Node3D.new()
	var a := _make_skinned_tri()
	var b := _make_skinned_tri()
	root.add_child(a)
	root.add_child(b)
	var result: Array = Combiner.combine(root, [])
	if result.is_empty():
		errs.append("uv2_omit no result")
		root.free()
		return
	var got = result[0].mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
	if got is PackedVector2Array and (got as PackedVector2Array).size() > 0:
		errs.append("uv2_omit should not publish UV2 when no source had it")
	root.free()


static func _check_per_surface_compact(errs: Array) -> void:
	var root := Node3D.new()
	var a := _make_skinned_tri()
	var b := _make_skinned_tri()
	a.mesh.surface_set_material(0, StandardMaterial3D.new())
	b.mesh.surface_set_material(0, StandardMaterial3D.new())
	root.add_child(a)
	root.add_child(b)
	var result: Array = Combiner.combine(root, [])
	if result.is_empty():
		errs.append("compact no result")
		root.free()
		return
	var mesh: ArrayMesh = result[0].mesh
	if mesh.get_surface_count() != 2:
		errs.append("compact surfaces %s want 2" % mesh.get_surface_count())
		root.free()
		return
	for s in 2:
		var verts: PackedVector3Array = mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		if verts.size() != 3:
			errs.append("compact surface %s verts %s want 3 (no full-buffer duplicate)" % [s, verts.size()])
	root.free()


static func _check_same_material_concatenates(errs: Array) -> void:
	var root := Node3D.new()
	var mat := StandardMaterial3D.new()
	var a := _make_skinned_tri()
	var b := _make_skinned_tri()
	a.mesh.surface_set_material(0, mat)
	b.mesh.surface_set_material(0, mat)
	root.add_child(a)
	root.add_child(b)
	var result: Array = Combiner.combine(root, [])
	if result.is_empty():
		errs.append("concat no result")
		root.free()
		return
	var mesh: ArrayMesh = result[0].mesh
	if mesh.get_surface_count() != 1:
		errs.append("concat surfaces %s want 1" % mesh.get_surface_count())
		root.free()
		return
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	if verts.size() != 6:
		errs.append("concat verts %s want 6" % verts.size())
	root.free()


static func _combine_indices(scale: Vector3) -> PackedInt32Array:
	var root := Node3D.new()
	var holder := Node3D.new()
	holder.scale = scale
	root.add_child(holder)
	var mi := _make_skinned_tri()
	holder.add_child(mi)
	var result: Array = Combiner.combine(root, [])
	var idx := PackedInt32Array()
	if not result.is_empty():
		var built = result[0]
		var mesh: ArrayMesh = built.mesh
		if mesh != null and mesh.get_surface_count() > 0:
			var arrays: Array = mesh.surface_get_arrays(0)
			idx = arrays[Mesh.ARRAY_INDEX]
	root.free()
	return idx


static func _make_skinned_tri() -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(
		[Vector3(0.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0), Vector3(0.0, 1.0, 0.0)]
	)
	arrays[Mesh.ARRAY_TANGENT] = PackedFloat32Array(
		[1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0]
	)
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var skin := Skin.new()
	skin.set_bind_count(1)
	skin.set_bind_name(0, "root")
	skin.set_bind_pose(0, Transform3D.IDENTITY)
	mi.skin = skin
	return mi
