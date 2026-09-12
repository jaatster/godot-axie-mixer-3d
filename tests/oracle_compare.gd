extends SceneTree
## Numeric parity gate against the Unity oracle (`tests/oracle/index.json`, produced by
## `tools/unity_export/AxieGltfExporter.cs`).
##
## For every fixture (genes/body/color, combined on/off) and every sample (rest + clip@time) it:
##   1. assembles the character with the Godot factory and puts it in the tree,
##   2. drives the same clip to the same time through AxiePlayable,
##   3. compares every Unity transform (bones, part joints, renderer nodes) by leaf name,
##   4. CPU-skins every MeshInstance3D and compares vertex positions (ordered for separate
##      renderers, as a sorted multiset for merged renderers).
##
## Usage:
##   godot --headless --path . -s tests/oracle_compare.gd [-- fixture_substring] [--verbose] [--direct]
## `--direct` bypasses AxiePlayable and writes the clip tracks straight into the skeleton.

const POS_TOL := 2.0e-3
const BASIS_TOL := 5.0e-3
const VERT_TOL := 3.0e-3

var _verbose := false
var _direct := false
var _filter := ""
var _failures := 0
var _checks := 0


var _started := false


## Runs from the first `_process` frame: nodes added during `_init`/`_initialize` are not inside the
## tree yet, and an off-tree Skeleton3D never re-dirties its global poses after the first update.
func _process(_delta: float) -> bool:
	if _started:
		return true
	_started = true
	for a in OS.get_cmdline_user_args():
		if a == "--verbose":
			_verbose = true
		elif a == "--direct":
			_direct = true
		elif not a.begins_with("--"):
			_filter = a
	var ok := _run()
	quit(0 if ok else 1)
	return true


func _run() -> bool:
	var index_path := "res://tests/oracle/index.json"
	var index: Variant = JSON.parse_string(FileAccess.get_file_as_string(index_path))
	if typeof(index) != TYPE_DICTIONARY:
		printerr("oracle index missing: ", index_path)
		return false
	var catalog := AxieCatalog.load_json("res://addons/axie_mixer_3d_assets/catalog.json")
	var factory := AxieFactory.new()
	factory.catalog = catalog
	AxieFactory.default_factory = factory
	AxieDefaults.factory = factory
	AxieWeaponAnims.register(catalog, factory)

	var fixtures: Array = index.get("fixtures", [])
	var t0 := Time.get_ticks_msec()
	for fx in fixtures:
		var name := str(fx.get("name", ""))
		var dir := str(fx.get("dir", name))
		if not _filter.is_empty() and not dir.contains(_filter):
			continue
		_check_fixture(factory, fx, "res://tests/oracle/%s" % dir)
	print("\n%d checks, %d failures (%.1fs)" % [_checks, _failures, (Time.get_ticks_msec() - t0) / 1000.0])
	return _failures == 0


