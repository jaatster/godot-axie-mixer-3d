extends SceneTree
## Visual parity gate against the Unity render oracle (`tests/render_oracle/index.json`, produced by
## the `render` stage of `tools/unity_export/AxieGltfExporter.cs`).
##
## Renders every fixture image with the same camera / main light / background through an offscreen
## SubViewport, writes `<out>/<fixture>/<image>.png` (Godot) and `<image>.cmp.png` (Unity | Godot |
## diff) and prints per-image mean absolute error + fraction of clearly-different pixels.
##
## Needs a real rendering device, so run it through a hidden background Godot instead of --headless:
##   tools/render_compare.sh [fixture_substring] [--out DIR]
## (`open -g -j -n -a Godot --args --path . -s tests/render_compare.gd -- ...`; never steals focus.)
##
## Preview-only flags (not part of the gate): `--particles` keeps the mystic VFX particle systems
## and `--ref DIR` compares against a different reference tree, e.g. a Unity render exported with
## AXIE_GODOT_RENDER_PARTICLES=1 AXIE_GODOT_RENDER_DIR=DIR.

const DEFAULT_OUT := "/tmp/axie_render"
const COMPARE_SIZE := 128
const PIXEL_TOL := 0.15 # per-channel difference that counts a (downsampled) pixel as "different"
const MAE_GATE := 0.02
const BAD_FRAC_GATE := 0.03

var _filter := ""
var _direct := false
var _particles := false
var _ref_dir := "res://tests/render_oracle"
var _out_dir := DEFAULT_OUT
var _root_scale := 1.0
var _shader_time := 0.0
var _started := false
var _viewport: SubViewport
var _camera: Camera3D
var _stage: Node3D
var _results: Array = []
var _failures := 0


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var a: String = args[i]
		if a == "--out" and i + 1 < args.size():
			_out_dir = args[i + 1]
			i += 1
		elif a == "--direct":
			_direct = true
		elif a == "--particles":
			# Preview only: keep the mystic VFX particles (Unity: AXIE_GODOT_RENDER_PARTICLES=1).
			_particles = true
		elif a == "--ref" and i + 1 < args.size():
			_ref_dir = args[i + 1]
			i += 1
		elif not a.begins_with("--"):
			_filter = a
		i += 1
	_run()
	return false


func _run() -> void:
	var index_path := _ref_dir.path_join("index.json")
	var index: Variant = JSON.parse_string(FileAccess.get_file_as_string(index_path))
	if typeof(index) != TYPE_DICTIONARY:
		_finish("render oracle index missing: %s" % index_path)
		return
	DirAccess.make_dir_recursive_absolute(_out_dir)
	_root_scale = float(index.get("root_scale", 1.0))
	_shader_time = float(index.get("shader_time", 0.0))
	_setup_stage(index)

	var catalog := AxieCatalog.load_json("res://addons/axie_mixer_3d_assets/catalog.json")
	var factory := AxieFactory.new()
	factory.catalog = catalog
	AxieFactory.default_factory = factory
	AxieDefaults.factory = factory
	AxieWeaponAnims.register(catalog, factory)

	var t0 := Time.get_ticks_msec()
	for fx in index.get("fixtures", []):
		var dir := str(fx.get("dir", fx.get("name", "")))
		if not _filter.is_empty() and not dir.contains(_filter):
			continue
		await _render_fixture(factory, fx, dir)
	var total := _results.size()
	var summary := "%d images, %d failures (%.1fs)" % [total, _failures, (Time.get_ticks_msec() - t0) / 1000.0]
	print("\n" + summary)
	_write_report(summary)
	_finish("")


func _setup_stage(index: Dictionary) -> void:
	var size := int(index.get("size", 512))
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(size, size)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	_viewport.use_debanding = false
	get_root().add_child(_viewport)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	# Unity (gamma-space project) writes these values straight to the sRGB target; Godot Colors are
	# sRGB too and get linearised by the renderer, so pass them through unchanged.
	env.background_color = _color(index.get("background", [0.18, 0.2, 0.24, 1.0]))
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = _color(index.get("ambient", [0.5, 0.5, 0.5, 1.0]))
	env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = float(index.get("exposure", 1.0))
	env.glow_enabled = false
	env.fog_enabled = false
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	_viewport.add_child(world_env)

	var cam_info: Dictionary = index.get("camera", {})
	_camera = Camera3D.new()
	_viewport.add_child(_camera)
	_camera.fov = float(cam_info.get("fov_vertical", 30.0))
	_camera.near = float(cam_info.get("near", 0.05))
	_camera.far = float(cam_info.get("far", 50.0))
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_camera.look_at_from_position(_vec3(cam_info.get("position", [0, 1, 4.6])), _vec3(cam_info.get("target", [0, 0.8, 0])), Vector3.UP)
	_camera.current = true

	var light := DirectionalLight3D.new()
	_viewport.add_child(light)
	light.light_color = Color.WHITE
	light.light_energy = 1.0
	light.shadow_enabled = false
	var forward := _vec3(index.get("light_forward", [0, -1, 0])).normalized()
	light.look_at_from_position(Vector3.ZERO, forward, Vector3.UP if absf(forward.y) < 0.99 else Vector3.RIGHT)

	_stage = Node3D.new()
	_viewport.add_child(_stage)


