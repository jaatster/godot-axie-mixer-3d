class_name AxieInstantiationParams
extends RefCounted

var combine_meshes: bool = true
## Array of {type: int (AxieTypes.Part), layer: int}
var part_layer_overrides: Array[Dictionary] = []


func merge(other: AxieInstantiationParams) -> AxieInstantiationParams:
	if other == null:
		return self
	var merged := AxieInstantiationParams.new()
	merged.combine_meshes = other.combine_meshes
	var overrides: Array[Dictionary] = []
	for o in part_layer_overrides:
		overrides.append(o.duplicate())
	for o in other.part_layer_overrides:
		var found := -1
		for i in overrides.size():
			if int(overrides[i].get("type", -1)) == int(o.get("type", -1)):
				found = i
				break
		if found >= 0:
			overrides[found] = o.duplicate()
		else:
			overrides.append(o.duplicate())
	merged.part_layer_overrides = overrides
	return merged


func find_layer_override(part_type: int) -> int:
	for o in part_layer_overrides:
		if int(o.get("type", -1)) == part_type:
			return int(o.get("layer", -1))
	return -1
