class_name AxieMysticGlow
extends Object
## Builds the mystic addon "Glow" prefab (a Unity ParticleSystem) as a GPUParticles3D from the pack's
## `addons/*.json` dump. Only the modules the shipped prefabs use are mapped.

const MixerMaterials := preload("res://addons/axie_mixer_3d/import/axie_mixer_materials.gd")

static var _json_cache: Dictionary = {}


static func instantiate(catalog: AxieCatalog, rel_path: String) -> Node3D:
	var d := _load(catalog, rel_path)
	if d.is_empty():
		return null
	var nodes: Array = d.get("nodes", [])
	if nodes.is_empty():
		return null
	var built: Dictionary = {}
	var root: Node3D = null
	for row in nodes:
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var n := _build_node(catalog, row)
		var parent_name := str(row.get("parent", ""))
		built[str(row.get("name", ""))] = n
		if root == null:
			root = n
		elif built.has(parent_name):
			(built[parent_name] as Node).add_child(n)
		else:
			root.add_child(n)
	return root


static func _load(catalog: AxieCatalog, rel_path: String) -> Dictionary:
	var path := catalog.abs_path(rel_path)
	if _json_cache.has(path):
		return _json_cache[path]
	var d: Dictionary = {}
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(parsed) == TYPE_DICTIONARY:
			d = parsed
	_json_cache[path] = d
	return d


static func _build_node(catalog: AxieCatalog, row: Dictionary) -> Node3D:
	var ps: Variant = row.get("particle_system", null)
	var node: Node3D
	if ps is Dictionary:
		node = _build_particles(catalog, ps)
	else:
		node = Node3D.new()
	node.name = str(row.get("name", "Glow"))
	node.transform = _trs(row)
	return node


static func _trs(row: Dictionary) -> Transform3D:
	var p: Array = row.get("position", [0, 0, 0])
	var r: Array = row.get("rotation", [0, 0, 0, 1])
	var s: Array = row.get("scale", [1, 1, 1])
	var q := Quaternion(float(r[0]), float(r[1]), float(r[2]), float(r[3])).normalized()
	return Transform3D(Basis(q).scaled(Vector3(float(s[0]), float(s[1]), float(s[2]))), Vector3(float(p[0]), float(p[1]), float(p[2])))


