class_name AxieTypes
extends Object

enum Body {
	NORMAL,
	SPIKY,
	FUZZY,
	CURLY,
	SUMO,
	WETDOG,
	BIGYAK,
	FROSTY,
}

enum Part {
	BACK,
	EAR,
	EYE,
	HORN,
	MOUTH,
	TAIL,
}

enum Rig {
	BACK_L,
	BACK_M,
	BACK_R,
	EAR_L,
	EAR_R,
	EYE_L,
	EYE_M,
	EYE_R,
	EYE_ACCESSORY_L,
	EYE_ACCESSORY_R,
	HORN_L,
	HORN_M,
	HORN_R,
	HORN_T,
	MOUTH_M,
	MOUTH_ACCESSORY_L,
	MOUTH_ACCESSORY_R,
	TAIL_L,
	TAIL_M,
	TAIL_R,
}

enum OutlineMode {
	NONE,
	DRAW_OBJECTS,
	POST_PROCESS,
}

const BODY_NAMES: PackedStringArray = [
	"Normal", "Spiky", "Fuzzy", "Curly", "Sumo", "Wetdog", "Bigyak", "Frosty"
]

const PART_NAMES: PackedStringArray = [
	"Back", "Ear", "Eye", "Horn", "Mouth", "Tail"
]

const GENES_PART_ORDER: PackedStringArray = [
	"Eye", "Mouth", "Ear", "Horn", "Back", "Tail"
]

const RIG_NAMES: PackedStringArray = [
	"Back_L", "Back_M", "Back_R",
	"Ear_L", "Ear_R",
	"Eye_L", "Eye_M", "Eye_R", "Eye_Accessory_L", "Eye_Accessory_R",
	"Horn_L", "Horn_M", "Horn_R", "Horn_T",
	"Mouth_M", "Mouth_Accessory_L", "Mouth_Accessory_R",
	"Tail_L", "Tail_M", "Tail_R",
]

const CLASS_NAMES: PackedStringArray = [
	"Beast", "Bug", "Bird", "Plant", "Aquatic", "Reptile", "Mech", "Dawn", "Dusk"
]


static func body_name(body: int) -> String:
	if body < 0 or body >= BODY_NAMES.size():
		return "Normal"
	return BODY_NAMES[body]


static func body_from_name(n: String) -> int:
	var i := BODY_NAMES.find(n)
	return i if i >= 0 else Body.NORMAL


static func part_name(part: int) -> String:
	if part < 0 or part >= PART_NAMES.size():
		return "Back"
	return PART_NAMES[part]


static func part_from_name(n: String) -> int:
	var i := PART_NAMES.find(n)
	return i if i >= 0 else Part.BACK


static func genes_part_from_name(n: String) -> int:
	# Genes layout uses Eye, Mouth, Ear, Horn, Back, Tail — not PART enum order.
	match n:
		"Eye":
			return Part.EYE
		"Mouth":
			return Part.MOUTH
		"Ear":
			return Part.EAR
		"Horn":
			return Part.HORN
		"Back":
			return Part.BACK
		"Tail":
			return Part.TAIL
		_:
			return Part.BACK


static func rig_name(rig: int) -> String:
	if rig < 0 or rig >= RIG_NAMES.size():
		return ""
	return RIG_NAMES[rig]


static func rig_from_name(n: String) -> int:
	return RIG_NAMES.find(n)


static func rig_to_part(rig: int) -> int:
	match rig:
		Rig.BACK_L, Rig.BACK_M, Rig.BACK_R:
			return Part.BACK
		Rig.EAR_L, Rig.EAR_R:
			return Part.EAR
		Rig.EYE_L, Rig.EYE_M, Rig.EYE_R, Rig.EYE_ACCESSORY_L, Rig.EYE_ACCESSORY_R:
			return Part.EYE
		Rig.HORN_L, Rig.HORN_M, Rig.HORN_R, Rig.HORN_T:
			return Part.HORN
		Rig.MOUTH_M, Rig.MOUTH_ACCESSORY_L, Rig.MOUTH_ACCESSORY_R:
			return Part.MOUTH
		Rig.TAIL_L, Rig.TAIL_M, Rig.TAIL_R:
			return Part.TAIL
		_:
			push_error("Unknown AxieRigType: %s" % rig)
			return Part.BACK


static func class_to_number(axie_class: String) -> int:
	match axie_class:
		"Beast":
			return 0
		"Bug":
			return 1
		"Bird":
			return 2
		"Plant":
			return 3
		"Aquatic":
			return 4
		"Reptile":
			return 5
		"Mech":
			return 16
		"Dawn":
			return 17
		"Dusk":
			return 18
		_:
			return 0


static func class_from_number(n: int) -> String:
	match n:
		0:
			return "Beast"
		1:
			return "Bug"
		2:
			return "Bird"
		3:
			return "Plant"
		4:
			return "Aquatic"
		5:
			return "Reptile"
		16:
			return "Mech"
		17:
			return "Dawn"
		18:
			return "Dusk"
		_:
			return ""
