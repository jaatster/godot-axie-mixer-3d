extends SceneTree
## Public integration surface: initializer → default factory → from_genes / create_character.
## Headless: godot --headless --path . -s tests/test_public_api.gd

const CATALOG := "res://addons/axie_mixer_3d_assets/catalog.json"
const Initializer := preload("res://addons/axie_mixer_3d/runtime/axie_mixer_initializer.gd")
const WeaponInitializer := preload("res://addons/axie_mixer_3d_weapon_anims/axie_weapon_anim_initializer.gd")
const Behaviour := preload("res://addons/axie_mixer_3d/runtime/axie_character_3d_behaviour.gd")
const AxieBodyType := preload("res://addons/axie_mixer_3d/core/axie_body_type.gd")
const AxiePartType := preload("res://addons/axie_mixer_3d/core/axie_part_type.gd")
const AxieRigType := preload("res://addons/axie_mixer_3d/core/axie_rig_type.gd")
const AxieNamedClip := preload("res://addons/axie_mixer_3d/runtime/axie_named_clip.gd")


func _init() -> void:
	var errs: Array = run(self)
	if errs.is_empty():
		print("ok  public_api")
		quit(0)
	else:
		for e in errs:
			print("FAIL public_api: %s" % e)
		quit(1)


static func run(tree: SceneTree = null) -> Array:
	var errs: Array = []
	errs.append_array(_check_types())
	errs.append_array(_check_no_factory())
	errs.append_array(_check_initializer_path(tree))
	errs.append_array(_check_create_character())
	errs.append_array(_check_named_clip_and_cache())
	errs.append_array(_check_behaviour(tree))
	AxieFactory.default_factory = null
	AxieDefaults.factory = null
	return errs


static func _check_types() -> Array:
	var errs: Array = []
	if AxieMixer3DVersion.VERSION != "1.1.0" or AxieMixer3DVersion.Version != "1.1.0":
		errs.append("version %s" % AxieMixer3DVersion.VERSION)
	if AxieBodyType.Normal != AxieTypes.Body.NORMAL or AxieBodyType.Frosty != AxieTypes.Body.FROSTY:
		errs.append("AxieBodyType mismatch")
	if AxiePartType.Horn != AxieTypes.Part.HORN or AxiePartType.Eye != AxieTypes.Part.EYE:
		errs.append("AxiePartType mismatch")
	if AxieRigType.Horn_T != AxieTypes.Rig.HORN_T:
		errs.append("AxieRigType mismatch")
	if AxieRigType.to_axie_part_type(AxieRigType.Horn_T) != AxiePartType.Horn:
		errs.append("to_axie_part_type Horn_T")
	if AxieRigType.to_axie_part_type(AxieRigType.Ear_L) != AxiePartType.Ear:
		errs.append("to_axie_part_type Ear_L")
	var missing := PackedStringArray()
	for n in [
		"AxieMixerInitializer",
		"AxieCharacter3D",
		"AxieFactory",
		"AxiePlayable",
		"AxieNamedClip",
		"AxieBodyType",
		"AxiePartType",
		"AxieRigType",
		"AxieWeaponAnimInitializer",
		"AnimNames",
		"WeaponAnimNames",
	]:
		if not _has_class(n):
			missing.append(n)
	if not missing.is_empty():
		errs.append("missing class_name %s" % ",".join(missing))
	return errs


static func _check_no_factory() -> Array:
	var errs: Array = []
	AxieFactory.default_factory = null
	AxieDefaults.factory = null
	var ch = AxieCharacter3D.from_genes("0x0")
	if ch != null:
		errs.append("from_genes without factory should be null")
		if ch:
			ch.dispose()
	return errs


static func _check_initializer_path(tree: SceneTree) -> Array:
	var errs: Array = []
	if tree == null:
		errs.append("no SceneTree")
		return errs
	var boot: Node = Initializer.new()
	boot.name = "AxieMixerInitializer"
	boot.set("catalog_path", CATALOG)
	boot.set("persist_across_scenes", false)
	boot.set("combine_meshes", true)
	boot.set("default_outline_mode", Initializer.DefaultOutlineMode.NONE)
	tree.root.add_child(boot)
	if AxieFactory.default_factory == null and boot.has_method("_assign_factory"):
		boot.call("_assign_factory")
	if AxieFactory.default_factory == null:
		errs.append("initializer did not assign default_factory")
		_free_now(boot)
		return errs
	if boot.get_factory() != AxieDefaults.factory:
		errs.append("initializer.factory is not default_factory")
	var weapons: Node = WeaponInitializer.new()
	weapons.name = "AxieWeaponAnimInitializer"
	boot.add_child(weapons)
	if weapons.has_method("_register"):
		weapons.call("_register")
	var desc := _fixture()
	var genes := desc.to_genes()
	if not genes.begins_with("0x") or genes.length() != 130:
		errs.append("fixture genes length %s" % genes.length())
	var params := AxieInstantiationParams.new()
	params.combine_meshes = true
	var ch: AxieCharacter3D = AxieCharacter3D.from_genes(genes, params)
	if ch == null or ch.root == null:
		errs.append("from_genes via initializer returned null")
		_free_now(boot)
		return errs
	if ch.descriptor == null or ch.descriptor.body != AxieBodyType.Normal:
		errs.append("from_genes body %s" % (ch.descriptor.body if ch.descriptor else -1))
	var idle: Animation = ch.get_anim_clip(AnimNames.Idle)
	if idle == null or idle.get_track_count() < 10:
		errs.append("Idle clip missing")
	var playable: AxiePlayable = ch.playable
	if playable == null or playable.play(AnimNames.Idle, "", true) == null:
		errs.append("play Idle failed")
	else:
		playable.call("_tick", 0.16)
	var sword: Animation = ch.get_anim_clip(WeaponAnimNames.SwordAttack)
	if sword == null or sword.get_track_count() < 5:
		errs.append("SwordAttack not registered via weapon initializer")
	ch.dispose()
	_free_now(boot)
	return errs


