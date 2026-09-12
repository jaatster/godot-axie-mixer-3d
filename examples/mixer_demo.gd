extends Node3D
## Unity `AxieMixer3DExample`: genes / descriptor, Idle→Walk→Run blend, one-shots, outline.

const DemoKit := preload("res://examples/demo_kit.gd")

const GRAPHQL_URL := "https://graphql-gateway.axieinfinity.com/graphql"
const CLASS_NAMES: PackedStringArray = ["Aquatic", "Beast", "Bird", "Bug", "Plant", "Reptile"]
const CLASS_COLORS: PackedInt32Array = [14, 3, 25, 20, 9, 30]
const VARIANT_VALS: PackedInt32Array = [2, 4, 6, 8, 10, 12]
const SKIN_COUNT := 14
const MAX_LEVEL := 4
const LOCO_SPEED_MAX := 5.0
const OUTLINE_LAYER := 2
const BASE_LAYER := 1

var _character: AxieCharacter3D
var _playable: AxiePlayable
var _anchor: Node3D
var _outline_fx: CompositorEffect
var _http: HTTPRequest
var _curl_thread: Thread
var _last_fetch_id: String = ""

var _ui_body_idx: int = 0
var _ui_body_class_idx: int = 1
var _ui_color_variant: int = 3
var _ui_part_class: PackedInt32Array = PackedInt32Array()
var _ui_part_variant: PackedInt32Array = PackedInt32Array()
var _ui_part_skin: PackedInt32Array = PackedInt32Array()
var _ui_part_level: PackedInt32Array = PackedInt32Array()

var _gene_mode: bool = false
var _applied_genes: String = ""
var _suppress_genes: bool = false
var _combine: bool = true
var _outline_mode: int = 0
var _loco_speed: float = 0.0
var _yaw: float = 0.0  # pack front is +Z; the stage camera sits on +Z, so 0 faces it
var _dragging: bool = false
var _current_clip: String = ""
var _fetching: bool = false
var _all_clips: PackedStringArray = PackedStringArray()

var _left_panel: Control
var _right_panel: Control
var _genes_edit: LineEdit
var _fetch_label: Label
var _picker_refreshers: Array[Callable] = []
var _status_label: Label
var _speed_label: Label
var _error_label: Label


func _ready() -> void:
	_anchor = get_node_or_null("World/CharacterAnchor") as Node3D
	if _anchor == null:
		_anchor = Node3D.new()
		_anchor.name = "CharacterAnchor"
		add_child(_anchor)
	DemoKit.ensure_bootstrap(self)
	DemoKit.ensure_stage(self)
	_init_customization()
	_all_clips = DemoKit.clip_names()
	_build_hud()
	_http = HTTPRequest.new()
	_http.timeout = 25.0
	_http.use_threads = true
	add_child(_http)
	_http.request_completed.connect(_on_fetch_completed)
	var missing := DemoKit.missing_classes(
		["AxieDescriptor", "AxieCharacter3D", "AxiePlayable", "AnimNames", "AxieMixerInitializer"]
	)
	if not missing.is_empty():
		_fatal("Missing mixer classes: %s. Enable the Axie Mixer 3D plugin." % ", ".join(missing))
		return
	await get_tree().process_frame
	_rebuild()


func _exit_tree() -> void:
	if _curl_thread != null:
		_curl_thread.wait_to_finish()
		_curl_thread = null
	_dispose_character()


func _unhandled_input(event: InputEvent) -> void:
	if _character == null or _character.root == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed and not _pointer_over_hud():
				_dragging = true
			elif not mb.pressed:
				_dragging = false
	elif event is InputEventMouseMotion and _dragging:
		_yaw += (event as InputEventMouseMotion).relative.x * -0.4
		_character.root.rotation_degrees.y = _yaw


func _fatal(msg: String) -> void:
	push_error(msg)
	if _error_label:
		_error_label.text = msg
		_error_label.get_parent().visible = true
	if _status_label:
		_status_label.text = msg


