class_name AxieWeaponAnims
extends Object
## Port of `com.skymavis.axiemixer3d.weaponanims` (1.0.0) `AxieWeaponAnims`.
##
## Unity ships the weapon/action clips as a second package with its own catalog asset; the Godot
## pack bakes them next to each body (`weapon_anims/<Body>.glb`, see `catalog.json`
## `bodies[].weapon_anims_glb`). Call `register()` after `AxieFactory.default_factory` is assigned.


## `catalog` may be null (uses the factory's pack) or an AxieCatalog.
static func register(catalog: Variant = null, factory: Object = null) -> void:
	if factory == null:
		factory = AxieFactory.default_factory
	if factory == null:
		push_error(
			"[AxieWeaponAnims] No AxieFactory to register with. Assign AxieFactory.default_factory (e.g. via AxieMixerInitializer) before registering weapon animations."
		)
		return
	var cat := _resolve_catalog(catalog, factory)
	if cat == null:
		push_warning("[AxieWeaponAnims] Register called without a catalog.")
		return
	for body in AxieTypes.BODY_NAMES.size():
		var clips := clips_for_body(cat, body)
		if not clips.is_empty():
			factory.call("register_animations", body, clips)


static func unregister(catalog: Variant = null, factory: Object = null) -> void:
	if factory == null:
		factory = AxieFactory.default_factory
	if factory == null:
		return
	var cat := _resolve_catalog(catalog, factory)
	if cat == null:
		return
	for body in AxieTypes.BODY_NAMES.size():
		var entry := cat.body_entry(body)
		for n in entry.get("weapon_animations", []):
			factory.call("unregister_animation", body, str(n))


## [{name, clip}] for one body, in catalog order (Unity `AxieWeaponAnimCatalog.bodies[].animations`).
static func clips_for_body(cat: AxieCatalog, body: int) -> Array:
	var out: Array = []
	var entry := cat.body_entry(body)
	if entry.is_empty():
		return out
	var glb := str(entry.get("weapon_anims_glb", ""))
	if glb.is_empty():
		return out
	var anims := cat.load_animations(glb)
	for n in entry.get("weapon_animations", []):
		var nme := str(n)
		var clip: Variant = anims.get(nme.to_lower(), null)
		if clip == null:
			var alias := AxieFactory.weapon_name_alias(nme)
			if not alias.is_empty():
				clip = anims.get(alias.to_lower(), null)
		if clip is Animation:
			out.append({"name": nme, "clip": clip})
	return out


static func _resolve_catalog(catalog: Variant, factory: Object) -> AxieCatalog:
	if catalog is AxieCatalog:
		return catalog
	if catalog is String and not str(catalog).is_empty():
		return AxieCatalog.load_json(str(catalog))
	var from_factory: Variant = factory.get("catalog")
	if from_factory is AxieCatalog:
		return from_factory
	return null