static func _check_create_character() -> Array:
	var errs: Array = []
	var cat := AxieCatalog.load_json(CATALOG)
	var factory := AxieFactory.new()
	factory.catalog = cat
	AxieFactory.default_factory = factory
	AxieDefaults.factory = factory
	var params := AxieInstantiationParams.new()
	params.combine_meshes = true
	var via_factory: AxieCharacter3D = factory.create_character(_fixture(), params)
	if via_factory == null or via_factory.root == null:
		errs.append("create_character returned null")
	else:
		via_factory.dispose()
	var via_static: AxieCharacter3D = AxieCharacter3D.from_descriptor(_fixture(), params)
	if via_static == null or via_static.root == null:
		errs.append("from_descriptor returned null")
	else:
		via_static.dispose()
	factory.setup_empty()
	var empty_ch: AxieCharacter3D = factory.create_character(_fixture(), params)
	if empty_ch != null:
		errs.append("setup_empty still created a character")
		empty_ch.dispose()
	return errs


static func _check_named_clip_and_cache() -> Array:
	var errs: Array = []
	var factory := AxieFactory.new()
	factory.setup_empty()
	factory.clear_cache()
	var clip := Animation.new()
	clip.length = 0.5
	var named := AxieNamedClip.new("MyCast", clip)
	factory.register_animations(AxieBodyType.Normal, [named])
	if factory.get_registered_anim_clip(AxieBodyType.Normal, "mycast") != clip:
		errs.append("named clip register miss")
	if not factory.unregister_animation(AxieBodyType.Normal, "MyCast"):
		errs.append("unregister_animation false")
	if factory.get_registered_anim_clip(AxieBodyType.Normal, "MyCast") != null:
		errs.append("unregister left clip")
	factory.register_animation(AxieBodyType.Normal, "CanonAttack", clip)
	if factory.get_registered_anim_clip(AxieBodyType.Normal, "CannonAttack") != clip:
		errs.append("Cannon alias missing")
	factory.unregister_animation(AxieBodyType.Normal, "CanonAttack")
	if factory.get_registered_anim_clip(AxieBodyType.Normal, "CannonAttack") != null:
		errs.append("Cannon alias survived unregister")
	return errs


static func _check_behaviour(tree: SceneTree) -> Array:
	var errs: Array = []
	if tree == null:
		errs.append("behaviour: no SceneTree")
		return errs
	var cat := AxieCatalog.load_json(CATALOG)
	var factory := AxieFactory.new()
	factory.catalog = cat
	AxieFactory.default_factory = factory
	AxieDefaults.factory = factory
	AxieDefaults.combine_meshes = true
	var node: Node3D = Behaviour.new()
	node.axie_genes = _fixture().to_genes()
	tree.root.add_child(node)
	if node.character == null:
		node.rebuild()
	if node.character == null or node.character.root == null:
		errs.append("behaviour rebuild did not create character")
	else:
		if node.playable == null:
			errs.append("behaviour.playable null")
		node.refresh()
		if node.character == null or node.character.root == null:
			errs.append("behaviour.refresh lost character")
	_free_now(node)
	return errs


static func _fixture() -> AxieDescriptor:
	var d := AxieDescriptor.new()
	d.body = AxieBodyType.Normal
	d.color_variant = 3
	for t in [
		AxiePartType.Eye, AxiePartType.Mouth, AxiePartType.Ear,
		AxiePartType.Horn, AxiePartType.Back, AxiePartType.Tail,
	]:
		d.parts.append(AxiePartDescriptor.new(t, 0, "Beast", 2, 1))
	return d


static func _free_now(n: Node) -> void:
	var p := n.get_parent()
	if p:
		p.remove_child(n)
	n.free()


static func _has_class(name: String) -> bool:
	if ClassDB.class_exists(name):
		return true
	for info in ProjectSettings.get_global_class_list():
		if str(info.get("class", "")) == name:
			return true
	return false
