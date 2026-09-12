extends SceneTree
## Weapon-anims package vs Unity AxieWeaponAnims / WeaponAnimNames / initializer.
## Headless: godot --headless --path . -s tests/test_weapon_anims_v2.gd

const CATALOG := "res://addons/axie_mixer_3d_assets/catalog.json"


func _init() -> void:
	var errs: Array = run()
	if errs.is_empty():
		print("ok  weapon_anims_v2")
		quit(0)
	else:
		for e in errs:
			print("FAIL weapon_anims_v2: %s" % e)
		quit(1)


static func run() -> Array:
	var errs: Array = []
	errs.append_array(_check_names())
	var catalog := AxieCatalog.load_json(CATALOG)
	if catalog == null:
		errs.append("v2 catalog failed")
		return errs
	var factory := AxieFactory.new()
	factory.catalog = catalog
	AxieFactory.default_factory = factory
	AxieDefaults.factory = factory

	var before := factory.get_registered_anim_clip(AxieTypes.Body.NORMAL, WeaponAnimNames.AxeAttack)
	if before != null:
		errs.append("AxeAttack resolved before register")

	AxieWeaponAnims.register(catalog, factory)
	var axe := factory.get_registered_anim_clip(AxieTypes.Body.NORMAL, WeaponAnimNames.AxeAttack)
	if axe == null:
		errs.append("AxeAttack null after register")
	var cannon := factory.get_registered_anim_clip(AxieTypes.Body.NORMAL, WeaponAnimNames.CannonAttack)
	var canon := factory.get_registered_anim_clip(AxieTypes.Body.NORMAL, "CanonAttack")
	if cannon == null or canon == null:
		errs.append("Cannon/Canon alias missing cannon=%s canon=%s" % [cannon != null, canon != null])
	elif cannon != canon:
		errs.append("CannonAttack and CanonAttack resolved to different clips")

	# Idempotent re-register replaces same names (Unity Register).
	AxieWeaponAnims.register(catalog, factory)
	var axe2 := factory.get_registered_anim_clip(AxieTypes.Body.NORMAL, WeaponAnimNames.AxeAttack)
	if axe2 == null:
		errs.append("AxeAttack null after re-register")

	var clips := AxieWeaponAnims.clips_for_body(catalog, AxieTypes.Body.NORMAL)
	if clips.size() < 80:
		errs.append("Normal clips_for_body %s expected >= 80" % clips.size())

	AxieWeaponAnims.unregister(catalog, factory)
	if factory.get_registered_anim_clip(AxieTypes.Body.NORMAL, WeaponAnimNames.AxeAttack) != null:
		errs.append("AxeAttack still registered after unregister")
	if factory.get_registered_anim_clip(AxieTypes.Body.NORMAL, WeaponAnimNames.CannonAttack) != null:
		errs.append("CannonAttack still registered after unregister")

	AxieWeaponAnims.register(catalog, factory)
	if factory.get_registered_anim_clip(AxieTypes.Body.NORMAL, WeaponAnimNames.AxeAttack) == null:
		errs.append("AxeAttack null after re-register following unregister")

	errs.append_array(_check_initializer(catalog, factory))
	errs.append_array(_check_per_body_catalog(catalog, factory))

	AxieFactory.default_factory = null
	AxieDefaults.factory = null
	return errs


static func _check_names() -> Array:
	var errs: Array = []
	if _unity_weapon_names().size() != 97:
		errs.append("Unity WeaponAnimNames has 97 constants, test list is %s" % _unity_weapon_names().size())
	if WeaponAnimNames.CannonAttack != "CannonAttack":
		errs.append("CannonAttack spelling %s" % WeaponAnimNames.CannonAttack)
	if WeaponAnimNames.CannonIdle != "CannonIdle":
		errs.append("CannonIdle spelling")
	if WeaponAnimNames.SwordAttackv2 != "SwordAttackv2":
		errs.append("SwordAttackv2 spelling")
	if WeaponAnimNames.SwordSkill2 != "SwordSkill2":
		errs.append("SwordSkill2 spelling")
	if WeaponAnimNames.AttackCombo != "AttackCombo":
		errs.append("AttackCombo spelling")
	return errs