static func _build_particles(catalog: AxieCatalog, ps: Dictionary) -> GPUParticles3D:
	var gp := GPUParticles3D.new()
	var renderer: Dictionary = ps.get("renderer", {})
	var mat_id := str(renderer.get("material", ""))
	var mat_json := MixerMaterials.material_json(catalog, mat_id) if not mat_id.is_empty() else {}
	var life_max := _minmax_max(ps.get("start_lifetime", {}), 1.0)
	var life_min := _minmax_min(ps.get("start_lifetime", {}), life_max)
	var duration := maxf(float(ps.get("duration", 1.0)), 0.01)
	var looping := bool(ps.get("looping", true))
	var emission: Dictionary = ps.get("emission", {})
	var rate := _minmax_max(emission.get("rate_over_time", {}), 0.0) if bool(emission.get("enabled", true)) else 0.0
	var burst_total := 0.0
	if bool(emission.get("enabled", true)):
		for b in emission.get("bursts", []):
			if b is Dictionary:
				var count := _minmax_max((b as Dictionary).get("count", {}), 0.0)
				burst_total += count * maxf(float((b as Dictionary).get("cycle_count", 1)), 1.0) * float((b as Dictionary).get("probability", 1.0))
	# Godot spawns `amount` particles evenly across `lifetime`; Unity emits rate×duration + bursts per
	# cycle. Use the Unity duration as the Godot cycle and let the shader apply the per-particle Unity
	# lifetime (vfx_particle_common.gdshaderinc). Non-looping systems simply run their one cycle.
	var cycle := duration if looping else maxf(duration, life_max)
	var max_particles := int(ps.get("max_particles", 1000))
	var amount := clampi(int(ceil(rate * cycle + burst_total)), 1, max_particles)
	gp.amount = amount
	gp.lifetime = maxf(cycle, 0.01)
	gp.one_shot = not looping
	gp.preprocess = gp.lifetime if bool(ps.get("prewarm", false)) else 0.0
	gp.explosiveness = 0.0
	gp.local_coords = str(ps.get("simulation_space", "Local")) == "Local"
	gp.speed_scale = float(ps.get("simulation_speed", 1.0))
	gp.visibility_aabb = AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
	gp.emitting = bool(ps.get("play_on_awake", true))
	# Unity: a ZTest Equal transparent particle never passes (no depth prepass for transparents) —
	# the "Common_glow_stencil" glow is invisible there. Keep the node (children such as Star_2 and
	# glow_dark hang off it) but give it nothing to draw.
	var invisible := MixerMaterials.vfx_is_invisible(mat_json)
	if invisible:
		gp.emitting = false

	var pm := ParticleProcessMaterial.new()
	var shape: Dictionary = ps.get("shape", {})
	var shape_type := str(shape.get("shape_type", "Sphere"))
	var radius := float(shape.get("radius", 0.1))
	if bool(shape.get("enabled", true)):
		match shape_type:
			"Sphere", "SphereShell", "Hemisphere", "HemisphereShell":
				var thickness := float(shape.get("radius_thickness", 1.0))
				pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE if thickness >= 0.5 else ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE
				pm.emission_sphere_radius = maxf(radius, 0.0001)
			"Circle":
				pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
				pm.emission_ring_radius = maxf(radius, 0.0001)
				pm.emission_ring_inner_radius = radius * (1.0 - float(shape.get("radius_thickness", 1.0)))
				pm.emission_ring_height = 0.0
				pm.emission_ring_axis = Vector3(0, 0, 1)
			"Box", "BoxShell", "BoxEdge":
				pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
				var sc: Array = shape.get("scale", [1, 1, 1])
				pm.emission_box_extents = Vector3(float(sc[0]), float(sc[1]), float(sc[2])) * 0.5
			_:
				pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
				pm.emission_sphere_radius = maxf(radius, 0.0001)
	else:
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINT

	var speed := _minmax_max(ps.get("start_speed", {}), 0.0)
	var speed_min := _minmax_min(ps.get("start_speed", {}), speed)
	pm.direction = Vector3(0, 0, 1)
	pm.spread = 180.0 if shape_type.begins_with("Sphere") else 0.0
	pm.initial_velocity_min = speed_min
	pm.initial_velocity_max = speed
	pm.gravity = Vector3(0, -9.81, 0) * _minmax_max(ps.get("gravity_modifier", {}), 0.0)

	var size := _minmax_max(ps.get("start_size", {}), 1.0)
	var size_min := _minmax_min(ps.get("start_size", {}), size)
	pm.scale_min = size_min
	pm.scale_max = size
	# Colour, size-over-lifetime, colour-over-lifetime and rotation-over-lifetime are applied in the
	# VFX shader against the Unity age (see below); the process material only randomises spawn state.
	pm.color = Color.WHITE

	var vol: Dictionary = ps.get("velocity_over_lifetime", {})
	if bool(vol.get("enabled", false)):
		pm.linear_accel_min = 0.0
		pm.orbit_velocity_min = _minmax_min(vol.get("orbital_y", {}), 0.0) / TAU
		pm.orbit_velocity_max = _minmax_max(vol.get("orbital_y", {}), 0.0) / TAU
		pm.radial_velocity_min = _minmax_min(vol.get("radial", {}), 0.0)
		pm.radial_velocity_max = _minmax_max(vol.get("radial", {}), 0.0)

	var rot := ps.get("start_rotation", {})
	pm.angle_min = rad_to_deg(_minmax_min(rot, 0.0))
	pm.angle_max = rad_to_deg(_minmax_max(rot, 0.0))
	gp.process_material = pm

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mat: Material = null
	if not mat_id.is_empty():
		var src := MixerMaterials.from_id(catalog, mat_id)
		if src != null:
			mat = src.duplicate()
	if mat == null:
		var sm := StandardMaterial3D.new()
		sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		sm.cull_mode = BaseMaterial3D.CULL_DISABLED
		sm.albedo_color = Color.WHITE
		mat = sm
	if MixerMaterials.is_vfx(mat):
		_configure_vfx_material(catalog, mat as ShaderMaterial, ps, life_min, life_max, cycle)
	elif mat is BaseMaterial3D:
		var bm := mat as BaseMaterial3D
		bm.vertex_color_use_as_albedo = true
		bm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		bm.billboard_keep_scale = true
		bm.no_depth_test = false
		bm.disable_receive_shadows = true
		pm.color = _gradient_color(ps.get("start_color", {}))
		var tsa: Dictionary = ps.get("texture_sheet_animation", {})
		if bool(tsa.get("enabled", false)) and str(tsa.get("mode", "Grid")) == "Grid":
			bm.particles_anim_h_frames = maxi(int(tsa.get("num_tiles_x", 1)), 1)
			bm.particles_anim_v_frames = maxi(int(tsa.get("num_tiles_y", 1)), 1)
			bm.particles_anim_loop = false
	quad.material = mat
	gp.draw_pass_1 = null if invisible else quad
	return gp


