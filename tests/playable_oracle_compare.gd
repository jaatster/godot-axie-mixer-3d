extends "res://tests/oracle_compare.gd"
## Playable parity gate against the Unity Play-mode oracle (`tests/playable_oracle/index.json`,
## produced by `tools/unity_export/AxiePlayableOracle.cs`).
##
## Unity drove the real `AxiePlayable` (PlayableGraph + Animator) frame by frame with a fixed
## `Time.captureDeltaTime` through scripted scenarios — one-shot → default, crossfades, queues,
## 1D blends with phase-lock, default blends, pause/resume/time scales, interrupt, start offsets,
## seek, Complete(), user-registered clips, a weapon-package clip — and recorded, at chosen frames,
## the animator state (is_playing, current track, progress, blend, default) and every posed
## transform, plus the frame of every `Completed` event.
##
## This script replays the same step list through the GDScript `AxiePlayable` with the same frame
## model (steps for frame k → one `_tick(dt)` → sample) and compares state, completion frames and
## transforms (same tolerances as the numeric oracle).
##
## Usage:
##   godot --headless --path . -s tests/playable_oracle_compare.gd [-- fixture_or_scenario_substring] [--verbose]

const PROGRESS_TOL := 1.0e-3
const SPEED_TOL := 1.0e-5

var _events: Array = []
var _frame := 0


func _run() -> bool:
	var index_path := "res://tests/playable_oracle/index.json"
	var index: Variant = JSON.parse_string(FileAccess.get_file_as_string(index_path))
	if typeof(index) != TYPE_DICTIONARY:
		printerr("playable oracle index missing: ", index_path)
		return false
	var dt := float(index.get("dt", 1.0 / 60.0))
	var catalog := AxieCatalog.load_json("res://addons/axie_mixer_3d_assets/catalog.json")
	var factory := AxieFactory.new()
	factory.catalog = catalog
	AxieFactory.default_factory = factory
	AxieDefaults.factory = factory
	AxieWeaponAnims.register(catalog, factory)

	var t0 := Time.get_ticks_msec()
	var scenarios := 0
	for fx in index.get("fixtures", []):
		var fx_name := str(fx.get("name", ""))
		for sc in fx.get("scenarios", []):
			var label := "%s/%s" % [fx_name, str(sc.get("name", ""))]
			if not _filter.is_empty() and not label.contains(_filter):
				continue
			scenarios += 1
			_check_scenario(factory, fx, sc, dt, label)
	print("\n%d scenarios, %d checks, %d failures (%.1fs)" % [scenarios, _checks, _failures, (Time.get_ticks_msec() - t0) / 1000.0])
	return _failures == 0


func _check_scenario(factory: AxieFactory, fx: Dictionary, sc: Dictionary, dt: float, label: String) -> void:
	var desc := AxieDescriptor.new()
	desc.body = AxieTypes.body_from_name(str(fx.get("body", "Normal")))
	desc.color_variant = int(fx.get("color_variant", 0))
	desc.clear_parts()
	for p in fx.get("parts", []):
		desc.parts.append(AxiePartDescriptor.from_dict(p))
	var params := AxieInstantiationParams.new()
	params.combine_meshes = false
	var character := factory.create_character(desc, params)
	if character == null or character.root == null:
		_fail("%s: factory returned no character" % label)
		return
	get_root().add_child(character.root)
	var playable := character.playable
	_events.clear()
	playable.completed.connect(func(clip: String) -> void: _events.append([_frame, clip]))

	var dir := "res://tests/playable_oracle/%s" % str(sc.get("dir", fx.get("name", "")))
	var steps: Array = sc.get("steps", [])
	var samples: Dictionary = {}
	var last_frame := 0
	for s in sc.get("samples", []):
		var f := int(s.get("frame", 0))
		samples[f] = str(s.get("file", ""))
		last_frame = maxi(last_frame, f)
	for s in steps:
		last_frame = maxi(last_frame, int(s.get("frame", 0)))

	var ctx := {"track": null, "blend": null}
	var worst := {"node": 0.0, "basis": 0.0, "progress": 0.0}
	var state_bad := 0
	for frame in last_frame + 1:
		_frame = frame
		# Unity frame: scripts' Update (the steps), the animator's Tick, the graph advance and pose
		# (all inside `_tick`), then LateUpdate samples.
		for s in steps:
			if int(s.get("frame", 0)) == frame:
				_apply_step(playable, character, s, ctx, label)
		playable._tick(dt)
		_force_update(character.root)
		if not samples.has(frame):
			continue
		var sample: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join(samples[frame])))
		if typeof(sample) != TYPE_DICTIONARY:
			_fail("%s: unreadable sample %s" % [label, samples[frame]])
			continue
		var sample_label := "%s@f%04d" % [label, frame]
		var pe := _compare_state(playable, sample.get("state", {}), sample_label)
		worst["progress"] = maxf(worst["progress"], pe["progress"])
		state_bad += pe["bad"]
		var r := _compare_sample(character, sample, sample_label, false)
		worst["node"] = maxf(worst["node"], r["node"])
		worst["basis"] = maxf(worst["basis"], r["basis"])

	# Completion events: same frames, same clips, same order.
	var expected_events: Array = []
	for e in sc.get("completed", []):
		expected_events.append([int(e.get("frame", -1)), str(e.get("clip", ""))])
	_checks += 1
	if expected_events != _events:
		_fail("%s: completed events %s, Unity %s" % [label, _events, expected_events])
	print(
		"%-44s worst: node %.5f basis %.5f progress %.5f  state mismatches %d  completions %s"
		% [label, worst["node"], worst["basis"], worst["progress"], state_bad, _events]
	)
	character.dispose()