func _init_customization() -> void:
	var n := AxieTypes.PART_NAMES.size()
	_ui_part_class.resize(n)
	_ui_part_variant.resize(n)
	_ui_part_skin.resize(n)
	_ui_part_level.resize(n)
	for i in n:
		_ui_part_class[i] = _ui_body_class_idx
		_ui_part_variant[i] = 0
		_ui_part_skin[i] = 0
		_ui_part_level[i] = 1
	_ui_color_variant = int(CLASS_COLORS[_ui_body_class_idx])
	_apply_genes_to_ui(DemoKit.SAMPLE_GENES)
	_gene_mode = true
	_applied_genes = DemoKit.SAMPLE_GENES


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	var hud := Control.new()
	hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.theme = DemoKit.HUD_THEME
	layer.add_child(hud)

	_left_panel = PanelContainer.new()
	_left_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_left_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_left_panel.offset_left = 12.0
	_left_panel.offset_top = 12.0
	_left_panel.offset_right = 430.0
	_left_panel.offset_bottom = 720.0
	hud.add_child(_left_panel)
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 8)
	_left_panel.add_child(left)
	DemoKit.add_nav(left, "Mixer")

	var title := Label.new()
	title.text = "Axie ID / Genes"
	title.add_theme_font_size_override("font_size", 16)
	left.add_child(title)
	var gene_row := HBoxContainer.new()
	left.add_child(gene_row)
	_genes_edit = LineEdit.new()
	_genes_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_genes_edit.placeholder_text = "Axie ID or 0x… genes"
	_genes_edit.text = DemoKit.SAMPLE_GENES
	_genes_edit.text_changed.connect(_on_genes_changed)
	gene_row.add_child(_genes_edit)
	DemoKit.button(gene_row, "Load", _on_load_pressed)
	_fetch_label = Label.new()
	_fetch_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_fetch_label)

	var customize := Label.new()
	customize.text = "Customize"
	customize.add_theme_font_size_override("font_size", 16)
	left.add_child(customize)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 280)
	left.add_child(scroll)
	var pickers := VBoxContainer.new()
	pickers.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pickers.add_theme_constant_override("separation", 6)
	scroll.add_child(pickers)
	_picker_row(pickers, "Body type", func() -> String: return AxieTypes.body_name(_ui_body_idx), func(d: int) -> void:
		_ui_body_idx = posmod(_ui_body_idx + d, AxieTypes.BODY_NAMES.size())
		_apply_ui()
	)
	_picker_row(pickers, "Body class", func() -> String: return CLASS_NAMES[_ui_body_class_idx], func(d: int) -> void:
		_ui_body_class_idx = posmod(_ui_body_class_idx + d, CLASS_NAMES.size())
		_ui_color_variant = int(CLASS_COLORS[_ui_body_class_idx])
		_apply_ui()
	)
	for i in AxieTypes.PART_NAMES.size():
		var pi := i
		var part := AxieTypes.PART_NAMES[pi]
		_picker_row(pickers, "%s class" % part, func() -> String: return CLASS_NAMES[_ui_part_class[pi]], func(d: int) -> void:
			_ui_part_class[pi] = posmod(_ui_part_class[pi] + d, CLASS_NAMES.size())
			_apply_ui()
		)
		_picker_row(pickers, "%s value" % part, func() -> String: return "V%02d" % VARIANT_VALS[_ui_part_variant[pi]], func(d: int) -> void:
			_ui_part_variant[pi] = posmod(_ui_part_variant[pi] + d, VARIANT_VALS.size())
			_apply_ui()
		)
		_picker_row(pickers, "%s skin" % part, func() -> String: return "S%02d" % _ui_part_skin[pi], func(d: int) -> void:
			_ui_part_skin[pi] = posmod(_ui_part_skin[pi] + d, SKIN_COUNT)
			_apply_ui()
		)
		_picker_row(pickers, "%s level" % part, func() -> String: return str(_ui_part_level[pi]), func(d: int) -> void:
			_ui_part_level[pi] = clampi(_ui_part_level[pi] + d, 1, MAX_LEVEL)
			_apply_ui()
		)

	var combine := CheckButton.new()
	combine.text = "Combine meshes"
	combine.button_pressed = _combine
	combine.toggled.connect(func(on: bool) -> void:
		_combine = on
		_rebuild()
	)
	left.add_child(combine)
	var outline_row := HBoxContainer.new()
	left.add_child(outline_row)
	var ol := Label.new()
	ol.text = "Outline"
	outline_row.add_child(ol)
	var outline := OptionButton.new()
	outline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outline.add_item("None", 0)
	outline.add_item("DrawObjects", 1)
	outline.add_item("PostProcess", 2)
	outline.select(_outline_mode)
	outline.item_selected.connect(func(idx: int) -> void:
		_outline_mode = idx
		_apply_outline()
	)
	outline_row.add_child(outline)
	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_status_label)

	_right_panel = PanelContainer.new()
	_right_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_right_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_right_panel.offset_left = -420.0
	_right_panel.offset_top = 12.0
	_right_panel.offset_right = -12.0
	_right_panel.offset_bottom = 720.0
	hud.add_child(_right_panel)
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 8)
	_right_panel.add_child(right)
	var blend_title := Label.new()
	blend_title.text = "Default Blend (Idle → Walk → Run)"
	blend_title.add_theme_font_size_override("font_size", 16)
	right.add_child(blend_title)
	_speed_label = Label.new()
	_speed_label.text = "Loco speed: 0.0"
	right.add_child(_speed_label)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = LOCO_SPEED_MAX
	slider.step = 0.05
	slider.value = _loco_speed
	slider.value_changed.connect(_on_speed_changed)
	right.add_child(slider)
	DemoKit.button(right, "Skill → Dead → Default", _play_skill_dead)
	var anim_title := Label.new()
	anim_title.text = "All Animations"
	anim_title.add_theme_font_size_override("font_size", 16)
	right.add_child(anim_title)
	var anim_scroll := ScrollContainer.new()
	anim_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(anim_scroll)
	var anim_list := VBoxContainer.new()
	anim_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	anim_scroll.add_child(anim_list)
	for clip_name in _all_clips:
		var n := clip_name
		DemoKit.button(anim_list, n, func() -> void: _play_one_shot(n))

	var err_wrap := PanelContainer.new()
	err_wrap.visible = false
	err_wrap.set_anchors_preset(Control.PRESET_CENTER)
	err_wrap.offset_left = -280.0
	err_wrap.offset_right = 280.0
	err_wrap.offset_top = -50.0
	err_wrap.offset_bottom = 50.0
	hud.add_child(err_wrap)
	_error_label = Label.new()
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	err_wrap.add_child(_error_label)