func _check_fixture(factory: AxieFactory, fx: Dictionary, dir: String) -> void:
	var genes := str(fx.get("genes", ""))
	var combined := bool(fx.get("combined", false))
	var desc := AxieDescriptor.new()
	desc.body = AxieTypes.body_from_name(str(fx.get("body", "Normal")))
	desc.color_variant = int(fx.get("color_variant", 0))
	desc.clear_parts()
	for p in fx.get("parts", []):
		desc.parts.append(AxiePartDescriptor.from_dict(p))
	if not genes.is_empty():
		# Free gene-decoder parity check: Unity decoded these genes into the listed parts.
		var decoded := AxieDescriptor.from_genes(genes)
		_checks += 1
		if not decoded.equals(desc):
			_fail("%s: AxieDescriptor.from_genes disagrees with Unity (body %s/%s color %d/%d parts %s vs %s)" % [
				dir, decoded.body, desc.body, decoded.color_variant, desc.color_variant,
				_parts_str(decoded), _parts_str(desc)])
	var params := AxieInstantiationParams.new()
	params.combine_meshes = combined
	var character := factory.create_character(desc, params)
	if character == null or character.root == null:
		_fail("%s: factory returned no character" % dir)
		return
	get_root().add_child(character.root)
	var playable := character.playable
	var header := "%s (body=%s combined=%s)" % [dir.get_file(), AxieTypes.body_name(desc.body), combined]
	var worst := {"node": 0.0, "basis": 0.0, "vert": 0.0}
	var sample_files: Array = fx.get("samples", [])
	for sample_file in sample_files:
		var path := dir.path_join(str(sample_file))
		var sample: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(sample) != TYPE_DICTIONARY:
			_fail("%s: unreadable sample %s" % [dir, sample_file])
			continue
		var clip := str(sample.get("clip", ""))
		var time := float(sample.get("time", 0.0))
		if clip.is_empty():
			playable.stop()
			_reset_pose(character.root)
		elif _direct:
			var anim := character.get_anim_clip(clip)
			if anim == null:
				_fail("%s: no clip %s" % [dir, clip])
				continue
			_reset_pose(character.root)
			_apply_clip_direct(character.root, anim, time)
		else:
			var track := playable.play(clip, "", true)
			if track == null:
				_fail("%s: playable could not play %s" % [dir, clip])
				continue
			playable._tick(time)
		_force_update(character.root)
		var r := _compare_sample(character, sample, "%s/%s" % [dir.get_file(), sample_file], combined)
		worst["node"] = maxf(worst["node"], r["node"])
		worst["basis"] = maxf(worst["basis"], r["basis"])
		worst["vert"] = maxf(worst["vert"], r["vert"])
	print(
		"%-52s worst: node %.5f basis %.5f vert %.5f"
		% [header, worst["node"], worst["basis"], worst["vert"]]
	)
	character.dispose()


## Reference sampler: write the clip's bone tracks straight into the skeleton (no playable).
static func _apply_clip_direct(root: Node3D, anim: Animation, time: float) -> void:
	for i in anim.get_track_count():
		var path := anim.track_get_path(i)
		var bone := String(path.get_concatenated_subnames())
		if bone.is_empty():
			continue
		var node := root.get_node_or_null(NodePath(path.get_concatenated_names()))
		var skel := node as Skeleton3D
		if skel == null:
			for s in root.find_children("*", "Skeleton3D", true, false):
				skel = s
				break
		if skel == null:
			continue
		var b := skel.find_bone(bone)
		if b < 0:
			continue
		match anim.track_get_type(i):
			Animation.TYPE_POSITION_3D:
				skel.set_bone_pose_position(b, anim.position_track_interpolate(i, time))
			Animation.TYPE_ROTATION_3D:
				skel.set_bone_pose_rotation(b, anim.rotation_track_interpolate(i, time))
			Animation.TYPE_SCALE_3D:
				skel.set_bone_pose_scale(b, anim.scale_track_interpolate(i, time))


static func _parts_str(d: AxieDescriptor) -> String:
	var out := PackedStringArray()
	for p in d.parts:
		out.append("%s:%s%02d-S%d-L%d" % [AxieTypes.part_name(p.type), p.part_class, p.variant, p.skin, p.level])
	return ",".join(out)


func _reset_pose(root: Node) -> void:
	for s in root.find_children("*", "Skeleton3D", true, false):
		var skel := s as Skeleton3D
		for b in skel.get_bone_count():
			skel.reset_bone_pose(b)


func _force_update(root: Node) -> void:
	for s in root.find_children("*", "Skeleton3D", true, false):
		(s as Skeleton3D).force_update_all_bone_transforms()


