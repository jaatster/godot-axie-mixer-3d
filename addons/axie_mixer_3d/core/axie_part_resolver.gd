class_name AxiePartResolver
extends Object
## Unity AxieFactory.TryResolvePart / HasPart — pure, no assets required.


static func part_name(part_class: String, variant: int, skin: int, level: int, type: int) -> String:
	return "S%02d_%s%02d_L%d_%s" % [skin, part_class, variant, level, AxieTypes.part_name(type)]


## Returns {ok, name, skin, level}. Falls back S{skin} L1 → S00 L{level} → S00 L1.
static func resolve(part: AxiePartDescriptor, has_part: Callable) -> Dictionary:
	var skin: int = 0 if part.skin < 0 else part.skin
	var level: int = 1 if part.level < 1 else part.level
	var candidates: Array[Vector2i] = [
		Vector2i(skin, level),
		Vector2i(skin, 1),
		Vector2i(0, level),
		Vector2i(0, 1),
	]
	var seen := {}
	for c in candidates:
		var key := "%d:%d" % [c.x, c.y]
		if seen.has(key):
			continue
		seen[key] = true
		var n := part_name(part.part_class, part.variant, c.x, c.y, part.type)
		if has_part.call(n):
			return {"ok": true, "name": n, "skin": c.x, "level": c.y}
	return {
		"ok": false,
		"name": part_name(part.part_class, part.variant, skin, level, part.type),
		"skin": skin,
		"level": level,
	}


static func addon_name(part_class: String, variant: int, skin: int, level: int, rig_name: String) -> String:
	var part_type_name := AxieTypes.part_name(AxieTypes.rig_to_part(AxieTypes.rig_from_name(rig_name)))
	return "%s-%s-%02d-S%02d-LV%d/%s" % [part_class, part_type_name, variant, skin, level, rig_name]
