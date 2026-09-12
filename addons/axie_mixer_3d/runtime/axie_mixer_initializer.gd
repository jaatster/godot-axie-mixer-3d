class_name AxieMixerInitializer
extends Node
## Bootstrap: assign catalog to AxieFactory.default_factory before any character is created.
## Unity Awake analog is `_enter_tree` (parent before children). `_ready` only binds lighting.


enum DefaultOutlineMode { NONE, DRAW_OBJECTS, POST_PROCESS }

@export_group("Catalog")
@export_file("*.json") var catalog_path: String = "res://addons/axie_mixer_3d_assets/catalog.json"
@export var persist_across_scenes: bool = true

@export_group("Assembly")
@export var combine_meshes: bool = true

@export_group("Outline")
@export var default_outline_mode: DefaultOutlineMode = DefaultOutlineMode.DRAW_OBJECTS
@export var outline_layer: int = 2
@export var base_outline_layer: int = 1

## Loaded JSON catalog (Godot). Unity's `Catalog` field is the factory — see `get_factory()`.
var catalog: AxieCatalog
var _factory: AxieFactory
var _assigned := false

## Unity `AxieMixerInitializer.Catalog` — the factory assigned to `AxieFactory.default_factory`.
var factory: AxieFactory:
	get = get_factory


func get_factory() -> AxieFactory:
	return _factory


func _enter_tree() -> void:
	process_priority = -10000
	_assign_factory()


func _ready() -> void:
	var tree := get_tree()
	if persist_across_scenes and tree != null and get_parent() == tree.root:
		set_process(false)


func _assign_factory() -> void:
	if _assigned:
		return
	if catalog_path.is_empty():
		push_error("AxieMixerInitializer on '%s' has no catalog_path assigned." % name)
		return
	catalog = AxieCatalog.load_json(catalog_path)
	_factory = AxieFactory.new()
	_factory.catalog = catalog
	AxieFactory.default_factory = _factory
	AxieDefaults.factory = _factory
	AxieDefaults.outline_layer = (
		outline_layer if default_outline_mode == DefaultOutlineMode.DRAW_OBJECTS else -1
	)
	AxieDefaults.outline_base_layer = base_outline_layer
	AxieDefaults.combine_meshes = combine_meshes
	_assigned = true


func _exit_tree() -> void:
	if not _assigned:
		return
	if AxieFactory.default_factory == _factory:
		AxieFactory.default_factory = null
		AxieDefaults.factory = null
		AxieDefaults.outline_layer = -1
		AxieDefaults.combine_meshes = true
	_assigned = false
