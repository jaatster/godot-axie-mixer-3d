extends SceneTree
## Every catalog-listed AnimNames / WeaponAnimNames clip resolves, plays, and moves a bone.
## Headless: godot --headless --path . -s tests/test_clip_coverage_v2.gd

const CATALOG := "res://addons/axie_mixer_3d_assets/catalog.json"


func _init() -> void:
	var errs: Array = run()
	if errs.is_empty():
		print("ok  clip_coverage_v2")
		quit(0)
	else:
		for e in errs:
			print("FAIL clip_coverage_v2: %s" % e)
		quit(1)


static func run() -> Array:
	var errs: Array = []
	errs.append_array(_check_playable_api())
	var catalog := AxieCatalog.load_json(CATALOG)
	if catalog == null:
		errs.append("v2 catalog failed")
		return errs
	var factory := AxieFactory.new()
	factory.catalog = catalog
	AxieFactory.default_factory = factory
	AxieDefaults.factory = factory
	AxieDefaults.outline_layer = -1
	AxieWeaponAnims.register(catalog, factory)

	var anim_names := _anim_names()
	var weapon_names := _weapon_names()
	var bodies_checked := 0
	var clips_checked := 0
	var clips_played := 0
	var static_clips: PackedStringArray = PackedStringArray()
	var missing_in_catalog := 0

	for body in AxieTypes.BODY_NAMES.size():
		var entry := catalog.body_entry(body)
		var listed: Dictionary = {}
		for n in entry.get("animations", []):
			listed[str(n)] = true
		for n in entry.get("weapon_animations", []):
			listed[str(n)] = true
		var ch := _make_character(factory, body)
		if ch == null or ch.root == null:
			errs.append("%s create_character failed" % AxieTypes.body_name(body))
			continue
		bodies_checked += 1
		var playable: AxiePlayable = ch.playable
		if playable == null:
			errs.append("%s playable is null" % AxieTypes.body_name(body))
			ch.dispose()
			continue
		var wanted: Dictionary = {}
		for n in anim_names:
			wanted[n] = true
		for n in weapon_names:
			wanted[n] = true
		for n in wanted.keys():
			var name := str(n)
			var clip := ch.get_anim_clip(name)
			if clip == null:
				if listed.has(name):
					errs.append("%s get_anim_clip(%s) null but catalog lists it" % [AxieTypes.body_name(body), name])
				else:
					missing_in_catalog += 1
				continue
			clips_checked += 1
			var track := playable.play(name)
			if track == null:
				errs.append("%s play(%s) returned null" % [AxieTypes.body_name(body), name])
				continue
			clips_played += 1
			_reset_bones(ch)
			playable._tick(0.1)
			if not _bones_moved(ch):
				_reset_bones(ch)
				var mid := clip.length * 0.5 if clip.length > 0.2 else maxf(clip.length, 0.0)
				playable.play(name)
				playable._tick(mid if mid > 0.0 else 0.1)
				if not _bones_moved(ch):
					static_clips.append("%s/%s" % [AxieTypes.body_name(body), name])
		if body == AxieTypes.Body.NORMAL:
			errs.append_array(_check_playable_behaviour(ch, playable))
		ch.dispose()

	print(
		"clip_coverage: %s bodies, %s clips resolved, %s played, %s static, %s constants not in catalog"
		% [bodies_checked, clips_checked, clips_played, static_clips.size(), missing_in_catalog]
	)
	if not static_clips.is_empty():
		print("clip_coverage static: %s" % ", ".join(static_clips))

	AxieFactory.default_factory = null
	AxieDefaults.factory = null
	return errs


static func _check_playable_api() -> Array:
	var errs: Array = []
	var methods := [
		"register", "unregister", "is_registered",
		"set_default", "try_set_default", "set_default_blend", "set_speed",
		"get_duration", "try_get_duration",
		"play", "play_blend", "queue", "interrupt", "pause", "resume", "stop", "dispose",
		"is_track_active", "is_blend_active", "stop_blend",
		"advance_on_complete", "make_pending_track",
	]
	var dummy := AxiePlayable.new()
	for m in methods:
		if not dummy.has_method(m):
			errs.append("AxiePlayable missing method %s (Unity %s)" % [m, _pascal(m)])
	for p in [
		"time_scale", "fade", "speed", "current_track", "current_blend",
		"default_clip_name", "is_playing", "is_paused",
	]:
		if not (p in dummy):
			errs.append("AxiePlayable missing property %s (Unity %s)" % [p, _pascal(p)])
	if not AnimTrack.new().has_method("queue") or not AnimTrack.new().has_method("complete"):
		errs.append("AnimTrack missing queue/complete")
	if not AnimBlend.new().has_method("stop"):
		errs.append("AnimBlend missing stop")
	return errs


