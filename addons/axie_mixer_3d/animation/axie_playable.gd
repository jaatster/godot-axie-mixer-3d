class_name AxiePlayable
extends RefCounted
## Official Axie animator. PlayableGraph analog: AnimationPlayer (AnimationMixer) + 2-input (active vs previous) crossfade.
## Ticks on process. Does not use AnimationTree.

signal completed(clip_name: String)

enum ActiveKind { NONE, SINGLE, BLEND }

const _LIB := &"axie"
const _MIN_DURATION := 0.0001

class _Updater extends Node:
	var playable_ref: WeakRef

	func _process(delta: float) -> void:
		if playable_ref == null:
			return
		var p: Variant = playable_ref.get_ref()
		if p != null:
			p._tick(delta)


## AnimationClipPlayable analog. `set_time` mirrors `Playable.SetTime`: the graph does not advance a
## playable on the frame its time was set explicitly (Unity skips its next PrepareFrame delta).
class _ClipPlayable:
	var clip: Animation
	var time: float = 0.0
	var speed: float = 0.0
	var duration: float = 0.0
	var length: float = 0.0
	var loop: bool = false
	var last_weight: float = 0.0
	var _time_set: bool = false

	func set_time(value: float) -> void:
		time = value
		_time_set = true

	func advance(delta: float) -> void:
		if _time_set:
			_time_set = false
			return
		time += speed * delta
		if duration != INF and time > duration:
			time = duration


class _Source:
	var kind: int = 0
	var clip: _ClipPlayable
	var clips: Array = []
	var mix_weights: PackedFloat32Array = PackedFloat32Array()


class _BoneAcc:
	var skeleton: Skeleton3D
	var bone: int = -1
	var pos: Vector3 = Vector3.ZERO
	var pos_w: float = 0.0
	var rest_pos: Vector3 = Vector3.ZERO
	var rot: Quaternion = Quaternion(0.0, 0.0, 0.0, 0.0)
	var rot_w: float = 0.0
	var rest_rot: Quaternion = Quaternion.IDENTITY
	var scl: Vector3 = Vector3.ZERO
	var scl_w: float = 0.0
	var rest_scl: Vector3 = Vector3.ONE


class _NodeAcc:
	var node: Node3D
	var pos: Vector3 = Vector3.ZERO
	var pos_w: float = 0.0
	var rest_pos: Vector3 = Vector3.ZERO
	var rot: Quaternion = Quaternion(0.0, 0.0, 0.0, 0.0)
	var rot_w: float = 0.0
	var rest_rot: Quaternion = Quaternion.IDENTITY
	var scl: Vector3 = Vector3.ZERO
	var scl_w: float = 0.0
	var rest_scl: Vector3 = Vector3.ONE


class _ValAcc:
	var target: Object
	var prop: NodePath
	var mesh: MeshInstance3D
	var blend_shape_idx: int = -1
	var value: Variant
	var w: float = 0.0
	var rest: Variant
	var has_rest: bool = false


var _character: Object
var _root: Node3D
var _player: AnimationPlayer
var _library: AnimationLibrary
var _skeleton: Skeleton3D
var _user_clips: Dictionary = {}
var _graph_playing: bool = false
var _disposed: bool = false

var _active_kind: int = ActiveKind.NONE
var _active: _Source
var _previous: _Source
var _active_clip: _ClipPlayable
var _active_length: float = 0.0

var _fading: bool = false
var _fade_duration: float = 0.0
var _fade_elapsed: float = 0.0

var _current: AnimTrack
var _blend: AnimBlend
var _default_clip_name: String = ""
var _default_blend: AnimBlend
var _time_scale: float = 1.0
var _fade: float = 0.0
var _paused: bool = false

var _target_cache: Dictionary = {}
var _touched_bones: Dictionary = {} ## bone key -> _BoneAcc written by the last _commit_pose
var _touched_nodes: Dictionary = {} ## node instance id -> _NodeAcc written by the last _commit_pose
var _touched_values: Dictionary = {} ## value key -> _ValAcc written by the last _commit_pose
var _pose_written: bool = false ## the last _commit_pose wrote something (or reset to rest)
var _node_bind: Dictionary = {}


static func compute_weights(thresholds: PackedFloat32Array, speed: float) -> PackedFloat32Array:
	var n := thresholds.size()
	var w := PackedFloat32Array()
	w.resize(n)
	w.fill(0.0)
	if n == 0:
		return w
	if n == 1 or speed <= thresholds[0]:
		w[0] = 1.0
		return w
	if speed >= thresholds[n - 1]:
		w[n - 1] = 1.0
		return w
	for i in n - 1:
		if speed >= thresholds[i] and speed <= thresholds[i + 1]:
			var span: float = thresholds[i + 1] - thresholds[i]
			var frac: float = (speed - thresholds[i]) / span if span > 0.0 else 0.0
			w[i] = 1.0 - frac
			w[i + 1] = frac
			break
	return w


static func phase_locked_speeds(
	lengths: PackedFloat32Array,
	weights: PackedFloat32Array,
	time_scale: float
) -> PackedFloat32Array:
	var n := mini(lengths.size(), weights.size())
	var ref_len := 0.0
	for i in n:
		if weights[i] > 0.0:
			ref_len += weights[i] * lengths[i]
	if ref_len <= 0.0:
		ref_len = lengths[0] if n > 0 and lengths[0] > 0.0 else 1.0
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		if weights[i] > 0.0:
			out[i] = lengths[i] / ref_len * time_scale if lengths[i] > 0.0 else time_scale
		else:
			out[i] = 0.0
	return out