func _apply_step(playable: AxiePlayable, character: AxieCharacter3D, s: Dictionary, ctx: Dictionary, label: String) -> void:
	var op := str(s.get("op", ""))
	match op:
		"set_default":
			playable.set_default(str(s.get("clip", "")))
		"set_fade":
			playable.fade = float(s.get("value", 0.0))
		"set_time_scale":
			playable.time_scale = float(s.get("value", 1.0))
		"play":
			var track := playable.play(_params_from(s))
			if track == null:
				_fail("%s: play(%s) returned null" % [label, str(s.get("clip", ""))])
			ctx["track"] = track
		"queue":
			var q := AnimPlayParams.new()
			q.clip_name = str(s.get("clip", ""))
			q.loop = bool(s.get("loop", false))
			playable.queue(q)
		"play_blend":
			var blend := playable.play_blend(_points_from(s), float(s.get("speed", 0.0)))
			if blend == null:
				_fail("%s: play_blend returned null" % label)
			ctx["blend"] = blend
		"set_default_blend":
			var blend := playable.set_default_blend(_points_from(s), float(s.get("speed", 0.0)), bool(s.get("play", true)))
			if blend == null:
				_fail("%s: set_default_blend returned null" % label)
			ctx["blend"] = blend
		"set_speed":
			playable.set_speed(float(s.get("value", 0.0)))
		"interrupt":
			playable.interrupt()
		"pause":
			playable.pause()
		"resume":
			playable.resume()
		"stop":
			playable.stop()
		"stop_blend":
			var b: AnimBlend = playable.current_blend if playable.current_blend != null else ctx["blend"]
			if b != null:
				b.stop()
		"seek":
			if ctx["track"] != null:
				(ctx["track"] as AnimTrack).progress = float(s.get("value", 0.0))
		"complete":
			if ctx["track"] != null:
				(ctx["track"] as AnimTrack).complete()
		"register":
			var src := str(s.get("source_clip", ""))
			var clip := character.get_anim_clip(src)
			if clip == null:
				_fail("%s: register: no body clip %s" % [label, src])
			else:
				playable.register(str(s.get("name", "")), clip)
		"unregister":
			playable.unregister(str(s.get("name", "")))
		_:
			_fail("%s: unknown op %s" % [label, op])


static func _params_from(s: Dictionary) -> AnimPlayParams:
	var p := AnimPlayParams.new()
	p.clip_name = str(s.get("clip", ""))
	p.loop = bool(s.get("loop", false))
	p.fade = float(s.get("fade", -1.0))
	p.time_scale = float(s.get("time_scale", 1.0))
	p.normalized_start = float(s.get("normalized_start", 0.0))
	p.start_time = float(s.get("start_time", 0.0))
	return p


static func _points_from(s: Dictionary) -> Array:
	var out: Array = []
	for pt in s.get("points", []):
		out.append([str(pt[0]), float(pt[1])])
	return out


## {progress, bad}: max progress error and number of mismatching state fields.
func _compare_state(playable: AxiePlayable, st: Dictionary, label: String) -> Dictionary:
	var bad: Array[String] = []
	var track := playable.current_track
	var got := {
		"is_playing": playable.is_playing,
		"is_paused": playable.is_paused,
		"track": track.clip_name if track != null else "",
		"track_loop": track.loop if track != null else false,
		"blend_active": playable.current_blend != null,
		"default_clip": playable.default_clip_name,
	}
	for k in got:
		var exp: Variant = st.get(k, null)
		if exp == null:
			continue
		if typeof(exp) == TYPE_STRING:
			if str(got[k]) != str(exp):
				bad.append("%s %s != %s" % [k, got[k], exp])
		elif bool(got[k]) != bool(exp):
			bad.append("%s %s != %s" % [k, got[k], exp])
	var got_progress := track.progress if track != null else 0.0
	var pe := absf(got_progress - float(st.get("progress", 0.0)))
	if pe > PROGRESS_TOL:
		bad.append("progress %.5f != %.5f" % [got_progress, float(st.get("progress", 0.0))])
	var got_speed := playable.speed
	if absf(got_speed - float(st.get("blend_speed", 0.0))) > SPEED_TOL:
		bad.append("blend_speed %.4f != %.4f" % [got_speed, float(st.get("blend_speed", 0.0))])
	_checks += 1
	if not bad.is_empty():
		_fail("%s: state %s" % [label, bad])
	return {"progress": pe, "bad": bad.size()}
