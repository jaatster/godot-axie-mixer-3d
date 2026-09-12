class_name AxieRigType
extends Object
## Unity `AxieRigType` + `AxieRigTypeExtensions.ToAxiePartType`.

const Back_L := AxieTypes.Rig.BACK_L
const Back_M := AxieTypes.Rig.BACK_M
const Back_R := AxieTypes.Rig.BACK_R
const Ear_L := AxieTypes.Rig.EAR_L
const Ear_R := AxieTypes.Rig.EAR_R
const Eye_L := AxieTypes.Rig.EYE_L
const Eye_M := AxieTypes.Rig.EYE_M
const Eye_R := AxieTypes.Rig.EYE_R
const Eye_Accessory_L := AxieTypes.Rig.EYE_ACCESSORY_L
const Eye_Accessory_R := AxieTypes.Rig.EYE_ACCESSORY_R
const Horn_L := AxieTypes.Rig.HORN_L
const Horn_M := AxieTypes.Rig.HORN_M
const Horn_R := AxieTypes.Rig.HORN_R
const Horn_T := AxieTypes.Rig.HORN_T
const Mouth_M := AxieTypes.Rig.MOUTH_M
const Mouth_Accessory_L := AxieTypes.Rig.MOUTH_ACCESSORY_L
const Mouth_Accessory_R := AxieTypes.Rig.MOUTH_ACCESSORY_R
const Tail_L := AxieTypes.Rig.TAIL_L
const Tail_M := AxieTypes.Rig.TAIL_M
const Tail_R := AxieTypes.Rig.TAIL_R

const BACK_L := Back_L
const BACK_M := Back_M
const BACK_R := Back_R
const EAR_L := Ear_L
const EAR_R := Ear_R
const EYE_L := Eye_L
const EYE_M := Eye_M
const EYE_R := Eye_R
const EYE_ACCESSORY_L := Eye_Accessory_L
const EYE_ACCESSORY_R := Eye_Accessory_R
const HORN_L := Horn_L
const HORN_M := Horn_M
const HORN_R := Horn_R
const HORN_T := Horn_T
const MOUTH_M := Mouth_M
const MOUTH_ACCESSORY_L := Mouth_Accessory_L
const MOUTH_ACCESSORY_R := Mouth_Accessory_R
const TAIL_L := Tail_L
const TAIL_M := Tail_M
const TAIL_R := Tail_R


static func to_axie_part_type(rig: int) -> int:
	return AxieTypes.rig_to_part(rig)
