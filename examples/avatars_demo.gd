extends Node3D
## Unity `AxieAvatars`: static AxieAvatarRenderer snapshots + a realtime spinning avatar.

const DemoKit := preload("res://examples/demo_kit.gd")
const AVATAR_SIZE := 512

var _character: AxieCharacter3D
var _renderer: AxieAvatarRenderer
var _realtime_params: AxieAvatarRenderParams
var _static_tex_0: TextureRect
var _static_tex_1: TextureRect
var _realtime_tex: TextureRect
var _error: Label
var _status: Label
var _heading: float = 180.0
var _ready_to_render: bool = false


func _ready() -> void:
	DemoKit.ensure_bootstrap(self)
	DemoKit.ensure_stage(self, Vector3(0.0, 1.2, 3.6))
	_build_hud()
	var missing := DemoKit.missing_classes(
		["AxieDescriptor", "AxieCharacter3D", "AxieAvatarRenderer", "AxieAvatarRenderParams"]
	)
	if not missing.is_empty():
		_fatal("Missing mixer classes: %s. Enable the Axie Mixer 3D plugin." % ", ".join(missing))
		return
	for _i in 3:
		await get_tree().process_frame
	_build_character()
	if _character == null:
		return
	await get_tree().process_frame
	await _capture_static()
	_ready_to_render = true


func _process(delta: float) -> void:
	if not _ready_to_render or _renderer == null or _realtime_params == null:
		return
	# Unity's example spins `modelHeading`, which only moves the shadow band (the view is in model
	# space). Orbit the view direction instead so the spin is visible.
	_heading = fposmod(_heading + 30.0 * delta, 360.0)
	_realtime_params.view_direction = Vector3(0.0, -0.35, -1.0).rotated(Vector3.UP, deg_to_rad(_heading))
	var tex: Texture2D = _renderer.render(ImageTexture.new(), _realtime_params)
	if tex and _realtime_tex:
		_realtime_tex.texture = tex


func _exit_tree() -> void:
	_ready_to_render = false
	if _renderer:
		_renderer.dispose()
	_renderer = null
	if _character:
		_character.dispose()
	_character = null


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

	var top := PanelContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_STOP
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.offset_left = 12.0
	top.offset_right = -12.0
	top.offset_top = 12.0
	top.offset_bottom = 88.0
	hud.add_child(top)
	var top_v := VBoxContainer.new()
	top.add_child(top_v)
	DemoKit.add_nav(top_v, "Avatars")
	_status = Label.new()
	_status.text = "Axie avatars — static snapshots + realtime spinning render"
	top_v.add_child(_status)

	var left := PanelContainer.new()
	left.mouse_filter = Control.MOUSE_FILTER_STOP
	left.set_anchor(SIDE_LEFT, 0.0)
	left.set_anchor(SIDE_TOP, 0.0)
	left.set_anchor(SIDE_BOTTOM, 1.0)
	left.offset_left = 12.0
	left.offset_top = 100.0
	left.offset_right = 340.0
	left.offset_bottom = -12.0
	hud.add_child(left)
	var left_v := VBoxContainer.new()
	left_v.add_theme_constant_override("separation", 8)
	left.add_child(left_v)
	left_v.add_child(_header("Static snapshot 0"))
	_static_tex_0 = _tex_rect(left_v, Vector2(300, 220))
	left_v.add_child(_header("Static snapshot 1"))
	_static_tex_1 = _tex_rect(left_v, Vector2(300, 220))

	var right := PanelContainer.new()
	right.mouse_filter = Control.MOUSE_FILTER_STOP
	right.set_anchor(SIDE_RIGHT, 1.0)
	right.set_anchor(SIDE_TOP, 0.0)
	right.set_anchor(SIDE_BOTTOM, 1.0)
	right.offset_left = -360.0
	right.offset_top = 100.0
	right.offset_right = -12.0
	right.offset_bottom = -12.0
	hud.add_child(right)
	var right_v := VBoxContainer.new()
	right_v.add_theme_constant_override("separation", 8)
	right.add_child(right_v)
	right_v.add_child(_header("Realtime renderer"))
	_realtime_tex = _tex_rect(right_v, Vector2(320, 240))

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


func _header(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 15)
	return l


func _tex_rect(parent: Control, min_size: Vector2) -> TextureRect:
	var tr := TextureRect.new()
	tr.custom_minimum_size = min_size
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(tr)
	return tr


func _build_character() -> void:
	_character = AxieCharacter3D.from_genes(DemoKit.SAMPLE_GENES)
	if _character == null or _character.root == null:
		_fatal("Failed to build avatar character (catalog missing?).")
		return
	_character.root.name = "Avatar Axie"
	add_child(_character.root)
	_character.root.rotation_degrees.y = 0.0  # front is +Z, toward the camera
	if _character.playable:
		if _character.playable.play(AnimNames.Run, "", true) == null:
			_character.playable.play(AnimNames.Idle, "", true)
	_renderer = AxieAvatarRenderer.new(_character)
	_realtime_params = AxieAvatarRenderParams.new()
	_realtime_params.width = AVATAR_SIZE
	_realtime_params.height = AVATAR_SIZE
	_realtime_params.model_heading = 180.0
	_realtime_params.view_center = Vector3(0.0, 0.75, 0.0)
	_realtime_params.view_direction = Vector3(-1.0, -1.0, -3.0)
	_status.text = "Character ready — capturing snapshots."


func _capture_static() -> void:
	if _renderer == null:
		return
	var p0 := AxieAvatarRenderParams.new()
	p0.width = AVATAR_SIZE
	p0.height = AVATAR_SIZE
	p0.model_heading = 0.0
	p0.view_center = Vector3(0.0, 0.75, 0.0)
	p0.view_direction = Vector3(0.0, 0.0, -1.0)
	var p1 := AxieAvatarRenderParams.new()
	p1.width = AVATAR_SIZE
	p1.height = AVATAR_SIZE
	p1.model_heading = 180.0
	p1.view_center = Vector3(0.0, 0.75, 0.0)
	p1.view_direction = Vector3(0.0, 0.0, 1.0) # from behind
	var dummy := ImageTexture.new()
	var t0: Texture2D = _renderer.render(dummy, p0)
	await RenderingServer.frame_post_draw
	if _static_tex_0:
		_static_tex_0.texture = _copy_texture(t0)
	var t1: Texture2D = _renderer.render(dummy, p1)
	await RenderingServer.frame_post_draw
	if _static_tex_1:
		_static_tex_1.texture = _copy_texture(t1)
	_status.text = "Static snapshots captured. Realtime renderer spinning."


func _copy_texture(src: Texture2D) -> Texture2D:
	if src == null:
		return null
	var img := src.get_image()
	if img == null:
		return src
	return ImageTexture.create_from_image(img)
