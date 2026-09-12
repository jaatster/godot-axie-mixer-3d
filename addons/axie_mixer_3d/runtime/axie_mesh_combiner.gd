class_name AxieMeshCombiner
extends Object
## Port of Unity AxieMeshCombiner. Groups outline-excluded vs others, unions bones, remaps weights.

const EXCLUDED_GROUP_KEY := -2147483648


class CombinedRenderer:
	var renderer: MeshInstance3D
	var mesh: ArrayMesh
	var skin: Skin
	var is_outline_excluded: bool


## Godot ArrayMesh cannot share a vertex buffer across surfaces (Unity Mesh can).
## One bucket per unique material; verts live only on the surface that indexes them.
class _SurfaceBucket:
	var material: Material
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var tangents := PackedFloat32Array()
	var colors := PackedColorArray()
	var uv0 := PackedVector2Array()
	var uv1 := PackedVector2Array()
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	var tris := PackedInt32Array()
	var any_normals := false
	var any_tangents := false
	var any_colors := false
	var any_uv0 := false
	var any_uv1 := false


static func combine(root: Node3D, outline_excluded_parts: Array) -> Array:
	var result: Array = []
	# Resolve the excluded renderers first: absorbing re-parents them under the body skeleton.
	var excluded: Dictionary = {}
	for part in outline_excluded_parts:
		if part == null:
			continue
		for smr in _collect_skinned(part):
			excluded[smr] = true
	var body_skeleton := _find_first_skeleton(root)
	# Resolve Unity's `rootBone` pick before absorbing (it needs the attach-point structure).
	var unity_first: MeshInstance3D = null
	if body_skeleton != null:
		unity_first = _unity_first_skinned(root, body_skeleton)
		absorb_part_skeletons(root, body_skeleton)
	var sources := _collect_skinned(root)
	if sources.is_empty():
		return result
	# Unity: every merged renderer gets `rootBone` of the first source SkinnedMeshRenderer. Godot has
	# no root bone on MeshInstance3D; record the bone name for AxieMysticRootTracker (Mystic_Final
	# positionOS space). Skin bind 0 = Unity bones[0] = rootBone on every mixer asset.
	var root_bone_name := ""
	if body_skeleton != null and is_instance_valid(unity_first) and unity_first.skin != null \
			and unity_first.skin.get_bind_count() > 0:
		var b := unity_first.skin.get_bind_bone(0)
		if b < 0:
			b = body_skeleton.find_bone(unity_first.skin.get_bind_name(0))
		if b >= 0:
			root_bone_name = body_skeleton.get_bone_name(b)

	var groups: Dictionary = {}
	var group_order: Array[int] = []
	for smr in sources:
		if smr.mesh == null:
			continue
		var key := EXCLUDED_GROUP_KEY if excluded.has(smr) else smr.layers
		if not groups.has(key):
			groups[key] = []
			group_order.append(key)
		groups[key].append(smr)

	for key in group_order:
		var is_excluded := key == EXCLUDED_GROUP_KEY
		var layer := 1 if is_excluded else key
		var built := _try_build_group_mesh(groups[key], body_skeleton)
		if built.is_empty():
			continue
		var go := MeshInstance3D.new()
		# Unity names by layer index; Godot layers are a mask, so use the lowest set bit (default mask 1 → 0).
		go.name = "AxieMergedRenderer_Excluded" if is_excluded else "AxieMergedRenderer_%d" % _layer_index(layer)
		go.layers = layer
		go.mesh = built["mesh"]
		go.skin = built["skin"]
		go.skeleton = NodePath("..")
		if not root_bone_name.is_empty():
			go.set_meta("axie_root_bone", root_bone_name)
		if body_skeleton != null:
			body_skeleton.add_child(go)
		else:
			root.add_child(go)
		var cr := CombinedRenderer.new()
		cr.renderer = go
		cr.mesh = built["mesh"]
		cr.skin = built["skin"]
		cr.is_outline_excluded = is_excluded
		result.append(cr)

	# Unity Destroy/DestroyImmediate: sources are gone when Combine returns.
	# queue_free() would leave them until idle-frame, so combine-on still draws
	# the unmerged parts and a harness that never pumps idle would pass anyway.
	for smr in sources:
		var parent := smr.get_parent()
		if parent:
			parent.remove_child(smr)
		smr.free()
	return result


