class_name AxieCatalog
extends Resource
## Runtime catalog for an Axie Mixer 3D asset pack (`catalog.json`, format 2, glTF-based).
##
## Unity's `AxieFactory` ScriptableObject holds bodies / parts / addons / colors; here the
## same tables come from the pack's JSON and the prefabs are `.glb` scenes. Scenes are loaded
## lazily and cached: the imported `PackedScene` when the pack lives in an imported project,
## otherwise parsed at runtime with `GLTFDocument` (works headless and from `user://`).

const PACK_FORMAT_VERSION := 2

@export var base_dir: String = ""
## Sample rate of the baked glTF clips (`catalog.json/animation_fps`). Godot's glTF importer re-bakes
## every TRS track at `GLTFState.bake_fps`, so it must match the pack or samples are dropped.
@export var animation_fps: int = 30
@export var format_version: int = 0
@export var package_version: String = ""
@export var colors: Array[Dictionary] = []
## body name -> {glb, animations[], materials[], attach_points[], weapon_anims_glb, weapon_animations[]}
@export var bodies: Dictionary = {}
## part name -> {rigs: [{type, glb, materials[], prefab_name}]}
@export var parts: Dictionary = {}
## addon name -> {materials: [{name, material}], prefabs: [json rel path]}
@export var addons: Dictionary = {}
@export var default_combine_meshes: bool = true
## texture id -> Unity importer settings (`textures.json`, see texture_info)
@export var textures: Dictionary = {}

var _scene_cache: Dictionary = {} ## abs path -> PackedScene
var _anim_cache: Dictionary = {} ## abs glb path -> {clip name (lower) -> Animation}
var _anim_names: Dictionary = {} ## abs glb path -> {clip name (lower) -> canonical name}


static func load_json(path: String) -> AxieCatalog:
	var cat := AxieCatalog.new()
	if path.is_empty() or not FileAccess.file_exists(path):
		push_error("AxieCatalog: catalog not found at %s" % path)
		return cat
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("AxieCatalog: invalid JSON at %s" % path)
		return cat
	var d: Dictionary = parsed
	cat.base_dir = path.get_base_dir()
	cat.format_version = int(d.get("format_version", 0))
	if cat.format_version != PACK_FORMAT_VERSION:
		push_error(
			"AxieCatalog: %s is pack format %d; this addon expects format %d. Re-export with tools/unity_export/AxieGltfExporter.cs."
			% [path, cat.format_version, PACK_FORMAT_VERSION]
		)
	cat.package_version = str(d.get("package_version", ""))
	cat.animation_fps = maxi(1, int(d.get("animation_fps", 30)))
	var tex_manifest := cat.base_dir.path_join("textures.json")
	if FileAccess.file_exists(tex_manifest):
		var tparsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(tex_manifest))
		if typeof(tparsed) == TYPE_DICTIONARY:
			cat.textures = tparsed
	for c in d.get("colors", []):
		if typeof(c) == TYPE_DICTIONARY:
			cat.colors.append(c)
	var body_rows: Variant = d.get("bodies", [])
	if body_rows is Array:
		for row in body_rows:
			if typeof(row) == TYPE_DICTIONARY:
				cat.bodies[str(row.get("type", ""))] = row
	elif body_rows is Dictionary:
		cat.bodies = body_rows
	var part_rows: Variant = d.get("parts", {})
	if part_rows is Dictionary:
		cat.parts = part_rows
	var addon_rows: Variant = d.get("addons", {})
	if addon_rows is Dictionary:
		cat.addons = addon_rows
	var dip: Variant = d.get("default_instantiation_params", {})
	if dip is Dictionary:
		cat.default_combine_meshes = bool(dip.get("combine_meshes", true))
	return cat


func color_for(index: int) -> Dictionary:
	for c in colors:
		if int(c.get("index", -1)) == index:
			return c
	return {}


func has_part(name: String) -> bool:
	return parts.has(name)


func body_entry(body: int) -> Dictionary:
	if body < 0 or body >= AxieTypes.BODY_NAMES.size():
		return {}
	return bodies.get(AxieTypes.body_name(body), {})