func _render_fixture(factory: AxieFactory, fx: Dictionary, dir: String) -> void:
	var desc := AxieDescriptor.new()
	desc.body = AxieTypes.body_from_name(str(fx.get("body", "Normal")))
	desc.color_variant = int(fx.get("color_variant", 0))
	desc.clear_parts()
	for p in fx.get("parts", []):
		desc.parts.append(AxiePartDescriptor.from_dict(p))
	var params := AxieInstantiationParams.new()
	params.combine_meshes = bool(fx.get("combined", false))
	var character := factory.create_character(desc, params)
	if character == null or character.root == null:
		_fail_image(dir, "-", "factory returned no character")
		return
	_stage.add_child(character.root)
	character.root.scale = Vector3.ONE * _root_scale
	# Particle systems are excluded on the Unity side as well (unless --particles, preview only).
	for n in character.root.find_children("*", "GPUParticles3D", true, false):
		var gp := n as GPUParticles3D
		if _particles:
			gp.emitting = gp.visible
			gp.restart()
		else:
			gp.visible = false
	# The Unity render stage zeroes every mystic panner speed (FreezeShaderTime) so the reference
	# is the t = 0 frame; pin the Godot shader clock to the same instant.
	_freeze_mystic_time(character.root)
	DirAccess.make_dir_recursive_absolute(_out_dir.path_join(dir))
	var playable := character.playable
	var worst_mae := 0.0
	var worst_frac := 0.0
	for img in fx.get("images", []):
		var file := str(img.get("file", ""))
		var clip := str(img.get("clip", ""))
		var time := float(img.get("time", 0.0))
		var yaw := float(img.get("yaw_unity_deg", 0.0))
		if clip.is_empty() or _direct:
			playable.resume()
			playable.stop()
			for s in character.root.find_children("*", "Skeleton3D", true, false):
				var skel := s as Skeleton3D
				for b in skel.get_bone_count():
					skel.reset_bone_pose(b)
			if not clip.is_empty():
				var anim := character.get_anim_clip(clip)
				if anim == null:
					_fail_image(dir, file, "no clip %s" % clip)
					continue
				_apply_clip_direct(character.root, anim, time)
		else:
			playable.resume()
			if playable.play(clip, "", true) == null:
				_fail_image(dir, file, "playable could not play %s" % clip)
				continue
			playable._tick(time)
			playable.pause() # the updater node keeps ticking while we wait for the frames below
		# Unity rotates about +Y in a left-handed world; mirrored across X that is -Y here.
		character.root.rotation = Vector3(0.0, -deg_to_rad(yaw), 0.0)
		await process_frame
		await process_frame
		if _particles:
			# Let the particle systems settle (Unity's preview simulates 0.75 s).
			for _i in 45:
				await process_frame
		if OS.has_environment("AXIE_RENDER_DEBUG_BONES"):
			_debug_bones(character.root, dir, clip, time)
		var got := _viewport.get_texture().get_image()
		got.convert(Image.FORMAT_RGBA8)
		var out_png := _out_dir.path_join(dir).path_join(file)
		got.save_png(out_png)
		var expected := Image.load_from_file("%s/%s/%s" % [_ref_dir, dir, file])
		if expected == null:
			_fail_image(dir, file, "reference image unreadable")
			continue
		expected.convert(Image.FORMAT_RGBA8)
		var m := _compare(expected, got)
		worst_mae = maxf(worst_mae, m["mae"])
		worst_frac = maxf(worst_frac, m["bad_frac"])
		_write_triptych(expected, got, out_png.get_basename() + ".cmp.png")
		var ok: bool = m["mae"] <= MAE_GATE and m["bad_frac"] <= BAD_FRAC_GATE
		_results.append({"dir": dir, "file": file, "mae": m["mae"], "bad_frac": m["bad_frac"], "ok": ok})
		if not ok:
			_failures += 1
	print("%-40s worst: mae %.4f bad_frac %.4f" % [dir, worst_mae, worst_frac])
	character.dispose()


## Reference sampler (same as tests/oracle_compare.gd): write the clip's bone tracks straight into
## the skeleton, bypassing AxiePlayable.
static func _apply_clip_direct(root: Node3D, anim: Animation, time: float) -> void:
	var skel: Skeleton3D = null
	for s in root.find_children("*", "Skeleton3D", true, false):
		skel = s
		break
	if skel == null:
		return
	for i in anim.get_track_count():
		var bone := String(anim.track_get_path(i).get_concatenated_subnames())
		var b := skel.find_bone(bone)
		if b < 0:
			continue
		match anim.track_get_type(i):
			Animation.TYPE_POSITION_3D:
				skel.set_bone_pose_position(b, anim.position_track_interpolate(i, time))
			Animation.TYPE_ROTATION_3D:
				skel.set_bone_pose_rotation(b, anim.rotation_track_interpolate(i, time))
			Animation.TYPE_SCALE_3D:
				skel.set_bone_pose_scale(b, anim.scale_track_interpolate(i, time))


