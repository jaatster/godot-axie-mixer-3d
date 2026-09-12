extends Object
## Unity `AxieMixerExampleOptions` — valid class/variant/body/color tables for samples.


const ALL_CLASSES: PackedStringArray = ["Beast", "Bug", "Bird", "Plant", "Aquatic", "Reptile"]
const ALL_VARIANTS: PackedInt32Array = [2, 4, 6, 8, 10, 12]


static func all_bodies() -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(AxieTypes.BODY_NAMES.size())
	for i in out.size():
		out[i] = i
	return out


static func color_variants_for(axie_class: String) -> PackedInt32Array:
	match axie_class:
		"Beast":
			return PackedInt32Array([0, 1, 2, 3, 4, 5])
		"Bug":
			return PackedInt32Array([17, 18, 19, 20, 21])
		"Bird":
			return PackedInt32Array([22, 23, 24, 25, 26])
		"Plant":
			return PackedInt32Array([6, 7, 8, 9, 10])
		"Aquatic":
			return PackedInt32Array([11, 12, 13, 14, 15, 16])
		"Reptile":
			return PackedInt32Array([27, 28, 29, 30, 31, 32])
		_:
			return PackedInt32Array([0, 1, 2, 3, 4])


## Unity AxieCombinationsDebug: when skin != 0, omit parts `HasPart` says are unshipped.
## Pass factory=null to include every slot (S00 browsing, or no catalog yet).
static func combo_descriptor(
	factory,
	body: int,
	axie_class: String,
	variant: int,
	skin: int,
	level: int,
	color_variant: int
) -> AxieDescriptor:
	var d := AxieDescriptor.new()
	d.body = body
	d.color_variant = color_variant
	d.clear_parts()
	for pi in AxieTypes.PART_NAMES.size():
		if factory != null and not factory.has_part(axie_class, variant, skin, level, pi):
			continue
		d.parts.append(AxiePartDescriptor.new(pi, skin, axie_class, variant, level))
	return d


static func fixture_descriptor() -> AxieDescriptor:
	var d := AxieDescriptor.new()
	d.body = AxieTypes.Body.NORMAL
	d.color_variant = 3
	d.clear_parts()
	for t in [
		AxieTypes.Part.EYE, AxieTypes.Part.MOUTH, AxieTypes.Part.EAR,
		AxieTypes.Part.HORN, AxieTypes.Part.BACK, AxieTypes.Part.TAIL,
	]:
		d.parts.append(AxiePartDescriptor.new(t, 0, "Beast", 2, 1))
	return d


static func random_descriptor(rng: RandomNumberGenerator) -> AxieDescriptor:
	var axie_class := ALL_CLASSES[rng.randi_range(0, ALL_CLASSES.size() - 1)]
	var variant := int(ALL_VARIANTS[rng.randi_range(0, ALL_VARIANTS.size() - 1)])
	var bodies := all_bodies()
	var body := int(bodies[rng.randi_range(0, bodies.size() - 1)])
	var colors := color_variants_for(axie_class)
	var color := 48 if body == AxieTypes.Body.FROSTY else int(colors[rng.randi_range(0, colors.size() - 1)])
	var d := AxieDescriptor.new()
	d.body = body
	d.color_variant = color
	d.clear_parts()
	for t in AxieTypes.PART_NAMES.size():
		d.parts.append(AxiePartDescriptor.new(t, 0, axie_class, variant, 1))
	return d