func _picker_row(parent: Control, label: String, value: Callable, nudge: Callable) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = 110.0
	row.add_child(l)
	var val := Label.new()
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	val.text = str(value.call())
	_picker_refreshers.append(func() -> void: val.text = str(value.call()))
	DemoKit.button(row, "<", func() -> void:
		nudge.call(-1)
		val.text = str(value.call())
	)
	row.add_child(val)
	DemoKit.button(row, ">", func() -> void:
		nudge.call(1)
		val.text = str(value.call())
	)


func _on_speed_changed(v: float) -> void:
	_loco_speed = v
	if _speed_label:
		_speed_label.text = "Loco speed: %.1f" % v
	if _playable:
		_playable.set_speed(v)


func _on_genes_changed(text: String) -> void:
	if _suppress_genes:
		return
	var trimmed := text.strip_edges()
	if trimmed != _applied_genes and _looks_like_genes(trimmed):
		_apply_genes(trimmed)


func _on_load_pressed() -> void:
	var s := _genes_edit.text.strip_edges()
	if s.is_empty():
		return
	if _is_axie_id(s):
		_fetch_genes_by_id(s)
	elif _looks_like_genes(s):
		_apply_genes(s)
	else:
		_fetch_label.text = "Enter an Axie ID (number) or a gene hex string."