static func _layer_index(mask: int) -> int:
	if mask <= 0:
		return 0
	var i := 0
	while (mask & (1 << i)) == 0 and i < 31:
		i += 1
	return i


## Unity `merged.rootBone` = rootBone of the first SkinnedMeshRenderer in GetComponentsInChildren
## order (hierarchy depth-first). Every body prefab lists `JointBase_Grp` before its own mesh, and a
## part is appended as the last child of its attach joint, so the first renderer is the part on the
## first attach joint in joint depth-first order (child joints before attachments) — normally the
## Back — and only a part-less axie falls back to the body mesh. Only Mystic_Final observes this
## (positionOS.y), but it observes it visibly, so mirror the pick.
static func _unity_first_skinned(root: Node3D, body: Skeleton3D) -> MeshInstance3D:
	var attachments: Dictionary = {} # bone index -> [BoneAttachment3D] in child order
	for c in body.get_children():
		if c is BoneAttachment3D:
			var ba := c as BoneAttachment3D
			var b := ba.bone_idx
			if b < 0:
				b = body.find_bone(ba.bone_name)
			if b < 0:
				continue
			if not attachments.has(b):
				attachments[b] = []
			attachments[b].append(ba)
	for b in body.get_bone_count():
		if body.get_bone_parent(b) < 0:
			var found := _first_skinned_under_bone(body, b, attachments)
			if found != null:
				return found
	var all := _collect_skinned(root)
	return all[0] if not all.is_empty() else null


static func _first_skinned_under_bone(body: Skeleton3D, bone: int, attachments: Dictionary) -> MeshInstance3D:
	for c in body.get_bone_children(bone):
		var found := _first_skinned_under_bone(body, c, attachments)
		if found != null:
			return found
	for ba in attachments.get(bone, []):
		for child in (ba as Node).get_children():
			var skinned := _collect_skinned(child)
			if not skinned.is_empty():
				return skinned[0]
	return null


static func _find_first_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var s := _find_first_skeleton(c)
		if s != null:
			return s
	return null


