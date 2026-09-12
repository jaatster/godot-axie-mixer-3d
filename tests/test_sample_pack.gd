extends SceneTree
## Pinned 10-axie sample pack: IDs, skip #1, from_genes matches oracle.
## Headless: godot --headless --path . -s tests/test_sample_pack.gd

const PACK := "res://tests/goldens/sample_axies.json"
const REQUIRED: PackedStringArray = [
	"123", "922", "4154", "1000", "1", "42", "256", "777", "2048", "3333"
]


func _init() -> void:
	var errs: Array = run()
	if errs.is_empty():
		print("ok  sample_pack")
		quit(0)
	else:
		for e in errs:
			print("FAIL sample_pack: %s" % e)
		quit(1)


static func run() -> Array:
	var errs: Array = []
	if not FileAccess.file_exists(PACK):
		errs.append("missing %s" % PACK)
		return errs
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PACK))
	if typeof(parsed) != TYPE_DICTIONARY:
		errs.append("pack not a dict")
		return errs
	var pack: Dictionary = parsed
	var ids: Array = pack.get("ids", [])
	if ids.size() != 10:
		errs.append("ids size %s expected 10" % ids.size())
	if int(pack.get("spawn_min", 0)) != 9:
		errs.append("spawn_min %s expected 9" % pack.get("spawn_min"))
	var required: Array = pack.get("required", [])
	if required.size() != 10:
		errs.append("required size %s expected 10" % required.size())
	for want in REQUIRED:
		if required.find(want) < 0:
			errs.append("required missing %s" % want)
	var seen := {}
	var spawnable := 0
	for row in ids:
		if typeof(row) != TYPE_DICTIONARY:
			errs.append("row not a dict")
			continue
		var id := str(row.get("id", ""))
		if seen.has(id):
			errs.append("duplicate id %s" % id)
		seen[id] = true
		var genes := str(row.get("genes", ""))
		if bool(row.get("skip", false)) or genes.length() < 40:
			if id != "1":
				errs.append("%s skipped but is not #1" % id)
			if not bool(row.get("skip", false)):
				errs.append("%s short genes without skip" % id)
			continue
		spawnable += 1
		if int(row.get("len", 0)) != genes.length():
			errs.append("%s len %s != genes.length %s" % [id, row.get("len"), genes.length()])
		var desc := AxieDescriptor.from_genes(genes)
		if AxieTypes.body_name(desc.body) != str(row.get("body", "")):
			errs.append("%s body %s expected %s" % [id, AxieTypes.body_name(desc.body), row.get("body")])
		if desc.color_variant != int(row.get("color", -1)):
			errs.append("%s color %s expected %s" % [id, desc.color_variant, row.get("color")])
		var want_parts: Array = row.get("parts", [])
		if want_parts.size() != 6 or desc.parts.size() != 6:
			errs.append("%s parts want=%s got=%s" % [id, want_parts.size(), desc.parts.size()])
			continue
		for i in 6:
			var p = desc.parts[i]
			var w: Dictionary = want_parts[i]
			if AxieTypes.part_name(p.type) != str(w.get("type", "")):
				errs.append("%s part type %s expected %s" % [id, AxieTypes.part_name(p.type), w.get("type")])
			if p.part_class != str(w.get("class", "")):
				errs.append("%s %s class %s expected %s" % [id, w.get("type"), p.part_class, w.get("class")])
			if p.variant != int(w.get("variant", -1)) or p.skin != int(w.get("skin", -1)) or p.level != int(w.get("level", -1)):
				errs.append("%s %s genes mismatch %s" % [id, w.get("type"), p.to_dict()])
			var resolved := AxiePartResolver.part_name(
				p.part_class, p.variant, p.skin, p.level, p.type
			)
			if resolved != str(w.get("resolved", "")):
				errs.append("%s %s resolved %s expected %s" % [id, w.get("type"), resolved, w.get("resolved")])
	for want in REQUIRED:
		if not seen.has(want):
			errs.append("pack missing id %s" % want)
	if spawnable != 9:
		errs.append("spawnable %s expected 9" % spawnable)
	var demo := FileAccess.get_file_as_string("res://examples/demo_kit.gd")
	if not demo.contains("sample_axies.json") and not demo.contains("SAMPLE_GENES"):
		errs.append("examples do not pin the sample pack genes")
	return errs
