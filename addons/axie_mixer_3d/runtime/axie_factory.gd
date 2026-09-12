class_name AxieFactory
extends RefCounted
## Port of Unity `AxieFactory` (com.skymavis.axiemixer3d 1.1.0) on top of the glTF asset pack.
##
## Pipeline (same order as Unity `AxieFactory.Build`):
##   body glb → attach points (`Root_{rig}_JNT` bones) → per-part rig glbs parented to the attach
##   point (each keeps its own joint chain / Skeleton3D like the Unity prefab) → mystic addon material
##   swap + glow prefabs → Colorize (clone materials, `_PrimaryColor` / `_SecondaryColor`) →
##   optional AxieMeshCombiner (absorb part skeletons into the body skeleton, merge renderers).

const MixerMaterials := preload("res://addons/axie_mixer_3d/import/axie_mixer_materials.gd")
const MysticGlow := preload("res://addons/axie_mixer_3d/runtime/axie_mystic_glow.gd")
const MysticRootTracker := preload("res://addons/axie_mixer_3d/runtime/axie_mystic_root_tracker.gd")

static var default_factory: AxieFactory

var catalog: AxieCatalog
var default_instantiation_params: AxieInstantiationParams = AxieInstantiationParams.new()
var _registered_animations: Dictionary = {} ## body int -> {name.lower: Animation | glb rel path}

const ATTACH_REGEX := "^Root_(?<rigType>\\w+)_JNT$"
const META_ATTACH_BONE := &"axie_attach_bone"
const META_PART_NAME := &"axie_part_name"
const META_RIG_TYPE := &"axie_rig_type"
const META_PART_TYPE := &"axie_part_type"
const META_ADDON := &"axie_addon"


class BuildResult:
	var root: Node3D
	var skeleton: Skeleton3D
	var right_weapon_attach_point: Node3D
	var left_weapon_attach_point: Node3D
	var body_data: Dictionary = {}
	var attach_points: Dictionary = {} ## rig type name -> BoneAttachment3D
	var parts: Array[Node3D] = [] ## instantiated part rig roots (pre-combine)
	var outline_excluded_parts: Array = []
	var owned_materials: Array = []
	var owned_meshes: Array = []
	var coerced_descriptor: AxieDescriptor
	var merged_params: AxieInstantiationParams
	var factory: AxieFactory


# ---------------------------------------------------------------------------
# Runtime-registered clips (Unity RegisterAnimations; weapon package uses this)
# ---------------------------------------------------------------------------


func register_animations(body: int, clips: Array) -> void:
	if not _registered_animations.has(body):
		_registered_animations[body] = {}
	var map: Dictionary = _registered_animations[body]
	for clip in clips:
		var pair := _named_clip_pair(clip)
		var n: String = pair[0]
		var anim: Variant = pair[1]
		if n.is_empty() or anim == null:
			continue
		map[n.to_lower()] = anim
		var alias := weapon_name_alias(n)
		if not alias.is_empty() and not map.has(alias.to_lower()):
			map[alias.to_lower()] = anim


func register_animation(body: int, name: String, clip: Animation) -> void:
	if name.is_empty() or clip == null:
		return
	register_animations(body, [{"name": name, "clip": clip}])


func _named_clip_pair(clip: Variant) -> Array:
	var n := ""
	var anim: Variant = null
	if typeof(clip) == TYPE_DICTIONARY:
		n = str(clip.get("name", ""))
		anim = clip.get("clip", null)
	elif clip is Object:
		n = str(clip.get("name"))
		anim = clip.get("clip")
	return [n, anim]


func unregister_animation(body: int, name: String) -> bool:
	if name.is_empty() or not _registered_animations.has(body):
		return false
	var map: Dictionary = _registered_animations[body]
	var removed: bool = map.erase(name.to_lower())
	var alias := weapon_name_alias(name)
	if not alias.is_empty():
		removed = map.erase(alias.to_lower()) or removed
	return removed


