extends SceneTree
## GPU regression: real Mystic_Final surfaces must retain values above display white.
## Exposure 0.01 makes clipped SDR white ~0.10, while original Unity HDR remains bright.
## Run with a rendering device, not --headless. Particles and glow are excluded here.

var viewport: SubViewport
var stage: Node3D
var output := "/tmp/axie_mystic_hdr"
var failures: Array[String] = []
var results: Array = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Mystic HDR test requires a real rendering device; use tools/mystic_hdr.sh")
		quit(1)
		return
	root.unfocusable = true
	var args := OS.get_cmdline_user_args()
	for i in args.size() - 1:
		if args[i] == "--out":
			output = args[i + 1]
	DirAccess.make_dir_recursive_absolute(output)
	viewport = SubViewport.new()
	viewport.size = Vector2i(512, 512)
	viewport.own_world_3d = true
	viewport.use_hdr_2d = args.has("--hdr2d")
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.5, 0.5)
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 0.01
	env.glow_enabled = false
	var world := WorldEnvironment.new()
	world.environment = env
	viewport.add_child(world)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	camera.fov = 30.0
	camera.look_at_from_position(Vector3(0, 1.05, 4.6), Vector3(0, 0.8, 0))
	camera.current = true
	var light := DirectionalLight3D.new()
	viewport.add_child(light)
	light.rotation_degrees = Vector3(-35, -140, 0)
	light.shadow_enabled = false
	stage = Node3D.new()
	viewport.add_child(stage)
	var factory := AxieFactory.new()
	factory.catalog = AxieCatalog.load_json("res://addons/axie_mixer_3d_assets/catalog.json")
	var fixtures: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/goldens/mystic_axies.json"))
	for fixture in fixtures["ids"]:
		await _check_fixture(factory, fixture)
	await _check_vfx_materials(factory.catalog)
	var report := {"renderer": RenderingServer.get_current_rendering_method(), "engine": Engine.get_version_info().string, "results": results, "failures": failures}
	FileAccess.open(output.path_join("report.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "  "))
	FileAccess.open(output.path_join("done.txt"), FileAccess.WRITE).store_string(str(failures.size()))
	for failure in failures:
		print("FAIL mystic_hdr: " + failure)
	print("MYSTIC_HDR: %d fixtures; %d failures" % [results.size(), failures.size()])
	quit(0 if failures.is_empty() else 1)


func _check_fixture(factory: AxieFactory, fixture: Dictionary) -> void:
	var id := str(fixture["id"])
	var params := AxieInstantiationParams.new()
	params.combine_meshes = true
	var character := factory.create_character(AxieDescriptor.from_genes(fixture["genes"]), params)
	stage.add_child(character.root)
	var mystic: Array[ShaderMaterial] = []
	for mesh in character.root.find_children("*", "MeshInstance3D", true, false):
		for surface in mesh.mesh.get_surface_count():
			var material: Material = mesh.get_active_material(surface)
			if AxieMixerMaterials.is_mystic(material):
				mystic.append(material)
	for particle in character.root.find_children("*", "GPUParticles3D", true, false):
		particle.visible = false
	var peaks: Array[float] = []
	var images: Array[Image] = []
	for shader_time in [0.0, 0.75, 1.0, 2.0]:
		for material in mystic:
			material.set_shader_parameter("mystic_time", shader_time)
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		var captured := _display_image()
		captured.save_png(output.path_join("%s-t%.2f.png" % [id, shader_time]))
		var peak := 0.0
		for y in captured.get_height():
			for x in captured.get_width():
				var pixel := captured.get_pixel(x, y)
				peak = maxf(peak, maxf(pixel.r, maxf(pixel.g, pixel.b)))
		peaks.append(peak)
		images.append(captured)
	var changed := 0
	for y in images[0].get_height():
		for x in images[0].get_width():
			var a := images[0].get_pixel(x, y)
			var b := images[1].get_pixel(x, y)
			if Vector3(a.r-b.r, a.g-b.g, a.b-b.b).length() > 0.05:
				changed += 1
	if id == "123":
		if peaks.max() > 0.2:
			failures.append("ordinary #123 exceeds the SDR control bound: %s" % [peaks])
	else:
		if peaks.min() < 0.35:
			failures.append("#%s loses original Unity HDR brightness at exposure 0.01: %s" % [id, peaks])
		if id == "883" and changed < 25:
			failures.append("#883 loses visible shader animation in HDR: %d changed pixels" % changed)
	results.append({"id": id, "peak_rgb": peaks, "animated_pixels": changed, "mystic_surfaces": mystic.size()})
	print("mystic_hdr #%s peaks=%s animated=%d" % [id, peaks, changed])
	character.dispose()
	await process_frame


func _check_vfx_materials(catalog: AxieCatalog) -> void:
	for name in ["Common_glow 9", "star_gradientmap_stecil_mysthic"]:
		var material: ShaderMaterial
		for file in DirAccess.get_files_at(catalog.abs_path("materials")):
			if not file.ends_with(".json"):
				continue
			var data := AxieMixerMaterials.material_json(catalog, file.get_basename())
			if str(data.get("name", "")) == name:
				material = AxieMixerMaterials.from_id(catalog, file.get_basename()).duplicate()
				break
		if material == null:
			failures.append("VFX material missing: " + name)
			continue
		# Use the actual imported particle material with a stationary quad to keep
		# this test independent of random emission and lifetime scheduling.
		material.set_shader_parameter("custom1_const", Vector4(0, 0, 1 if name.begins_with("star") else 0, 0))
		var mesh := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(1.0, 1.0)
		quad.material = material
		mesh.mesh = quad
		stage.add_child(mesh)
		mesh.position = Vector3(0, 0.8, 0)
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		var captured := _display_image()
		captured.save_png(output.path_join(name + ".png"))
		var peak := 0.0
		for y in captured.get_height():
			for x in captured.get_width():
				var c := captured.get_pixel(x, y)
				peak = maxf(peak, maxf(c.r, maxf(c.g, c.b)))
		results.append({"material": name, "peak_rgb": peak})
		if peak < 0.2:
			failures.append("%s loses particle HDR brightness: %.4f" % [name, peak])
		print("mystic_hdr VFX %s peak=%.4f" % [name, peak])
		mesh.queue_free()
		await process_frame


func _display_image() -> Image:
	var raw := viewport.get_texture().get_image()
	if not viewport.use_hdr_2d:
		return raw
	# HDR 2D readback is linear RGBA16F; convert only the saved/display comparison.
	var display := Image.create(raw.get_width(), raw.get_height(), false, Image.FORMAT_RGBA8)
	for y in raw.get_height():
		for x in raw.get_width():
			display.set_pixel(x, y, raw.get_pixel(x, y).linear_to_srgb())
	return display
