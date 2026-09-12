extends SceneTree
## Mystic addon VFX (docs/design.md §3): every `addons/*.json` particle system builds a GPUParticles3D whose
## quad carries the ported Unity shader (vfx_dissolve / vfx_star) with the lifetime emulation,
## texture-sheet sprite, Custom1 curve and colour parameters filled in; the ZTest-Equal
## "Common_glow_stencil" glow draws nothing (invisible in Unity) but keeps its children.
## Headless: godot --headless --path . -s tests/test_mystic_vfx.gd

const CATALOG := "res://addons/axie_mixer_3d_assets/catalog.json"
const MixerMaterials := preload("res://addons/axie_mixer_3d/import/axie_mixer_materials.gd")
const MysticGlow := preload("res://addons/axie_mixer_3d/runtime/axie_mystic_glow.gd")


func _init() -> void:
	_start.call_deferred()


func _start() -> void:
	var errs: Array = run()
	if errs.is_empty():
		print("ok  mystic_vfx")
		quit(0)
	else:
		for e in errs:
			print("FAIL mystic_vfx: %s" % e)
		quit(1)


static func run() -> Array:
	var errs: Array = []
	var catalog := AxieCatalog.load_json(CATALOG)
	if catalog == null:
		return ["catalog failed to load"]
	var addon_dir := catalog.abs_path("addons")
	var files := DirAccess.get_files_at(addon_dir)
	var seen_dissolve := 0
	var seen_star := 0
	var seen_invisible := 0
	var systems := 0
	for f in files:
		if not f.ends_with(".json"):
			continue
		var rel := "addons/" + f
		var node := MysticGlow.instantiate(catalog, rel)
		if node == null:
			errs.append("%s: instantiate returned null" % f)
			continue
		var particles := node.find_children("*", "GPUParticles3D", true, false)
		if node is GPUParticles3D:
			particles.push_front(node)
		if particles.is_empty():
			errs.append("%s: no GPUParticles3D built" % f)
		for p in particles:
			systems += 1
			var gp := p as GPUParticles3D
			if gp.lifetime <= 0.0 or gp.amount < 1:
				errs.append("%s/%s: bad lifetime/amount %s/%s" % [f, gp.name, gp.lifetime, gp.amount])
			if gp.draw_pass_1 == null:
				seen_invisible += 1
				if gp.emitting:
					errs.append("%s/%s: invisible system still emitting" % [f, gp.name])
				continue
			var mat := (gp.draw_pass_1 as QuadMesh).material
			if not MixerMaterials.is_vfx(mat):
				errs.append("%s/%s: expected a VFX ShaderMaterial, got %s" % [f, gp.name, mat])
				continue
			var sm := mat as ShaderMaterial
			var cycle: float = sm.get_shader_parameter("cycle_seconds")
			var life_max: float = sm.get_shader_parameter("life_max")
			if not is_equal_approx(cycle, gp.lifetime):
				errs.append("%s/%s: cycle_seconds %s != lifetime %s" % [f, gp.name, cycle, gp.lifetime])
			if life_max <= 0.0:
				errs.append("%s/%s: life_max %s" % [f, gp.name, life_max])
			var pm := gp.process_material as ParticleProcessMaterial
			if pm == null or pm.color != Color.WHITE:
				errs.append("%s/%s: process colour must stay white (start colour lives in the shader)" % [f, gp.name])
			if sm.shader == MixerMaterials.SHADER_VFX_DISSOLVE:
				seen_dissolve += 1
				# The glow sprite comes from the Texture Sheet Animation (Sprites mode), not _MainTex.
				var tex: Texture2D = sm.get_shader_parameter("main_tex")
				if tex == null:
					errs.append("%s/%s: dissolve glow without a main texture" % [f, gp.name])
				var start: Vector4 = sm.get_shader_parameter("start_color")
				if start.w <= 0.0:
					errs.append("%s/%s: start colour alpha %s" % [f, gp.name, start.w])
			elif sm.shader == MixerMaterials.SHADER_VFX_STAR:
				seen_star += 1
				# Star threshold is Custom1.z, a curve over lifetime; a zero constant would draw nothing.
				var is_curve: bool = sm.get_shader_parameter("custom1_z_is_curve")
				var consts: Vector4 = sm.get_shader_parameter("custom1_const")
				if not is_curve and consts.z <= 0.0:
					errs.append("%s/%s: star has no Custom1.z threshold" % [f, gp.name])
				var c0: Vector4 = sm.get_shader_parameter("color0")
				if c0.x <= 0.0:
					errs.append("%s/%s: color0 unset" % [f, gp.name])
		node.free()
	if seen_dissolve == 0 or seen_star == 0 or seen_invisible == 0:
		errs.append("coverage: dissolve %d star %d invisible %d (expected all > 0)" % [seen_dissolve, seen_star, seen_invisible])
	print("    mystic_vfx: %d systems (%d dissolve, %d star, %d invisible ZTest-Equal glows)" % [systems, seen_dissolve, seen_star, seen_invisible])

	# Material dump facts the port relies on.
	for pair in [["Common_glow 9", false], ["Common_glow_stencil", true], ["star_gradientmap_stecil_mysthic", false]]:
		var found := false
		for id in _material_ids(catalog):
			var d := MixerMaterials.material_json(catalog, id)
			if str(d.get("name", "")) != pair[0]:
				continue
			found = true
			if MixerMaterials.vfx_is_invisible(d) != pair[1]:
				errs.append("%s: expected invisible=%s" % [pair[0], pair[1]])
			var m := MixerMaterials.from_id(catalog, id)
			if not MixerMaterials.is_vfx(m):
				errs.append("%s: from_id did not build a VFX material (%s)" % [pair[0], m])
			break
		if not found:
			errs.append("material %s not in pack" % pair[0])
	MixerMaterials.clear_cache()
	return errs


static func _material_ids(catalog: AxieCatalog) -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(catalog.abs_path("materials")):
		if f.ends_with(".json"):
			out.append(f.get_basename())
	return out
