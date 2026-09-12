extends SceneTree
## Golden tests for 1D locomotion blend weights. Seam: AxiePlayable.compute_weights.
## Headless: godot --headless --path . -s tests/test_blend_weights.gd


func _init() -> void:
	var errs: Array = run()
	if errs.is_empty():
		print("ok  blend_weights")
		quit(0)
	else:
		for e in errs:
			print("FAIL blend_weights: %s" % e)
		quit(1)


static func run() -> Array:
	var errs: Array = []
	_check_equal(errs, "idle_walk_run_at_zero", AxiePlayable.compute_weights(PackedFloat32Array([0.0, 1.0, 3.5]), 0.0), [1.0, 0.0, 0.0])
	_check_equal(errs, "below_lowest_clamps", AxiePlayable.compute_weights(PackedFloat32Array([0.0, 1.0, 3.5]), -2.0), [1.0, 0.0, 0.0])
	_check_equal(errs, "above_highest_clamps", AxiePlayable.compute_weights(PackedFloat32Array([0.0, 1.0, 3.5]), 9.0), [0.0, 0.0, 1.0])
	_check_almost(errs, "mid_idle_walk", AxiePlayable.compute_weights(PackedFloat32Array([0.0, 1.0, 3.5]), 0.5), [0.5, 0.5, 0.0])
	_check_almost(errs, "exact_walk_threshold", AxiePlayable.compute_weights(PackedFloat32Array([0.0, 1.0, 3.5]), 1.0), [0.0, 1.0, 0.0])
	_check_almost(errs, "walk_run_span", AxiePlayable.compute_weights(PackedFloat32Array([0.0, 1.0, 3.5]), 2.25), [0.0, 0.5, 0.5])
	_check_equal(errs, "single_point", AxiePlayable.compute_weights(PackedFloat32Array([0.0]), 99.0), [1.0])
	var w := PackedFloat32Array([0.5, 0.5, 0.0])
	var lengths := PackedFloat32Array([2.0, 1.0, 0.8])
	var speeds := AxiePlayable.phase_locked_speeds(lengths, w, 1.0)
	var ref := 0.5 * 2.0 + 0.5 * 1.0
	if abs(ref - 1.5) > 1e-7:
		errs.append("phase_lock_speeds ref %s" % ref)
	if speeds.size() != 3:
		errs.append("phase_lock_speeds size %s" % speeds.size())
	else:
		if abs(speeds[0] - 2.0 / 1.5) > 1e-7:
			errs.append("phase_lock_speeds[0] %s" % speeds[0])
		if abs(speeds[1] - 1.0 / 1.5) > 1e-7:
			errs.append("phase_lock_speeds[1] %s" % speeds[1])
		if abs(speeds[2] - 0.0) > 1e-7:
			errs.append("phase_lock_speeds[2] %s" % speeds[2])
	return errs


static func _check_equal(errs: Array, name: String, got: PackedFloat32Array, expected: Array) -> void:
	if got.size() != expected.size():
		errs.append("%s size %s != %s" % [name, got.size(), expected.size()])
		return
	for i in got.size():
		if got[i] != float(expected[i]):
			errs.append("%s[%s] %s != %s" % [name, i, got[i], expected[i]])
			return


static func _check_almost(errs: Array, name: String, got: PackedFloat32Array, expected: Array) -> void:
	if got.size() != expected.size():
		errs.append("%s size %s != %s" % [name, got.size(), expected.size()])
		return
	for i in got.size():
		if abs(got[i] - float(expected[i])) > 1e-7:
			errs.append("%s[%s] %s != %s" % [name, i, got[i], expected[i]])
			return