var time_scale: float:
	get:
		return _time_scale
	set(value):
		_time_scale = value
		_apply_live_time_scale()

var fade: float:
	get:
		return _fade
	set(value):
		_fade = value

var speed: float:
	get:
		var b: AnimBlend = _blend if _blend != null else _default_blend
		return b.speed if b != null else 0.0
	set(value):
		set_speed(value)

var current_track: AnimTrack:
	get:
		return _current

var current_blend: AnimBlend:
	get:
		return _blend

var default_clip_name: String:
	get:
		return _default_clip_name

var is_playing: bool:
	get:
		return _current != null and _graph_playing and is_instance_valid(_player) and not _disposed

var is_paused: bool:
	get:
		return _paused


func _init(character: Object = null) -> void:
	if character == null:
		return
	var root_var: Variant = character.get("root")
	if root_var == null or not (root_var is Node3D):
		push_error("AxiePlayable: character.root is required")
		return
	_character = character
	_root = root_var as Node3D
	_graph_playing = true
	_ensure_runtime_nodes()


func _ensure_runtime_nodes() -> void:
	if _disposed or _root == null:
		return
	if _player == null or not is_instance_valid(_player):
		var existing := _root.get_node_or_null("AxiePlayable")
		if existing is AnimationPlayer:
			_player = existing
		else:
			_player = AnimationPlayer.new()
			_player.name = "AxiePlayable"
			_root.add_child(_player)
		_player.active = false
		_player.deterministic = true
		_player.callback_mode_process = AnimationPlayer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		_player.root_node = NodePath("..")
		if _player.has_animation_library(_LIB):
			_library = _player.get_animation_library(_LIB)
		else:
			_library = AnimationLibrary.new()
			_player.add_animation_library(_LIB, _library)
	if _player.get_node_or_null("AxiePlayableUpdater") == null:
		var updater := _Updater.new()
		updater.name = "AxiePlayableUpdater"
		updater.playable_ref = weakref(self)
		updater.process_priority = 1
		_player.add_child(updater)
	else:
		var updater: Node = _player.get_node("AxiePlayableUpdater")
		updater.set("playable_ref", weakref(self))


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and not _disposed:
		_disposed = true
		_blend = null
		_default_blend = null
		_current = null
		_graph_playing = false


func register(name: String, clip: Animation) -> void:
	if name.is_empty():
		push_error("Register requires a non-empty name.")
		return
	if clip == null:
		push_error("Register requires a clip.")
		return
	var key := name.to_lower()
	if not _user_clips.has(key) and _resolve_baked(name) != null:
		push_warning("AxiePlayable: Register('%s') shadows a baked body clip of the same name." % name)
	_user_clips[key] = clip
	_ensure_in_library(name, clip)


func unregister(name: String) -> bool:
	if name.is_empty():
		return false
	return _user_clips.erase(name.to_lower())


func is_registered(name: String) -> bool:
	return _resolve_source(name) != null


func set_default(clip_name: String) -> void:
	_default_blend = null
	_default_clip_name = clip_name


func try_set_default(clip_name: Variant) -> bool:
	if clip_name == null:
		_default_clip_name = ""
		_default_blend = null
		return true
	var name := str(clip_name)
	if _resolve_source(name) == null:
		return false
	_default_blend = null
	_default_clip_name = name
	return true


func set_default_blend(points: Array, p_speed: float = 0.0, play: bool = true) -> AnimBlend:
	var blend := _build_blend(points, p_speed)
	if blend == null:
		push_warning("AxiePlayable: SetDefaultBlend found no valid clips; default unchanged.")
		return null
	_default_clip_name = ""
	_default_blend = blend
	if play:
		_arm_blend(blend)
	return blend


func set_speed(p_speed: float) -> void:
	if _blend != null:
		_blend.speed = p_speed
	if _default_blend != null and _default_blend != _blend:
		_default_blend.speed = p_speed


func get_duration(clip_name: String) -> float:
	var clip := _resolve_source(clip_name)
	return clip.length if clip != null else 0.0


func try_get_duration(clip_name: String, seconds: Array = []) -> bool:
	var clip := _resolve_source(clip_name)
	var length := clip.length if clip != null else 0.0
	if seconds.is_empty():
		seconds.append(length)
	else:
		seconds[0] = length
	return clip != null


func play(
	clip_name_or_params: Variant,
	state_name: String = "",
	loop: bool = false,
	on_complete: Callable = Callable()
) -> AnimTrack:
	return _play_params(_as_params(clip_name_or_params, state_name, loop, on_complete))


func play_blend(points: Array, p_speed: float = 0.0) -> AnimBlend:
	var blend := _build_blend(points, p_speed)
	if blend == null:
		push_warning("AxiePlayable: PlayBlend found no valid clips; nothing played.")
		return null
	_arm_blend(blend)
	return blend


func queue(
	clip_name_or_params: Variant,
	state_name: String = "",
	loop: bool = false,
	on_complete: Callable = Callable()
) -> AnimTrack:
	if _current != null and is_playing:
		return _current.queue(clip_name_or_params, state_name, loop, on_complete)
	return play(clip_name_or_params, state_name, loop, on_complete)


