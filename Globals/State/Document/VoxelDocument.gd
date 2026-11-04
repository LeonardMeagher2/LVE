class_name VoxelDocument
extends Resource

## The voxel document resource.
##
## A document holds the palette, the frames, and the animation tags. It also
## holds the editor lighting and the export settings. The class encodes and
## decodes the `.lve` binary format and the `.lve.png` container. See
## `docs/DOCUMENT_FORMAT.md` for the format.

## Emitted when [member file_path] changes.
signal file_path_changed()

## The application name.
const APP_NAME := "Leonard's Voxel Editor"
## The four-byte binary file signature.
const FILE_SIGNATURE := [76, 86, 69, 0]
## The current binary format version.
const FORMAT_VERSION := 3
## The maximum file size in bytes.
const MAX_FILE_BYTES := 64 * 1024 * 1024
## The maximum frame count.
const MAX_FRAMES := 10000
## The maximum tag count.
const MAX_TAGS := 10000
## The maximum palette entry count.
const MAX_PALETTE_COLORS := 65536
## The PNG file signature.
const PNG_SIGNATURE := [137, 80, 78, 71, 13, 10, 26, 10]
## The private PNG chunk type that holds the document bytes.
const PNG_DOCUMENT_CHUNK := "lvED"
static var _crc_table := PackedInt64Array()

# Phase counters of the terrain benchmark. The benchmark resets them by direct
# static write.
static var _profile_rescan_calls := 0
static var _profile_rescan_us := 0

## The ordered material entries. Each entry holds nine floats.
@export var palette: Array[PackedFloat32Array] = []
## The animation frames.
@export var frames: Array[VoxelFrame] = []
## The animation tags.
@export var tags: Array[AnimationTag] = []
## The smooth normals model option.
@export var smooth_normals := false
## The editor lighting settings. See `docs/DOCUMENT_FORMAT.md` for the keys.
@export var lighting_settings: Dictionary = {}
## The export workspace settings. See `docs/DOCUMENT_FORMAT.md` for the keys.
@export var export_settings: Dictionary = {}

## The path of the last save or load. The document data does not store it.
var file_path := "":
	set(value):
		if value == file_path:
			return
		file_path = value
		file_path_changed.emit()
var _bounds: AABB
var _bounds_dirty := true


func _init() -> void:
	if frames.is_empty():
		frames.append(VoxelFrame.new())


## Returns the file name for display. It falls back to [code]Untitled[/code].
func get_file_name() -> String:
	var path := file_path if not file_path.is_empty() else resource_path
	return path.get_file() if not path.is_empty() else "Untitled"


## Returns the document as an untyped dictionary for the binary encoder.
func document_data() -> Dictionary:
	# Use an untyped container for the document's restricted Variant decoder.
	var palette_data := []
	for entry in palette:
		palette_data.append(entry.duplicate())
	var frame_data := []
	for frame in frames:
		frame_data.append({"delay_ms": frame.delay_ms, "voxels": frame.storage_data()})
	var tag_data := []
	for tag in tags:
		tag_data.append({"name": tag.name, "from": tag.from, "to": tag.to, "loop_mode": tag.loop_mode, "repeats": tag.repeats})
	return {"palette": palette_data, "frames": frame_data, "tags": tag_data, "smooth_normals": smooth_normals, "lighting": _storage_settings(lighting_settings), "export": _storage_settings(export_settings)}


static func _storage_settings(settings: Dictionary) -> Dictionary:
	var stored := {}
	for key in settings:
		var stored_key: Variant = String(key) if key is StringName else key
		stored[stored_key] = _storage_settings(settings[key]) if settings[key] is Dictionary else settings[key]
	return stored


