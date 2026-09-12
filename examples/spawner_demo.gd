extends Node3D
## Unity `AxieMixer3DSpawner`: a grid of random valid Axies on the public factory path.

const DemoKit := preload("res://examples/demo_kit.gd")
const ExampleOptions := preload("res://examples/example_options.gd")

@export var rows: int = 3
@export var columns: int = 3
@export var spacing: float = 2.5
@export var use_seed: bool = true
@export var seed_value: int = 12345
@export var clip_name: String = "Idle"

var _characters: Array[AxieCharacter3D] = []
var _status: Label
var _perf: Label
var _frames: int = 0
var _accum: float = 0.0
var _fps: float = 0.0


func _ready() -> void:
	DemoKit.ensure_bootstrap(self)
	DemoKit.ensure_stage(self)
	_build_hud()
	spawn_grid()
	_frame_camera()


func _process(delta: float) -> void:
	_frames += 1
	_accum += delta
	if _accum >= 0.5:
		_fps = float(_frames) / _accum
		_frames = 0
		_accum = 0.0
		if _perf:
			_perf.text = "Perf  %.1f fps  %d axies  %d MeshInstance3D" % [
				_fps, _characters.size(), _count_meshes()
			]


func _exit_tree() -> void:
	dispose_all()


func spawn_grid() -> int:
	dispose_all()
	var rng := RandomNumberGenerator.new()
	if use_seed:
		rng.seed = seed_value
	else:
		rng.randomize()
	var built := 0
	var failed := 0
	var count := maxi(rows, 1) * maxi(columns, 1)
	for i in count:
		var desc: AxieDescriptor = ExampleOptions.random_descriptor(rng)
		var character := AxieCharacter3D.from_descriptor(desc)
		if character == null or character.root == null:
			failed += 1
			continue
		var cls := desc.parts[0].part_class if not desc.parts.is_empty() else ""
		var variant := desc.parts[0].variant if not desc.parts.is_empty() else 0
		character.root.name = "Axie_%02d_%s%02d_%s_c%d" % [
			i, cls, variant, AxieTypes.body_name(desc.body), desc.color_variant
		]
		add_child(character.root)
		character.root.position = _grid_position(i)
		character.root.rotation_degrees.y = 0.0  # front is +Z, toward the camera
		_characters.append(character)
		if character.playable:
			character.playable.play(clip_name, "", true)
		built += 1
	if _status:
		_status.text = "Spawned %d / %d  (failed %d). Dispose on exit." % [built, count, failed]
	return built


func dispose_all() -> void:
	for ch in _characters:
		if ch:
			ch.dispose()
	_characters.clear()


func _grid_position(index: int) -> Vector3:
	var cols := maxi(columns, 1)
	var row := int(index / cols)
	var col := index % cols
	var x_off := (cols - 1) * 0.5
	var z_off := (maxi(rows, 1) - 1) * 0.5
	return Vector3((col - x_off) * spacing, 0.0, (row - z_off) * spacing)


func _frame_camera() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var cols := maxi(columns, 1)
	var r := maxi(rows, 1)
	var span := maxf(cols, r) * spacing
	cam.position = Vector3(0.0, 1.4 + span * 0.25, 3.2 + span * 0.55)
	cam.fov = 60.0
	cam.look_at(Vector3(0.0, 0.7, 0.0))


func _count_meshes() -> int:
	var n := 0
	for ch in _characters:
		if ch == null or ch.root == null:
			continue
		n += ch.root.find_children("*", "MeshInstance3D", true, false).size()
	return n


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	var hud := Control.new()
	hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.theme = DemoKit.HUD_THEME
	layer.add_child(hud)
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.offset_left = 12.0
	panel.offset_top = 12.0
	panel.offset_right = 480.0
	panel.offset_bottom = 170.0
	hud.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	DemoKit.add_nav(v, "Spawner")
	var title := Label.new()
	title.text = "Spawner — random valid grid (from_descriptor)"
	title.add_theme_font_size_override("font_size", 16)
	v.add_child(title)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_status)
	_perf = Label.new()
	_perf.text = "Perf  —"
	v.add_child(_perf)