## {node, basis, vert} max errors for this sample.
func _compare_sample(character: AxieCharacter3D, sample: Dictionary, label: String, combined: bool) -> Dictionary:
	var root: Node3D = character.root
	var godot_nodes := _collect_godot_transforms(root)
	var out := {"node": 0.0, "basis": 0.0, "vert": 0.0}
	var missing: Array[String] = []
	var bad: Array[String] = []
	var unity_paths := {}
	for n in sample.get("nodes", []):
		unity_paths[str(n.get("path", ""))] = true
	for n in sample.get("nodes", []):
		var upath := str(n.get("path", ""))
		if upath.is_empty():
			continue
		var leaf := upath.get_file()
		var key := _unity_path(upath)
		if leaf == "SM_Mesh" or leaf == "Model" or upath.get_base_dir().get_file() == "SM_Mesh":
			continue # renderer nodes are covered by the vertex comparison
		if not godot_nodes.has(key) and combined:
			# Absorbed part joints hang directly off the attach bone; Unity keeps the part root
			# GameObject in between (`Root_X_JNT/<part>/<joint>` → `Root_X_JNT/<joint>`).
			key = _drop_part_segment(key)
			if not godot_nodes.has(key) and _is_destroyed_renderer(upath, unity_paths):
				continue
		if not godot_nodes.has(key):
			missing.append(upath)
			continue
		var expected := _matrix_to_transform(n.get("matrix", []))
		var got: Transform3D = godot_nodes[key]
		var pe := got.origin.distance_to(expected.origin)
		var be := _basis_error(got.basis, expected.basis)
		out["node"] = maxf(out["node"], pe)
		out["basis"] = maxf(out["basis"], be)
		if pe > POS_TOL or be > BASIS_TOL:
			bad.append("%s pos %.4f basis %.4f" % [upath, pe, be])
	_checks += 1
	if not missing.is_empty():
		_fail("%s: %d Unity transforms have no Godot counterpart, e.g. %s" % [label, missing.size(), missing.slice(0, 3)])
	if not bad.is_empty():
		_fail("%s: %d transforms off tolerance, e.g. %s" % [label, bad.size(), bad.slice(0, 4)])

	var godot_meshes := _skin_all(root)
	var renderers: Array = sample.get("renderers", [])
	var merged_expected := PackedVector3Array()
	var merged_got := PackedVector3Array()
	var any_merged := false
	for r in renderers:
		var rpath := str(r.get("path", ""))
		var rname := rpath.get_file()
		var verts: Array = r.get("vertices", [])
		var expected := PackedVector3Array()
		expected.resize(verts.size() / 3)
		for i in expected.size():
			expected[i] = Vector3(float(verts[i * 3]), float(verts[i * 3 + 1]), float(verts[i * 3 + 2]))
		if rname.begins_with("AxieMergedRenderer"):
			any_merged = true
			merged_expected.append_array(expected)
			continue
		if not godot_meshes.has(rname):
			_fail("%s: renderer %s not found in Godot tree" % [label, rname])
			continue
		var got: PackedVector3Array = godot_meshes[rname]
		if got.size() != expected.size():
			_fail("%s: %s vertex count %d != %d" % [label, rname, got.size(), expected.size()])
			continue
		var worst := 0.0
		var worst_i := -1
		for i in got.size():
			var d := got[i].distance_to(expected[i])
			if d > worst:
				worst = d
				worst_i = i
		out["vert"] = maxf(out["vert"], worst)
		_checks += 1
		if worst > VERT_TOL:
			_fail("%s: %s max vertex error %.4f at #%d (got %s expected %s)" % [label, rname, worst, worst_i, got[worst_i], expected[worst_i]])
	if any_merged:
		for k in godot_meshes.keys():
			merged_got.append_array(godot_meshes[k])
		_checks += 1
		if merged_got.size() != merged_expected.size():
			_fail("%s: merged vertex count %d != %d" % [label, merged_got.size(), merged_expected.size()])
		else:
			var worst := _multiset_error(merged_got, merged_expected)
			out["vert"] = maxf(out["vert"], worst)
			if worst > VERT_TOL:
				_fail("%s: merged renderers max (sorted) vertex error %.4f" % [label, worst])
	return out


## Unity-style transform path -> root-relative Transform3D, computed analytically from bone poses.
## Godot-only levels (scene root, the glb "Model" wrapper, Skeleton3D, BoneAttachment3D) are folded
## away so paths read like Unity's: `JointBase_Grp/Root_Character/Root_Horn_L_JNT/<part>/<joints…>`.
func _collect_godot_transforms(root: Node3D) -> Dictionary:
	var out := {}
	_walk(root, root, Transform3D.IDENTITY, "", out)
	return out


