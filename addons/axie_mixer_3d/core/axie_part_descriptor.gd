class_name AxiePartDescriptor
extends RefCounted

var type: int = AxieTypes.Part.EYE
var skin: int = 0
var part_class: String = ""
var variant: int = 0
var level: int = 1


func _init(
	p_type: int = AxieTypes.Part.EYE,
	p_skin: int = 0,
	p_class: String = "",
	p_variant: int = 0,
	p_level: int = 1
) -> void:
	type = p_type
	skin = p_skin
	part_class = p_class
	variant = p_variant
	level = p_level


func duplicate_part() -> AxiePartDescriptor:
	return AxiePartDescriptor.new(type, skin, part_class, variant, level)


func to_dict() -> Dictionary:
	return {
		"type": AxieTypes.part_name(type),
		"skin": skin,
		"class": part_class,
		"variant": variant,
		"level": level,
	}


static func from_dict(d: Dictionary) -> AxiePartDescriptor:
	return AxiePartDescriptor.new(
		AxieTypes.part_from_name(str(d.get("type", "Eye"))),
		int(d.get("skin", 0)),
		str(d.get("class", "")),
		int(d.get("variant", 0)),
		int(d.get("level", 1))
	)