func _apply_ui() -> void:
	_gene_mode = false
	_rebuild()


func _apply_genes(genes: String) -> void:
	_gene_mode = true
	_applied_genes = genes
	_apply_genes_to_ui(genes)
	_rebuild()


## Refreshes every Customize value label from the current _ui_* state (after loading genes).
func _refresh_pickers() -> void:
	for r in _picker_refreshers:
		(r as Callable).call()


func _apply_genes_to_ui(genes: String) -> void:
	var d := AxieDescriptor.from_genes(genes)
	_ui_body_idx = clampi(d.body, 0, AxieTypes.BODY_NAMES.size() - 1)
	_ui_color_variant = d.color_variant
	_ui_body_class_idx = _class_idx_from_color(d.color_variant)
	for p in d.parts:
		var ti := p.type
		if ti < 0 or ti >= _ui_part_class.size():
			continue
		var ci := CLASS_NAMES.find(p.part_class)
		if ci >= 0:
			_ui_part_class[ti] = ci
		var vi := _variant_index(p.variant)
		if vi >= 0:
			_ui_part_variant[ti] = vi
		_ui_part_skin[ti] = clampi(p.skin, 0, SKIN_COUNT - 1)
		_ui_part_level[ti] = clampi(p.level, 1, MAX_LEVEL)
	_refresh_pickers()


func _variant_index(variant: int) -> int:
	for i in VARIANT_VALS.size():
		if VARIANT_VALS[i] == variant:
			return i
	return -1


static func _class_idx_from_color(cv: int) -> int:
	var cls := "Beast"
	if cv <= 5:
		cls = "Beast"
	elif cv <= 10:
		cls = "Plant"
	elif cv <= 16:
		cls = "Aquatic"
	elif cv <= 21:
		cls = "Bug"
	elif cv <= 26:
		cls = "Bird"
	elif cv <= 32:
		cls = "Reptile"
	var idx := CLASS_NAMES.find(cls)
	return idx if idx >= 0 else 1


static func _is_axie_id(s: String) -> bool:
	if s.is_empty() or s.length() > 12:
		return false
	for c in s:
		if c < "0" or c > "9":
			return false
	return true


static func _looks_like_genes(s: String) -> bool:
	if s.is_empty():
		return false
	var hex := s
	if hex.begins_with("0x") or hex.begins_with("0X"):
		hex = hex.substr(2)
	if hex.length() < 40:
		return false
	for c in hex:
		var ok := (c >= "0" and c <= "9") or (c >= "a" and c <= "f") or (c >= "A" and c <= "F")
		if not ok:
			return false
	return true


func _gene_query_body(id: String) -> String:
	return JSON.stringify({"query": "{ axie (axieId: \"%s\") { id, genes, newGenes } }" % id})


func _fetch_genes_by_id(id: String) -> void:
	if _fetching:
		return
	_fetching = true
	_last_fetch_id = id
	_fetch_label.text = "Fetching Axie #%s…" % id
	var headers := PackedStringArray(["Content-Type: application/json"])
	var err := _http.request(GRAPHQL_URL, headers, HTTPClient.METHOD_POST, _gene_query_body(id))
	if err != OK:
		_fetching = false
		_fetch_label.text = "Fetch failed to start (%s)." % err