func _walk(node: Node, root: Node3D, parent_xf: Transform3D, prefix: String, out: Dictionary) -> void:
	var xf := parent_xf
	var path := prefix
	if node is Skeleton3D:
		var skel := node as Skeleton3D
		xf = parent_xf * skel.transform
		var bone_paths := PackedStringArray()
		bone_paths.resize(skel.get_bone_count())
		for b in skel.get_bone_count():
			var parent := skel.get_bone_parent(b)
			var bname := skel.get_bone_name(b)
			# Absorbed part bones carry a "<part>__" prefix when they collided with body bone names.
			var sep := bname.find("__")
			if sep > 0:
				bname = bname.substr(sep + 2)
			var bpath: String = (bone_paths[parent] + "/" + bname) if parent >= 0 else _join(prefix, bname)
			bone_paths[b] = bpath
			out[bpath] = xf * skel.get_bone_global_pose(b)
		for c in skel.get_children():
			if c is BoneAttachment3D:
				var att := c as BoneAttachment3D
				var idx := att.bone_idx if att.bone_idx >= 0 else skel.find_bone(att.bone_name)
				var bone_xf := xf * skel.get_bone_global_pose(idx) if idx >= 0 else xf
				var bone_path: String = bone_paths[idx] if idx >= 0 else prefix
				for cc in att.get_children():
					_walk(cc, root, bone_xf, bone_path, out)
			elif c is MeshInstance3D:
				# Merged renderers sit at identity next to the bones (Unity: children of the root).
				out[_join(prefix, str(c.name))] = xf * (c as Node3D).transform
			else:
				_walk(c, root, xf, prefix, out)
		return
	if node is Node3D and node != root:
		xf = parent_xf * (node as Node3D).transform
		if node.name != "Model":
			path = _join(prefix, str(node.name))
			out[path] = xf
	for c in node.get_children():
		_walk(c, root, xf, path, out)


static func _join(prefix: String, leaf: String) -> String:
	return leaf if prefix.is_empty() else prefix + "/" + leaf


static func _unity_path(p: String) -> String:
	return p.replace("(Clone)", "")


## Unity's combiner Destroy()s source renderers deferred, so the oracle still lists them as leaf
## transforms (some prefabs keep the renderer directly under the part root, without SM_Mesh).
static func _is_destroyed_renderer(upath: String, unity_paths: Dictionary) -> bool:
	var leaf := upath.get_file()
	if leaf.ends_with("_JNT") or leaf.ends_with("_Scale") or leaf.ends_with("_Offsets"):
		return false
	var prefix := upath + "/"
	for p in unity_paths:
		if str(p).begins_with(prefix):
			return false
	return true


static func _drop_part_segment(p: String) -> String:
	var segs := p.split("/")
	for i in range(segs.size() - 1):
		if segs[i].begins_with("Root_") and segs[i].ends_with("_JNT") and i + 1 < segs.size():
			segs.remove_at(i + 1)
			return "/".join(segs)
	return p


## renderer leaf name -> skinned vertex positions (root-relative).
func _skin_all(root: Node3D) -> Dictionary:
	var out := {}
	var xfs := _collect_skeleton_transforms(root)
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		var skel := m.get_node_or_null(m.skeleton) as Skeleton3D
		var skel_xf: Transform3D = xfs.get(skel, Transform3D.IDENTITY) if skel else Transform3D.IDENTITY
		out[str(m.name)] = _skin_mesh(m, skel, skel_xf)
	return out


func _collect_skeleton_transforms(root: Node3D) -> Dictionary:
	var all := {}
	_walk_skeletons(root, root, Transform3D.IDENTITY, all)
	return all


func _walk_skeletons(node: Node, root: Node3D, parent_xf: Transform3D, out: Dictionary) -> void:
	var xf := parent_xf
	if node is Skeleton3D:
		var skel := node as Skeleton3D
		xf = parent_xf * skel.transform
		out[skel] = xf
		for c in skel.get_children():
			if c is BoneAttachment3D:
				var att := c as BoneAttachment3D
				var idx := att.bone_idx if att.bone_idx >= 0 else skel.find_bone(att.bone_name)
				var bone_xf := xf * skel.get_bone_global_pose(idx) if idx >= 0 else xf
				for cc in att.get_children():
					_walk_skeletons(cc, root, bone_xf, out)
			else:
				_walk_skeletons(c, root, xf, out)
		return
	if node is Node3D and node != root:
		xf = parent_xf * (node as Node3D).transform
	for c in node.get_children():
		_walk_skeletons(c, root, xf, out)