static func _check_initializer(catalog: AxieCatalog, factory: AxieFactory) -> Array:
	var errs: Array = []
	AxieWeaponAnims.unregister(catalog, factory)
	var boot := AxieWeaponAnimInitializer.new()
	boot.name = "AxieWeaponAnimInitializer"
	# `_enter_tree` needs a SceneTree; call the same register/unregister path Unity Awake/OnDestroy uses.
	boot._register()
	if factory.get_registered_anim_clip(AxieTypes.Body.NORMAL, WeaponAnimNames.AxeAttack) == null:
		errs.append("initializer did not register weapon clips")
	if boot.catalog == null:
		errs.append("initializer.catalog is null (Unity Catalog analog)")
	boot._exit_tree()
	if factory.get_registered_anim_clip(AxieTypes.Body.NORMAL, WeaponAnimNames.AxeAttack) != null:
		errs.append("initializer exit did not unregister")
	boot.free()
	AxieWeaponAnims.register(catalog, factory)
	return errs


static func _check_per_body_catalog(catalog: AxieCatalog, factory: AxieFactory) -> Array:
	var errs: Array = []
	for body in AxieTypes.BODY_NAMES.size():
		var entry := catalog.body_entry(body)
		var listed: Array = entry.get("weapon_animations", [])
		for n in listed:
			var name := str(n)
			if factory.get_registered_anim_clip(body, name) == null:
				errs.append("%s listed %s but get_registered_anim_clip is null" % [AxieTypes.body_name(body), name])
	return errs


static func _unity_weapon_names() -> PackedStringArray:
	return PackedStringArray([
		"AttackCombo", "AttackHead", "AttackRange",
		"AxeAttack", "AxeIdle", "AxeRun", "AxeSkill", "AxeWalk",
		"BowAttack", "BowIdle", "BowRun", "BowSkill", "BowWalk",
		"BrushAttack", "BrushIdle", "BrushRun", "BrushWalk",
		"CannonAttack", "CannonIdle", "CannonRun", "CannonSkill", "CannonWalk",
		"CutTree",
		"DaggerAttack", "DaggerIdle", "DaggerRun", "DaggerSkill", "DaggerWalk",
		"FlagAttack", "FlagIdle", "FlagRun", "FlagSkill", "FlagWalk",
		"FluteAttack", "FluteIdle", "FluteRun", "FluteSkill", "FluteWalk",
		"GauntletAttack", "GauntletIdle", "GauntletRun", "GauntletSkill", "GauntletWalk",
		"HammerAttack", "HammerIdle", "HammerRun", "HammerSkill", "HammerWalk",
		"HitTree", "IdleCarryItem", "IdleGetHit",
		"LanternAttack", "LanternIdle", "LanternRun", "LanternSkill", "LanternWalk",
		"LootItem",
		"MalaAttack", "MalaIdle", "MalaRun", "MalaSkill", "MalaWalk",
		"PourWater", "Shoveling",
		"SpearAttack", "SpearIdle", "SpearRun", "SpearSkill", "SpearWalk",
		"StaffAttack", "StaffIdle", "StaffRun", "StaffSkill", "StaffWalk",
		"StoneHarvest",
		"SwordAttack", "SwordAttackv2", "SwordIdle", "SwordRun", "SwordSkill", "SwordSkill2", "SwordWalk",
		"TalismanAttack", "TalismanIdle", "TalismanRun", "TalismanSkill", "TalismanWalk",
		"TomeAttack", "TomeIdle", "TomeRun", "TomeSkill", "TomeWalk",
		"WhipAttack", "WhipIdle", "WhipRun", "WhipSkill", "WhipWalk",
	])
