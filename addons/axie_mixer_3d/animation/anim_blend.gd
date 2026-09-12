class_name AnimBlend
extends RefCounted
## Handle to a running 1D blend (e.g. Idle→Walk→Run). Drive Speed every frame.

class Point:
	var clip_name: String = ""
	var threshold: float = 0.0
	var state_name: String = ""
	var length: float = 0.0


var _animator: AxiePlayable
var points: Array = []
var weights: PackedFloat32Array = PackedFloat32Array()
var speed: float = 0.0


func _init(animator: AxiePlayable = null, p_points: Array = []) -> void:
	_animator = animator
	points = p_points
	weights.resize(p_points.size())
	weights.fill(0.0)


var is_active: bool:
	get:
		return _animator != null and _animator.is_blend_active(self)


func stop() -> void:
	if _animator != null:
		_animator.stop_blend(self)
