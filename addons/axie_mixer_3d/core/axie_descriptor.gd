class_name AxieDescriptor
extends RefCounted
## Faithful port of Unity AxieDescriptor.FromGenes / ToGenes (C# int32 bit ops).

var color_variant: int = 0
var body: int = AxieTypes.Body.NORMAL
var parts: Array[AxiePartDescriptor] = []


func _init() -> void:
	parts.clear()


func clear_parts() -> void:
	parts.clear()


func duplicate_descriptor() -> AxieDescriptor:
	var d := AxieDescriptor.new()
	d.color_variant = color_variant
	d.body = body
	for p in parts:
		d.parts.append(p.duplicate_part())
	return d


func equals(other: AxieDescriptor) -> bool:
	if other == null:
		return false
	if color_variant != other.color_variant or body != other.body:
		return false
	if parts.size() != other.parts.size():
		return false
	for i in parts.size():
		var a := parts[i]
		var b := other.parts[i]
		if (
			a.type != b.type
			or a.skin != b.skin
			or a.part_class != b.part_class
			or a.variant != b.variant
			or a.level != b.level
		):
			return false
	return true


static func from_genes(genes: String) -> AxieDescriptor:
	var desc := AxieDescriptor.new()
	var bit_index := [0]
	var buf := _parse_genes(genes)

	var main_class := _pop_bits(buf, bit_index, 5)
	_pop_bits(buf, bit_index, 45)
	_pop_bits(buf, bit_index, 5)
	_pop_bits(buf, bit_index, 1)
	var body_skin := _pop_bits(buf, bit_index, 9)
	var body_detail0 := _pop_bits(buf, bit_index, 9)
	_pop_bits(buf, bit_index, 9)
	_pop_bits(buf, bit_index, 9)
	var primary_color0 := _pop_bits(buf, bit_index, 6)
	_pop_bits(buf, bit_index, 6)
	_pop_bits(buf, bit_index, 6)
	_pop_bits(buf, bit_index, 6)
	_pop_bits(buf, bit_index, 6)
	_pop_bits(buf, bit_index, 6)

	if body_skin == 1:
		desc.color_variant = 48
		desc.body = AxieTypes.Body.FROSTY
	else:
		desc.color_variant = _color_variant(AxieTypes.class_from_number(main_class), primary_color0)
		desc.body = _detail_to_body(body_detail0)

	for part_name in AxieTypes.GENES_PART_ORDER:
		_pop_bits(buf, bit_index, 12)
		var part_stage := _pop_bits(buf, bit_index, 3)
		_pop_bits(buf, bit_index, 1)
		var part_skin := _pop_bits(buf, bit_index, 9)
		var part_class0 := _pop_bits(buf, bit_index, 5)
		var part_value0 := _pop_bits(buf, bit_index, 8)
		_pop_bits(buf, bit_index, 5)
		_pop_bits(buf, bit_index, 8)
		_pop_bits(buf, bit_index, 5)
		_pop_bits(buf, bit_index, 8)
		desc.parts.append(
			AxiePartDescriptor.new(
				AxieTypes.genes_part_from_name(part_name),
				part_skin,
				AxieTypes.class_from_number(part_class0),
				part_value0,
				part_stage + 1
			)
		)
	return desc


