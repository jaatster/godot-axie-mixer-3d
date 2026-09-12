extends SceneTree
## Weapon clips resolve through AxieWeaponAnims.register; attach points exist on every body.
## Headless: godot --headless --path . -s tests/test_weapon_attach.gd

const CATALOG := "res://addons/axie_mixer_3d_assets/catalog.json"


func _init() -> void:
	var errs: Array = run()
	if errs.is_empty():
		print("ok  weapon_attach")
		quit(0)
	else:
		for e in errs:
			print("FAIL weapon_attach: %s" % e)
		quit(1)


static func run() -> Array:
	var errs: Array = []
	var cat := AxieCatalog.load_json(CATALOG)
	var factory := AxieFactory.new()
	factory.catalog = cat
	AxieFactory.default_factory = factory
	AxieDefaults.factory = factory
	AxieWeaponAnims.register(cat, factory)
	var cannon := factory.get_registered_anim_clip(AxieTypes.Body.NORMAL, "CannonAttack")
	var canon := factory.get_registered_anim_clip(AxieTypes.Body.NORMAL, "CanonAttack")
	if cannon == null or canon == null:
		errs.append("Cannon/Canon alias missing cannon=%s canon=%s" % [cannon != null, canon != null])
	if factory.get_registered_anim_clip(AxieTypes.Body.SUMO, "AttackCombo") != null:
		errs.append("Sumo should not have AttackCombo")
	var sword: Animation = factory.get_registered_anim_clip(AxieTypes.Body.NORMAL, "SwordAttack")
	if sword == null or sword.get_track_count() < 5:
		errs.append("SwordAttack missing after AxieWeaponAnims.register")
	elif sword:
		var found_root_w := false
		for i in sword.get_track_count():
			var p := String(sword.track_get_path(i))
			if p.contains("Root_Weapon_L_JNT") or p.contains("Root_Weapon_R_JNT"):
				found_root_w = true
				break
		if not found_root_w:
			errs.append("SwordAttack missing Root_Weapon_* tracks")
	errs.append_array(_check_body(factory, AxieTypes.Body.NORMAL, true))
	errs.append_array(_check_body(factory, AxieTypes.Body.SPIKY, false))
	errs.append_array(_check_body(factory, AxieTypes.Body.SUMO, false))
	AxieFactory.default_factory = null
	AxieDefaults.factory = null
	return errs


static func _check_body(_factory, body: int, expect_root_weapon_bone: bool) -> Array:
	var errs: Array = []
	var desc := AxieDescriptor.new()
	desc.body = body
	desc.color_variant = 3
	for t in [
		AxieTypes.Part.EYE, AxieTypes.Part.MOUTH, AxieTypes.Part.EAR,
		AxieTypes.Part.HORN, AxieTypes.Part.BACK, AxieTypes.Part.TAIL,
	]:
		desc.parts.append(AxiePartDescriptor.new(t, 0, "Beast", 2, 1))
	var params := AxieInstantiationParams.new()
	params.combine_meshes = true
	var ch := AxieCharacter3D.from_descriptor(desc, params)
	var name := AxieTypes.body_name(body)
	if ch == null or ch.root == null:
		errs.append("%s from_descriptor failed" % name)
		return errs
	if ch.left_weapon_attach_point == null or ch.right_weapon_attach_point == null:
		if expect_root_weapon_bone:
			errs.append("%s attach L=%s R=%s" % [name, ch.left_weapon_attach_point, ch.right_weapon_attach_point])
	else:
		if not (ch.left_weapon_attach_point is BoneAttachment3D):
			errs.append("%s left attach is %s" % [name, ch.left_weapon_attach_point.get_class()])
		if str(ch.left_weapon_attach_point.name) != "Root_Weapon_L_JNT":
			errs.append("%s left attach name %s" % [name, ch.left_weapon_attach_point.name])
		if str(ch.right_weapon_attach_point.name) != "Root_Weapon_R_JNT":
			errs.append("%s right attach name %s" % [name, ch.right_weapon_attach_point.name])
		var left_att := ch.left_weapon_attach_point as BoneAttachment3D
		if expect_root_weapon_bone and left_att and left_att.bone_name != "Root_Weapon_L_JNT":
			errs.append("%s left bone_name %s want Root_Weapon_L_JNT" % [name, left_att.bone_name])
	var clip: Animation = ch.get_anim_clip("SwordAttack")
	if clip == null or clip.get_track_count() < 5:
		errs.append("%s SwordAttack missing" % name)
	ch.dispose()
	return errs