func interrupt() -> void:
	if _current == null and _blend == null and _default_clip_name.is_empty() and _default_blend == null:
		return
	var queued: AnimPlayParams = _current.queued_next if _current != null else null
	_teardown_active()
	_current = null
	_blend = null
	if queued != null:
		_play_params(queued)
	else:
		_play_default_internal()


func pause() -> void:
	_paused = true
	_apply_pause_speeds()


func resume() -> void:
	_paused = false
	if _current != null and _active_kind == ActiveKind.SINGLE and _active_clip != null:
		_active_clip.speed = _time_scale * _current.params.time_scale


func stop() -> void:
	_teardown_active()
	_current = null
	_blend = null


func dispose() -> void:
	_disposed = true
	_blend = null
	_default_blend = null
	_teardown_active()
	_library = null
	_user_clips.clear()
	_current = null
	_active_kind = ActiveKind.NONE
	_graph_playing = false
	_character = null
	_root = null
	_skeleton = null
	_target_cache.clear()
	_node_bind.clear()
	if is_instance_valid(_player):
		_player.queue_free()
	_player = null


func is_track_active(track: AnimTrack) -> bool:
	return _current == track


func is_blend_active(blend: AnimBlend) -> bool:
	return _blend != null and _blend == blend


func stop_blend(blend: AnimBlend) -> void:
	if _blend != blend:
		return
	var was_default := blend == _default_blend
	_teardown_active()
	_blend = null
	_current = null
	if was_default:
		return
	_play_default_internal()


func make_pending_track(data: AnimPlayParams) -> AnimTrack:
	var clip := data.clip_name if data != null else ""
	return AnimTrack.new(self, data, clip)


func advance_on_complete(fire_callbacks: bool) -> void:
	var finished := _current
	_current = null
	if fire_callbacks:
		if finished != null and finished.params != null and finished.params.on_complete.is_valid():
			finished.params.on_complete.call()
		if _current == null:
			completed.emit(finished.clip_name if finished != null else "")
	if _current != null:
		return
	if finished != null and finished.queued_next != null:
		_play_params(finished.queued_next)
	else:
		_play_default_internal(finished)


func get_track_duration(track: AnimTrack) -> float:
	if track == null:
		return 0.0
	var clip := _resolve_source(track.clip_name)
	return clip.length if clip != null else 0.0


func get_track_progress(track: AnimTrack) -> float:
	if _current != track or _active_kind != ActiveKind.SINGLE or _active_clip == null:
		return 0.0
	return clampf(_active_clip.time / _active_length, 0.0, 1.0) if _active_length > 0.0 else 0.0


func seek_track(track: AnimTrack, normalized_time: float) -> void:
	if _current != track or _active_kind != ActiveKind.SINGLE or _active_clip == null:
		return
	if _active_length > 0.0:
		_active_clip.set_time(clampf(normalized_time, 0.0, 1.0) * _active_length)


func _play_params(data: AnimPlayParams) -> AnimTrack:
	if _disposed:
		return null
	if data == null or data.clip_name.is_empty():
		push_error("AnimPlayParams.clip_name is required.")
		return null
	var clip := _resolve_source(data.clip_name)
	if clip == null:
		push_warning("AxiePlayable: clip '%s' not found on this body." % data.clip_name)
		return null
	var use_fade := data.fade if data.fade >= 0.0 else _fade
	var cp := _ClipPlayable.new()
	cp.clip = clip
	cp.length = clip.length
	cp.loop = data.loop
	cp.duration = INF if data.loop else maxf(clip.length, _MIN_DURATION)
	cp.speed = 0.0 if _paused else _time_scale * data.time_scale
	var start := 0.0
	if data.normalized_start > 0.0:
		start = data.normalized_start * clip.length
	elif data.start_time > 0.0:
		start = data.start_time
	if start > 0.0:
		cp.set_time(start)
	var src := _Source.new()
	src.kind = ActiveKind.SINGLE
	src.clip = cp
	_set_active_source(src, use_fade)
	_blend = null
	_active_length = clip.length
	_ensure_in_library(data.clip_name, clip)
	_current = AnimTrack.new(self, data, data.clip_name)
	return _current


func _build_blend(points: Array, p_speed: float) -> AnimBlend:
	if points.is_empty():
		push_error("A blend requires at least one (clipName, threshold) point.")
		return null
	var valid: Array = []
	for entry in points:
		var pair := _parse_point(entry)
		if pair.is_empty():
			continue
		var clip_name: String = pair[0]
		var threshold: float = pair[1]
		var clip := _resolve_source(clip_name)
		if clip == null:
			push_warning("AxiePlayable: blend clip '%s' not found on this body; skipping." % clip_name)
			continue
		var pt := AnimBlend.Point.new()
		pt.clip_name = clip_name
		pt.threshold = threshold
		pt.state_name = clip_name
		pt.length = clip.length
		valid.append(pt)
	if valid.is_empty():
		return null
	valid.sort_custom(func(a, b): return a.threshold < b.threshold)
	var blend := AnimBlend.new(self, valid)
	blend.speed = p_speed
	return blend


