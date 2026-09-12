class_name AxieNamedClip
extends RefCounted
## Unity `AxieNamedClip` — a named clip handed to `AxieFactory.register_animations`.

var name: String = ""
var clip: Animation


func _init(p_name: String = "", p_clip: Animation = null) -> void:
	name = p_name
	clip = p_clip