## Unity keeps one bone Transform hierarchy for the whole character: a part's joints are plain
## children of the body's `Root_{rig}_JNT`. Godot skins one MeshInstance3D to one Skeleton3D, so
## before merging we graft every part Skeleton3D (parented under a BoneAttachment3D of the body
## skeleton) into the body skeleton: bones are appended with the same local rests, the top joints
## get the attach bone as parent (with the node offsets between attachment and part skeleton folded
## in), skins are re-pointed by name, and the part skeleton is freed.
static func absorb_part_skeletons(root: Node3D, body: Skeleton3D) -> void:
	var part_skeletons: Array = []
	for n in root.find_children("*", "Skeleton3D", true, false):
		if n != body and n is Skeleton3D:
			part_skeletons.append(n)
	for p_node in part_skeletons:
		var p := p_node as Skeleton3D
		if not is_instance_valid(p):
			continue
		var attach: BoneAttachment3D = null
		var offset := Transform3D.IDENTITY
		var cur: Node = p
		while cur != null and cur != body:
			if cur is BoneAttachment3D and cur.get_parent() == body:
				attach = cur
				break
			if cur is Node3D:
				offset = (cur as Node3D).transform * offset
			cur = cur.get_parent()
		if attach == null:
			continue
		var attach_bone := attach.bone_idx
		if attach_bone < 0:
			attach_bone = body.find_bone(attach.bone_name)
		if attach_bone < 0:
			continue
		var part_name := attach.name
		var owner_part: Node = p
		while owner_part != null and owner_part.get_parent() != attach:
			owner_part = owner_part.get_parent()
		if owner_part != null:
			part_name = owner_part.name

		var map: Dictionary = {}
		var count := p.get_bone_count()
		var remaining := count
		var guard := 0
		while remaining > 0 and guard <= count:
			guard += 1
			for b in count:
				if map.has(b):
					continue
				var parent := p.get_bone_parent(b)
				if parent >= 0 and not map.has(parent):
					continue
				var bone_name := p.get_bone_name(b)
				var new_name := bone_name
				if body.find_bone(new_name) >= 0:
					new_name = "%s__%s" % [part_name, bone_name]
					var k := 2
					while body.find_bone(new_name) >= 0:
						new_name = "%s__%s_%d" % [part_name, bone_name, k]
						k += 1
				var nb := body.add_bone(new_name)
				var rest := p.get_bone_rest(b)
				if parent < 0:
					body.set_bone_parent(nb, attach_bone)
					rest = offset * rest
				else:
					body.set_bone_parent(nb, map[parent])
				body.set_bone_rest(nb, rest)
				body.set_bone_pose_position(nb, rest.origin)
				body.set_bone_pose_rotation(nb, rest.basis.get_rotation_quaternion())
				body.set_bone_pose_scale(nb, rest.basis.get_scale())
				map[b] = nb
				remaining -= 1

		for mi in _skinned_meshes_of(p, root):
			var src_skin: Skin = mi.skin
			var new_skin := Skin.new()
			var binds := src_skin.get_bind_count() if src_skin else 0
			new_skin.set_bind_count(binds)
			for i in binds:
				var src_bone := src_skin.get_bind_bone(i)
				var src_name := str(src_skin.get_bind_name(i))
				if src_bone < 0 and not src_name.is_empty():
					src_bone = p.find_bone(src_name)
				var target: int = map.get(src_bone, -1)
				if target < 0:
					target = attach_bone
				new_skin.set_bind_bone(i, target)
				new_skin.set_bind_name(i, body.get_bone_name(target))
				new_skin.set_bind_pose(i, src_skin.get_bind_pose(i))
			var parent := mi.get_parent()
			if parent:
				parent.remove_child(mi)
			# The part scene's owner would point outside the body's subtree after the reparent.
			mi.owner = null
			body.add_child(mi)
			mi.skeleton = NodePath("..")
			mi.skin = new_skin
			# Skinned vertices live in skeleton space (glTF / Unity SMR semantics).
			mi.transform = Transform3D.IDENTITY
			mi.set_meta(&"axie_part_name", part_name)
		if p.get_parent():
			p.get_parent().remove_child(p)
		p.free()