func _arm_blend(blend: AnimBlend, p_fade: float = 0.0) -> void:
	_current = null
	var src := _Source.new()
	src.kind = ActiveKind.BLEND
	src.clips = []
	src.mix_weights.resize(blend.points.size())
	src.mix_weights.fill(0.0)
	for i in blend.points.size():
		var pt: AnimBlend.Point = blend.points[i]
		var clip := _resolve_source(pt.clip_name)
		if clip == null:
			src.clips.append(null)
			continue
		var cp := _ClipPlayable.new()
		cp.clip = clip
		cp.length = clip.length
		cp.duration = INF
		cp.speed = 0.0
		cp.loop = true
		src.clips.append(cp)
		_ensure_in_library(pt.clip_name, clip)
	_blend = blend
	var crossfade := p_fade > 0.0 and _active_kind != ActiveKind.NONE
	_set_active_source(src, p_fade if crossfade else 0.0)
	_update_blend()


func _play_default_internal(_from: AnimTrack = null) -> bool:
	var use_fade := _fade
	if _default_blend != null:
		_arm_blend(_default_blend, use_fade)
		return true
	if not _default_clip_name.is_empty():
		var data := AnimPlayParams.new()
		data.clip_name = _default_clip_name
		data.loop = true
		data.fade = use_fade
		_play_params(data)
		return true
	return false


## One frame, in Unity's order: `AxiePlayable.Tick` (fade envelope, blend weights / phase-lock, loop
## wrap and one-shot completion, all reading the clip times left by the previous frame), then the
## PlayableGraph advances every source by `delta` (skipping playables whose time was just set), then
## the Animator writes the pose. The updater node runs this at process priority 1, after user code,
## like `AxieAnimatorUpdater.Update` runs after the caller's `Update`.
func _tick(delta: float) -> void:
	if _disposed:
		return
	if _fading:
		if not _paused:
			_fade_elapsed += delta
		var t := clampf(_fade_elapsed / _fade_duration, 0.0, 1.0) if _fade_duration > 0.0 else 1.0
		if t >= 1.0:
			_finalize_previous_immediate()
	if _blend != null:
		_update_blend()
	elif _current != null and _active_kind == ActiveKind.SINGLE and _active_clip != null and _active_length > 0.0:
		var length := _active_length
		var time := _active_clip.time
		if _current.loop:
			if time >= length:
				_active_clip.set_time(fposmod(time, length))
		elif not _paused and time >= length:
			_active_clip.set_time(length)
			advance_on_complete(true)
	_advance_source(_active, delta)
	_advance_source(_previous, delta)
	_apply_graph()


func _fill_blend_weights(blend: AnimBlend) -> PackedFloat32Array:
	var n := blend.points.size()
	var th := PackedFloat32Array()
	th.resize(n)
	for i in n:
		th[i] = (blend.points[i] as AnimBlend.Point).threshold
	var w := compute_weights(th, blend.speed)
	if blend.weights.size() != w.size():
		blend.weights.resize(w.size())
	for i in w.size():
		blend.weights[i] = w[i]
	return blend.weights


func _update_blend() -> void:
	if _active == null or _active.kind != ActiveKind.BLEND or _blend == null:
		return
	var pts: Array = _blend.points
	var n := pts.size()
	var w := _fill_blend_weights(_blend)
	if _active.mix_weights.size() != n:
		_active.mix_weights.resize(n)
	var ref_len := 0.0
	for i in n:
		if w[i] > 0.0:
			ref_len += w[i] * (pts[i] as AnimBlend.Point).length
	if ref_len <= 0.0:
		var l0: float = (pts[0] as AnimBlend.Point).length if n > 0 else 0.0
		ref_len = l0 if l0 > 0.0 else 1.0
	var phase := 0.0
	var have_phase := false
	for i in n:
		if i >= _active.clips.size():
			break
		var cp: _ClipPlayable = _active.clips[i]
		var pt: AnimBlend.Point = pts[i]
		if (
			cp != null
			and cp.clip != null
			and cp.last_weight > 0.0
			and w[i] > 0.0
			and pt.length > 0.0
		):
			phase = fposmod(cp.time, pt.length) / pt.length
			have_phase = true
			break
	for i in n:
		if i >= _active.clips.size():
			break
		var cp: _ClipPlayable = _active.clips[i]
		if cp == null or cp.clip == null:
			_active.mix_weights[i] = 0.0
			continue
		var pt: AnimBlend.Point = pts[i]
		if w[i] > 0.0:
			if cp.last_weight <= 0.0:
				cp.set_time(phase * pt.length if have_phase else 0.0)
			_active.mix_weights[i] = w[i]
			cp.last_weight = w[i]
			if _paused:
				cp.speed = 0.0
			elif pt.length > 0.0:
				cp.speed = pt.length / ref_len * _time_scale
			else:
				cp.speed = _time_scale
			if pt.length > 0.0 and cp.time >= pt.length:
				cp.set_time(fposmod(cp.time, pt.length))
		else:
			_active.mix_weights[i] = 0.0
			cp.last_weight = 0.0
			cp.speed = 0.0


func _set_active_source(new_root: _Source, p_fade: float) -> void:
	_finalize_previous_immediate()
	var has_old := _active_kind != ActiveKind.NONE
	if p_fade > 0.0:
		if has_old:
			_previous = _active
		_active = new_root
		_fading = true
		_fade_duration = p_fade
		_fade_elapsed = 0.0
	else:
		_previous = null
		_active = new_root
		_fading = false
	_active_kind = new_root.kind if new_root != null else ActiveKind.NONE
	_active_clip = new_root.clip if new_root != null and new_root.kind == ActiveKind.SINGLE else null