static func _check_playable_behaviour(ch: AxieCharacter3D, playable: AxiePlayable) -> Array:
	var errs: Array = []
	if playable.get_duration(AnimNames.Idle) <= 0.0:
		errs.append("Idle duration <= 0")
		return errs
	playable.set_default(AnimNames.Idle)
	var walk := playable.play(AnimNames.Walk)
	if walk == null:
		errs.append("play Walk failed")
		return errs
	var queued := walk.queue(AnimNames.Run)
	if queued == null:
		errs.append("queue Run returned null")
	# Unity frame model: Tick reads the clip time left by the previous frame's graph advance, so a
	# completion is observed on the frame after the clip ran past its length.
	playable._tick(playable.get_duration(AnimNames.Walk) + 0.05)
	playable._tick(0.0)
	if playable.current_track == null or playable.current_track.clip_name != AnimNames.Run:
		errs.append(
			"queue did not advance to Run (current=%s)"
			% (playable.current_track.clip_name if playable.current_track else "null")
		)

	var idle_len := playable.get_duration(AnimNames.Idle)
	var looped := playable.play(AnimNames.Idle, "", true)
	if looped == null:
		errs.append("play Idle loop failed")
	else:
		playable._tick(idle_len + 0.15)
		if not looped.is_playing:
			errs.append("loop=true stopped after clip length")
		if playable.current_track != looped:
			errs.append("loop=true did not keep the same track")

	var shot := playable.play(AnimNames.Stun)
	if shot == null:
		errs.append("play Stun failed")
	else:
		playable._tick(playable.get_duration(AnimNames.Stun) + 0.05)
		playable._tick(0.0)
		if playable.current_track == null or playable.current_track.clip_name != AnimNames.Idle:
			errs.append(
				"one-shot did not return to default Idle (current=%s)"
				% (playable.current_track.clip_name if playable.current_track else "null")
			)
		elif not playable.current_track.loop:
			errs.append("default Idle after one-shot is not looping")

	playable.play(AnimNames.Walk, "", true)
	playable._tick(0.1)
	var progress := playable.current_track.progress if playable.current_track else 0.0
	playable.pause()
	if not playable.is_paused:
		errs.append("pause did not set is_paused")
	playable._tick(0.25)
	var paused_progress := playable.current_track.progress if playable.current_track else -1.0
	if absf(paused_progress - progress) > 0.002:
		errs.append("pause still advanced progress %s → %s" % [progress, paused_progress])
	playable.resume()
	if playable.is_paused:
		errs.append("resume left is_paused")
	playable._tick(0.15)
	var resumed := playable.current_track.progress if playable.current_track else 0.0
	if resumed <= paused_progress + 1e-4:
		errs.append("resume did not advance progress")

	var fade_p := AnimPlayParams.new()
	fade_p.clip_name = AnimNames.Run
	fade_p.loop = true
	fade_p.fade = 0.15
	var faded := playable.play(fade_p)
	if faded == null:
		errs.append("play with fade=0.15 returned null")
	else:
		playable._tick(0.05)

	playable.stop()
	return errs


static func _make_character(factory: AxieFactory, body: int) -> AxieCharacter3D:
	var desc := AxieDescriptor.new()
	desc.body = body
	desc.color_variant = 3 if body != AxieTypes.Body.FROSTY else 48
	desc.clear_parts()
	for part in [
		{"type": "Eye", "class": "Beast", "variant": 2, "skin": 0, "level": 1},
		{"type": "Mouth", "class": "Beast", "variant": 2, "skin": 0, "level": 1},
		{"type": "Ear", "class": "Beast", "variant": 2, "skin": 0, "level": 1},
		{"type": "Horn", "class": "Beast", "variant": 2, "skin": 0, "level": 1},
		{"type": "Back", "class": "Beast", "variant": 2, "skin": 0, "level": 1},
		{"type": "Tail", "class": "Beast", "variant": 2, "skin": 0, "level": 1},
	]:
		desc.parts.append(AxiePartDescriptor.from_dict(part))
	var params := AxieInstantiationParams.new()
	params.combine_meshes = true
	return factory.create_character(desc, params)


static func _reset_bones(ch: AxieCharacter3D) -> void:
	for s in ch.root.find_children("*", "Skeleton3D", true, false):
		var skel := s as Skeleton3D
		for b in skel.get_bone_count():
			skel.reset_bone_pose(b)


static func _bones_moved(ch: AxieCharacter3D) -> bool:
	for s in ch.root.find_children("*", "Skeleton3D", true, false):
		var skel := s as Skeleton3D
		for b in skel.get_bone_count():
			var pose := skel.get_bone_pose(b)
			if pose.origin.length() > 1e-4:
				return true
			if pose.basis.get_rotation_quaternion().angle_to(Quaternion.IDENTITY) > 1e-3:
				return true
			if pose.basis.get_scale().distance_to(Vector3.ONE) > 1e-3:
				return true
	return false


static func _pascal(snake: String) -> String:
	var parts := snake.split("_")
	var out := ""
	for p in parts:
		if p.is_empty():
			continue
		out += p.substr(0, 1).to_upper() + p.substr(1)
	return out