## Returns the encoded document bytes. Returns an empty array when the data is
## invalid or too large.
func encode_document() -> PackedByteArray:
	var data := document_data()
	if not _valid_document_data(data):
		return PackedByteArray()
	var payload := var_to_bytes(data)
	if payload.size() > MAX_FILE_BYTES - 16:
		return PackedByteArray()
	var result := PackedByteArray(FILE_SIGNATURE)
	result.resize(16)
	result.encode_u32(4, FORMAT_VERSION)
	result.encode_u32(8, payload.size())
	result.encode_u32(12, _crc32(payload))
	result.append_array(payload)
	return result


## Writes the document to a file and returns the error code. A PNG destination
## also writes the preview image. An already encoded byte array is reused when
## it is not empty.
func save_file(path: String, preview: Image = null, encoded := PackedByteArray()) -> Error:
	if path.get_extension().to_lower() not in ["lve", "png"]:
		return ERR_FILE_UNRECOGNIZED
	var data := encoded if not encoded.is_empty() else encode_document()
	if data.is_empty():
		return ERR_INVALID_DATA
	if path.get_extension().to_lower() == "png":
		if preview == null or preview.is_empty():
			return ERR_INVALID_PARAMETER
		data = document_png(preview, data)
	if data.is_empty() or data.size() > MAX_FILE_BYTES:
		return ERR_OUT_OF_MEMORY
	# Write beside the destination so the final rename stays on one file system.
	var temporary_path := path + ".%s.tmp" % Time.get_ticks_usec()
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(data)
	file.flush()
	var error := file.get_error()
	file.close()
	if error == OK:
		error = DirAccess.rename_absolute(temporary_path, path)
	if error != OK:
		DirAccess.remove_absolute(temporary_path)
	return error


## Loads a document from a file. It accepts `.lve` bytes and PNG containers.
## Returns null on failure.
static func load_file(path: String) -> VoxelDocument:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > MAX_FILE_BYTES:
		return null
	var data := file.get_buffer(file.get_length())
	file.close()
	if data.size() >= 8 and data.slice(0, 8) == PackedByteArray(PNG_SIGNATURE):
		data = png_document_data(data)
	var document := decode_document(data)
	if document:
		document.file_path = path
	return document


## Decodes a document from bytes. It also reads format versions 1 and 2.
## Returns null when the bytes are invalid.
static func decode_document(data: PackedByteArray) -> VoxelDocument:
	if data.size() < 16 or data.size() > MAX_FILE_BYTES or data.slice(0, 4) != PackedByteArray(FILE_SIGNATURE):
		return null
	var version := data.decode_u32(4)
	if version < 1 or version > FORMAT_VERSION or data.decode_u32(8) != data.size() - 16:
		return null
	var payload := data.slice(16)
	if _crc32(payload) != data.decode_u32(12):
		return null
	# Reject object types, typed containers, excessive nesting, and invalid lengths before decoding.
	if _variant_end(payload, 0, 0, [1000000]) != payload.size():
		return null
	var fields: Variant = bytes_to_var(payload)
	if version < 3:
		if not fields is Dictionary or not fields.get("palette") is PackedColorArray:
			return null
		var materials: Array = []
		if fields.palette.size() > MAX_PALETTE_COLORS:
			return null
		for color in fields.palette:
			if not _valid_color(color, 1.0):
				return null
			materials.append(VoxelFrame.material(color))
		fields.palette = materials
	if not _valid_document_data(fields):
		return null
	var document := VoxelDocument.new()
	document.palette = unique_palette(fields.palette)
	document.frames.clear()
	for frame_data in fields.frames:
		var frame := VoxelFrame.new()
		frame.delay_ms = frame_data.delay_ms
		frame.restore_storage(frame_data.voxels)
		document.frames.append(frame)
	for tag_data in fields.tags:
		document.add_tag(tag_data.name, tag_data.from, tag_data.to, tag_data.loop_mode, tag_data.repeats)
	document.smooth_normals = fields.smooth_normals
	document.lighting_settings = fields.lighting
	document.export_settings = fields.export
	return document