func _finalize_previous_immediate() -> void:
	_previous = null
	_fading = false
	_fade_elapsed = 0.0
	_fade_duration = 0.0


func _teardown_active() -> void:
	_finalize_previous_immediate()
	if _active_kind != ActiveKind.NONE:
		_active = null
		_active_kind = ActiveKind.NONE
		_active_clip = null


func _advance_source(src: _Source, delta: float) -> void:
	if src == null:
		return
	if src.kind == ActiveKind.SINGLE:
		if src.clip != null:
			src.clip.advance(delta)
	elif src.kind == ActiveKind.BLEND:
		for item in src.clips:
			if item != null:
				(item as _ClipPlayable).advance(delta)


func _apply_pause_speeds() -> void:
	if _active_kind == ActiveKind.SINGLE and _active_clip != null:
		_active_clip.speed = 0.0
	elif _active_kind == ActiveKind.BLEND and _active != null:
		for item in _active.clips:
			if item != null:
				(item as _ClipPlayable).speed = 0.0


func _apply_live_time_scale() -> void:
	if _current == null or _paused:
		return
	if _active_kind == ActiveKind.SINGLE and _active_clip != null:
		_active_clip.speed = _time_scale * _current.params.time_scale


func _apply_graph() -> void:
	if _root == null:
		return
	if _active_kind == ActiveKind.NONE and not _fading:
		# Unity's Animator keeps writing default values while the graph has no source, so
		# stop() / stopping the default blend snap the rig back to the rest pose.
		if _pose_written:
			_commit_pose({}, {}, {})
			_pose_written = false
		return
	_pose_written = true
	var t := 1.0
	if _fading:
		t = clampf(_fade_elapsed / _fade_duration, 0.0, 1.0) if _fade_duration > 0.0 else 1.0
	var bones: Dictionary = {}
	var nodes: Dictionary = {}
	var values: Dictionary = {}
	_sample_source(_active, t, bones, nodes, values)
	if _fading and _previous != null:
		_sample_source(_previous, 1.0 - t, bones, nodes, values)
	_commit_pose(bones, nodes, values)


func _sample_source(src: _Source, outer_w: float, bones: Dictionary, nodes: Dictionary, values: Dictionary) -> void:
	if src == null or outer_w <= 0.0:
		return
	if src.kind == ActiveKind.SINGLE:
		_sample_clip(src.clip, outer_w, bones, nodes, values)
		return
	if src.kind != ActiveKind.BLEND:
		return
	# A blend is its own AnimationMixerPlayable feeding the root mixer: Unity normalises the inner
	# quaternion sum before the outer mix, so flattening the weights would under-weight the blend
	# whenever its clips disagree (visible as a few milliradians mid-crossfade). Mix the inner
	# clips into their own accumulators, resolve them (rest fill + normalise) and feed the result
	# to the outer accumulators as a single input.
	var inner_bones: Dictionary = {}
	var inner_nodes: Dictionary = {}
	var inner_values: Dictionary = {}
	for i in src.clips.size():
		var mw := src.mix_weights[i] if i < src.mix_weights.size() else 0.0
		if mw <= 0.0:
			continue
		_sample_clip(src.clips[i], mw, inner_bones, inner_nodes, inner_values)
	_merge_nested(inner_bones, inner_nodes, inner_values, outer_w, bones, nodes, values)


## Resolve one mixer's accumulators (as Unity's mixer output would) and add them to the parent
## mixer's accumulators with weight `outer_w`.
func _merge_nested(
	inner_bones: Dictionary,
	inner_nodes: Dictionary,
	inner_values: Dictionary,
	outer_w: float,
	bones: Dictionary,
	nodes: Dictionary,
	values: Dictionary
) -> void:
	for key in inner_bones:
		var acc: _BoneAcc = inner_bones[key]
		var out := _bone_acc(bones, acc.skeleton, acc.bone)
		if acc.pos_w > 0.0:
			out.pos += (acc.pos + acc.rest_pos * (1.0 - acc.pos_w)) * outer_w
			out.pos_w += outer_w
		if acc.rot_w > 0.0:
			_add_bone_rot(out, _finish_rot(acc.rot, acc.rot_w, acc.rest_rot), outer_w)
		if acc.scl_w > 0.0:
			out.scl += (acc.scl + acc.rest_scl * (1.0 - acc.scl_w)) * outer_w
			out.scl_w += outer_w
	for key in inner_nodes:
		var nacc: _NodeAcc = inner_nodes[key]
		var nout := _node_acc(nodes, nacc.node)
		if nacc.pos_w > 0.0:
			nout.pos += (nacc.pos + nacc.rest_pos * (1.0 - nacc.pos_w)) * outer_w
			nout.pos_w += outer_w
		if nacc.rot_w > 0.0:
			_add_node_rot(nout, _finish_rot(nacc.rot, nacc.rot_w, nacc.rest_rot), outer_w)
		if nacc.scl_w > 0.0:
			nout.scl += (nacc.scl + nacc.rest_scl * (1.0 - nacc.scl_w)) * outer_w
			nout.scl_w += outer_w
	for key in inner_values:
		var vacc: _ValAcc = inner_values[key]
		var resolved: Variant = vacc.value
		if vacc.has_rest:
			resolved = _add_any(resolved, _mul_any(vacc.rest, 1.0 - vacc.w))
		elif vacc.w > 0.0:
			resolved = _div_any(resolved, vacc.w)
		if resolved is Quaternion:
			resolved = (resolved as Quaternion).normalized()
		_acc_value(values, key, vacc.target, vacc.prop, resolved, outer_w, vacc.mesh, vacc.blend_shape_idx)