func clear_registered_animations(body: int = -1) -> void:
	if body < 0:
		_registered_animations.clear()
	else:
		_registered_animations.erase(body)


func get_registered_anim_clip(body: int, name: String) -> Animation:
	if name.is_empty() or not _registered_animations.has(body):
		return null
	var map: Dictionary = _registered_animations[body]
	var v: Variant = map.get(name.to_lower(), null)
	if v == null:
		var alias := weapon_name_alias(name)
		if not alias.is_empty():
			v = map.get(alias.to_lower(), null)
	if v is Animation:
		return v
	return null


## Unity art bakes "Canon*"; `WeaponAnimNames` public API is "Cannon*".
static func weapon_name_alias(name: String) -> String:
	if name.begins_with("Canon") and not name.begins_with("Cannon"):
		return "Cannon" + name.substr(5)
	if name.begins_with("Cannon"):
		return "Canon" + name.substr(6)
	return ""


# ---------------------------------------------------------------------------
# Catalog queries
# ---------------------------------------------------------------------------


func has_part(axie_class: String, variant: int, skin: int, level: int, type: int) -> bool:
	if catalog == null:
		return false
	return catalog.has_part(AxiePartResolver.part_name(axie_class, variant, skin, level, type))


## Unity TryResolvePart. {ok, name, skin, level} after S{skin}L{level} → S{skin}L1 → S00 L{level} → S00 L1.
func resolve_part(part: AxiePartDescriptor) -> Dictionary:
	if part == null:
		return {"ok": false, "name": "", "skin": 0, "level": 1}
	var has := func(n: String) -> bool:
		return catalog != null and catalog.has_part(n)
	return AxiePartResolver.resolve(part, has)


func setup_empty() -> void:
	catalog = AxieCatalog.new()
	default_instantiation_params = AxieInstantiationParams.new()
	_registered_animations.clear()


func clear_cache() -> void:
	# Unity: addons are pre-baked; ClearCache is a no-op.
	pass


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------


func create_character(
	axie_descriptor: AxieDescriptor, instantiation_params: AxieInstantiationParams = null
) -> AxieCharacter3D:
	var build := build_character(axie_descriptor, instantiation_params)
	if build == null or build.root == null:
		return null
	var character := AxieCharacter3D.new()
	character.apply_build(build)
	if AxieDefaults.outline_layer >= 0:
		character.set_outline_layer(AxieDefaults.outline_layer, AxieDefaults.outline_base_layer)
	return character