static func _anim_names() -> PackedStringArray:
	return PackedStringArray([
		AnimNames.Dead, AnimNames.Idle, AnimNames.IdleCarryItem, AnimNames.IdleGetHit,
		AnimNames.Run, AnimNames.RunAttack, AnimNames.RunCarryItem, AnimNames.Stun,
		AnimNames.Walk, AnimNames.WalkAttack, AnimNames.WalkCarryItem,
	])


static func _weapon_names() -> PackedStringArray:
	return PackedStringArray([
		WeaponAnimNames.AttackCombo, WeaponAnimNames.AttackHead, WeaponAnimNames.AttackRange,
		WeaponAnimNames.AxeAttack, WeaponAnimNames.AxeIdle, WeaponAnimNames.AxeRun,
		WeaponAnimNames.AxeSkill, WeaponAnimNames.AxeWalk,
		WeaponAnimNames.BowAttack, WeaponAnimNames.BowIdle, WeaponAnimNames.BowRun,
		WeaponAnimNames.BowSkill, WeaponAnimNames.BowWalk,
		WeaponAnimNames.BrushAttack, WeaponAnimNames.BrushIdle, WeaponAnimNames.BrushRun,
		WeaponAnimNames.BrushWalk,
		WeaponAnimNames.CannonAttack, WeaponAnimNames.CannonIdle, WeaponAnimNames.CannonRun,
		WeaponAnimNames.CannonSkill, WeaponAnimNames.CannonWalk,
		WeaponAnimNames.CutTree,
		WeaponAnimNames.DaggerAttack, WeaponAnimNames.DaggerIdle, WeaponAnimNames.DaggerRun,
		WeaponAnimNames.DaggerSkill, WeaponAnimNames.DaggerWalk,
		WeaponAnimNames.FlagAttack, WeaponAnimNames.FlagIdle, WeaponAnimNames.FlagRun,
		WeaponAnimNames.FlagSkill, WeaponAnimNames.FlagWalk,
		WeaponAnimNames.FluteAttack, WeaponAnimNames.FluteIdle, WeaponAnimNames.FluteRun,
		WeaponAnimNames.FluteSkill, WeaponAnimNames.FluteWalk,
		WeaponAnimNames.GauntletAttack, WeaponAnimNames.GauntletIdle, WeaponAnimNames.GauntletRun,
		WeaponAnimNames.GauntletSkill, WeaponAnimNames.GauntletWalk,
		WeaponAnimNames.HammerAttack, WeaponAnimNames.HammerIdle, WeaponAnimNames.HammerRun,
		WeaponAnimNames.HammerSkill, WeaponAnimNames.HammerWalk,
		WeaponAnimNames.HitTree, WeaponAnimNames.IdleCarryItem, WeaponAnimNames.IdleGetHit,
		WeaponAnimNames.LanternAttack, WeaponAnimNames.LanternIdle, WeaponAnimNames.LanternRun,
		WeaponAnimNames.LanternSkill, WeaponAnimNames.LanternWalk,
		WeaponAnimNames.LootItem,
		WeaponAnimNames.MalaAttack, WeaponAnimNames.MalaIdle, WeaponAnimNames.MalaRun,
		WeaponAnimNames.MalaSkill, WeaponAnimNames.MalaWalk,
		WeaponAnimNames.PourWater, WeaponAnimNames.Shoveling,
		WeaponAnimNames.SpearAttack, WeaponAnimNames.SpearIdle, WeaponAnimNames.SpearRun,
		WeaponAnimNames.SpearSkill, WeaponAnimNames.SpearWalk,
		WeaponAnimNames.StaffAttack, WeaponAnimNames.StaffIdle, WeaponAnimNames.StaffRun,
		WeaponAnimNames.StaffSkill, WeaponAnimNames.StaffWalk,
		WeaponAnimNames.StoneHarvest,
		WeaponAnimNames.SwordAttack, WeaponAnimNames.SwordAttackv2, WeaponAnimNames.SwordIdle,
		WeaponAnimNames.SwordRun, WeaponAnimNames.SwordSkill, WeaponAnimNames.SwordSkill2,
		WeaponAnimNames.SwordWalk,
		WeaponAnimNames.TalismanAttack, WeaponAnimNames.TalismanIdle, WeaponAnimNames.TalismanRun,
		WeaponAnimNames.TalismanSkill, WeaponAnimNames.TalismanWalk,
		WeaponAnimNames.TomeAttack, WeaponAnimNames.TomeIdle, WeaponAnimNames.TomeRun,
		WeaponAnimNames.TomeSkill, WeaponAnimNames.TomeWalk,
		WeaponAnimNames.WhipAttack, WeaponAnimNames.WhipIdle, WeaponAnimNames.WhipRun,
		WeaponAnimNames.WhipSkill, WeaponAnimNames.WhipWalk,
	])
