extends RefCounted

## Reads the GIF files that the test suite writes. Test-only.
##
## The reader parses one global or local color table, the NETSCAPE loop
## extension, a graphic control extension per frame, and the LZW image data.

var width := 0
var height := 0
var frames: Array[Dictionary] = []
## -1 means no loop extension. Zero means forever. A positive value is a
## repeat count.
var loop_count := -1


func read(data: PackedByteArray) -> bool:
	width = 0
	height = 0
	frames.clear()
	loop_count = -1
	if data.size() < 13 or data.slice(0, 6).get_string_from_ascii() != "GIF89a":
		return false
	width = data[6] | (data[7] << 8)
	height = data[8] | (data[9] << 8)
	var packed := data[10]
	var pos := 13
	var global_table := PackedInt32Array()
	if packed & 0x80:
		var size := 2 << (packed & 7)
		var parsed := _table(data, pos, size)
		if parsed.is_empty():
			return false
		global_table = parsed
		pos += size * 3
	var delay := 0
	var transparent := -1
	var disposal := 0
	while pos < data.size():
		var label := data[pos]
		pos += 1
		if label == 0x3B:
			return not frames.is_empty()
		if label == 0x21:
			if pos >= data.size():
				return false
			var extension := data[pos]
			pos += 1
			if extension == 0xF9:
				if pos + 6 > data.size() or data[pos] != 4:
					return false
				var control := data[pos + 1]
				delay = data[pos + 2] | (data[pos + 3] << 8)
				transparent = data[pos + 4] if control & 1 else -1
				disposal = (control >> 2) & 7
				pos += 6
			elif extension == 0xFF:
				if pos >= data.size():
					return false
				var block_size := data[pos]
				pos += 1
				if pos + block_size > data.size():
					return false
				var identifier := data.slice(pos, pos + block_size).get_string_from_ascii()
				pos += block_size
				var blocks := _sub_blocks(data, pos)
				if blocks.is_empty():
					return false
				var payload: PackedByteArray = blocks[0]
				var next_pos: int = blocks[1]
				pos = next_pos
				if identifier == "NETSCAPE2.0" and payload.size() >= 3 and payload[0] == 1:
					loop_count = payload[1] | (payload[2] << 8)
			else:
				return false
		elif label == 0x2C:
			if pos + 9 > data.size():
				return false
			var frame_width := data[pos + 4] | (data[pos + 5] << 8)
			var frame_height := data[pos + 6] | (data[pos + 7] << 8)
			var descriptor := data[pos + 8]
			pos += 9
			var table := global_table
			if descriptor & 0x80:
				var size := 2 << (descriptor & 7)
				var parsed := _table(data, pos, size)
				if parsed.is_empty():
					return false
				table = parsed
				pos += size * 3
			if pos >= data.size():
				return false
			var min_code_size := data[pos]
			pos += 1
			var blocks := _sub_blocks(data, pos)
			if blocks.is_empty():
				return false
			var compressed: PackedByteArray = blocks[0]
			var next_pos: int = blocks[1]
			pos = next_pos
			var indices := _lzw(compressed, min_code_size, frame_width * frame_height)
			if indices.is_empty():
				return false
			var image := _image(indices, frame_width, frame_height, table, transparent)
			if image == null:
				return false
			frames.append({"image": image, "delay": delay, "disposal": disposal, "transparent": transparent})
			delay = 0
			transparent = -1
			disposal = 0
		else:
			return false
	return false


func _table(data: PackedByteArray, start: int, count: int) -> PackedInt32Array:
	var table := PackedInt32Array()
	if start < 0 or count < 1 or start + count * 3 > data.size():
		return table
	for index in count:
		var offset := start + index * 3
		table.append(data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16))
	return table


func _sub_blocks(data: PackedByteArray, start: int) -> Array:
	var result := PackedByteArray()
	var pos := start
	while pos < data.size():
		var size := data[pos]
		pos += 1
		if size == 0:
			return [result, pos]
		if pos + size > data.size():
			return []
		result.append_array(data.slice(pos, pos + size))
		pos += size
	return []


func _image(indices: PackedByteArray, frame_width: int, frame_height: int, table: PackedInt32Array, transparent: int) -> Image:
	if frame_width <= 0 or frame_height <= 0 or indices.size() != frame_width * frame_height:
		return null
	if table.is_empty():
		return null
	var pixels := PackedByteArray()
	pixels.resize(frame_width * frame_height * 4)
	for index in indices.size():
		var pixel := indices[index]
		if pixel == transparent:
			continue
		if pixel >= table.size():
			return null
		var color := table[pixel]
		var offset := index * 4
		pixels[offset] = color & 255
		pixels[offset + 1] = (color >> 8) & 255
		pixels[offset + 2] = (color >> 16) & 255
		pixels[offset + 3] = 255
	return Image.create_from_data(frame_width, frame_height, false, Image.FORMAT_RGBA8, pixels)


func _lzw(data: PackedByteArray, min_code_size: int, expected: int) -> PackedByteArray:
	if min_code_size < 2 or min_code_size > 11:
		return PackedByteArray()
	var clear := 1 << min_code_size
	var end := clear + 1
	var code_size := min_code_size + 1
	var next_code := end + 1
	var table: Array[PackedByteArray] = []
	table.resize(4096)
	for index in clear:
		table[index] = PackedByteArray([index])
	var out := PackedByteArray()
	var previous := PackedByteArray()
	var has_previous := false
	var bits := 0
	var bit_count := 0
	var pos := 0
	while true:
		while bit_count < code_size:
			if pos >= data.size():
				return PackedByteArray()
			bits |= data[pos] << bit_count
			bit_count += 8
			pos += 1
		var code := bits & ((1 << code_size) - 1)
		bits >>= code_size
		bit_count -= code_size
		if code == clear:
			code_size = min_code_size + 1
			next_code = end + 1
			has_previous = false
			continue
		if code == end:
			break
		var entry := PackedByteArray()
		if code < next_code and not table[code].is_empty():
			entry = table[code]
		elif code == next_code and has_previous:
			entry = previous.duplicate()
			entry.append(previous[0])
		else:
			return PackedByteArray()
		out.append_array(entry)
		if has_previous and next_code < 4096:
			var added := previous.duplicate()
			added.append(entry[0])
			table[next_code] = added
			next_code += 1
			if next_code == (1 << code_size) and code_size < 12:
				code_size += 1
		previous = entry
		has_previous = true
		if out.size() > expected:
			return PackedByteArray()
	if out.size() != expected:
		return PackedByteArray()
	return out