func build_character(descriptor: AxieDescriptor, instantiation_params: AxieInstantiationParams = null) -> BuildResult:
	var result := BuildResult.new()
	if descriptor == null:
		return result
	descriptor = coerce_descriptor(descriptor)
	var caller_combine = null
	if instantiation_params != null:
		caller_combine = instantiation_params.combine_meshes
	var merged := (
		default_instantiation_params if default_instantiation_params else AxieInstantiationParams.new()
	).merge(instantiation_params)
	if catalog == null:
		push_error("AxieFactory: no catalog assigned.")
		return result
	if descriptor.body < 0 or descriptor.body >= AxieTypes.BODY_NAMES.size():
		push_error("Cannot find body %s." % descriptor.body)
		return result
	var body_data: Dictionary = catalog.body_entry(descriptor.body)
	if body_data.is_empty():
		push_error("Cannot find body %s." % AxieTypes.body_name(descriptor.body))
		return result
	var body_scene := catalog.load_scene(str(body_data.get("glb", "")))
	if body_scene == null:
		push_error("Body prefab for %s is missing." % AxieTypes.body_name(descriptor.body))
		return result

	var root := body_scene.instantiate() as Node3D
	if root == null:
		return result
	_strip_imported_animation_players(root)
	var skel := find_skeleton(root)
	if skel == null:
		push_error("Body prefab for %s has no Skeleton3D." % AxieTypes.body_name(descriptor.body))
		root.free()
		return result

	var attach := collect_attach_points(root)
	var attach_points: Dictionary = attach["points"]
	result.left_weapon_attach_point = attach["left"]
	result.right_weapon_attach_point = attach["right"]
	_bind_materials(root, body_data.get("materials", []))

	var outline_excluded: Array = []
	var parts: Array[Node3D] = []
	for part_desc in descriptor.parts:
		var resolved := resolve_part(part_desc)
		if not resolved["ok"]:
			push_warning(
				"[AxieFactory] No asset for %s%02d %s (skin=%s, level=%s). Part skipped."
				% [
					part_desc.part_class,
					part_desc.variant,
					AxieTypes.part_name(part_desc.type),
					part_desc.skin,
					part_desc.level,
				]
			)
			continue
		var part_entry: Dictionary = catalog.parts.get(resolved["name"], {})
		var layer_override := merged.find_layer_override(part_desc.type)
		var is_outline_excluded := part_desc.type in AxieDefaults.OUTLINE_EXCLUDED_PART_TYPES
		var seen_rigs: Dictionary = {}
		for rig in part_entry.get("rigs", []):
			var rig_type_name := str(rig.get("type", ""))
			if not attach_points.has(rig_type_name):
				push_error("Cannot find attach point for %s." % rig_type_name)
				continue
			var rig_scene := catalog.load_scene(str(rig.get("glb", "")))
			if rig_scene == null:
				continue
			var attach_node: Node3D = attach_points[rig_type_name]
			var part := rig_scene.instantiate() as Node3D
			if part == null:
				continue
			_strip_imported_animation_players(part)
			part.name = "%s_%s" % [resolved["name"], rig_type_name]
			part.set_meta(META_PART_NAME, str(resolved["name"]))
			part.set_meta(META_RIG_TYPE, rig_type_name)
			part.set_meta(META_PART_TYPE, part_desc.type)
			part.set_meta(META_ATTACH_BONE, "Root_%s_JNT" % rig_type_name)
			attach_node.add_child(part)
			parts.append(part)
			_bind_materials(part, rig.get("materials", []))
			if is_outline_excluded:
				outline_excluded.append(part)
			if layer_override >= 0:
				set_layer_recursively(part, layer_override)

			# Addon lookup uses the resolved (post-fallback) skin/level, like Unity.
			var addon_key := AxiePartResolver.addon_name(
				part_desc.part_class,
				part_desc.variant,
				int(resolved["skin"]),
				int(resolved["level"]),
				rig_type_name
			)
			var addon: Dictionary = catalog.addons.get(addon_key, {})
			if not addon.is_empty():
				_apply_addon_material(part, addon, str(rig.get("prefab_name", "")))
				if not seen_rigs.has(rig_type_name):
					seen_rigs[rig_type_name] = true
					for prefab_rel in addon.get("prefabs", []):
						var glow := MysticGlow.instantiate(catalog, str(prefab_rel))
						if glow != null:
							glow.set_meta(META_ADDON, addon_key)
							attach_node.add_child(glow)

	var owned_materials := _colorize(root, descriptor.color_variant)
	_stamp_mystic_uv2(root)

	var combine := AxieDefaults.combine_meshes
	if caller_combine != null:
		combine = bool(caller_combine)
	var owned_meshes: Array = []
	var outline_parts: Array = outline_excluded
	if combine:
		var merged_renderers := AxieMeshCombiner.combine(root, outline_excluded)
		var excluded: Array = []
		for m in merged_renderers:
			owned_meshes.append(m.mesh)
			if m.is_outline_excluded:
				excluded.append(m.renderer)
		outline_parts = excluded
	# Mystic_Final reads positionOS.y in root-bone space; after combine the renderers are final.
	MysticRootTracker.attach(root)

	result.root = root
	result.skeleton = skel
	result.body_data = body_data
	result.attach_points = attach_points
	result.parts = parts
	result.outline_excluded_parts = outline_parts
	result.owned_materials = owned_materials
	result.owned_meshes = owned_meshes
	result.coerced_descriptor = descriptor
	result.merged_params = merged
	result.factory = self
	return result


