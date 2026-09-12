extends Node
## Feeds the `positionOS.y` source of Mystic_Final (the _Top/_Mid height gradient).
##
## Unity's vertex shader receives skinned positions in the SkinnedMeshRenderer's root-bone space
## (`unity_ObjectToWorld` is `rootBone.localToWorld` without scale): for a part that is its
## `*_Offsets` joint under the attach point (so a mirrored R part has negative Y and its material is
## authored for that), for a merged renderer it is the body's root bone, which AxieMeshCombiner reuses
## for every merged renderer. Godot's fragment stage only has the world position, so every frame this
## node pushes row Y of inverse(root-bone world transform) into each mystic material (`root_inv_y`);
## the shader then evaluates exactly the same height as Unity.
##
## Root bone per MeshInstance3D: `axie_root_bone` meta (set by the combiner) or skin bind 0
## (Unity `bones[0]`, which is `rootBone` on every mixer asset); unskinned meshes use their own
## transform (Unity MeshRenderer object space).

const MixerMaterials := preload("res://addons/axie_mixer_3d/import/axie_mixer_materials.gd")
const META_ROOT_BONE := "axie_root_bone"
const NODE_NAME := "AxieMysticRootTracker"

var _entries: Array = [] ## [{material, mesh, skeleton, bone}]
var _watched: Array = [] ## Skeleton3D connected to skeleton_updated


## Installs a tracker under `root` when any mystic material is present. Call after mesh combine.
static func attach(root: Node3D) -> void:
	if root == null:
		return
	var old := root.get_node_or_null(NODE_NAME)
	if old != null:
		old.free()
	var tracker := new()
	tracker.name = NODE_NAME
	tracker._collect(root)
	if tracker._entries.is_empty():
		tracker.free()
		return
	root.add_child(tracker)
	tracker.process_priority = 1000 # after AxiePlayable / AnimationPlayer nodes
	tracker.update_now()


func _collect(root: Node3D) -> void:
	var seen_materials: Dictionary = {}
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var skeleton := mi.get_node_or_null(mi.skeleton) as Skeleton3D
		var bone := -1
		if skeleton != null:
			if mi.has_meta(META_ROOT_BONE):
				bone = skeleton.find_bone(str(mi.get_meta(META_ROOT_BONE)))
			elif mi.skin != null and mi.skin.get_bind_count() > 0:
				bone = mi.skin.get_bind_bone(0)
				if bone < 0:
					bone = skeleton.find_bone(mi.skin.get_bind_name(0))
		for s in mi.mesh.get_surface_count():
			var material := mi.get_active_material(s)
			if not MixerMaterials.is_mystic(material):
				continue
			var sm := material as ShaderMaterial
			var key := sm.get_instance_id()
			if seen_materials.has(key):
				# One material on renderers with different root bones (never the case for the pack,
				# but a user material could be): give this surface its own copy.
				var prev: Dictionary = seen_materials[key]
				if prev["mesh"] != mi or prev["bone"] != bone:
					sm = sm.duplicate()
					mi.set_surface_override_material(s, sm)
				else:
					continue
			var entry := {"material": sm, "mesh": mi, "skeleton": skeleton, "bone": bone}
			seen_materials[sm.get_instance_id()] = entry
			_entries.append(entry)
			if skeleton != null and not _watched.has(skeleton):
				_watched.append(skeleton)


func _ready() -> void:
	for s in _watched:
		var skeleton := s as Skeleton3D
		if is_instance_valid(skeleton) and not skeleton.skeleton_updated.is_connected(update_now):
			skeleton.skeleton_updated.connect(update_now)
	set_process(true)


func _process(_delta: float) -> void:
	update_now()


## Recomputes `root_inv_y` for every tracked material from the current root-bone transforms.
func update_now() -> void:
	for e in _entries:
		var mi: MeshInstance3D = e["mesh"]
		var sm: ShaderMaterial = e["material"]
		if not is_instance_valid(mi) or not is_instance_valid(sm) or not mi.is_inside_tree():
			continue
		var xf: Transform3D
		var skeleton: Skeleton3D = e["skeleton"]
		var bone: int = e["bone"]
		if is_instance_valid(skeleton) and bone >= 0:
			xf = skeleton.global_transform * skeleton.get_bone_global_pose(bone)
		else:
			xf = mi.global_transform
		xf.basis = xf.basis.orthonormalized() # Unity: root-bone matrix without scale
		var inv := xf.affine_inverse()
		sm.set_shader_parameter(
			"root_inv_y", Vector4(inv.basis.x.y, inv.basis.y.y, inv.basis.z.y, inv.origin.y)
		)