func to_genes() -> String:
	var buf := PackedByteArray()
	buf.resize(64)
	var bit_index := [0]
	var frosty := body == AxieTypes.Body.FROSTY or color_variant == 48
	var main_class_num := 0
	var primary_color0 := 0
	if not frosty:
		var pair := _color_variant_to_class_color(color_variant)
		main_class_num = pair[0]
		primary_color0 = pair[1]
	var body_skin := 1 if frosty else 0
	var body_detail0 := 0 if frosty else _body_to_detail(body)

	_push_bits(buf, bit_index, main_class_num, 5)
	_push_bits(buf, bit_index, 0, 45)
	_push_bits(buf, bit_index, 0, 5)
	_push_bits(buf, bit_index, 0, 1)
	_push_bits(buf, bit_index, body_skin, 9)
	_push_bits(buf, bit_index, body_detail0, 9)
	_push_bits(buf, bit_index, 0, 9)
	_push_bits(buf, bit_index, 0, 9)
	_push_bits(buf, bit_index, primary_color0, 6)
	_push_bits(buf, bit_index, primary_color0, 6)
	_push_bits(buf, bit_index, primary_color0, 6)
	_push_bits(buf, bit_index, 0, 6)
	_push_bits(buf, bit_index, 0, 6)
	_push_bits(buf, bit_index, 0, 6)

	for part_name in AxieTypes.GENES_PART_ORDER:
		var want := AxieTypes.genes_part_from_name(part_name)
		var stage := 0
		var skin := 0
		var class_num := 0
		var value := 0
		for p in parts:
			if p.type != want:
				continue
			stage = clampi(p.level - 1, 0, 7)
			skin = p.skin & 0x1FF
			class_num = AxieTypes.class_to_number(p.part_class)
			value = p.variant & 0xFF
			break
		_push_bits(buf, bit_index, 0, 12)
		_push_bits(buf, bit_index, stage, 3)
		_push_bits(buf, bit_index, 0, 1)
		_push_bits(buf, bit_index, skin, 9)
		_push_bits(buf, bit_index, class_num, 5)
		_push_bits(buf, bit_index, value, 8)
		_push_bits(buf, bit_index, class_num, 5)
		_push_bits(buf, bit_index, value, 8)
		_push_bits(buf, bit_index, class_num, 5)
		_push_bits(buf, bit_index, value, 8)

	const HEX := "0123456789abcdef"
	var chars := PackedStringArray()
	chars.resize(128)
	for i in 128:
		var nibble := (buf[i / 2] >> (4 * (i % 2))) & 0xF
		chars[127 - i] = HEX[nibble]
	return "0x" + "".join(chars)


static func _parse_genes(genes: String) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(64)
	if genes.is_empty():
		return buf
	var hexstr := genes
	if hexstr.begins_with("0x") or hexstr.begins_with("0X"):
		hexstr = hexstr.substr(2)
	for i in hexstr.length():
		if i / 2 >= 64:
			break
		var ch := hexstr[hexstr.length() - 1 - i]
		var d := -1
		if ch >= "0" and ch <= "9":
			d = ch.unicode_at(0) - 48
		elif ch >= "a" and ch <= "f":
			d = ch.unicode_at(0) - 97 + 10
		elif ch >= "A" and ch <= "F":
			d = ch.unicode_at(0) - 65 + 10
		if d < 0:
			break
		var idx := i / 2
		buf[idx] = (buf[idx] + ((d << (4 * (i % 2))) & 0xFF)) & 0xFF
	return buf


static func _to_i32(x: int) -> int:
	x = x & 0xFFFFFFFF
	if x >= 0x80000000:
		return x - 0x100000000
	return x


static func _shl_i32(a: int, n: int) -> int:
	return _to_i32(_to_i32(a) << (n & 31))


static func _shr_i32(a: int, n: int) -> int:
	return _to_i32(a) >> (n & 31)


static func _not_i32(a: int) -> int:
	return _to_i32(~_to_i32(a))


static func _mask_bits(bit_count: int) -> int:
	return _not_i32(_shl_i32(-1, bit_count))


static func _pop_bits(buf: PackedByteArray, bit_index: Array, bit_count: int) -> int:
	var value := 0
	var byte_offset := int(bit_index[0]) / 8
	var bit_offset := int(bit_index[0]) % 8
	var byte_count := (bit_offset + bit_count + 7) / 8
	bit_index[0] = int(bit_index[0]) + bit_count
	for byte_index in byte_count:
		var src := byte_offset + byte_index
		if src < buf.size():
			var b := buf[buf.size() - 1 - src]
			value = _to_i32(value | _shl_i32(b, 8 * (byte_count - byte_index - 1)))
	var shift := 8 * byte_count - (bit_offset + bit_count)
	return _to_i32(_shr_i32(value, shift) & _mask_bits(bit_count))


static func _push_bits(buf: PackedByteArray, bit_index: Array, value: int, bit_count: int) -> void:
	var byte_offset := int(bit_index[0]) / 8
	var bit_offset := int(bit_index[0]) % 8
	var byte_count := (bit_offset + bit_count + 7) / 8
	bit_index[0] = int(bit_index[0]) + bit_count
	var masked := _to_i32(value) & _mask_bits(bit_count)
	var shifted := masked << (8 * byte_count - (bit_offset + bit_count))
	for byte_index in byte_count:
		var src := byte_offset + byte_index
		if src < buf.size():
			var piece := (shifted >> (8 * (byte_count - byte_index - 1))) & 0xFF
			var idx := buf.size() - 1 - src
			buf[idx] = buf[idx] | piece