static func coerce_descriptor(descriptor: AxieDescriptor) -> AxieDescriptor:
	return descriptor.duplicate_descriptor()


## Unity `CollectAttachPoints`: every `Root_{rig}_JNT` transform. Here those are bones of the body
## Skeleton3D, exposed as BoneAttachment3D children named after the bone.
static func collect_attach_points(root: Node) -> Dictionary:
	var points := {}
	var left: Node3D = null
	var right: Node3D = null
	var skel := find_skeleton(root)
	if skel == null:
		return {"points": points, "left": left, "right": right}
	var re := RegEx.new()
	re.compile(ATTACH_REGEX)
	for b in skel.get_bone_count():
		var bone_name := skel.get_bone_name(b)
		var m := re.search(bone_name)
		if m == null:
			continue
		var rig_type_name := m.get_string("rigType")
		var is_rig := AxieTypes.rig_from_name(rig_type_name) >= 0
		if not is_rig and rig_type_name != "Weapon_R" and rig_type_name != "Weapon_L":
			continue
		var att := skel.get_node_or_null(NodePath(bone_name)) as BoneAttachment3D
		if att == null:
			att = BoneAttachment3D.new()
			att.name = bone_name
			skel.add_child(att)
			att.bone_name = bone_name
			att.bone_idx = b
		if is_rig:
			points[rig_type_name] = att
		elif rig_type_name == "Weapon_R":
			right = att
		else:
			left = att
	return {"points": points, "left": left, "right": right}


static func find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var s := find_skeleton(c)
		if s:
			return s
	return null


static func _strip_imported_animation_players(n: Node) -> void:
	for ap in n.find_children("*", "AnimationPlayer", true, false):
		ap.get_parent().remove_child(ap)
		ap.free()


