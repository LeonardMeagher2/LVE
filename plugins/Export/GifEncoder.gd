extends RefCounted


const EXPORT_PALETTE := preload("./ExportPalette.gd")

const MAX_CODE := 4096
const MAX_CODE_BITS := 12

var _width: int
var _height: int
var _loop_count: int
var _bytes := PackedByteArray()
var _palette: RefCounted
var _closed := false


class BitWriter extends RefCounted:
	var bytes := PackedByteArray()
	var bits := 0
	var count := 0

	func put(code: int, width: int) -> void:
		bits |= code << count
		count += width
		while count >= 8:
			bytes.append(bits & 255)
			bits >>= 8
			count -= 8

	func flush() -> PackedByteArray:
		if count > 0:
			bytes.append(bits & 255)
			bits = 0
			count = 0
		return bytes


func _init(width: int, height: int, loop_count := 0, base_colors := PackedColorArray()) -> void:
	_width = clampi(width, 1, 65535)
	_height = clampi(height, 1, 65535)
	_loop_count = clampi(loop_count, -1, 65535)
	_palette = EXPORT_PALETTE.new(base_colors, EXPORT_PALETTE.MAX_COLORS)
	_write_header()


func add_frame(image: Image, delay_ms: int) -> Error:
	if _closed:
		return ERR_UNCONFIGURED
	if image == null or image.get_width() != _width or image.get_height() != _height:
		return ERR_INVALID_PARAMETER
	var rgba: Image = image.duplicate() as Image
	if rgba == null:
		return ERR_INVALID_DATA
	rgba.convert(Image.FORMAT_RGBA8)
	var indices := _index_image(rgba)
	_write_frame(delay_ms, indices)
	return OK


func finish() -> PackedByteArray:
	if not _closed:
		_bytes.append(0x3B)
		_closed = true
	return _bytes


func _index_image(image: Image) -> PackedByteArray:
	var data := image.get_data()
	var count := _width * _height
	var indices := PackedByteArray()
	indices.resize(count)
	var offset := 0
	var pixel := 0
	while pixel < count:
		if data[offset + 3] < EXPORT_PALETTE.ALPHA_THRESHOLD:
			indices[pixel] = 0
		else:
			var key: int = data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16)
			indices[pixel] = _palette.nearest(key)
		offset += 4
		pixel += 1
	return indices


func _write_header() -> void:
	_bytes.append_array("GIF89a".to_ascii_buffer())
	_append_u16(_width)
	_append_u16(_height)
	_bytes.append(0xF7)
	_bytes.append(0)
	_bytes.append(0)
	for index in EXPORT_PALETTE.MAX_COLORS:
		var packed: int = _palette.packed_at(index)
		_bytes.append(packed & 255)
		_bytes.append((packed >> 8) & 255)
		_bytes.append((packed >> 16) & 255)
	if _loop_count >= 0:
		_write_loop()


func _write_loop() -> void:
	_bytes.append(0x21)
	_bytes.append(0xFF)
	_bytes.append(0x0B)
	_bytes.append_array("NETSCAPE2.0".to_ascii_buffer())
	_bytes.append(0x03)
	_bytes.append(0x01)
	_append_u16(_loop_count)
	_bytes.append(0x00)


func _write_frame(delay_ms: int, indices: PackedByteArray) -> void:
	var delay := clampi(roundi(delay_ms / 10.0), 1, 65535)
	_bytes.append(0x21)
	_bytes.append(0xF9)
	_bytes.append(0x04)
	_bytes.append(0x09)
	_append_u16(delay)
	_bytes.append(0x00)
	_bytes.append(0x00)

	_bytes.append(0x2C)
	_append_u16(0)
	_append_u16(0)
	_append_u16(_width)
	_append_u16(_height)
	_bytes.append(0x00)
	_bytes.append(8)

	var compressed := lzw_encode(indices, 8)
	var offset := 0
	while offset < compressed.size():
		var size := mini(255, compressed.size() - offset)
		_bytes.append(size)
		_bytes.append_array(compressed.slice(offset, offset + size))
		offset += size
	_bytes.append(0x00)


func _append_u16(value: int) -> void:
	_bytes.append(value & 255)
	_bytes.append((value >> 8) & 255)


static func lzw_encode(indices: PackedByteArray, min_code_size: int) -> PackedByteArray:
	var writer := BitWriter.new()
	var clear := 1 << min_code_size
	var end := clear + 1
	var code_size := min_code_size + 1
	var next_code := end + 1
	var table := {}
	writer.put(clear, code_size)
	if indices.is_empty():
		writer.put(end, code_size)
		return writer.flush()
	var prefix: int = indices[0]
	for index in range(1, indices.size()):
		var value: int = indices[index]
		var key := (prefix << 8) | value
		if table.has(key):
			prefix = int(table[key])
			continue
		writer.put(prefix, code_size)
		if next_code < MAX_CODE:
			if next_code == (1 << code_size) and code_size < MAX_CODE_BITS:
				code_size += 1
			table[key] = next_code
			next_code += 1
		else:
			writer.put(clear, code_size)
			table.clear()
			code_size = min_code_size + 1
			next_code = end + 1
		prefix = value
	writer.put(prefix, code_size)
	writer.put(end, code_size)
	return writer.flush()