## Fills the vfx_particle_common uniforms (lifetime emulation, sprite rect, over-lifetime curves,
## Custom1 stream) from the Unity ParticleSystem dump.
static func _configure_vfx_material(catalog: AxieCatalog, mat: ShaderMaterial, ps: Dictionary, life_min: float, life_max: float, cycle: float) -> void:
	mat.set_shader_parameter("cycle_seconds", cycle)
	mat.set_shader_parameter("life_min", life_min)
	mat.set_shader_parameter("life_max", life_max)
	var sc := ps.get("start_color", {})
	var c := _gradient_color(sc)
	mat.set_shader_parameter("start_color", Vector4(c.r, c.g, c.b, c.a))

	var sol: Dictionary = ps.get("size_over_lifetime", {})
	if bool(sol.get("enabled", false)):
		var curve := _curve_from_minmax(sol.get("size", {}))
		if curve != null:
			var ct := CurveTexture.new()
			ct.curve = curve
			mat.set_shader_parameter("size_curve", ct)
			mat.set_shader_parameter("use_size_curve", true)
	var col: Dictionary = ps.get("color_over_lifetime", {})
	if bool(col.get("enabled", false)):
		var grad := _gradient(col.get("color", {}))
		if grad != null:
			var gt := GradientTexture1D.new()
			gt.gradient = grad
			mat.set_shader_parameter("color_ramp", gt)
			mat.set_shader_parameter("use_color_ramp", true)
	var rol: Dictionary = ps.get("rotation_over_lifetime", {})
	if bool(rol.get("enabled", false)):
		mat.set_shader_parameter("rot_speed", _minmax_max(rol.get("z", {}), 0.0))

	# Texture Sheet Animation in Sprites mode replaces the material texture with the sprite's atlas.
	var tsa: Dictionary = ps.get("texture_sheet_animation", {})
	if bool(tsa.get("enabled", false)) and str(tsa.get("mode", "Grid")) == "Sprites":
		var sprites: Array = tsa.get("sprites", [])
		if not sprites.is_empty() and sprites[0] is Dictionary:
			var sp: Dictionary = sprites[0]
			var tex_id := str(sp.get("texture", ""))
			var path := catalog.texture_path(tex_id) if not tex_id.is_empty() else ""
			if not path.is_empty():
				var info := catalog.texture_info(tex_id)
				var tex := MixerMaterials.load_texture(path, bool(info.get("mipmaps", true)))
				if tex != null:
					mat.set_shader_parameter("main_tex", tex)
			var r: Array = sp.get("rect", [0, 0, 1, 1])
			if r.size() >= 4:
				# Unity rect is V-up; Godot UVs run down.
				var y := 1.0 - float(r[1]) - float(r[3])
				mat.set_shader_parameter("sprite_rect", Vector4(float(r[0]), y, float(r[2]), float(r[3])))
	elif bool(tsa.get("enabled", false)):
		# Grid mode with a constant frame: static tile of _MainTex.
		var tiles_x := maxi(int(tsa.get("num_tiles_x", 1)), 1)
		var tiles_y := maxi(int(tsa.get("num_tiles_y", 1)), 1)
		var frame := int(floor(_minmax_max(tsa.get("frame_over_time", {}), 0.0) * float(tiles_x * tiles_y)))
		frame = clampi(frame, 0, tiles_x * tiles_y - 1)
		var cx := frame % tiles_x
		var cy := frame / tiles_x
		mat.set_shader_parameter("sprite_rect", Vector4(float(cx) / tiles_x, float(cy) / tiles_y, 1.0 / tiles_x, 1.0 / tiles_y))

	# Custom Data → Custom1 vertex stream (TEXCOORD0.zw = xy, TEXCOORD1.xy = zw in Unity's packing).
	var cd: Dictionary = ps.get("custom_data", {})
	var c1: Dictionary = cd.get("custom1", {})
	if bool(cd.get("enabled", false)) and str(c1.get("mode", "Disabled")) == "Vector":
		var comps: Array = c1.get("components", [])
		var consts := Vector4.ZERO
		for i in mini(comps.size(), 4):
			var mm: Variant = comps[i]
			var mode := str((mm as Dictionary).get("mode", "Constant")) if mm is Dictionary else "Constant"
			if (mode == "Curve" or mode == "TwoCurves") and (i == 2 or i == 3):
				var curve := _curve_from_minmax(mm)
				if curve != null:
					var ct := CurveTexture.new()
					ct.curve = curve
					mat.set_shader_parameter("custom1_curve_z" if i == 2 else "custom1_curve_w", ct)
					mat.set_shader_parameter("custom1_z_is_curve" if i == 2 else "custom1_w_is_curve", true)
					continue
			consts[i] = _minmax_max(mm, 0.0)
		mat.set_shader_parameter("custom1_const", consts)