func _on_fetch_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if response_code == 403 and _fetch_via_curl(_last_fetch_id):
		# Cloudflare's bot check rejects Godot's built-in HTTP client (its TLS fingerprint), whatever
		# headers it sends; Unity's UnityWebRequest and curl pass. On desktop retry through curl.
		return
	_fetching = false
	if response_code == 403:
		_fetch_label.text = "Fetch blocked (HTTP 403, Cloudflare) and curl is unavailable. Paste the genes instead — e.g. curl -X POST %s -H 'Content-Type: application/json' -d '{\"query\":\"{ axie(axieId: \\\"%s\\\") { newGenes } }\"}'" % [GRAPHQL_URL, _last_fetch_id]
		return
	if response_code != 200:
		_fetch_label.text = "Fetch failed: HTTP %s" % response_code
		return
	_apply_fetch_body(body.get_string_from_utf8())


## Desktop fallback: run the same query through the system curl on a worker thread.
func _fetch_via_curl(id: String) -> bool:
	if not (OS.has_feature("windows") or OS.has_feature("macos") or OS.has_feature("linux")):
		return false
	if _curl_thread != null:
		return true
	_fetch_label.text = "Fetching Axie #%s (via curl)…" % id
	# GET with the query URL-encoded: OS.execute mangles quotes/spaces inside arguments on some
	# platforms, so no argument may contain either. The preflight header satisfies Apollo's CSRF check.
	var query := "{ axie (axieId: \"%s\") { id, genes, newGenes } }" % id
	var args := PackedStringArray([
		"-s", "-S", "-m", "20", "-H", "Apollo-Require-Preflight:true",
		GRAPHQL_URL + "?query=" + query.uri_encode(),
	])
	_curl_thread = Thread.new()
	var err := _curl_thread.start(func() -> void:
		var out: Array = []
		var code := OS.execute("curl", args, out, true)
		_on_curl_completed.call_deferred(code, str(out[0]) if not out.is_empty() else "")
	)
	if err != OK:
		_curl_thread = null
		return false
	return true


func _on_curl_completed(exit_code: int, output: String) -> void:
	if _curl_thread != null:
		_curl_thread.wait_to_finish()
		_curl_thread = null
	_fetching = false
	if exit_code != 0:
		_fetch_label.text = "Fetch failed (curl exit %d): %s" % [exit_code, output.strip_edges().left(160)]
		return
	_apply_fetch_body(output)


func _apply_fetch_body(text: String) -> void:
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_fetch_label.text = "Fetch failed: invalid JSON."
		return
	var axie: Variant = (parsed as Dictionary).get("data", {}).get("axie", null)
	if typeof(axie) != TYPE_DICTIONARY:
		_fetch_label.text = "Axie not found."
		return
	var genes := str((axie as Dictionary).get("newGenes", (axie as Dictionary).get("genes", "")))
	if genes.is_empty():
		_fetch_label.text = "Axie has no genes."
		return
	_fetch_label.text = "Loaded Axie #%s." % str((axie as Dictionary).get("id", ""))
	_suppress_genes = true
	_genes_edit.text = genes
	_suppress_genes = false
	_apply_genes(genes)


func _build_descriptor() -> AxieDescriptor:
	var d := AxieDescriptor.new()
	d.body = _ui_body_idx
	d.color_variant = _ui_color_variant
	d.clear_parts()
	for i in AxieTypes.PART_NAMES.size():
		d.parts.append(
			AxiePartDescriptor.new(
				i,
				_ui_part_skin[i],
				CLASS_NAMES[_ui_part_class[i]],
				VARIANT_VALS[_ui_part_variant[i]],
				_ui_part_level[i]
			)
		)
	return d


func _dispose_character() -> void:
	_playable = null
	if _character:
		_character.dispose()
	_character = null


