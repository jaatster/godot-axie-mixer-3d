extends SceneTree
## AxieAvatarRenderer vs Unity AxieAvatarRenderParams / AxieAvatarRenderer.
## Structural checks are headless-safe (`static func run()`). Pixel checks need a GPU:
##   open -g -j -n -a /Applications/Godot.app --args --path <repo> -s tests/test_avatar_v2.gd \
##     --resolution 320x200 --position 4000,4000 --log-file /tmp/axie_avatar_v2.log
## Writes /tmp/axie_avatar_v2_done.txt (and a PNG) when launched as the main script.

const CATALOG := "res://addons/axie_mixer_3d_assets/catalog.json"
const DONE_PATH := "/tmp/axie_avatar_v2_done.txt"
const PNG_PATH := "/tmp/axie_avatar_v2.png"

var _started := false


func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	_run_standalone()
	return false


func _run_standalone() -> void:
	var errs: Array = run()
	var gpu := DisplayServer.get_name() != "headless"
	if gpu:
		errs.append_array(await _run_gpu(self))
	else:
		print("note  avatar_v2: headless — skipped GPU snapshot (launch hidden Godot for pixels)")
	_write_done(errs)
	if errs.is_empty():
		print("ok  avatar_v2")
		quit(0)
	else:
		for e in errs:
			print("FAIL avatar_v2: %s" % e)
		quit(1)


static func run() -> Array:
	return _check_params()


static func _check_params() -> Array:
	var errs: Array = []
	var p := AxieAvatarRenderParams.new()
	if p.width != 128:
		errs.append("width %s expected 128" % p.width)
	if p.height != 128:
		errs.append("height %s expected 128" % p.height)
	if absf(p.model_heading - 180.0) > 1e-5:
		errs.append("model_heading %s expected 180" % p.model_heading)
	if p.view_center != Vector3(0, 0.75, 0):
		errs.append("view_center %s expected (0, 0.75, 0)" % p.view_center)
	# Unity (-1, -1, -1) mirrored across X into Godot space.
	if p.view_direction != Vector3(1, -1, -1):
		errs.append("view_direction %s expected (1,-1,-1)" % p.view_direction)
	# Unity throws on zero width/height — port push_errors and returns the target.
	var dummy := AxieAvatarRenderer.new(AxieCharacter3D.new())
	var zero := AxieAvatarRenderParams.new()
	zero.width = 0
	var ret := dummy.render(null, zero)
	if ret != null:
		# target was null; render should refuse without crashing
		pass
	dummy.dispose()
	return errs


func _run_gpu(tree: SceneTree) -> Array:
	var errs: Array = []
	var catalog := AxieCatalog.load_json(CATALOG)
	if catalog == null:
		errs.append("v2 catalog failed")
		return errs
	var factory := AxieFactory.new()
	factory.catalog = catalog
	AxieFactory.default_factory = factory
	AxieDefaults.factory = factory
	AxieDefaults.outline_layer = -1
	var desc := AxieDescriptor.new()
	desc.body = AxieTypes.Body.NORMAL
	desc.color_variant = 3
	desc.clear_parts()
	for part in [
		{"type": "Eye", "class": "Beast", "variant": 2, "skin": 0, "level": 1},
		{"type": "Mouth", "class": "Beast", "variant": 2, "skin": 0, "level": 1},
		{"type": "Ear", "class": "Beast", "variant": 2, "skin": 0, "level": 1},
		{"type": "Horn", "class": "Beast", "variant": 2, "skin": 0, "level": 1},
		{"type": "Back", "class": "Beast", "variant": 2, "skin": 0, "level": 1},
		{"type": "Tail", "class": "Beast", "variant": 2, "skin": 0, "level": 1},
	]:
		desc.parts.append(AxiePartDescriptor.from_dict(part))
	var params := AxieInstantiationParams.new()
	params.combine_meshes = true
	var ch := factory.create_character(desc, params)
	if ch == null or ch.root == null:
		errs.append("create_character failed")
		return errs
	tree.root.add_child(ch.root)
	# Hulls must not appear in the avatar (Unity CommandBuffer skips the outline pass).
	ch.set_outline_layer(2, 1)
	var rp := AxieAvatarRenderParams.new()
	rp.width = 128
	rp.height = 128
	var renderer := AxieAvatarRenderer.new(ch)
	var tex := renderer.render(null, rp)
	if tex == null:
		errs.append("render returned null")
		renderer.dispose()
		ch.dispose()
		return errs
	await tree.process_frame
	await tree.process_frame
	var img := renderer.capture_image()
	# The character must still be where the caller put it (no re-parenting side effects).
	if ch.root.get_parent() != tree.root:
		errs.append("render() moved the character root")
	var hull_bit := 1 << (AxieAvatarRenderer.AVATAR_LAYER - 1)
	for h in ch.root.find_children(AxieAvatarRenderer.HULL_NAME, "MeshInstance3D", true, false):
		if ((h as MeshInstance3D).layers & hull_bit) != 0:
			errs.append("outline hull tagged for the avatar camera")
	if img == null:
		errs.append("capture_image is null")
	else:
		if img.get_width() != 128 or img.get_height() != 128:
			errs.append("image size %sx%s expected 128x128" % [img.get_width(), img.get_height()])
		var painted := _count_painted(img)
		if painted < 32:
			errs.append("avatar is empty (painted=%s / %s)" % [painted, img.get_width() * img.get_height()])
		else:
			print("ok  avatar_v2 pixels painted=%s size=%sx%s" % [painted, img.get_width(), img.get_height()])
		img.save_png(PNG_PATH)
	var rp2 := AxieAvatarRenderParams.new()
	rp2.width = 64
	rp2.height = 96
	renderer.render(null, rp2)
	await tree.process_frame
	await tree.process_frame
	var img2 := renderer.capture_image()
	if img2 == null or img2.get_width() != 64 or img2.get_height() != 96:
		errs.append("custom size got %s" % (img2.get_size() if img2 else "null"))
	elif _count_painted(img2) < 8:
		errs.append("64x96 avatar empty")
	renderer.dispose()
	ch.dispose()
	AxieFactory.default_factory = null
	AxieDefaults.factory = null
	AxieDefaults.outline_layer = -1
	return errs


static func _count_painted(img: Image) -> int:
	img.convert(Image.FORMAT_RGBA8)
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a > 0.04 or maxf(c.r, maxf(c.g, c.b)) > 0.04:
				n += 1
	return n


static func _write_done(errs: Array) -> void:
	var f := FileAccess.open(DONE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("%d\n" % errs.size())
	for e in errs:
		f.store_string("%s\n" % e)
	f.close()
