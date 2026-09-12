class_name AnimTrack
extends RefCounted
## Handle returned by AxiePlayable.play. Use queue() to chain follow-up clips.

var _animator: AxiePlayable
var _state_name: String = ""
var params: AnimPlayParams
var queued_next: AnimPlayParams


func _init(animator: AxiePlayable = null, data: AnimPlayParams = null, state_name: String = "") -> void:
	_animator = animator
	params = data if data != null else AnimPlayParams.new()
	_state_name = state_name


var clip_name: String:
	get:
		return params.clip_name if params != null else ""

var state_name: String:
	get:
		return params.state_name if params != null else ""

var loop: bool:
	get:
		return params.loop if params != null else false

var is_playing: bool:
	get:
		return _animator != null and _animator.is_track_active(self) and _animator.is_playing

var duration: float:
	get:
		return _animator.get_track_duration(self) if _animator != null else 0.0

var progress: float:
	get:
		return _animator.get_track_progress(self) if _animator != null else 0.0
	set(value):
		if _animator != null:
			_animator.seek_track(self, value)

var internal_state_name: String:
	get:
		return _state_name


func queue(
	clip_name_or_params: Variant,
	p_state_name: String = "",
	p_loop: bool = false,
	on_complete: Callable = Callable()
) -> AnimTrack:
	var data := _as_params(clip_name_or_params, p_state_name, p_loop, on_complete)
	queued_next = data
	if _animator == null:
		return null
	return _animator.make_pending_track(data)


func complete() -> void:
	if _animator != null and _animator.is_track_active(self):
		_animator.advance_on_complete(true)


static func _as_params(
	clip_name_or_params: Variant,
	p_state_name: String,
	p_loop: bool,
	on_complete: Callable
) -> AnimPlayParams:
	if clip_name_or_params is AnimPlayParams:
		return clip_name_or_params
	var data := AnimPlayParams.new()
	data.clip_name = str(clip_name_or_params)
	data.state_name = p_state_name
	data.loop = p_loop
	data.on_complete = on_complete
	return data