func abs_path(rel: String) -> String:
	if rel.is_empty():
		return ""
	if rel.begins_with("res://") or rel.begins_with("user://") or rel.is_absolute_path():
		return rel
	return base_dir.path_join(rel)


func material_json_path(material_id: String) -> String:
	if material_id.is_empty():
		return ""
	return base_dir.path_join("materials/%s.json" % material_id)


func texture_path(texture_id: String) -> String:
	if texture_id.is_empty():
		return ""
	var info := texture_info(texture_id)
	if info.has("file"):
		return base_dir.path_join(str(info["file"]))
	for ext in ["png", "jpg", "jpeg"]:
		var p := base_dir.path_join("textures/%s.%s" % [texture_id, ext])
		if FileAccess.file_exists(p) or ResourceLoader.exists(p):
			return p
	return ""


## Unity importer sampling settings for a texture id (`textures.json`): file, width, height,
## mipmaps (bool), filter ("Point"/"Bilinear"/"Trilinear"), wrap_u/wrap_v ("Repeat"/"Clamp"), srgb.
## Empty when the pack predates the manifest.
func texture_info(texture_id: String) -> Dictionary:
	var v: Variant = textures.get(texture_id, null)
	return v if v is Dictionary else {}


## Body clip names as exported (canonical spelling), for the given body index.
func body_animation_names(body: int) -> PackedStringArray:
	var out := PackedStringArray()
	var entry := body_entry(body)
	for n in entry.get("animations", []):
		out.append(str(n))
	return out


## Load (and cache) a pack scene by catalog-relative path.
func load_scene(rel: String) -> PackedScene:
	var path := abs_path(rel)
	if path.is_empty():
		return null
	if _scene_cache.has(path):
		return _scene_cache[path]
	# Always parse the glb at runtime. The pack directory carries a .gdignore so the editor never
	# imports it: the editor importer applies its own settings (track optimisation, mesh
	# compression) and would make editor and exported builds diverge from the verified path.
	var packed := _load_gltf_runtime(path, animation_fps)
	if packed == null:
		push_error("AxieCatalog: cannot load scene %s" % path)
		return null
	_scene_cache[path] = packed
	return packed


static func _load_gltf_runtime(path: String, bake_fps: int = 30) -> PackedScene:
	if not FileAccess.file_exists(path):
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	# Keep every baked channel: the playable fills missing tracks with rest, but a clip that
	# fully specifies its pose blends identically to Unity's PlayableGraph.
	var err := doc.append_from_file(path, state)
	if err != OK:
		push_error("AxieCatalog: glTF parse failed for %s (%s)" % [path, error_string(err)])
		return null
	var root := doc.generate_scene(state, float(bake_fps))
	if root == null:
		return null
	root.name = path.get_file().get_basename()
	_own_recursive(root, root)
	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		root.free()
		return null
	root.free()
	return packed


static func _own_recursive(n: Node, owner: Node) -> void:
	for c in n.get_children():
		c.owner = owner
		_own_recursive(c, owner)


## Animations baked into a glb, keyed by lower-case clip name.
func load_animations(rel: String) -> Dictionary:
	var path := abs_path(rel)
	if path.is_empty():
		return {}
	if _anim_cache.has(path):
		return _anim_cache[path]
	var out: Dictionary = {}
	var names: Dictionary = {}
	var packed := load_scene(rel)
	if packed != null:
		var inst := packed.instantiate()
		for ap in inst.find_children("*", "AnimationPlayer", true, false):
			var player := ap as AnimationPlayer
			for lib_name in player.get_animation_library_list():
				var lib := player.get_animation_library(lib_name)
				for anim_name in lib.get_animation_list():
					var anim := lib.get_animation(anim_name)
					var key := str(anim_name).to_lower()
					out[key] = anim
					names[key] = str(anim_name)
		inst.free()
	_anim_cache[path] = out
	_anim_names[path] = names
	return out


func find_body_animation(body: int, clip_name: String) -> Animation:
	var entry := body_entry(body)
	if entry.is_empty() or clip_name.is_empty():
		return null
	var anims := load_animations(str(entry.get("glb", "")))
	var key := clip_name.to_lower()
	if anims.has(key):
		return anims[key]
	return null


func clear_cache() -> void:
	_scene_cache.clear()
	_anim_cache.clear()
	_anim_names.clear()
