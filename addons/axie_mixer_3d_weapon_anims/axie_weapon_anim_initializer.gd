class_name AxieWeaponAnimInitializer
extends Node
## Optional bootstrap: register weapon/action clips after AxieMixerInitializer assigns the factory.
## Unity execution order -9000. As a child of AxieMixerInitializer, `_enter_tree` runs after the
## parent has assigned `AxieFactory.default_factory`.

## Optional override; empty means "the pack of AxieFactory.default_factory".
@export_file("*.json") var catalog_path: String = ""

var _registered := false
var _catalog: AxieCatalog

## Unity `Catalog` analog.
var catalog: AxieCatalog:
	get:
		return _catalog


func _enter_tree() -> void:
	process_priority = -9000
	_register()


func _register() -> void:
	if _registered:
		return
	var factory = AxieFactory.default_factory
	if factory == null:
		push_error(
			"[AxieWeaponAnimInitializer] No AxieFactory.default_factory. Add AxieMixerInitializer first."
		)
		return
	_catalog = AxieCatalog.load_json(catalog_path) if not catalog_path.is_empty() else factory.catalog
	AxieWeaponAnims.register(_catalog, factory)
	_registered = true


func _exit_tree() -> void:
	if not _registered:
		return
	var factory = AxieFactory.default_factory
	if factory != null:
		AxieWeaponAnims.unregister(_catalog, factory)
	_registered = false