## Returns PNG bytes that hold the preview image and the document chunk.
static func document_png(preview: Image, document_bytes: PackedByteArray) -> PackedByteArray:
	var png := preview.save_png_to_buffer()
	if png.size() < 20:
		return PackedByteArray()
	var result := png.slice(0, png.size() - 12)
	_append_u32_be(result, document_bytes.size())
	var chunk := PNG_DOCUMENT_CHUNK.to_ascii_buffer()
	chunk.append_array(document_bytes)
	result.append_array(chunk)
	_append_u32_be(result, _crc32(chunk))
	result.append_array(png.slice(png.size() - 12))
	return result


## Returns the document bytes from a PNG. Returns an empty array when no valid
## document chunk exists.
static func png_document_data(png: PackedByteArray) -> PackedByteArray:
	if png.size() < 8 or png.size() > MAX_FILE_BYTES or png.slice(0, 8) != PackedByteArray(PNG_SIGNATURE):
		return PackedByteArray()
	var offset := 8
	var document_bytes := PackedByteArray()
	var has_image := false
	while offset + 12 <= png.size():
		var length := _u32_be(png, offset)
		if length > png.size() - offset - 12:
			return PackedByteArray()
		var type := png.slice(offset + 4, offset + 8).get_string_from_ascii()
		if offset == 8 and (type != "IHDR" or length != 13):
			return PackedByteArray()
		if type == "IDAT":
			has_image = true
		if type == PNG_DOCUMENT_CHUNK:
			if not document_bytes.is_empty() or length == 0:
				return PackedByteArray()
			if _crc32(png.slice(offset + 4, offset + 8 + length)) != _u32_be(png, offset + 8 + length):
				return PackedByteArray()
			document_bytes = png.slice(offset + 8, offset + 8 + length)
		if type == "IEND":
			return document_bytes if length == 0 and has_image and offset + 12 == png.size() else PackedByteArray()
		offset += length + 12
	return PackedByteArray()


static func _append_u32_be(data: PackedByteArray, value: int) -> void:
	for shift in [24, 16, 8, 0]:
		data.append((value >> shift) & 255)


static func _u32_be(data: PackedByteArray, offset: int) -> int:
	return (data[offset] << 24) | (data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3]


static func _crc32(data: PackedByteArray) -> int:
	if _crc_table.is_empty():
		for index in 256:
			var value := index
			for bit in 8:
				value = (value >> 1) ^ (0xedb88320 if value & 1 else 0)
			_crc_table.append(value)
	var crc := 0xffffffff
	for byte in data:
		crc = _crc_table[(crc ^ byte) & 255] ^ (crc >> 8)
	return crc ^ 0xffffffff


# The document permits only the Variant types that its schema uses.
static func _variant_end(data: PackedByteArray, offset: int, depth: int, budget: Array) -> int:
	if depth > 16 or offset < 0 or offset + 4 > data.size() or budget[0] <= 0:
		return -1
	budget[0] -= 1
	var header := data.decode_u32(offset)
	var type := header & 0xffff
	var flags := header >> 16
	offset += 4
	var size := 0
	match type:
		TYPE_BOOL:
			if flags != 0:
				return -1
			size = 4
		TYPE_INT, TYPE_FLOAT:
			if flags > 1:
				return -1
			size = 8 if flags == 1 else 4
		TYPE_VECTOR3, TYPE_BASIS:
			if flags > 1:
				return -1
			size = (3 if type == TYPE_VECTOR3 else 9) * (8 if flags == 1 else 4)
		TYPE_VECTOR3I, TYPE_COLOR:
			if flags != 0:
				return -1
			size = 12 if type == TYPE_VECTOR3I else 16
		TYPE_STRING, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_COLOR_ARRAY:
			if flags != 0 or offset + 4 > data.size():
				return -1
			var count := data.decode_u32(offset)
			offset += 4
			if count > 1000000:
				return -1
			match type:
				TYPE_STRING: size = (count + 3) & ~3
				TYPE_PACKED_INT32_ARRAY: size = count * 4
				TYPE_PACKED_FLOAT32_ARRAY: size = count * 4
				TYPE_PACKED_COLOR_ARRAY: size = count * 16
		TYPE_ARRAY, TYPE_DICTIONARY:
			if flags != 0 or offset + 4 > data.size():
				return -1
			var count := data.decode_u32(offset)
			offset += 4
			if count > 1000000:
				return -1
			if type == TYPE_DICTIONARY:
				count *= 2
			if count > budget[0] or count * 4 > data.size() - offset:
				return -1
			for index in count:
				offset = _variant_end(data, offset, depth + 1, budget)
				if offset < 0:
					return -1
			return offset
		_:
			return -1
	return offset + size if offset + size <= data.size() else -1


