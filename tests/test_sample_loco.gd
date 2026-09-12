extends SceneTree
## Sample pack Idle/Walk must move, not explode, extras stay authored rest.
## Headless: godot --headless --path . -s tests/test_sample_loco.gd

const Initializer := preload("res://addons/axie_mixer_3d/runtime/axie_mixer_initializer.gd")
const Character := preload("res://addons/axie_mixer_3d/runtime/axie_character_3d.gd")
const Params := preload("res://addons/axie_mixer_3d/core/axie_instantiation_params.gd")
const PACK := "res://tests/goldens/sample_axies.json"
const MAX_EXTENT_FRAC := 0.40


func _init() -> void:
	var errs: Array = run(self)
	if errs.is_empty():
		print("ok  sample_loco")
		quit(0)
	else:
		for e in errs:
			print("FAIL sample_loco: %s" % e)
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
	var n := 0
	for row in (parsed as Dictionary).get("ids", []):
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var id := str(row.get("id", ""))
		var genes := str(row.get("genes", ""))
		if bool(row.get("skip", false)) or genes.length() < 40:
			continue
		errs.append_array(_check_id(tree, id, genes))
		n += 1
	if n != 9:
		errs.append("loco n=%s expected 9" % n)
	boot.queue_free()
	return errs


static func _check_id(tree: SceneTree, id: String, genes: String) -> Array:
	var errs: Array = []
	var params = Params.new()
	params.combine_meshes = true
	var ch = Character.from_genes(genes, params)
	if ch == null or ch.root == null:
		errs.append("%s from_genes null" % id)
		return errs
	tree.root.add_child(ch.root)
	var skel := _find_skel(ch.root)
	if skel == null or ch.playable == null:
		errs.append("%s missing skel/playable" % id)
		ch.dispose()
		return errs
	var rest := _snap(skel)
	var rest_ext := _extent(skel)
	for row in [["Idle", 0.20], ["Walk", 0.25]]:
		var clip_name := str(row[0])
		var t := float(row[1])
		ch.playable.play(clip_name, "", true)
		ch.playable.call("_tick", t)
		var moved := _delta(skel, rest)
		if moved < 1:
			errs.append("%s %s did not move bones" % [id, clip_name])
		elif moved >= int(ceil(skel.get_bone_count() * 0.95)):
			errs.append("%s %s moved almost all bones (%s)" % [id, clip_name, moved])
		var neg := _neg_scales(skel)
		if neg > 0:
			errs.append("%s %s negative pose scales %s" % [id, clip_name, neg])
		var extras := _extra_drift(skel, rest, ch.get_anim_clip(clip_name))
		if extras > 0:
			errs.append("%s %s extra joints left authored rest n=%s" % [id, clip_name, extras])
		var ext := _extent(skel)
		if rest_ext > 0.01 and absf(ext - rest_ext) / rest_ext > MAX_EXTENT_FRAC:
			errs.append("%s %s extent %.3f vs rest %.3f" % [id, clip_name, ext, rest_ext])
	ch.dispose()
	return errs


static func _extra_drift(skel: Skeleton3D, rest: Array, clip: Animation) -> int:
	var tracked := _tracked(clip)
	var n := 0
	for i in skel.get_bone_count():
		if tracked.has(skel.get_bone_name(i)) or i >= rest.size():
			continue
		var pose := skel.get_bone_pose(i)
		var r: Transform3D = rest[i]
		if pose.origin.distance_to(r.origin) > 0.0005:
			n += 1
			continue
		if pose.basis.get_scale().distance_to(r.basis.get_scale()) > 0.001:
			n += 1
	return n


static func _tracked(clip: Animation) -> Dictionary:
	var out := {}
	if clip == null:
		return out
	for i in clip.get_track_count():
		var path := clip.track_get_path(i)
		var bone := String(path.get_concatenated_subnames())
		if bone.is_empty():
			bone = String(path).get_file()
		if not bone.is_empty():
			out[bone] = true
	return out


static func _neg_scales(skel: Skeleton3D) -> int:
	var n := 0
	for i in skel.get_bone_count():
		var s := skel.get_bone_pose_scale(i)
		if s.x < 0.0 or s.y < 0.0 or s.z < 0.0:
			n += 1
	return n


static func _extent(skel: Skeleton3D) -> float:
	var m := 0.0
	for i in skel.get_bone_count():
		m = maxf(m, _composed(skel, i).origin.length())
	return m


static func _composed(skel: Skeleton3D, bone: int) -> Transform3D:
	var chain: Array[int] = []
	var cur := bone
	var guard := 0
	while cur >= 0 and guard < 64:
		chain.append(cur)
		cur = skel.get_bone_parent(cur)
		guard += 1
	var xf := Transform3D.IDENTITY
	var i := chain.size() - 1
	while i >= 0:
		xf *= skel.get_bone_pose(chain[i])
		i -= 1
	return xf


static func _snap(skel: Skeleton3D) -> Array:
	var out: Array = []
	for i in skel.get_bone_count():
		out.append(skel.get_bone_pose(i))
	return out


static func _delta(skel: Skeleton3D, rest: Array) -> int:
	var moved := 0
	for i in mini(skel.get_bone_count(), rest.size()):
		if not skel.get_bone_pose(i).is_equal_approx(rest[i]):
			moved += 1
	return moved


static func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var s := _find_skel(c)
		if s:
			return s
	return null
