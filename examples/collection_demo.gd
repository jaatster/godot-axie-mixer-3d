extends Node3D
## Grid of characters across body types × part classes. Disposes every Axie on exit.

const DemoKit := preload("res://examples/demo_kit.gd")
const ExampleOptions := preload("res://examples/example_options.gd")
const CLASS_NAMES: PackedStringArray = ["Aquatic", "Beast", "Bird", "Bug", "Plant", "Reptile"]
const CLASS_COLORS: PackedInt32Array = [14, 3, 25, 20, 9, 30]
const SPACING := 2.5
const VARIANT := 2
const LEVEL := 1
const SKIN_COUNT := 14

var _characters: Array[AxieCharacter3D] = []
var _status: Label
var _error: Label
var _skin_label: Label
var _skin: int = 0


func _ready() -> void:
	DemoKit.ensure_bootstrap(self)
	DemoKit.ensure_stage(self)
	_build_hud()
	var missing := DemoKit.missing_classes(["AxieDescriptor", "AxieCharacter3D", "AxiePartDescriptor"])
	if not missing.is_empty():
		_fatal("Missing mixer classes: %s. Enable the Axie Mixer 3D plugin." % ", ".join(missing))
		return
	await get_tree().process_frame
	_spawn_grid()
	_frame_camera()


func _exit_tree() -> void:
	_dispose_all()


func _fatal(msg: String) -> void:
	push_error(msg)
	if _error:
		_error.text = msg
		_error.get_parent().visible = true
	if _status:
		_status.text = msg


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
	panel.offset_right = 460.0
	panel.offset_bottom = 170.0
	hud.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	DemoKit.add_nav(v, "Collection")
	var title := Label.new()
	title.text = "Collection — body types × part classes"
	title.add_theme_font_size_override("font_size", 16)
	v.add_child(title)
	var skin_row := HBoxContainer.new()
	v.add_child(skin_row)
	DemoKit.button(skin_row, "< Skin", func() -> void: _nudge_skin(-1))
	_skin_label = Label.new()
	_skin_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_skin_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	skin_row.add_child(_skin_label)
	DemoKit.button(skin_row, "Skin >", func() -> void: _nudge_skin(1))
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_status)
	_refresh_skin_label()
	var err_wrap := PanelContainer.new()
	err_wrap.visible = false
	err_wrap.set_anchors_preset(Control.PRESET_CENTER)
	err_wrap.offset_left = -280.0
	err_wrap.offset_right = 280.0
	err_wrap.offset_top = -50.0
	err_wrap.offset_bottom = 50.0
	hud.add_child(err_wrap)
	_error = Label.new()
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	err_wrap.add_child(_error)


func _nudge_skin(delta: int) -> void:
	_skin = posmod(_skin + delta, SKIN_COUNT)
	_refresh_skin_label()
	_spawn_grid()


func _refresh_skin_label() -> void:
	if _skin_label:
		_skin_label.text = "S%02d" % _skin


func _spawn_grid() -> void:
	_dispose_all()
	var bodies := AxieTypes.BODY_NAMES.size()
	var cols := CLASS_NAMES.size()
	var built := 0
	var hidden := 0
	var failed := 0
	for bi in bodies:
		for ci in cols:
			var desc := _make_descriptor(bi, ci)
			var character := AxieCharacter3D.from_descriptor(desc)
			if character == null or character.root == null:
				failed += 1
				continue
			var index := bi * cols + ci
			character.root.name = "Axie_%02d_%s_%s" % [index, AxieTypes.body_name(bi), CLASS_NAMES[ci]]
			add_child(character.root)
			character.root.position = _grid_position(index, cols)
			character.root.rotation_degrees.y = 0.0  # front is +Z, toward the camera
			if _skin != 0 and desc.parts.is_empty():
				character.root.visible = false
				hidden += 1
			_characters.append(character)
			if character.playable:
				character.playable.play(AnimNames.Idle, "", true)
			built += 1
	_status.text = "Spawned %d / %d  (hidden %d, failed %d). S%02d omits unshipped parts." % [
		built, bodies * cols, hidden, failed, _skin
	]


func _make_descriptor(body: int, class_idx: int) -> AxieDescriptor:
	var part_class := CLASS_NAMES[class_idx]
	var color := 48 if body == AxieTypes.Body.FROSTY else int(CLASS_COLORS[class_idx])
	var factory = null if _skin == 0 else AxieFactory.default_factory
	return ExampleOptions.combo_descriptor(
		factory, body, part_class, VARIANT, _skin, LEVEL, color
	)


func _grid_position(index: int, columns: int) -> Vector3:
	var rows := AxieTypes.BODY_NAMES.size()
	var row := int(index / columns)
	var col := index % columns
	var x_off := (columns - 1) * 0.5
	var z_off := (rows - 1) * 0.5
	return Vector3((col - x_off) * SPACING, 0.0, (row - z_off) * SPACING)


func _frame_camera() -> void:
	var cols := CLASS_NAMES.size()
	var rows := AxieTypes.BODY_NAMES.size()
	var span := maxf(cols, rows) * SPACING
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	cam.position = Vector3(0.0, span * 0.55 + 1.2, span * 0.9 + 2.4)
	cam.look_at(Vector3(0.0, 0.4, 0.0))


func _dispose_all() -> void:
	for c in _characters:
		if c:
			c.dispose()
	_characters.clear()
