class_name AxieDefaults
extends Object
## Process-wide mixer defaults. Broken out so Factory and Character3D do not cyclic-import.

const OUTLINE_EXCLUDED_PART_TYPES: Array[int] = [
	AxieTypes.Part.EYE,
	AxieTypes.Part.MOUTH,
]

static var outline_layer: int = -1
static var outline_base_layer: int = 1
static var combine_meshes: bool = true
static var factory: RefCounted # AxieFactory, untyped to avoid class cycles at parse time
