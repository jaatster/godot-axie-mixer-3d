class_name AxieCharacter3D
extends RefCounted
## Assembled 3D Axie. Call dispose() when finished.

const OutlineDrawObjects := preload("res://addons/axie_mixer_3d/outline/outline_draw_objects.gd")

static var OUTLINE_EXCLUDED_PART_TYPES: Array[int]:
	get:
		return AxieDefaults.OUTLINE_EXCLUDED_PART_TYPES

static var default_outline_layer: int:
	get:
		return AxieDefaults.outline_layer
	set(v):
		AxieDefaults.outline_layer = v

static var default_outline_base_layer: int:
	get:
		return AxieDefaults.outline_base_layer
	set(v):
		AxieDefaults.outline_base_layer = v

static var default_combine_meshes: bool:
	get:
		return AxieDefaults.combine_meshes
	set(v):
		AxieDefaults.combine_meshes = v

var instantiation_params: AxieInstantiationParams
var root: Node3D
var right_weapon_attach_point: Node3D
var left_weapon_attach_point: Node3D
var descriptor: AxieDescriptor

var _body_data: Dictionary = {}
var _outline_excluded_parts: Array = []
var _owned_materials: Array = []
var _owned_meshes: Array = []
var _outline_layer: int = -1
var _outline_base_layer: int = 1
var _playable: AxiePlayable
var _factory: AxieFactory
var skeleton: Skeleton3D
var attach_points: Dictionary = {}


static func from_descriptor(
	axie_descriptor: AxieDescriptor, instantiation_params: AxieInstantiationParams = null
) -> AxieCharacter3D:
	var factory = AxieFactory.default_factory
	if factory == null:
		factory = AxieDefaults.factory
	if factory == null:
		push_error(
			"AxieFactory.default_factory has not been assigned. Add an AxieMixerInitializer and assign your catalog."
		)
		return null
	return factory.create_character(axie_descriptor, instantiation_params)


static func from_genes(genes: String, instantiation_params: AxieInstantiationParams = null) -> AxieCharacter3D:
	return from_descriptor(AxieDescriptor.from_genes(genes), instantiation_params)


var playable: AxiePlayable:
	get:
		if _playable == null and root != null:
			_playable = AxiePlayable.new(self)
		return _playable


func apply_descriptor(desc: AxieDescriptor) -> void:
	var factory = AxieFactory.default_factory
	if factory == null:
		factory = AxieDefaults.factory
	if factory == null:
		push_error("AxieFactory.default_factory has not been assigned.")
		return
	var build = factory.build_character(desc, instantiation_params)
	if build == null or build.root == null:
		return
	apply_build(build)


func apply_genes(genes: String) -> void:
	apply_descriptor(AxieDescriptor.from_genes(genes))


func apply_build(build) -> void:
	var is_rebuild := root != null
	var old_root := root
	if is_rebuild:
		if _playable and _playable.has_method("dispose"):
			_playable.dispose()
		_playable = null
		for material in _owned_materials:
			if material:
				pass
		old_root.queue_free()
		if build.root and old_root.get_parent():
			var parent := old_root.get_parent()
			var idx := old_root.get_index()
			parent.add_child(build.root)
			parent.move_child(build.root, idx)
			build.root.transform = old_root.transform

	instantiation_params = build.merged_params
	root = build.root
	skeleton = build.skeleton
	attach_points = build.attach_points
	_factory = build.factory
	right_weapon_attach_point = build.right_weapon_attach_point
	left_weapon_attach_point = build.left_weapon_attach_point
	_body_data = build.body_data
	_outline_excluded_parts = build.outline_excluded_parts
	_owned_materials = build.owned_materials
	_owned_meshes = build.owned_meshes
	descriptor = build.coerced_descriptor
	if is_rebuild and _outline_layer >= 0:
		set_outline_layer(_outline_layer, _outline_base_layer)


func dispose() -> void:
	if root == null:
		return
	if _playable and _playable.has_method("dispose"):
		_playable.dispose()
	_playable = null
	root.queue_free()
	root = null


func set_outline_layer(outline_layer: int, base_layer: int = 1) -> void:
	if root == null:
		return
	_outline_layer = outline_layer
	_outline_base_layer = base_layer
	# Godot `VisualInstance3D.layers` is a bitmask; arguments are 1-indexed render layers
	# (Unity `GameObject.layer` is 0-indexed; Godot layer 1 ≡ Unity Default / bit 0).
	_set_layer_recursively(root, _layer_mask(outline_layer))
	var draw_objects := outline_layer != base_layer
	if draw_objects:
		for part in _outline_excluded_parts:
			if part:
				_set_layer_recursively(part, _layer_mask(base_layer))
	OutlineDrawObjects.sync(root, _outline_excluded_parts, draw_objects)


## Unity `GetAnimClip`: body-baked clips first (case-insensitive), then clips registered at runtime
## (e.g. the weapon-anims package).
func get_anim_clip(animation_name: String) -> Animation:
	if animation_name.is_empty():
		return null
	var body := descriptor.body if descriptor else 0
	var factory: AxieFactory = _factory if _factory else AxieFactory.default_factory
	if factory == null:
		factory = AxieDefaults.factory as AxieFactory
	if factory != null and factory.catalog != null:
		var baked := factory.catalog.find_body_animation(body, animation_name)
		if baked != null:
			return baked
	if factory != null:
		return factory.get_registered_anim_clip(body, animation_name)
	return null


static func _layer_mask(layer: int) -> int:
	if layer <= 0:
		return 0
	return 1 << (layer - 1)


static func _set_layer_recursively(n: Node, mask: int) -> void:
	if n is VisualInstance3D:
		(n as VisualInstance3D).layers = mask
	for c in n.get_children():
		_set_layer_recursively(c, mask)
