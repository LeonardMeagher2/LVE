extends RefCounted

## Encodes RGBA frames as a GIF89a animation.
##
## The encoder uses one 256-color global table. Index 0 is transparent. Each
## frame uses disposal method 2, so a moved voxel leaves no trail. The caller
## supplies the document palette colors. A 6 by 6 by 6 RGB cube fills the rest.
##
## GIF is a service mark of CompuServe Incorporated. The GIF89a specification
## defines the file structure and the LZW stream.

## The alpha value that separates an opaque pixel from a transparent pixel.
const ALPHA_THRESHOLD := 128
## The global color table size.
const MAX_COLORS := 256
## The largest LZW code count.
const MAX_CODE := 4096
## The largest LZW code width.
const MAX_CODE_BITS := 12
## The RGB levels of the fallback cube.
const CUBE_LEVELS := [0, 51, 102, 153, 204, 255]

var _width: int
var _height: int
var _loop_count: int
var _bytes := PackedByteArray()
var _palette := PackedInt32Array([0])
var _palette_seen := {}
var _color_cache := {}
var _closed := false


## One least-significant-bit-first code writer.
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
	_build_palette(base_colors)
	_write_header()


## Adds one frame. The call does not change [param image]. [param delay_ms] is
## the document frame duration in milliseconds.
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


## Writes the trailer and returns the file bytes.
func finish() -> PackedByteArray:
	if not _closed:
		_bytes.append(0x3B)
		_closed = true
	return _bytes


func _build_palette(base_colors: PackedColorArray) -> void:
	for color in base_colors:
		if _palette.size() >= MAX_COLORS:
			return
		if color.a <= 0.5:
			continue
		_add_color(color)
	for red in CUBE_LEVELS:
		if _palette.size() >= MAX_COLORS:
			return
		for green in CUBE_LEVELS:
			if _palette.size() >= MAX_COLORS:
				return
			for blue in CUBE_LEVELS:
				if _palette.size() >= MAX_COLORS:
					return
				_add_color(Color8(red, green, blue))


func _add_color(color: Color) -> void:
	var packed := _pack_color(color)
	if _palette_seen.has(packed):
		return
	_palette_seen[packed] = true
	_palette.append(packed)


static func _pack_color(color: Color) -> int:
	var red := clampi(roundi(color.r * 255.0), 0, 255)
	var green := clampi(roundi(color.g * 255.0), 0, 255)
	var blue := clampi(roundi(color.b * 255.0), 0, 255)
	return red | (green << 8) | (blue << 16)


func _index_image(image: Image) -> PackedByteArray:
	var data := image.get_data()
	var count := _width * _height
	var indices := PackedByteArray()
	indices.resize(count)
	var offset := 0
	var pixel := 0
	while pixel < count:
		if data[offset + 3] < ALPHA_THRESHOLD:
			indices[pixel] = 0
		else:
			var key: int = data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16)
			var cached: int = _color_cache.get(key, -1)
			if cached < 0:
				cached = _nearest(key)
				_color_cache[key] = cached
			indices[pixel] = cached
		offset += 4
		pixel += 1
	return indices


func _nearest(packed: int) -> int:
	var red := packed & 255
	var green := (packed >> 8) & 255
	var blue := (packed >> 16) & 255
	var best := 0
	var best_distance := 1 << 30
	for index in range(1, _palette.size()):
		var entry := _palette[index]
		var dr := red - (entry & 255)
		var dg := green - ((entry >> 8) & 255)
		var db := blue - ((entry >> 16) & 255)
		var distance := dr * dr + dg * dg + db * db
		if distance < best_distance:
			best_distance = distance
			best = index
	return best


func _write_header() -> void:
	_bytes.append_array("GIF89a".to_ascii_buffer())
	_append_u16(_width)
	_append_u16(_height)
	# Global table, eight-bit color resolution, 256 entries.
	_bytes.append(0xF7)
	_bytes.append(0)
	_bytes.append(0)
	for index in MAX_COLORS:
		var packed: int = _palette[index] if index < _palette.size() else 0
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
	# Disposal method 2 and the transparent color flag.
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


## Compresses palette indices with the GIF LZW stream.
##
## GIF uses an early code-size change. The encoder increases the width before
## it assigns the code that needs the new width. The decoder adds that entry
## after it reads the previous code, so both sides stay in step.
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