func _sample_clip(cp: _ClipPlayable, weight: float, bones: Dictionary, nodes: Dictionary, values: Dictionary) -> void:
	if cp == null or cp.clip == null or weight <= 0.0:
		return
	var anim: Animation = cp.clip
	var t := cp.time
	for i in anim.get_track_count():
		if not anim.track_is_enabled(i):
			continue
		var path := anim.track_get_path(i)
		match anim.track_get_type(i):
			Animation.TYPE_POSITION_3D:
				_acc_pos(path, anim.position_track_interpolate(i, t), weight, bones, nodes)
			Animation.TYPE_ROTATION_3D:
				_acc_rot(path, anim.rotation_track_interpolate(i, t), weight, bones, nodes)
			Animation.TYPE_SCALE_3D:
				_acc_scl(path, anim.scale_track_interpolate(i, t), weight, bones, nodes)
			Animation.TYPE_BLEND_SHAPE:
				var mesh := _resolve_mesh(path)
				if mesh == null:
					continue
				var bs := StringName(path.get_concatenated_subnames())
				var idx := mesh.find_blend_shape_by_name(bs)
				if idx < 0:
					continue
				var key := "bs:%d:%d" % [mesh.get_instance_id(), idx]
				_acc_value(
					values,
					key,
					mesh,
					NodePath(),
					anim.blend_shape_track_interpolate(i, t),
					weight,
					mesh,
					idx
				)
			Animation.TYPE_VALUE:
				var node := _resolve_node(path)
				if node == null:
					continue
				var prop := NodePath(path.get_concatenated_subnames())
				if prop.is_empty():
					continue
				var key := "v:%d:%s" % [node.get_instance_id(), String(prop)]
				_acc_value(values, key, node, prop, anim.value_track_interpolate(i, t), weight)
			Animation.TYPE_BEZIER:
				var node_b := _resolve_node(path)
				if node_b == null:
					continue
				var prop_b := NodePath(path.get_concatenated_subnames())
				if prop_b.is_empty():
					continue
				var key_b := "v:%d:%s" % [node_b.get_instance_id(), String(prop_b)]
				_acc_value(values, key_b, node_b, prop_b, anim.bezier_track_interpolate(i, t), weight)


func _acc_pos(path: NodePath, sample: Vector3, w: float, bones: Dictionary, nodes: Dictionary) -> void:
	var target := _resolve_transform_target(path)
	if target.has("skeleton"):
		var acc := _bone_acc(bones, target["skeleton"], int(target["bone"]))
		acc.pos += sample * w
		acc.pos_w += w
	elif target.has("node"):
		var nacc := _node_acc(nodes, target["node"])
		nacc.pos += sample * w
		nacc.pos_w += w


func _acc_rot(path: NodePath, sample: Quaternion, w: float, bones: Dictionary, nodes: Dictionary) -> void:
	var target := _resolve_transform_target(path)
	if target.has("skeleton"):
		_add_bone_rot(_bone_acc(bones, target["skeleton"], int(target["bone"])), sample, w)
	elif target.has("node"):
		_add_node_rot(_node_acc(nodes, target["node"]), sample, w)


func _acc_scl(path: NodePath, sample: Vector3, w: float, bones: Dictionary, nodes: Dictionary) -> void:
	var target := _resolve_transform_target(path)
	if target.has("skeleton"):
		var acc := _bone_acc(bones, target["skeleton"], int(target["bone"]))
		acc.scl += sample * w
		acc.scl_w += w
	elif target.has("node"):
		var nacc := _node_acc(nodes, target["node"])
		nacc.scl += sample * w
		nacc.scl_w += w


func _bone_acc(bones: Dictionary, skel: Skeleton3D, bone: int) -> _BoneAcc:
	var key := "%d:%d" % [skel.get_instance_id(), bone]
	if bones.has(key):
		return bones[key]
	var acc := _BoneAcc.new()
	acc.skeleton = skel
	acc.bone = bone
	var rest := skel.get_bone_rest(bone)
	acc.rest_pos = rest.origin
	acc.rest_rot = rest.basis.get_rotation_quaternion()
	acc.rest_scl = rest.basis.get_scale()
	bones[key] = acc
	return acc


func _node_acc(nodes: Dictionary, node: Node3D) -> _NodeAcc:
	var key := node.get_instance_id()
	if nodes.has(key):
		return nodes[key]
	var acc := _NodeAcc.new()
	acc.node = node
	var rest := _node_rest(node)
	acc.rest_pos = rest.origin
	acc.rest_rot = rest.basis.get_rotation_quaternion()
	acc.rest_scl = rest.basis.get_scale()
	nodes[key] = acc
	return acc


func _node_rest(node: Node3D) -> Transform3D:
	var id := node.get_instance_id()
	if not _node_bind.has(id):
		_node_bind[id] = node.transform
	return _node_bind[id]