func _debug_bones(root: Node3D, dir: String, clip: String, time: float) -> void:
	var skel: Skeleton3D = null
	for s in root.find_children("*", "Skeleton3D", true, false):
		skel = s
		break
	if skel == null:
		return
	var file := "rest.json" if clip.is_empty() else "%s_%.2f.json" % [clip, time]
	var sample: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://tests/oracle/%s/%s" % [dir, file]))
	if typeof(sample) != TYPE_DICTIONARY:
		print("  no oracle sample for ", file)
		return
	var root_inv := root.global_transform.affine_inverse()
	var skel_xf := root_inv * skel.global_transform
	var worst := 0.0
	var worst_name := ""
	for n in sample.get("nodes", []):
		var leaf := str(n.get("path", "")).get_file()
		var b := skel.find_bone(leaf)
		if b < 0 or not leaf.ends_with("_JNT"):
			continue
		var m: Array = n.get("matrix", [])
		var expected := Vector3(float(m[12]), float(m[13]), float(m[14]))
		var got := (skel_xf * skel.get_bone_global_pose(b)).origin
		var d := got.distance_to(expected)
		if d > worst:
			worst = d
			worst_name = leaf
	print("  [bones] %s %s: worst joint pos error %.4f (%s)" % [dir, file, worst, worst_name])


## Mean absolute RGB error and the fraction of pixels whose max channel difference exceeds
## PIXEL_TOL, both measured on COMPARE_SIZE² area-downsampled copies (robust to sub-pixel
## rasterization / filtering differences between engines).
static func _compare(a: Image, b: Image) -> Dictionary:
	var da := a.duplicate() as Image
	var db := b.duplicate() as Image
	da.resize(COMPARE_SIZE, COMPARE_SIZE, Image.INTERPOLATE_BILINEAR)
	db.resize(COMPARE_SIZE, COMPARE_SIZE, Image.INTERPOLATE_BILINEAR)
	var sum := 0.0
	var bad := 0
	for y in COMPARE_SIZE:
		for x in COMPARE_SIZE:
			var ca := da.get_pixel(x, y)
			var cb := db.get_pixel(x, y)
			var dr := absf(ca.r - cb.r)
			var dg := absf(ca.g - cb.g)
			var dbb := absf(ca.b - cb.b)
			sum += dr + dg + dbb
			if maxf(dr, maxf(dg, dbb)) > PIXEL_TOL:
				bad += 1
	var n := float(COMPARE_SIZE * COMPARE_SIZE)
	return {"mae": sum / (3.0 * n), "bad_frac": bad / n}


static func _write_triptych(expected: Image, got: Image, path: String) -> void:
	var w := expected.get_width()
	var h := expected.get_height()
	var sheet := Image.create(w * 3, h, false, Image.FORMAT_RGBA8)
	sheet.blit_rect(expected, Rect2i(0, 0, w, h), Vector2i(0, 0))
	sheet.blit_rect(got, Rect2i(0, 0, w, h), Vector2i(w, 0))
	var diff := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var ca := expected.get_pixel(x, y)
			var cb := got.get_pixel(x, y)
			var d := maxf(absf(ca.r - cb.r), maxf(absf(ca.g - cb.g), absf(ca.b - cb.b)))
			var v := clampf(d * 4.0, 0.0, 1.0)
			diff.set_pixel(x, y, Color(v, v * 0.3, 1.0 - v, 1.0) if d > 0.02 else Color(0, 0, 0, 1))
	sheet.blit_rect(diff, Rect2i(0, 0, w, h), Vector2i(w * 2, 0))
	sheet.save_png(path)


func _write_report(summary: String) -> void:
	var f := FileAccess.open(_out_dir.path_join("report.json"), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"summary": summary, "failures": _failures, "images": _results}, "\t"))
	f.close()


func _freeze_mystic_time(root: Node) -> void:
	const MixerMaterials := preload("res://addons/axie_mixer_3d/import/axie_mixer_materials.gd")
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		var count := mi.get_surface_override_material_count()
		for i in count:
			var m := mi.get_active_material(i)
			if MixerMaterials.is_mystic(m):
				(m as ShaderMaterial).set_shader_parameter("mystic_time", _shader_time)


func _fail_image(dir: String, file: String, msg: String) -> void:
	_failures += 1
	_results.append({"dir": dir, "file": file, "mae": 1.0, "bad_frac": 1.0, "ok": false, "error": msg})
	printerr("FAIL %s/%s: %s" % [dir, file, msg])


func _finish(error: String) -> void:
	if not error.is_empty():
		printerr(error)
		_failures += 1
	var f := FileAccess.open(_out_dir.path_join("done.txt"), FileAccess.WRITE)
	if f != null:
		f.store_string("%d\n%s\n" % [_failures, error])
		f.close()
	quit(0 if _failures == 0 else 1)


static func _vec3(a: Variant) -> Vector3:
	if a is Array and a.size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO


static func _color(a: Variant) -> Color:
	if a is Array and a.size() >= 3:
		return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if a.size() > 3 else 1.0)
	return Color.BLACK
