extends SceneTree
## Idle/Walk/Run must resolve from catalog paths after a factory build.
## Headless: godot --headless --path . -s tests/test_clip_resolve.gd

const AxieCatalog := preload("res://addons/axie_mixer_3d/runtime/axie_catalog.gd")
const AxieFactory := preload("res://addons/axie_mixer_3d/runtime/axie_factory.gd")
const AxieCharacter3D := preload("res://addons/axie_mixer_3d/runtime/axie_character_3d.gd")
const AxieDescriptor := preload("res://addons/axie_mixer_3d/core/axie_descriptor.gd")
const AxiePartDescriptor := preload("res://addons/axie_mixer_3d/core/axie_part_descriptor.gd")
const AxieTypes := preload("res://addons/axie_mixer_3d/core/axie_types.gd")
const AxieDefaults := preload("res://addons/axie_mixer_3d/core/axie_defaults.gd")
const AxieInstantiationParams := preload("res://addons/axie_mixer_3d/core/axie_instantiation_params.gd")


func _init() -> void:
	var errs: Array = run()
	if errs.is_empty():
		print("ok  clip_resolve")
		quit(0)
	else:
		for e in errs:
			print("FAIL clip_resolve: %s" % e)
		quit(1)


static func run() -> Array:
	var errs: Array = []
	var cat = AxieCatalog.load_json("res://addons/axie_mixer_3d_assets/catalog.json")
	if cat.bodies.is_empty():
		errs.append("catalog bodies empty")
		return errs
	var factory = AxieFactory.new()
	factory.catalog = cat
	AxieFactory.default_factory = factory
	AxieDefaults.factory = factory
	AxieDefaults.combine_meshes = false
	var desc = AxieDescriptor.new()
	desc.body = AxieTypes.Body.NORMAL
	desc.color_variant = 3
	for t in [
		AxieTypes.Part.EYE,
		AxieTypes.Part.MOUTH,
		AxieTypes.Part.EAR,
		AxieTypes.Part.HORN,
		AxieTypes.Part.BACK,
		AxieTypes.Part.TAIL,
	]:
		desc.parts.append(AxiePartDescriptor.new(t, 0, "Beast", 2, 1))
	var params = AxieInstantiationParams.new()
	params.combine_meshes = false
	var ch = AxieCharacter3D.from_descriptor(desc, params)
	if ch == null or ch.root == null:
		errs.append("from_descriptor failed")
		return errs
	for clip_name in ["Idle", "Walk", "Run"]:
		var clip: Animation = ch.get_anim_clip(clip_name)
		if clip == null:
			errs.append("get_anim_clip %s is null" % clip_name)
			continue
		if clip.get_track_count() <= 0:
			errs.append("%s has 0 tracks" % clip_name)
		if clip.length <= 0.0:
			errs.append("%s length %s" % [clip_name, clip.length])
	var playable = ch.playable
	if playable == null:
		errs.append("playable is null")
	else:
		for clip_name in ["Idle", "Walk", "Run"]:
			if not playable.is_registered(clip_name):
				errs.append("playable not registered %s" % clip_name)
		var track = playable.play("Idle", "", true)
		if track == null:
			errs.append("play Idle returned null")
	ch.dispose()
	AxieFactory.default_factory = null
	AxieDefaults.factory = null
	return errs