static func _valid_document_data(data: Variant) -> bool:
	if not data is Dictionary:
		return false
	if not valid_palette(data.get("palette")):
		return false
	if not data.get("frames") is Array or data.frames.is_empty() or data.frames.size() > MAX_FRAMES:
		return false
	var occupied := 0
	for frame in data.frames:
		if not frame is Dictionary or not _integer_in(frame.get("delay_ms"), 1, 86400000):
			return false
		var count := VoxelFrame.validate_storage(frame.get("voxels"), VoxelFrame.MAX_STORED_VOXELS - occupied)
		if count < 0:
			return false
		occupied += count
	if not data.get("tags") is Array or data.tags.size() > MAX_TAGS:
		return false
	for tag in data.tags:
		if not tag is Dictionary:
			return false
		if not tag.get("name") is String or tag.name.length() > 1024:
			return false
		if not _integer_in(tag.get("from"), 0, data.frames.size() - 1) or not _integer_in(tag.get("to"), tag.from, data.frames.size() - 1):
			return false
		if not _integer_in(tag.get("loop_mode"), 0, 3) or not _integer_in(tag.get("repeats"), 0, 1000000):
			return false
	return data.get("smooth_normals") is bool and _valid_lighting(data.get("lighting"), false) and _valid_export(data.get("export"), data.tags.size())


## Returns the palette with duplicate entries removed. The first occurrence
## keeps its position.
static func unique_palette(materials: Array) -> Array[PackedFloat32Array]:
	var result: Array[PackedFloat32Array] = []
	var seen := {}
	for material: PackedFloat32Array in materials:
		if not seen.has(material):
			seen[material] = true
			result.append(material.duplicate())
	return result


## Returns [code]true[/code] when the value is a valid palette.
static func valid_palette(value: Variant) -> bool:
	if not value is Array or value.size() > MAX_PALETTE_COLORS:
		return false
	for entry in value:
		if not valid_material(entry):
			return false
	return true


## Returns [code]true[/code] when the value is a valid nine-float material. Each
## component must be finite and between zero and one.
static func valid_material(value: Variant) -> bool:
	if not value is PackedFloat32Array or value.size() != VoxelFrame.MATERIAL_STRIDE:
		return false
	for component in value:
		if not _number_in(component, 0.0, 1.0):
			return false
	return true


static func _integer_in(value: Variant, low: int, high: int) -> bool:
	return value is int and value >= low and value <= high


static func _number_in(value: Variant, low: float, high: float) -> bool:
	return (value is float or value is int) and is_finite(value) and value >= low and value <= high


static func _valid_color(value: Variant, maximum: float) -> bool:
	return value is Color and _number_in(value.r, 0, maximum) and _number_in(value.g, 0, maximum) and _number_in(value.b, 0, maximum) and _number_in(value.a, 0, maximum)


static func _valid_basis(value: Variant) -> bool:
	return value is Basis and value.is_finite() and absf(value.determinant()) > 0.0001 and value.x.length() < 2 and value.y.length() < 2 and value.z.length() < 2