static func _minmax_max(mm: Variant, fallback: float) -> float:
	if not (mm is Dictionary):
		return fallback
	var d: Dictionary = mm
	var mode := str(d.get("mode", "Constant"))
	match mode:
		"Constant":
			return float(d.get("constant", fallback))
		"TwoConstants":
			return float(d.get("constant_max", fallback))
		"Curve", "TwoCurves":
			var samples: Array = d.get("curve", [])
			var best := -INF
			for s in samples:
				best = maxf(best, float(s))
			return best if best > -INF else fallback
	return fallback


static func _minmax_min(mm: Variant, fallback: float) -> float:
	if not (mm is Dictionary):
		return fallback
	var d: Dictionary = mm
	var mode := str(d.get("mode", "Constant"))
	match mode:
		"Constant":
			return float(d.get("constant", fallback))
		"TwoConstants":
			return float(d.get("constant_min", fallback))
		"Curve":
			return _minmax_max(mm, fallback)
		"TwoCurves":
			var samples: Array = d.get("curve_min", [])
			var best := INF
			for s in samples:
				best = minf(best, float(s))
			return best if best < INF else fallback
	return fallback


static func _curve_from_minmax(mm: Variant) -> Curve:
	if not (mm is Dictionary):
		return null
	var samples: Array = (mm as Dictionary).get("curve", [])
	if samples.is_empty():
		return null
	var c := Curve.new()
	var n := samples.size()
	# Curve clamps points to [min_value, max_value] (default 0..1); Unity curves are unbounded.
	var lo := 0.0
	var hi := 1.0
	for v in samples:
		lo = minf(lo, float(v))
		hi = maxf(hi, float(v))
	c.min_value = lo
	c.max_value = hi
	for i in n:
		c.add_point(Vector2(float(i) / float(maxi(n - 1, 1)), float(samples[i])))
	return c


static func _gradient_color(g: Variant) -> Color:
	if not (g is Dictionary):
		return Color.WHITE
	var d: Dictionary = g
	var mode := str(d.get("mode", "Color"))
	if mode == "Color" or mode == "TwoColors":
		return _color(d.get("color", [1, 1, 1, 1]))
	var grad := _gradient(g)
	if grad != null:
		return grad.sample(0.0)
	return Color.WHITE


static func _gradient(g: Variant) -> Gradient:
	if not (g is Dictionary):
		return null
	var d: Dictionary = g
	var gd: Variant = d.get("gradient", {})
	if not (gd is Dictionary) or (gd as Dictionary).is_empty():
		return null
	var color_keys: Array = gd.get("color_keys", [])
	var alpha_keys: Array = gd.get("alpha_keys", [])
	if color_keys.is_empty() and alpha_keys.is_empty():
		return null
	var times: Dictionary = {}
	for k in color_keys:
		times[snappedf(float(k.get("t", 0.0)), 0.001)] = true
	for k in alpha_keys:
		times[snappedf(float(k.get("t", 0.0)), 0.001)] = true
	var ts: Array = times.keys()
	ts.sort()
	var grad := Gradient.new()
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for t in ts:
		var c := _sample_keys_color(color_keys, float(t))
		c.a = _sample_keys_alpha(alpha_keys, float(t))
		offsets.append(float(t))
		colors.append(c)
	grad.offsets = offsets
	grad.colors = colors
	return grad


static func _sample_keys_color(keys: Array, t: float) -> Color:
	if keys.is_empty():
		return Color.WHITE
	var prev: Dictionary = keys[0]
	for k in keys:
		var kt := float(k.get("t", 0.0))
		if kt >= t:
			var pt := float(prev.get("t", 0.0))
			var c0 := _color(prev.get("color", [1, 1, 1, 1]))
			var c1 := _color(k.get("color", [1, 1, 1, 1]))
			if kt <= pt:
				return c1
			return c0.lerp(c1, (t - pt) / (kt - pt))
		prev = k
	return _color(prev.get("color", [1, 1, 1, 1]))


static func _sample_keys_alpha(keys: Array, t: float) -> float:
	if keys.is_empty():
		return 1.0
	var prev: Dictionary = keys[0]
	for k in keys:
		var kt := float(k.get("t", 0.0))
		if kt >= t:
			var pt := float(prev.get("t", 0.0))
			var a0 := float(prev.get("a", 1.0))
			var a1 := float(k.get("a", 1.0))
			if kt <= pt:
				return a1
			return lerpf(a0, a1, (t - pt) / (kt - pt))
		prev = k
	return float(prev.get("a", 1.0))


static func _color(v: Variant) -> Color:
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if a.size() > 3 else 1.0)
	return Color.WHITE