static func _add_bone_rot(acc: _BoneAcc, q: Quaternion, w: float) -> void:
	if acc.rot_w > 0.0 and acc.rot.dot(q) < 0.0:
		q = Quaternion(-q.x, -q.y, -q.z, -q.w)
	acc.rot = Quaternion(acc.rot.x + q.x * w, acc.rot.y + q.y * w, acc.rot.z + q.z * w, acc.rot.w + q.w * w)
	acc.rot_w += w


static func _add_node_rot(acc: _NodeAcc, q: Quaternion, w: float) -> void:
	if acc.rot_w > 0.0 and acc.rot.dot(q) < 0.0:
		q = Quaternion(-q.x, -q.y, -q.z, -q.w)
	acc.rot = Quaternion(acc.rot.x + q.x * w, acc.rot.y + q.y * w, acc.rot.z + q.z * w, acc.rot.w + q.w * w)
	acc.rot_w += w


func _acc_value(
	values: Dictionary,
	key: String,
	target: Object,
	prop: NodePath,
	sample: Variant,
	w: float,
	mesh: MeshInstance3D = null,
	bs: int = -1
) -> void:
	var acc: _ValAcc
	if values.has(key):
		acc = values[key]
		acc.value = _add_any(acc.value, _mul_any(sample, w))
		acc.w += w
		return
	acc = _ValAcc.new()
	acc.target = target
	acc.prop = prop
	acc.mesh = mesh
	acc.blend_shape_idx = bs
	acc.value = _mul_any(sample, w)
	acc.w = w
	if mesh != null and bs >= 0:
		acc.rest = mesh.get_blend_shape_value(bs)
		acc.has_rest = true
	elif target != null and not prop.is_empty():
		acc.rest = target.get_indexed(prop)
		acc.has_rest = true
	values[key] = acc


func _commit_pose(bones: Dictionary, nodes: Dictionary, values: Dictionary) -> void:
	var skels: Dictionary = {}
	var touched: Dictionary = {}
	for key in bones:
		var acc: _BoneAcc = bones[key]
		# Unity's PlayableGraph writes the default (rest) value for any property no active clip
		# animates; a channel missing from every input therefore snaps back to rest.
		acc.skeleton.set_bone_pose_position(acc.bone, acc.pos + acc.rest_pos * (1.0 - acc.pos_w))
		acc.skeleton.set_bone_pose_rotation(acc.bone, _finish_rot(acc.rot, acc.rot_w, acc.rest_rot))
		acc.skeleton.set_bone_pose_scale(acc.bone, acc.scl + acc.rest_scl * (1.0 - acc.scl_w))
		if acc.skeleton:
			skels[acc.skeleton] = true
			touched[key] = true
	# Bones a previous clip posed but no current input touches (glTF import drops constant
	# channels, so most clips leave many bones without tracks) return to rest.
	for key in _touched_bones:
		if touched.has(key):
			continue
		var acc: _BoneAcc = _touched_bones[key]
		if is_instance_valid(acc.skeleton):
			acc.skeleton.reset_bone_pose(acc.bone)
			skels[acc.skeleton] = true
	_touched_bones = bones
	for skel in skels:
		if skel is Skeleton3D:
			(skel as Skeleton3D).force_update_all_bone_transforms()
	for key in nodes:
		var nacc: _NodeAcc = nodes[key]
		if nacc.pos_w > 0.0:
			nacc.node.position = nacc.pos + nacc.rest_pos * (1.0 - nacc.pos_w)
		if nacc.rot_w > 0.0:
			nacc.node.quaternion = _finish_rot(nacc.rot, nacc.rot_w, nacc.rest_rot)
		if nacc.scl_w > 0.0:
			nacc.node.scale = nacc.scl + nacc.rest_scl * (1.0 - nacc.scl_w)
	for key in _touched_nodes:
		if nodes.has(key):
			continue
		var old: _NodeAcc = _touched_nodes[key]
		if is_instance_valid(old.node):
			old.node.transform = _node_rest(old.node)
	_touched_nodes = nodes
	for key in _touched_values:
		if values.has(key):
			continue
		var oldv: _ValAcc = _touched_values[key]
		if not oldv.has_rest:
			continue
		if oldv.mesh != null and is_instance_valid(oldv.mesh) and oldv.blend_shape_idx >= 0:
			oldv.mesh.set_blend_shape_value(oldv.blend_shape_idx, float(oldv.rest))
		elif oldv.target != null and is_instance_valid(oldv.target) and not oldv.prop.is_empty():
			oldv.target.set_indexed(oldv.prop, oldv.rest)
	_touched_values = values
	for key in values:
		var vacc: _ValAcc = values[key]
		var out: Variant = vacc.value
		if vacc.has_rest:
			out = _add_any(out, _mul_any(vacc.rest, 1.0 - vacc.w))
		elif vacc.w > 0.0:
			out = _div_any(out, vacc.w)
		if out is Quaternion:
			out = (out as Quaternion).normalized()
		if vacc.mesh != null and vacc.blend_shape_idx >= 0:
			vacc.mesh.set_blend_shape_value(vacc.blend_shape_idx, float(out))
		elif vacc.target != null and not vacc.prop.is_empty():
			vacc.target.set_indexed(vacc.prop, out)


