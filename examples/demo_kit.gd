extends Object
## Shared helpers for the community examples. Not part of the public mixer API.


const HUD_THEME := preload("res://examples/hud_theme.tres")
const BOOTSTRAP := preload("res://examples/bootstrap.tscn")

const MIXER := "res://examples/mixer_demo.tscn"
const COLLECTION := "res://examples/collection_demo.tscn"
const SPAWNER := "res://examples/spawner_demo.tscn"
const AVATARS := "res://examples/avatars_demo.tscn"
const MINIMAL := "res://examples/minimal_from_genes.tscn"

const SAMPLE_PACK := "res://tests/goldens/sample_axies.json"

## Axie #123 from the pinned sample pack.
const SAMPLE_GENES := "0x180000000000030002018040810800000001000c080043040001000c0800800200010014084083020001000c1860430600010008100085060001000408604506"


static func ensure_bootstrap(host: Node) -> void:
	if host.get_node_or_null("Bootstrap") != null:
		return
	if host.get_node_or_null("AxieMixerInitializer") != null:
		return
	if AxieFactory.default_factory != null or AxieDefaults.factory != null:
		return
	var boot: Node = BOOTSTRAP.instantiate()
	boot.name = "Bootstrap"
	host.add_child(boot)


static func ensure_stage(host: Node, cam_pos: Vector3 = Vector3(0.0, 1.2, 3.5), look_at: Vector3 = Vector3(0.0, 0.7, 0.0)) -> void:
	if host.get_viewport().get_camera_3d() == null:
		var cam := Camera3D.new()
		cam.name = "MainCamera"
		host.add_child(cam)
		cam.position = cam_pos
		cam.fov = 60.0
		cam.look_at(look_at)
		cam.current = true
	if _find_type(host, "DirectionalLight3D") == null:
		var sun := DirectionalLight3D.new()
		sun.name = "Sun"
		sun.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
		sun.light_energy = 1.15
		host.add_child(sun)
	if _find_type(host, "WorldEnvironment") == null:
		var we := WorldEnvironment.new()
		we.name = "WorldEnvironment"
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.18, 0.2, 0.24)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.28, 0.3, 0.36)
		env.ambient_light_energy = 0.55
		we.environment = env
		host.add_child(we)


static func missing_classes(names: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for n in names:
		if not has_global_class(n):
			out.append(n)
	return out


static func has_global_class(name: String) -> bool:
	if ClassDB.class_exists(name):
		return true
	for info in ProjectSettings.get_global_class_list():
		if str(info.get("class", "")) == name:
			return true
	return false


static func add_nav(parent: Control, current: String) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	_nav_btn(row, "Mixer", MIXER, current)
	_nav_btn(row, "Collection", COLLECTION, current)
	_nav_btn(row, "Spawner", SPAWNER, current)
	_nav_btn(row, "Avatars", AVATARS, current)
	_nav_btn(row, "Minimal", MINIMAL, current)


static func button(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


static func clip_names() -> PackedStringArray:
	var seen := {}
	var out := PackedStringArray()
	for path in [
		"res://addons/axie_mixer_3d/animation/anim_names.gd",
		"res://addons/axie_mixer_3d_weapon_anims/weapon_anim_names.gd",
	]:
		var script: Script = load(path)
		if script == null:
			continue
		var map: Dictionary = script.get_script_constant_map()
		for k in map.keys():
			if typeof(map[k]) != TYPE_STRING:
				continue
			var n := str(map[k])
			if seen.has(n):
				continue
			seen[n] = true
			out.append(n)
	out.sort()
	return out


static func _nav_btn(parent: Control, text: String, scene: String, current: String) -> void:
	var b := Button.new()
	b.text = text
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.disabled = text == current
	b.pressed.connect(func() -> void: parent.get_tree().change_scene_to_file(scene))
	parent.add_child(b)


static func _find_type(host: Node, type_name: String) -> Node:
	var stack: Array[Node] = [host]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.get_class() == type_name:
			return n
		for c in n.get_children():
			stack.append(c)
	return null
