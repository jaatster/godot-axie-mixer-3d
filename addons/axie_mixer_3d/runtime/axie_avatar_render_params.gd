class_name AxieAvatarRenderParams
extends RefCounted
## Unity `AxieAvatarRenderParams`. Vectors are in Godot (right-handed) model space: Unity's default
## `viewDirection = (-1, -1, -1)` becomes `(1, -1, -1)` after the pack's X mirror, so the default
## image matches Unity's default avatar.

## Output width in pixels (Unity `width`, default 128).
var width: int = 128
## Output height in pixels (Unity `height`, default 128).
var height: int = 128
## Unity `modelHeading` (180): world yaw Unity gives the model while drawing. The view is in model
## space, so it never changes the framing; in Unity it only moves the shadow band. Kept for API
## parity; the Godot renderer lights the character at its actual world yaw (see AxieAvatarRenderer).
var model_heading: float = 180.0
## Focal point in model space (Unity `viewCenter`).
var view_center: Vector3 = Vector3(0, 0.75, 0)
## Viewing direction in model space (Unity `viewDirection = (-1, -1, -1)`, mirrored).
var view_direction: Vector3 = Vector3(1, -1, -1)
