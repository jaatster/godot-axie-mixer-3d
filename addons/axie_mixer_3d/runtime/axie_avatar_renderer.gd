class_name AxieAvatarRenderer
extends RefCounted
## Orthographic off-screen snapshot of an assembled Axie (Unity `AxieAvatarRenderer`).
##
## Unity records a CommandBuffer that draws only the character's skinned renderers with a view
## matrix built from the character root (rotated to `modelHeading`) and `Ortho(-1, 1, -aspect,
## aspect, -2, 2)`, cleared to transparent, and executes it synchronously into the caller's
## RenderTexture. Godot renders asynchronously, so the analog is a SubViewport that shares the
## character's world and isolates it with a render-layer cull mask:
##   - the character is not moved, re-parented or hidden; only a reserved render-layer bit
##     (`AVATAR_LAYER`) is OR-ed into its mesh instances, which the main camera also sees;
##   - the camera sits in the character's local frame (Unity's view matrix is
##     `inverse(root.localToWorld * LookAt(viewCenter, viewDirection))`), so `view_center` /
##     `view_direction` frame the model identically;
##   - the scene's `DirectionalLight3D` lights it as Unity's main light does. Unity temporarily
##     sets the root's world yaw to `model_heading` while drawing, which only changes where the
##     shadow band falls; Godot draws asynchronously and does not touch the character, so the
##     band follows the character's actual world yaw instead (framing is unaffected either way);
##   - outline hulls and particles are excluded, like Unity's skinned-renderer-only draw.
## Call `render`, wait for `RenderingServer.frame_post_draw` (or a process frame), then read
## `get_texture()` / `capture_image()`.

## Godot render layer (1-indexed) reserved for avatar isolation. It is the last layer the default
## camera cull mask includes, so adding it never changes what other cameras see.
const AVATAR_LAYER := 20
const HULL_NAME := "AxieOutlineHull"
## Unity `Matrix4x4.Ortho(-1, 1, -aspect, aspect, -2, 2)`: 2 units in front of and behind the
## focal plane at `view_center`.
const _DEPTH_HALF := 2.0

var _character: AxieCharacter3D
var _viewport: SubViewport
var _camera: Camera3D
var _host: Node
var _cached_root: Node


func _init(character: AxieCharacter3D) -> void:
	if character == null:
		push_error("AxieAvatarRenderer: character is required")
	_character = character


## Unity `Render(RenderTexture, AxieAvatarRenderParams)`. `target` is accepted for API parity;
## the image is produced on the returned viewport texture (`get_texture()`) at the next draw.
func render(target: Texture2D, params: AxieAvatarRenderParams = null) -> Texture2D:
	if _character == null or _character.root == null or not is_instance_valid(_character.root):
		return target
	if params == null:
		params = AxieAvatarRenderParams.new()
	if params.width == 0:
		push_error("AxieAvatarRenderer: Render width cannot be zero!")
		return target
	if params.height == 0:
		push_error("AxieAvatarRenderer: Render height cannot be zero!")
		return target
	var root := _character.root
	var tree := root.get_tree()
	if tree == null:
		push_error("AxieAvatarRenderer: character.root must be in the scene tree")
		return target
	_ensure_viewport(params, tree)
	_tag_visuals(root, true)
	_place_camera(params)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	return _viewport.get_texture()


func get_texture() -> Texture2D:
	if _viewport == null or not is_instance_valid(_viewport):
		return null
	return _viewport.get_texture()


func capture_image() -> Image:
	var tex := get_texture()
	return tex.get_image() if tex != null else null


func dispose() -> void:
	if _cached_root != null and is_instance_valid(_cached_root):
		_tag_visuals(_cached_root, false)
	if _host != null and is_instance_valid(_host):
		_host.queue_free()
	_host = null
	_viewport = null
	_camera = null
	_cached_root = null


static func _mask() -> int:
	return 1 << (AVATAR_LAYER - 1)


func _ensure_viewport(params: AxieAvatarRenderParams, tree: SceneTree) -> void:
	var size := Vector2i(maxi(params.width, 1), maxi(params.height, 1))
	if _viewport != null and is_instance_valid(_viewport):
		if _cached_root != _character.root and _cached_root != null and is_instance_valid(_cached_root):
			_tag_visuals(_cached_root, false)
		_cached_root = _character.root
		_viewport.size = size
		return
	_host = Node.new()
	_host.name = "AxieAvatarRendererHost"
	tree.root.add_child(_host)
	_viewport = SubViewport.new()
	_viewport.size = size
	_viewport.transparent_bg = true # Unity ClearRenderTarget(Color.clear)
	_viewport.own_world_3d = false # share the character's world (meshes, skeleton, main light)
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	_viewport.positional_shadow_atlas_size = 0
	_host.add_child(_viewport)
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_camera.cull_mask = _mask()
	_camera.current = true
	_viewport.add_child(_camera)
	_cached_root = _character.root


## Unity view = inverse(root.localToWorld * LookAt(viewCenter, viewCenter + viewDirection, up)),
## projection Ortho(-1, 1, -aspect, aspect, -2, 2): an orthographic camera in the model's local
## frame whose depth slab is centred on `view_center`.
func _place_camera(params: AxieAvatarRenderParams) -> void:
	var root := _character.root
	var aspect := float(params.height) / float(params.width)
	_camera.size = 2.0 * aspect # Godot `size` is the full vertical extent; Unity half-extent is `aspect`
	_camera.near = 0.001
	_camera.far = _DEPTH_HALF * 2.0
	var dir := params.view_direction
	if dir.length_squared() < 1e-12:
		dir = Vector3(1, -1, -1)
	dir = dir.normalized()
	var frame := root.global_transform
	var eye := frame * (params.view_center - dir * _DEPTH_HALF)
	var look := frame * params.view_center
	var world_dir := (look - eye).normalized()
	var up := Vector3.UP if absf(world_dir.dot(Vector3.UP)) < 0.999 else Vector3.FORWARD
	_camera.look_at_from_position(eye, look, up)


## OR the avatar layer into every mesh Unity would draw (skinned renderers); keep hulls and
## particles out of the avatar camera's cull mask.
static func _tag_visuals(root: Node, on: bool) -> void:
	var mask := _mask()
	for n in root.find_children("*", "VisualInstance3D", true, false):
		var vi := n as VisualInstance3D
		var draw := on and vi is MeshInstance3D and vi.name != HULL_NAME
		vi.layers = (vi.layers | mask) if draw else (vi.layers & ~mask)
	if root is VisualInstance3D:
		var rv := root as VisualInstance3D
		rv.layers = (rv.layers | mask) if on else (rv.layers & ~mask)