func _rebuild() -> void:
	var params := AxieInstantiationParams.new()
	params.combine_meshes = _combine
	if _character != null:
		_character.instantiation_params = params
		if _gene_mode:
			_character.apply_genes(_applied_genes)
		else:
			_character.apply_descriptor(_build_descriptor())
		_after_spawn()
		return
	_dispose_character()
	if _gene_mode and not _applied_genes.is_empty():
		_character = AxieCharacter3D.from_genes(_applied_genes, params)
	else:
		_character = AxieCharacter3D.from_descriptor(_build_descriptor(), params)
	if _character == null or _character.root == null:
		_fetch_label.text = "Build failed — catalog not assigned or body missing."
		_update_status()
		return
	_character.root.name = "Example Axie"
	_anchor.add_child(_character.root)
	_after_spawn()


func _after_spawn() -> void:
	if _character == null or _character.root == null:
		_update_status()
		return
	_character.root.rotation_degrees.y = _yaw
	_playable = _character.playable
	if _playable:
		_playable.fade = 0.2
	_setup_default_blend()
	_apply_outline()
	_sync_genes_box()
	_update_status()


func _sync_genes_box() -> void:
	var genes := _applied_genes
	if not _gene_mode and _character and _character.descriptor:
		genes = _character.descriptor.to_genes()
	elif not _gene_mode:
		genes = _build_descriptor().to_genes()
	_applied_genes = genes
	_suppress_genes = true
	if _genes_edit:
		_genes_edit.text = genes
	_suppress_genes = false


func _setup_default_blend() -> void:
	if _playable == null:
		return
	var points: Array = [
		{"clip_name": AnimNames.Idle, "threshold": 0.0},
		{"clip_name": AnimNames.Walk, "threshold": 1.0},
		{"clip_name": AnimNames.Run, "threshold": 3.5},
	]
	var blend: AnimBlend = _playable.set_default_blend(points, _loco_speed)
	if blend == null:
		_playable.play(AnimNames.Idle, "", true)
		_current_clip = AnimNames.Idle
	else:
		_current_clip = "Idle→Walk→Run"
		_playable.set_speed(_loco_speed)


func _play_one_shot(clip_name: String) -> void:
	if _playable == null:
		return
	var track := _playable.play(clip_name, "", false)
	if track == null:
		push_warning("[mixer_demo] '%s' not available on this body." % clip_name)
		return
	_current_clip = clip_name
	_update_status()


func _play_skill_dead() -> void:
	if _playable == null:
		return
	var track := _playable.play(WeaponAnimNames.AttackCombo, "", false)
	if track:
		track.queue(AnimNames.Dead, "", false)
		_current_clip = "AttackCombo→Dead"
	_update_status()


func _apply_outline() -> void:
	if _character == null:
		return
	match _outline_mode:
		1:
			_character.set_outline_layer(OUTLINE_LAYER, BASE_LAYER)
			_set_post_process(false)
		2:
			_character.set_outline_layer(BASE_LAYER, BASE_LAYER)
			_set_post_process(true)
		_:
			_character.set_outline_layer(BASE_LAYER, BASE_LAYER)
			_set_post_process(false)


func _set_post_process(active: bool) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or not DemoKit.has_global_class("AxieOutlinePostProcess"):
		return
	if active:
		_outline_fx = AxieOutlinePostProcess.attach_to_camera(cam, _outline_fx)
		return
	if cam.compositor == null:
		return
	var kept: Array[CompositorEffect] = []
	for e in cam.compositor.compositor_effects:
		if e != _outline_fx:
			kept.append(e)
	cam.compositor.compositor_effects = kept
	_outline_fx = null


func _update_status() -> void:
	if _status_label == null:
		return
	var outline_names := PackedStringArray(["None", "DrawObjects", "PostProcess"])
	_status_label.text = "body=%s  color=%s  combine=%s  outline=%s  clip=%s" % [
		AxieTypes.body_name(_ui_body_idx),
		_ui_color_variant,
		"on" if _combine else "off",
		outline_names[_outline_mode],
		_current_clip,
	]


func _pointer_over_hud() -> bool:
	var pos := get_viewport().get_mouse_position()
	for panel in [_left_panel, _right_panel]:
		if panel and panel.get_global_rect().has_point(pos):
			return true
	return false