static func all_mesh_instances(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(all_mesh_instances(c))
	return out


## `layer` is a 1-indexed Godot render layer (Unity `GameObject.layer` index + 1), the same
## convention as `AxieCharacter3D.set_outline_layer` and `AxieInstantiationParams.part_layer_overrides`.
static func set_layer_recursively(n: Node, layer: int) -> void:
	var mask := (1 << (layer - 1)) if layer > 0 else 0
	if n is VisualInstance3D:
		(n as VisualInstance3D).layers = mask
	for c in n.get_children():
		set_layer_recursively(c, layer)


# ---------------------------------------------------------------------------
# Materials
# ---------------------------------------------------------------------------


## Bind the prefab's `sharedMaterials` (pack material ids) per surface, in order.
func _bind_materials(n: Node, ids: Variant) -> void:
	var mats: Array = []
	if ids is Array:
		for item in ids:
			mats.append(MixerMaterials.from_id(catalog, str(item)))
	for renderer in all_mesh_instances(n):
		if renderer.mesh == null:
			continue
		for s in renderer.mesh.get_surface_count():
			var pick: Material = null
			if s < mats.size():
				pick = mats[s]
			elif mats.size() > 0:
				pick = mats[0]
			if pick == null:
				# Fall back to the material id the exporter stamped on the primitive.
				pick = MixerMaterials.from_id(catalog, _surface_material_id(renderer.mesh, s))
			if pick != null:
				renderer.set_surface_override_material(s, pick)


static func _surface_material_id(mesh: Mesh, surface: int) -> String:
	if mesh is ArrayMesh:
		var meta: Variant = (mesh as ArrayMesh).get_meta("extras", null)
		if meta is Dictionary and meta.has("material_id"):
			return str(meta["material_id"])
	var mat := mesh.surface_get_material(surface)
	if mat != null and mat.has_meta("extras"):
		var extras: Variant = mat.get_meta("extras")
		if extras is Dictionary:
			return str(extras.get("material_id", ""))
	return ""


## Unity: single addon material → applied; several → the one whose name equals the rig prefab name.
func _apply_addon_material(part: Node, addon: Dictionary, rig_prefab_name: String) -> void:
	var entries: Array = addon.get("materials", [])
	if entries.is_empty():
		return
	var material_id := ""
	if entries.size() == 1:
		material_id = str(entries[0].get("material", ""))
	else:
		for e in entries:
			if str(e.get("name", "")) == rig_prefab_name:
				material_id = str(e.get("material", ""))
				break
	if material_id.is_empty():
		return
	var addon_mat := MixerMaterials.from_id(catalog, material_id)
	if addon_mat == null:
		return
	var renderers := all_mesh_instances(part)
	if renderers.is_empty():
		return
	# Unity swaps `renderer.sharedMaterial` (slot 0) of the first renderer only.
	var renderer := renderers[0]
	if renderer.mesh != null and renderer.mesh.get_surface_count() > 0:
		renderer.set_surface_override_material(0, addon_mat)


## Unity `Colorize`: clone every distinct material once, set `_PrimaryColor` / `_SecondaryColor`.
func _colorize(root: Node, color_variant: int) -> Array:
	var owned: Array = []
	if catalog == null:
		return owned
	var color: Dictionary = catalog.color_for(color_variant)
	if color.is_empty():
		return owned
	var primary := parse_html_color(str(color.get("primary1", "")))
	var secondary := parse_html_color(str(color.get("primary2", "")))
	var material_map: Dictionary = {}
	for renderer in all_mesh_instances(root):
		var mesh: Mesh = renderer.mesh
		if mesh == null:
			continue
		for s in mesh.get_surface_count():
			var material: Material = renderer.get_surface_override_material(s)
			if material == null:
				material = mesh.surface_get_material(s)
			if material == null:
				continue
			var key := material.get_instance_id()
			if material_map.has(key):
				renderer.set_surface_override_material(s, material_map[key])
				continue
			var clone: Material = material.duplicate()
			clone.resource_name = material.resource_name
			set_color_params(clone, primary, secondary)
			renderer.set_surface_override_material(s, clone)
			material_map[key] = clone
			owned.append(clone)
	return owned


static func set_color_params(material: Material, primary: Color, secondary: Color) -> void:
	if material is ShaderMaterial:
		var sm := material as ShaderMaterial
		sm.set_shader_parameter("primary_color", primary)
		sm.set_shader_parameter("secondary_color", secondary)


static func parse_html_color(value: String) -> Color:
	if value.is_empty():
		return Color.WHITE
	var html := value if value.begins_with("#") else ("#" + value)
	if html.is_valid_html_color():
		return Color.html(html)
	push_warning("Cannot parse color %s" % html)
	return Color.WHITE


## Unity Mystic_Final samples TEXCOORD1 (Mesh.GetUVs(1)) = glTF TEXCOORD_1 = Godot UV2.
static func _stamp_mystic_uv2(root: Node) -> void:
	for renderer in all_mesh_instances(root):
		if renderer.mesh == null:
			continue
		var has := mesh_has_uv2(renderer.mesh)
		for s in renderer.mesh.get_surface_count():
			var material: Material = renderer.get_surface_override_material(s)
			if material == null:
				material = renderer.mesh.surface_get_material(s)
			if MixerMaterials.is_mystic(material):
				(material as ShaderMaterial).set_shader_parameter("has_uv2", has)


static func mesh_has_uv2(mesh: Mesh) -> bool:
	if mesh == null:
		return false
	for s in mesh.get_surface_count():
		if (mesh.surface_get_format(s) & Mesh.ARRAY_FORMAT_TEX_UV2) != 0:
			return true
	return false