static func _skinned_meshes_of(skel: Skeleton3D, root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for mi in _collect_skinned(root):
		var target := mi.get_node_or_null(mi.skeleton)
		if target == skel:
			out.append(mi)
	return out


static func _collect_skinned(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var mi := n as MeshInstance3D
		if mi.skin != null or _mesh_has_bones(mi.mesh):
			out.append(mi)
	for c in n.get_children():
		out.append_array(_collect_skinned(c))
	return out


static func _mesh_has_bones(mesh: Mesh) -> bool:
	if mesh == null or mesh.get_surface_count() == 0:
		return false
	var fmt: int = mesh.surface_get_format(0)
	return (fmt & Mesh.ARRAY_FORMAT_BONES) != 0


static func _try_build_group_mesh(group: Array, body_skeleton: Skeleton3D = null) -> Dictionary:
	var bone_index: Dictionary = {}
	var bone_names: PackedStringArray = []
	var bindposes: Array[Transform3D] = []

	var material_to_submesh: Dictionary = {}
	var buckets: Array = []
	var group_any_uv1 := false

	for smr in group:
		var src_mesh: Mesh = smr.mesh
		if src_mesh == null:
			continue
		var flip: bool = affine_world_transform(smr).basis.determinant() < 0.0
		var src_skin: Skin = smr.skin
		var remap: PackedInt32Array = PackedInt32Array()
		var src_bone_count := src_skin.get_bind_count() if src_skin else 0
		remap.resize(maxi(src_bone_count, 1))
		for i in src_bone_count:
			var bname := src_skin.get_bind_name(i)
			if str(bname).is_empty() and body_skeleton != null:
				var bb := src_skin.get_bind_bone(i)
				if bb >= 0 and bb < body_skeleton.get_bone_count():
					bname = StringName(body_skeleton.get_bone_name(bb))
			if str(bname).is_empty():
				remap[i] = 0
				continue
			if not bone_index.has(bname):
				var unified: int = bone_names.size()
				bone_index[bname] = unified
				bone_names.append(str(bname))
				bindposes.append(src_skin.get_bind_pose(i))
			remap[i] = bone_index[bname]

		for surf in src_mesh.get_surface_count():
			# Unity CombineMeshes uses renderer.sharedMaterials (overrides win).
			# Resolve material before copying streams so a null slot cannot inflate
			# another surface's vertex buffer.
			var material: Material = null
			if smr.get_surface_override_material_count() > surf:
				material = smr.get_surface_override_material(surf)
			if material == null:
				material = src_mesh.surface_get_material(surf)
			if material == null:
				continue
			var arrays := src_mesh.surface_get_arrays(surf)
			var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var count := v.size()
			if count == 0:
				continue
			if not material_to_submesh.has(material):
				var fresh := _SurfaceBucket.new()
				fresh.material = material
				material_to_submesh[material] = buckets.size()
				buckets.append(fresh)
			var bucket: _SurfaceBucket = buckets[material_to_submesh[material]]
			var vertex_offset := bucket.verts.size()
			bucket.verts.append_array(v)

			bucket.any_normals = (
				_append_or_pad_v3(bucket.normals, arrays[Mesh.ARRAY_NORMAL], count, Vector3.UP)
				or bucket.any_normals
			)
			var src_tan: Variant = arrays[Mesh.ARRAY_TANGENT]
			if src_tan is PackedFloat32Array and (src_tan as PackedFloat32Array).size() == count * 4:
				var tan_arr: PackedFloat32Array = src_tan
				if flip:
					for t in count:
						bucket.tangents.append(tan_arr[t * 4 + 0])
						bucket.tangents.append(tan_arr[t * 4 + 1])
						bucket.tangents.append(tan_arr[t * 4 + 2])
						bucket.tangents.append(-tan_arr[t * 4 + 3])
				else:
					bucket.tangents.append_array(tan_arr)
				bucket.any_tangents = true
			else:
				for _t in count:
					bucket.tangents.append(1.0)
					bucket.tangents.append(0.0)
					bucket.tangents.append(0.0)
					bucket.tangents.append(-1.0 if not flip else 1.0)

			bucket.any_colors = (
				_append_or_pad_color(bucket.colors, arrays[Mesh.ARRAY_COLOR], count, Color.WHITE)
				or bucket.any_colors
			)
			bucket.any_uv0 = (
				_append_or_pad_v2(bucket.uv0, arrays[Mesh.ARRAY_TEX_UV], count, Vector2.ZERO)
				or bucket.any_uv0
			)
			# Missing uv1 is not (0,0): Unity mystic gold gate treats a missing channel
			# differently from a fabricated zero. Pad with UV0 so Back/Eye/Mouth keep gold.
			var src_uv2: Variant = arrays[Mesh.ARRAY_TEX_UV2]
			if src_uv2 is PackedVector2Array and (src_uv2 as PackedVector2Array).size() == count:
				bucket.any_uv1 = (
					_append_or_pad_v2(bucket.uv1, src_uv2, count, Vector2.ZERO) or true
				)
				group_any_uv1 = true
			else:
				# Pad UV0 so a later UV2 source in this same material bucket stays
				# contiguous. Do not set any_uv1: UV0-only parts must not publish
				# a fabricated UV2 unless some source in the group actually had it.
				_append_or_pad_v2(bucket.uv1, arrays[Mesh.ARRAY_TEX_UV], count, Vector2.ZERO)

			_append_remapped_weights(bucket, arrays, count, remap)

			var idx := PackedInt32Array()
			if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array:
				idx = arrays[Mesh.ARRAY_INDEX]
			if idx.is_empty():
				idx = PackedInt32Array()
				idx.resize(count)
				for t in count:
					idx[t] = t
			if flip:
				var t := 0
				while t + 2 < idx.size():
					bucket.tris.append(idx[t] + vertex_offset)
					bucket.tris.append(idx[t + 2] + vertex_offset)
					bucket.tris.append(idx[t + 1] + vertex_offset)
					t += 3
			else:
				for tri in idx:
					bucket.tris.append(tri + vertex_offset)

	if buckets.is_empty():
		return {}

	var mesh := ArrayMesh.new()
	mesh.resource_name = "AxieCombinedMesh"
	for bucket: _SurfaceBucket in buckets:
		if bucket.verts.is_empty():
			continue
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = bucket.verts
		if bucket.any_normals:
			arrays[Mesh.ARRAY_NORMAL] = bucket.normals
		if bucket.any_tangents:
			arrays[Mesh.ARRAY_TANGENT] = bucket.tangents
		if bucket.any_colors:
			arrays[Mesh.ARRAY_COLOR] = bucket.colors
		if bucket.any_uv0:
			arrays[Mesh.ARRAY_TEX_UV] = bucket.uv0
		# Publish UV2 on every surface if any source in the group had it, matching
		# Unity's one-mesh channel layout. Godot still stores compact per-surface
		# verts; the padded uv1 copy is only the verts this surface actually uses.
		if group_any_uv1:
			arrays[Mesh.ARRAY_TEX_UV2] = bucket.uv1
		arrays[Mesh.ARRAY_BONES] = bucket.bones
		arrays[Mesh.ARRAY_WEIGHTS] = bucket.weights
		arrays[Mesh.ARRAY_INDEX] = bucket.tris
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, bucket.material)

	if mesh.get_surface_count() == 0:
		return {}

	var skin := Skin.new()
	skin.set_bind_count(bone_names.size())
	for i in bone_names.size():
		skin.set_bind_name(i, bone_names[i])
		skin.set_bind_pose(i, bindposes[i] if i < bindposes.size() else Transform3D.IDENTITY)

	return {"mesh": mesh, "skin": skin}


static func _append_remapped_weights(
	bucket: _SurfaceBucket, arrays: Array, count: int, remap: PackedInt32Array
) -> void:
	var src_bones := PackedInt32Array()
	if arrays[Mesh.ARRAY_BONES] is PackedInt32Array:
		src_bones = arrays[Mesh.ARRAY_BONES]
	var src_weights := PackedFloat32Array()
	if arrays[Mesh.ARRAY_WEIGHTS] is PackedFloat32Array:
		src_weights = arrays[Mesh.ARRAY_WEIGHTS]
	var bw := 4
	if src_bones.size() == count * 8:
		bw = 8
	var boff := bucket.bones.size()
	bucket.bones.resize(boff + count * 4)
	bucket.weights.resize(boff + count * 4)
	var remap_size := remap.size()
	var has_weights := src_weights.size() > 0
	for vi in count:
		var sbase := vi * bw
		var dbase := boff + vi * 4
		for k in 4:
			var bi := 0
			var w := 0.0
			if src_bones.size() >= sbase + bw:
				bi = src_bones[sbase + k]
				if src_weights.size() >= sbase + bw:
					w = src_weights[sbase + k]
			if remap_size > 0:
				bi = remap[clampi(bi, 0, remap_size - 1)]
			bucket.bones[dbase + k] = bi
			bucket.weights[dbase + k] = w if has_weights else (1.0 if k == 0 else 0.0)


## Unity localToWorldMatrix analog. Walks `.transform` so combine works off-tree.
static func affine_world_transform(n: Node3D) -> Transform3D:
	if n == null:
		return Transform3D.IDENTITY
	var xform := n.transform
	if n.top_level:
		return xform
	var cur: Node = n.get_parent()
	while cur is Node3D:
		var p := cur as Node3D
		xform = p.transform * xform
		if p.top_level:
			break
		cur = p.get_parent()
	return xform


static func _append_or_pad_v3(dst: PackedVector3Array, src, count: int, pad: Vector3) -> bool:
	if src is PackedVector3Array and src.size() == count:
		dst.append_array(src)
		return true
	for _i in count:
		dst.append(pad)
	return false


static func _append_or_pad_v2(dst: PackedVector2Array, src, count: int, pad: Vector2) -> bool:
	if src is PackedVector2Array and src.size() == count:
		dst.append_array(src)
		return true
	for _i in count:
		dst.append(pad)
	return false


static func _append_or_pad_color(dst: PackedColorArray, src, count: int, pad: Color) -> bool:
	if src is PackedColorArray and src.size() == count:
		dst.append_array(src)
		return true
	for _i in count:
		dst.append(pad)
	return false