static func _skin_mesh(mi: MeshInstance3D, skel: Skeleton3D, skel_xf: Transform3D) -> PackedVector3Array:
	var result := PackedVector3Array()
	var skin := mi.skin
	var bind_mats: Array[Transform3D] = []
	if skel != null and skin != null:
		for i in skin.get_bind_count():
			var b := skin.get_bind_bone(i)
			if b < 0:
				b = skel.find_bone(skin.get_bind_name(i))
			var pose := skel.get_bone_global_pose(b) if b >= 0 else Transform3D.IDENTITY
			bind_mats.append(skel_xf * pose * skin.get_bind_pose(i))
	for s in mi.mesh.get_surface_count():
		var arrays := mi.mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: Variant = arrays[Mesh.ARRAY_BONES]
		var weights: Variant = arrays[Mesh.ARRAY_WEIGHTS]
		if bind_mats.is_empty() or not (bones is PackedInt32Array) or not (weights is PackedFloat32Array):
			for p in v:
				result.append(skel_xf * mi.transform * p)
			continue
		var bi: PackedInt32Array = bones
		var bw: PackedFloat32Array = weights
		var stride := 8 if bi.size() == v.size() * 8 else 4
		for i in v.size():
			var acc := Vector3.ZERO
			var wsum := 0.0
			for k in stride:
				var w := bw[i * stride + k]
				if w <= 0.0:
					continue
				var idx := bi[i * stride + k]
				if idx < 0 or idx >= bind_mats.size():
					continue
				acc += (bind_mats[idx] * v[i]) * w
				wsum += w
			if wsum <= 0.0:
				acc = skel_xf * v[i]
			result.append(acc)
	return result


## Order-independent vertex comparison: max over both sets of the distance to the nearest vertex
## of the other set (hash grid, cell = 4*VERT_TOL).
static func _multiset_error(a: PackedVector3Array, b: PackedVector3Array) -> float:
	var cell := VERT_TOL * 4.0
	var grid_b := _grid(b, cell)
	var grid_a := _grid(a, cell)
	var worst := 0.0
	for p in a:
		worst = maxf(worst, _nearest(p, grid_b, b, cell))
	for p in b:
		worst = maxf(worst, _nearest(p, grid_a, a, cell))
	return worst


static func _grid(pts: PackedVector3Array, cell: float) -> Dictionary:
	var g := {}
	for i in pts.size():
		var k := Vector3i((pts[i] / cell).floor())
		if not g.has(k):
			g[k] = []
		(g[k] as Array).append(i)
	return g


static func _nearest(p: Vector3, grid: Dictionary, pts: PackedVector3Array, cell: float) -> float:
	var c := Vector3i((p / cell).floor())
	var best := INF
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				var k := c + Vector3i(dx, dy, dz)
				if not grid.has(k):
					continue
				for i in grid[k]:
					best = minf(best, p.distance_to(pts[i]))
	return best


static func _matrix_to_transform(m: Array) -> Transform3D:
	if m.size() < 16:
		return Transform3D.IDENTITY
	# column-major 4x4
	var x := Vector3(float(m[0]), float(m[1]), float(m[2]))
	var y := Vector3(float(m[4]), float(m[5]), float(m[6]))
	var z := Vector3(float(m[8]), float(m[9]), float(m[10]))
	var o := Vector3(float(m[12]), float(m[13]), float(m[14]))
	return Transform3D(Basis(x, y, z), o)


static func _basis_error(a: Basis, b: Basis) -> float:
	var e := 0.0
	for i in 3:
		e = maxf(e, (a[i] - b[i]).length())
	return e


func _fail(msg: String) -> void:
	_failures += 1
	printerr("FAIL ", msg)