static func _valid_lighting(data: Variant, exported: bool) -> bool:
	if not data is Dictionary:
		return false
	if exported:
		# These fields are read directly by the export workspace.
		for key in ["basis", "color", "ambient_color", "energy", "ambient_energy", "shadows", "shaded"]:
			if not data.has(key):
				return false
	for key in data:
		match key:
			"basis", "view_basis":
				if not _valid_basis(data[key]): return false
			"color", "ambient_color":
				if not _valid_color(data[key], 16.0): return false
			"energy", "ambient_energy":
				if not _number_in(data[key], 0, 16): return false
			"shadows", "shaded", "view_locked":
				if not data[key] is bool: return false
	return true


static func _valid_export(data: Variant, tag_count: int) -> bool:
	if not data is Dictionary:
		return false
	for key in data:
		match key:
			"view":
				if not _integer_in(data[key], 0, 7): return false
			"frame_size":
				if not _number_in(data[key], 1, 8192): return false
			"views":
				if not _number_in(data[key], 1, 128): return false
			"model_tag", "sheet_tag":
				if not _integer_in(data[key], -1, tag_count - 1): return false
			"lighting":
				if not _valid_lighting(data[key], true): return false
			"camera":
				if not _valid_camera(data[key]): return false
			"sprite_ortho", "sprite_center", "automatic_size", "turntable", "metadata", "center":
				if not data[key] is bool: return false
	return true


static func _valid_camera(data: Variant) -> bool:
	if not data is Dictionary:
		return false
	for key in data:
		match key:
			"target":
				if not data[key] is Vector3 or not data[key].is_finite() or data[key].length() > 4000000: return false
			"orthographic":
				if not data[key] is bool: return false
			"fov":
				if not _number_in(data[key], 1, 179): return false
			"distance", "initial_distance":
				if not _number_in(data[key], 0.001, 10000000): return false
			"yaw", "pitch":
				if not _number_in(data[key], -1000000, 1000000): return false
	return true


## Adds a frame after the last frame. A source index above or equal to zero
## copies that frame. Returns the new frame.
func add_frame(from_frame: int = -1) -> VoxelFrame:
	var f := VoxelFrame.new()
	if from_frame >= 0 and from_frame < frames.size():
		f = frames[from_frame].copy_frame()
		f.delay_ms = frames[from_frame].delay_ms
	elif not frames.is_empty():
		f.delay_ms = frames.back().delay_ms
	var old_last := frames.size() - 1
	frames.append(f)
	_extend_end_tags(old_last)
	return f


## Duplicates one frame and inserts it after the source.
func duplicate_frame(i: int) -> void:
	if i < 0 or i >= frames.size():
		return
	var f := VoxelFrame.new()
	f = frames[i].copy_frame()
	f.delay_ms = frames[i].delay_ms
	frames.insert(i + 1, f)
	_extend_end_tags(frames.size() - 2)


func _extend_end_tags(old_last: int) -> void:
	var new_last := frames.size() - 1
	if new_last <= old_last:
		return
	for tag in tags:
		if tag.to >= old_last:
			tag.to = new_last


## Removes one frame. The last remaining frame is kept.
func remove_frame(i: int) -> void:
	if frames.size() <= 1:
		return
	if i < 0 or i >= frames.size():
		return
	frames.remove_at(i)
	_shift_tags_after_remove(i)
	_bounds_dirty = true


func _shift_tags_after_remove(i: int) -> void:
	var last := frames.size() - 1
	for tag in tags:
		if tag.from > i:
			tag.from -= 1
		if tag.to >= i:
			tag.to -= 1
		tag.from = clampi(tag.from, 0, last)
		tag.to = clampi(tag.to, 0, last)
		if tag.from > tag.to:
			tag.to = tag.from