static func _finish_rot(acc: Quaternion, w: float, rest: Quaternion) -> Quaternion:
	var rem := 1.0 - w
	if rem > 0.0001:
		var r := rest
		if acc.dot(r) < 0.0:
			r = Quaternion(-r.x, -r.y, -r.z, -r.w)
		acc = Quaternion(acc.x + r.x * rem, acc.y + r.y * rem, acc.z + r.z * rem, acc.w + r.w * rem)
	var len_sq := acc.x * acc.x + acc.y * acc.y + acc.z * acc.z + acc.w * acc.w
	if len_sq <= 0.0000001:
		return rest
	return acc.normalized()


static func _mul_any(v: Variant, s: float) -> Variant:
	match typeof(v):
		TYPE_FLOAT, TYPE_INT:
			return float(v) * s
		TYPE_VECTOR2:
			return (v as Vector2) * s
		TYPE_VECTOR3:
			return (v as Vector3) * s
		TYPE_VECTOR4:
			return (v as Vector4) * s
		TYPE_COLOR:
			return (v as Color) * s
		TYPE_QUATERNION:
			var q: Quaternion = v
			return Quaternion(q.x * s, q.y * s, q.z * s, q.w * s)
		_:
			return v


static func _div_any(v: Variant, s: float) -> Variant:
	if s == 0.0:
		return v
	return _mul_any(v, 1.0 / s)


static func _add_any(a: Variant, b: Variant) -> Variant:
	if typeof(a) != typeof(b) and not ((typeof(a) == TYPE_INT or typeof(a) == TYPE_FLOAT) and (typeof(b) == TYPE_INT or typeof(b) == TYPE_FLOAT)):
		return a
	match typeof(a):
		TYPE_FLOAT, TYPE_INT:
			return float(a) + float(b)
		TYPE_VECTOR2:
			return (a as Vector2) + (b as Vector2)
		TYPE_VECTOR3:
			return (a as Vector3) + (b as Vector3)
		TYPE_VECTOR4:
			return (a as Vector4) + (b as Vector4)
		TYPE_COLOR:
			return (a as Color) + (b as Color)
		TYPE_QUATERNION:
			var qa: Quaternion = a
			var qb: Quaternion = b
			if qa.dot(qb) < 0.0:
				qb = Quaternion(-qb.x, -qb.y, -qb.z, -qb.w)
			return Quaternion(qa.x + qb.x, qa.y + qb.y, qa.z + qb.z, qa.w + qb.w)
		_:
			return a


func _resolve_transform_target(path: NodePath) -> Dictionary:
	var key := String(path)
	if _target_cache.has(key):
		return _target_cache[key]
	var result: Dictionary = {}
	var node := _resolve_node(path)
	var bone_name := String(path.get_concatenated_subnames())
	if not bone_name.is_empty():
		var skel: Skeleton3D = node as Skeleton3D if node is Skeleton3D else _ensure_skeleton()
		if skel != null:
			var idx := skel.find_bone(bone_name)
			if idx >= 0:
				result = {"skeleton": skel, "bone": idx}
	elif node is Node3D:
		result = {"node": node}
	_target_cache[key] = result
	return result


func _resolve_node(path: NodePath) -> Node:
	if _root == null:
		return null
	var names := NodePath(path.get_concatenated_names())
	if names.is_empty() or String(names) == ".":
		return _root
	var node := _root.get_node_or_null(names)
	if node != null:
		return node
	return _root.get_node_or_null(path)


func _resolve_mesh(path: NodePath) -> MeshInstance3D:
	var node := _resolve_node(path)
	return node as MeshInstance3D if node is MeshInstance3D else null


func _ensure_skeleton() -> Skeleton3D:
	if is_instance_valid(_skeleton):
		return _skeleton
	_skeleton = _find_skeleton(_root)
	return _skeleton


static func _find_skeleton(n: Node) -> Skeleton3D:
	if n == null:
		return null
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var s := _find_skeleton(c)
		if s != null:
			return s
	return null


func _resolve_source(clip_name: String) -> Animation:
	if clip_name.is_empty():
		return null
	var key := clip_name.to_lower()
	if _user_clips.has(key):
		var user: Animation = _user_clips[key]
		if user != null:
			return user
	return _resolve_baked(clip_name)


func _resolve_baked(clip_name: String) -> Animation:
	if _character != null and _character.has_method("get_anim_clip"):
		var baked: Variant = _character.call("get_anim_clip", clip_name)
		if baked is Animation:
			return baked
	return null


func _ensure_in_library(name: String, clip: Animation) -> void:
	if _library == null or clip == null or name.is_empty():
		return
	var key := StringName(name)
	if _library.has_animation(key):
		if _library.get_animation(key) != clip:
			_library.remove_animation(key)
			_library.add_animation(key, clip)
	else:
		_library.add_animation(key, clip)


static func _parse_point(entry: Variant) -> Array:
	if entry is Array:
		if (entry as Array).size() < 2:
			return []
		return [str(entry[0]), float(entry[1])]
	if entry is Dictionary:
		var n := str(entry.get("clip_name", entry.get("clipName", entry.get("name", ""))))
		return [n, float(entry.get("threshold", 0.0))]
	return []


static func _as_params(
	clip_name_or_params: Variant,
	state_name: String,
	loop: bool,
	on_complete: Callable
) -> AnimPlayParams:
	if clip_name_or_params is AnimPlayParams:
		return clip_name_or_params
	var data := AnimPlayParams.new()
	data.clip_name = str(clip_name_or_params) if clip_name_or_params != null else ""
	data.state_name = state_name
	data.loop = loop
	data.on_complete = on_complete
	return data
