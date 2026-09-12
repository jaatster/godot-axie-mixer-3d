class_name AnimPlayParams
extends RefCounted
## Full play specification. Fade < 0 inherits the animator's global fade; 0 = snap; > 0 overrides.

var clip_name: String = ""
var state_name: String = ""
var loop: bool = false
var fade: float = -1.0
var time_scale: float = 1.0
var normalized_start: float = 0.0
var start_time: float = 0.0
var on_complete: Callable = Callable()


func _init(
	p_clip_name: String = "",
	p_state_name: String = "",
	p_loop: bool = false,
	p_fade: float = -1.0,
	p_time_scale: float = 1.0,
	p_normalized_start: float = 0.0,
	p_start_time: float = 0.0,
	p_on_complete: Callable = Callable()
) -> void:
	clip_name = p_clip_name
	state_name = p_state_name
	loop = p_loop
	fade = p_fade
	time_scale = p_time_scale
	normalized_start = p_normalized_start
	start_time = p_start_time
	on_complete = p_on_complete