static func _color_variant(body_class: String, primary_color0: int) -> int:
	var key := "%s:%d" % [body_class, primary_color0]
	const TABLE := {
		"Beast:0": 0, "Beast:1": 1, "Beast:2": 2, "Beast:3": 3, "Beast:4": 4, "Beast:6": 5,
		"Bug:0": 17, "Bug:1": 18, "Bug:2": 19, "Bug:3": 20, "Bug:4": 21,
		"Bird:0": 22, "Bird:1": 23, "Bird:2": 24, "Bird:3": 25, "Bird:4": 26,
		"Plant:0": 6, "Plant:1": 7, "Plant:2": 8, "Plant:3": 9, "Plant:4": 10,
		"Aquatic:0": 11, "Aquatic:1": 12, "Aquatic:2": 13, "Aquatic:3": 14, "Aquatic:4": 15, "Aquatic:6": 16,
		"Reptile:0": 27, "Reptile:1": 28, "Reptile:2": 29, "Reptile:3": 30, "Reptile:4": 31, "Reptile:6": 32,
		"Mech:0": 43, "Mech:1": 44, "Mech:2": 45, "Mech:3": 46, "Mech:4": 47,
		"Dawn:0": 33, "Dawn:1": 34, "Dawn:2": 35, "Dawn:3": 36, "Dawn:4": 37,
		"Dusk:0": 38, "Dusk:1": 39, "Dusk:2": 40, "Dusk:3": 41, "Dusk:4": 42,
	}
	return int(TABLE.get(key, 0))


static func _color_variant_to_class_color(color_variant: int) -> PackedInt32Array:
	const TABLE := {
		0: Vector2i(0, 0), 1: Vector2i(0, 1), 2: Vector2i(0, 2), 3: Vector2i(0, 3), 4: Vector2i(0, 4), 5: Vector2i(0, 6),
		6: Vector2i(3, 0), 7: Vector2i(3, 1), 8: Vector2i(3, 2), 9: Vector2i(3, 3), 10: Vector2i(3, 4),
		11: Vector2i(4, 0), 12: Vector2i(4, 1), 13: Vector2i(4, 2), 14: Vector2i(4, 3), 15: Vector2i(4, 4), 16: Vector2i(4, 6),
		17: Vector2i(1, 0), 18: Vector2i(1, 1), 19: Vector2i(1, 2), 20: Vector2i(1, 3), 21: Vector2i(1, 4),
		22: Vector2i(2, 0), 23: Vector2i(2, 1), 24: Vector2i(2, 2), 25: Vector2i(2, 3), 26: Vector2i(2, 4),
		27: Vector2i(5, 0), 28: Vector2i(5, 1), 29: Vector2i(5, 2), 30: Vector2i(5, 3), 31: Vector2i(5, 4), 32: Vector2i(5, 6),
		33: Vector2i(17, 0), 34: Vector2i(17, 1), 35: Vector2i(17, 2), 36: Vector2i(17, 3), 37: Vector2i(17, 4),
		38: Vector2i(18, 0), 39: Vector2i(18, 1), 40: Vector2i(18, 2), 41: Vector2i(18, 3), 42: Vector2i(18, 4),
		43: Vector2i(16, 0), 44: Vector2i(16, 1), 45: Vector2i(16, 2), 46: Vector2i(16, 3), 47: Vector2i(16, 4),
	}
	var v: Vector2i = TABLE.get(color_variant, Vector2i(0, 0))
	return PackedInt32Array([v.x, v.y])


static func _body_to_detail(body: int) -> int:
	match body:
		AxieTypes.Body.SPIKY:
			return 1
		AxieTypes.Body.FUZZY:
			return 2
		AxieTypes.Body.CURLY:
			return 3
		AxieTypes.Body.SUMO:
			return 256
		AxieTypes.Body.WETDOG:
			return 257
		AxieTypes.Body.BIGYAK:
			return 384
		_:
			return 0


static func _detail_to_body(detail: int) -> int:
	match detail:
		1:
			return AxieTypes.Body.SPIKY
		2:
			return AxieTypes.Body.FUZZY
		3:
			return AxieTypes.Body.CURLY
		256:
			return AxieTypes.Body.SUMO
		257:
			return AxieTypes.Body.WETDOG
		384:
			return AxieTypes.Body.BIGYAK
		_:
			return AxieTypes.Body.NORMAL