## Moves one frame to a new index.
func move_frame(from: int, to: int) -> void:
	if from < 0 or from >= frames.size() or to < 0 or to >= frames.size():
		return
	if from == to:
		return
	var frame := frames[from]
	frames.remove_at(from)
	frames.insert(to, frame)
	_bounds_dirty = true


## Adds a tag and returns its index. The frame range is inclusive. A repeat
## count of zero means continuous playback.
func add_tag(name: String, from: int, to: int, loop_mode := AnimationTag.LoopMode.FORWARD, repeats := 0) -> int:
	var tag := AnimationTag.new()
	tag.name = name
	tag.from = clampi(from, 0, frames.size() - 1)
	tag.to = clampi(to, tag.from, frames.size() - 1)
	tag.loop_mode = loop_mode
	tag.repeats = repeats
	tags.append(tag)
	return tags.size() - 1

## Returns one tag by index, or null when the index is out of range.
func get_tag(i:int) -> AnimationTag:
	if i >= 0 and i < tags.size():
		return tags[i]
	return null

## Removes one tag by index.
func remove_tag(i: int) -> void:
	if i >= 0 and i < tags.size():
		tags.remove_at(i)


## Returns the bounds of every frame in cell units.
func bounds() -> AABB:
	if _bounds_dirty:
		_rescan_bounds()
	return _bounds


func _rescan_bounds() -> void:
	var started := Time.get_ticks_usec()
	var b := AABB()
	for f in frames:
		var box := f.get_bounds()
		if box.has_volume():
			b = b.merge(box) if b.has_volume() else box
		
	_bounds = b
	_bounds_dirty = false
	_profile_rescan_calls += 1
	_profile_rescan_us += Time.get_ticks_usec() - started


func _grow_bounds(cell: Vector3i) -> void:
	var half = Vector3.ONE * 0.5
	if not _bounds.has_volume():
		_bounds = AABB(Vector3(cell) - half, Vector3.ONE)
	else:
		_bounds = _bounds.merge(AABB(Vector3(cell) - half, Vector3.ONE))


func _may_shrink_bounds(_frame: int, cell: Vector3i) -> void:
	if _bounds_dirty or not _bounds.has_volume():
		_bounds_dirty = true
		return
	var lo := Vector3i(_bounds.position + Vector3.ONE * 0.5)
	var hi := Vector3i(_bounds.position + _bounds.size - Vector3.ONE * 0.5)
	if cell.x == lo.x or cell.x == hi.x or cell.y == lo.y or cell.y == hi.y or cell.z == lo.z or cell.z == hi.z:
		_bounds_dirty = true


## Paints one cell. It erases the cell when the material is empty.
func paint(frame: int, cell: Vector3i, cell_material: PackedFloat32Array) -> void:
	set_cell(frame, cell, cell_material)


## Sets one cell. It erases the cell when the material is empty.
func set_cell(frame: int, cell: Vector3i, cell_material: PackedFloat32Array) -> void:
	if VoxelFrame.is_empty(cell_material):
		erase(frame, cell)
		return
	frames[frame].set_cell(cell, cell_material)
	_grow_bounds(cell)


## Erases one cell.
func erase(frame: int, cell: Vector3i) -> void:
	if not frames[frame].has(cell):
		return
	frames[frame].set_cell(cell, VoxelFrame.material(Color.TRANSPARENT))
	_may_shrink_bounds(frame, cell)


## Returns the color of one cell in a frame.
func get_color_at(frame: int, cell: Vector3i) -> Color:
	return frames[frame].get_color(cell)


## Returns [code]true[/code] when a frame holds the cell.
func has_cell(frame: int, cell: Vector3i) -> bool:
	return frames[frame].has(cell)


## Returns the color of one palette entry. An out-of-range index returns
## magenta.
func get_color(index: int) -> Color:
	if index >= 0 and index < palette.size():
		return VoxelFrame.material_color(palette[index])
	return Color.MAGENTA
