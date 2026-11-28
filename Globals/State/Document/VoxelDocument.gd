class_name VoxelDocument
extends Resource


signal file_path_changed()

const APP_NAME := "Leonard's Voxel Editor"
const FILE_SIGNATURE := [76, 86, 69, 0]
const FORMAT_VERSION := 5
const MAX_FILE_BYTES := 64 * 1024 * 1024
const MAX_DOCUMENT_SIZE := 4096
const MAX_FRAMES := 10000
const MAX_LAYERS := 64
const MAX_TAGS := 10000
const MAX_PALETTE_COLORS := 65536
const PNG_SIGNATURE := [137, 80, 78, 71, 13, 10, 26, 10]
const PNG_DOCUMENT_CHUNK := "lvED"
static var _crc_table := PackedInt64Array()

static var _profile_rescan_calls := 0
static var _profile_rescan_us := 0

@export var palette: Array[PackedFloat32Array] = []
@export var tags: Array[AnimationTag] = []
@export var smooth_normals := false
@export_range(0, 1, 1) var mesh_style := 0
@export_range(0.0, 1.0, 0.01) var ao_strength := 1.0
@export var lighting_settings: Dictionary = {}
@export var export_settings: Dictionary = {}
@export var tool_settings: Dictionary = {}
@export var view_settings: Dictionary = {}
@export var size := Vector3i.ZERO

var layers: Array[VoxelLayer] = []
var frame_delays: Array[int] = []

var file_path := "":
	set(value):
		if value == file_path:
			return
		file_path = value
		file_path_changed.emit()
var _bounds: AABB
var _bounds_dirty := true
var _composite_frame: VoxelFrame
var _composite_index := -1
var _composite_sources := {}

var edit_frame := 0
var edit_layer := 0
var edit_tag := 0
var edit_playing := false
var edit_selection := VoxelSelection.new()
var edit_history := UndoRedo.new()
var edit_save_path := ""
var edit_dirty := false
var edit_camera := {}
var edit_stamp := {}
var reset_workspace := false


func _init() -> void:
	if layers.is_empty():
		var layer := VoxelLayer.new()
		layer.frames.append(VoxelFrame.new())
		layers.append(layer)
	if frame_delays.is_empty():
		frame_delays.append(100)
	edit_layer = clampi(edit_layer, 0, layers.size() - 1)
	edit_frame = clampi(edit_frame, 0, frame_delays.size() - 1)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(edit_history):
		edit_history.free()
		edit_history = null


func get_file_name() -> String:
	var path := file_path if not file_path.is_empty() else resource_path
	return path.get_file() if not path.is_empty() else "Untitled"


func document_data() -> Dictionary:
	var palette_data := []
	for entry in palette:
		palette_data.append(entry.duplicate())
	var frame_data := []
	for delay in frame_delays:
		frame_data.append({"delay_ms": delay})
	var layer_data := []
	for layer in layers:
		var cel_data := []
		for cel in layer.frames:
			cel_data.append({"voxels": cel.storage_data()})
		layer_data.append({"name": layer.name, "visible": layer.visible, "locked": layer.locked, "frames": cel_data})
	var tag_data := []
	for tag in tags:
		tag_data.append({"name": tag.name, "from": tag.from, "to": tag.to, "loop_mode": tag.loop_mode, "repeats": tag.repeats})
	return {"palette": palette_data, "frames": frame_data, "layers": layer_data, "tags": tag_data, "smooth_normals": smooth_normals, "mesh_style": mesh_style, "ao": ao_strength, "lighting": _storage_settings(lighting_settings), "export": _storage_settings(export_settings), "tools": _storage_settings(tool_settings), "view": _storage_settings(view_settings), "camera": _storage_settings(edit_camera), "edit_frame": edit_frame, "edit_layer": edit_layer, "edit_tag": edit_tag if not tags.is_empty() else -1, "edit_playing": edit_playing, "size": size}


static func _storage_settings(settings: Dictionary) -> Dictionary:
	var stored := {}
	for key in settings:
		var stored_key: Variant = String(key) if key is StringName else key
		stored[stored_key] = _storage_settings(settings[key]) if settings[key] is Dictionary else settings[key]
	return stored


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
	result.encode_u32(12, _checksum(payload))
	result.append_array(payload)
	return result


func save_file(path: String, preview: Image = null, encoded := PackedByteArray()) -> Error:
	var is_uri := path.contains("://")
	var extension := path.get_extension().to_lower()
	if extension not in ["lve", "png"] and not is_uri:
		return ERR_FILE_UNRECOGNIZED
	var data := encoded if not encoded.is_empty() else encode_document()
	if data.is_empty():
		return ERR_INVALID_DATA
	if extension == "png":
		if preview == null or preview.is_empty():
			return ERR_INVALID_PARAMETER
		data = document_png(preview, data)
	if data.is_empty() or data.size() > MAX_FILE_BYTES:
		return ERR_OUT_OF_MEMORY
	var temporary_path := "" if is_uri else path + ".%s.tmp" % Time.get_ticks_usec()
	var file := FileAccess.open(path if is_uri else temporary_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(data)
	file.flush()
	var error := file.get_error()
	file.close()
	if not temporary_path.is_empty():
		if error == OK:
			error = DirAccess.rename_absolute(temporary_path, path)
		if error != OK:
			DirAccess.remove_absolute(temporary_path)
	return error


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


static func decode_document(data: PackedByteArray) -> VoxelDocument:
	if data.size() < 16 or data.size() > MAX_FILE_BYTES or data.slice(0, 4) != PackedByteArray(FILE_SIGNATURE):
		return null
	var version := data.decode_u32(4)
	if version < 1 or version > FORMAT_VERSION or data.decode_u32(8) != data.size() - 16:
		return null
	var payload := data.slice(16)
	var expected := _checksum(payload) if version >= 4 else _crc32(payload)
	if expected != data.decode_u32(12):
		return null
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
	document.frame_delays.clear()
	for frame_data in fields.frames:
		document.frame_delays.append(int(frame_data.delay_ms))
	document.layers.clear()
	var stored_layers: Variant = fields.get("layers", null)
	if stored_layers is Array and not stored_layers.is_empty():
		for layer_data in stored_layers:
			var layer := VoxelLayer.new()
			layer.name = layer_data.name
			layer.visible = layer_data.visible
			layer.locked = layer_data.locked
			for cel_data in layer_data.frames:
				var cel := VoxelFrame.new()
				cel.restore_storage(cel_data.voxels)
				layer.frames.append(cel)
			document.layers.append(layer)
	else:
		var layer := VoxelLayer.new()
		layer.name = "Layer 1"
		for frame_data in fields.frames:
			var cel := VoxelFrame.new()
			cel.restore_storage(frame_data.voxels)
			layer.frames.append(cel)
		document.layers.append(layer)
	document.edit_layer = clampi(int(fields.get("edit_layer", 0)), 0, document.layers.size() - 1)
	for tag_data in fields.tags:
		document.add_tag(tag_data.name, tag_data.from, tag_data.to, tag_data.loop_mode, tag_data.repeats)
	document.smooth_normals = fields.smooth_normals
	var stored_style: Variant = fields.get("mesh_style", 0)
	document.mesh_style = int(stored_style) if stored_style is int else 0
	var stored_ao: Variant = fields.get("ao", 1.0)
	document.ao_strength = 1.0 if stored_ao is bool else float(stored_ao)
	document.lighting_settings = fields.lighting
	document.export_settings = fields.export
	var stored_tools: Variant = fields.get("tools", {})
	document.tool_settings = stored_tools if stored_tools is Dictionary else {}
	var stored_view: Variant = fields.get("view", {})
	document.view_settings = stored_view if stored_view is Dictionary else {}
	var stored_camera: Variant = fields.get("camera", {})
	document.edit_camera = stored_camera if stored_camera is Dictionary else {}
	var stored_frame: Variant = fields.get("edit_frame", 0)
	document.edit_frame = clampi(int(stored_frame), 0, document.frame_count() - 1)
	var stored_tag: Variant = fields.get("edit_tag", 0)
	document.edit_tag = clampi(int(stored_tag), -1, document.tags.size() - 1) if not document.tags.is_empty() else -1
	var stored_playing: Variant = fields.get("edit_playing", false)
	document.edit_playing = stored_playing if stored_playing is bool else false
	var stored_size: Variant = fields.get("size")
	if stored_size is Vector3i:
		document.size = stored_size
	return document


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


static func _checksum(data: PackedByteArray) -> int:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(data)
	return context.finish().decode_u32(0)


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
	var frame_count: int = data.frames.size()
	for frame in data.frames:
		if not frame is Dictionary or not _integer_in(frame.get("delay_ms"), 1, 86400000):
			return false
	var occupied := 0
	var stored_layers: Variant = data.get("layers", null)
	if stored_layers == null:
		for frame in data.frames:
			var count := VoxelFrame.validate_storage(frame.get("voxels"), VoxelFrame.MAX_STORED_VOXELS - occupied)
			if count < 0:
				return false
			occupied += count
	elif stored_layers is Array and not stored_layers.is_empty() and stored_layers.size() <= MAX_LAYERS:
		for layer in stored_layers:
			if not layer is Dictionary:
				return false
			if not layer.get("name") is String or layer.name.length() > 1024:
				return false
			if not layer.get("visible") is bool or not layer.get("locked") is bool:
				return false
			var cels: Variant = layer.get("frames")
			if not cels is Array or cels.size() != frame_count:
				return false
			for cel in cels:
				if not cel is Dictionary:
					return false
				var count := VoxelFrame.validate_storage(cel.get("voxels"), VoxelFrame.MAX_STORED_VOXELS - occupied)
				if count < 0:
					return false
				occupied += count
		if not _integer_in(data.get("edit_layer", 0), 0, stored_layers.size() - 1):
			return false
	else:
		return false
	if not data.get("tags") is Array or data.tags.size() > MAX_TAGS:
		return false
	for tag in data.tags:
		if not tag is Dictionary:
			return false
		if not tag.get("name") is String or tag.name.length() > 1024:
			return false
		if not _integer_in(tag.get("from"), 0, frame_count - 1) or not _integer_in(tag.get("to"), tag.from, frame_count - 1):
			return false
		if not _integer_in(tag.get("loop_mode"), 0, 3) or not _integer_in(tag.get("repeats"), 0, 1000000):
			return false
	var ao: Variant = data.get("ao")
	if ao != null and not _number_in(ao, 0.0, 1.0):
		return false
	if not _integer_in(data.get("edit_frame", 0), 0, MAX_FRAMES - 1):
		return false
	if not _integer_in(data.get("edit_tag", 0), -1, MAX_TAGS - 1):
		return false
	if not data.get("edit_playing", false) is bool:
		return false
	return data.get("smooth_normals") is bool and _integer_in(data.get("mesh_style", 0), 0, 1) and _valid_document_size(data.get("size")) and _valid_lighting(data.get("lighting"), false) and _valid_export(data.get("export"), data.tags.size()) and _valid_tool_settings(data.get("tools", {})) and _valid_view_settings(data.get("view", {})) and _valid_camera(data.get("camera", {}))


static func _valid_tool_settings(data: Variant) -> bool:
	if not data is Dictionary:
		return false
	for key in data:
		if not (key is String or key is StringName):
			return false
		match String(key):
			"active":
				if not data[key] is String:
					return false
			"material":
				if not valid_material(data[key]):
					return false
			"editing":
				if not _valid_editing_state(data[key]):
					return false
			_:
				var entry: Variant = data[key]
				if not entry is Dictionary:
					return false
				for setting_key in entry:
					if not (setting_key is String or setting_key is StringName):
						return false
					var value: Variant = entry[setting_key]
					if not (value is bool or value is int or value is float):
						return false
					if value is float and not is_finite(value):
						return false
	return true


static func _valid_editing_state(data: Variant) -> bool:
	if not data is Dictionary:
		return false
	for key in data:
		if not (key is String or key is StringName):
			return false
		match String(key):
			"symmetry_axes":
				if not _integer_in(data[key], 0, 7):
					return false
			"symmetry_origin":
				var origin: Variant = data[key]
				if not origin is Vector3 or not origin.is_finite():
					return false
			"floor_axis":
				if not _integer_in(data[key], 0, 2):
					return false
			"floor_index":
				if not _integer_in(data[key], -1100000, 1100000):
					return false
			"slice_layers":
				if not _integer_in(data[key], 0, 8):
					return false
	return true


static func _valid_view_settings(data: Variant) -> bool:
	if not data is Dictionary:
		return false
	for key in data:
		if not (key is String or key is StringName):
			return false
		match String(key):
			"grid", "wireframe", "orthographic":
				if not data[key] is bool:
					return false
			"view_mode":
				if not _integer_in(data[key], 0, 3):
					return false
	return true


static func _valid_document_size(value: Variant) -> bool:
	if value == null:
		return true
	if not value is Vector3i:
		return false
	var stored: Vector3i = value
	for axis in 3:
		if stored[axis] < 0 or stored[axis] > MAX_DOCUMENT_SIZE:
			return false
	return true


static func unique_palette(materials: Array) -> Array[PackedFloat32Array]:
	var result: Array[PackedFloat32Array] = []
	var seen := {}
	for material: PackedFloat32Array in materials:
		if not seen.has(material):
			seen[material] = true
			result.append(material.duplicate())
	return result


static func valid_palette(value: Variant) -> bool:
	if not value is Array or value.size() > MAX_PALETTE_COLORS:
		return false
	for entry in value:
		if not valid_material(entry):
			return false
	return true


static func valid_material(value: Variant) -> bool:
	if not value is PackedFloat32Array or value.size() != VoxelFrame.MATERIAL_STRIDE:
		return false
	for component in value:
		if not _number_in(component, 0.0, 1.0):
			return false
	return true


static func valid_lighting_settings(value: Variant) -> bool:
	return _valid_lighting(value, false)


static func valid_view_settings(value: Variant) -> bool:
	return _valid_view_settings(value)


static func valid_camera_pose(value: Variant) -> bool:
	return _valid_camera(value)


static func valid_export_settings(value: Variant, tag_count: int) -> bool:
	return _valid_export(value, tag_count)


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
			"sprite_ortho", "sprite_center", "automatic_size", "turntable", "metadata", "center", "unlit", "normal", "specular":
				if not data[key] is bool: return false
			"ao":
				if not _number_in(data[key], 0.0, 1.0): return false
			"specular_intensity":
				if not _number_in(data[key], 0.0, 1.0): return false
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


func frame_count() -> int:
	return frame_delays.size()


func frame_delay(index: int) -> int:
	return frame_delays[index] if index >= 0 and index < frame_delays.size() else 100


func set_frame_delay(index: int, ms: int) -> void:
	if index >= 0 and index < frame_delays.size():
		frame_delays[index] = ms


func active_layer() -> VoxelLayer:
	if layers.is_empty():
		return null
	return layers[edit_layer] if edit_layer >= 0 and edit_layer < layers.size() else layers[0]


func cel(layer_index: int, frame_index: int) -> VoxelFrame:
	if layer_index < 0 or layer_index >= layers.size():
		return null
	var layer := layers[layer_index]
	if frame_index < 0 or frame_index >= layer.frames.size():
		return null
	return layer.frames[frame_index]


func active_cel(frame_index: int = -1) -> VoxelFrame:
	return cel(edit_layer, edit_frame if frame_index < 0 else frame_index)


func find_cel(cel_position: VoxelFrame) -> Vector2i:
	if cel_position == null:
		return Vector2i(-1, -1)
	for layer_index in layers.size():
		var frame_index := layers[layer_index].frames.find(cel_position)
		if frame_index >= 0:
			return Vector2i(layer_index, frame_index)
	return Vector2i(-1, -1)


func make_layer(layer_name := "") -> VoxelLayer:
	var layer := VoxelLayer.new()
	layer.name = layer_name if not layer_name.is_empty() else "Layer %d" % (layers.size() + 1)
	for index in frame_count():
		layer.frames.append(VoxelFrame.new())
	return layer


func replace_active_frames(value: Array[VoxelFrame], delays: Array = []) -> void:
	var layer := active_layer()
	if layer == null:
		return
	layer.frames.clear()
	layer.frames.append_array(value)
	frame_delays.clear()
	if delays.is_empty():
		for index in value.size():
			frame_delays.append(100)
	else:
		for delay in delays:
			frame_delays.append(int(delay))
	edit_frame = clampi(edit_frame, 0, frame_count() - 1)
	_bounds_dirty = true
	invalidate_composite()


func composite_frame(index: int) -> VoxelFrame:
	if index < 0 or index >= frame_count():
		return null
	var visible_layers: Array[VoxelLayer] = []
	for layer in layers:
		if layer.visible and index < layer.frames.size():
			visible_layers.append(layer)
	if visible_layers.is_empty():
		invalidate_composite()
		return null
	if visible_layers.size() == 1:
		invalidate_composite()
		return visible_layers[0].frames[index]
	if _composite_frame == null or _composite_index != index:
		_build_composite(visible_layers, index)
	else:
		_refresh_composite(visible_layers, index)
	return _composite_frame


func invalidate_composite() -> void:
	_composite_frame = null
	_composite_index = -1
	_composite_sources.clear()


func _build_composite(visible_layers: Array[VoxelLayer], index: int) -> void:
	var composite := VoxelFrame.new()
	var sources := {}
	var locations := {}
	for layer in visible_layers:
		for location in layer.frames[index].chunks:
			locations[location] = true
	for location: Vector3i in locations:
		var contributors := _chunk_contributors(visible_layers, index, location)
		var merged := _merge_contributors(contributors)
		if merged == null:
			continue
		composite.chunks[location] = merged
		sources[location] = _source_signature(contributors)
	composite.invalidate_bounds()
	_composite_frame = composite
	_composite_index = index
	_composite_sources = sources


func _refresh_composite(visible_layers: Array[VoxelLayer], index: int) -> void:
	var locations := {}
	for layer in visible_layers:
		for location in layer.frames[index].chunks:
			locations[location] = true
	var changed := false
	for location: Vector3i in locations:
		var contributors := _chunk_contributors(visible_layers, index, location)
		if contributors.is_empty():
			if _composite_sources.erase(location):
				_composite_frame.chunks.erase(location)
				changed = true
			continue
		var signature := _source_signature(contributors)
		if _composite_sources.get(location, []) == signature:
			continue
		_composite_sources[location] = signature
		_composite_frame.chunks[location] = _merge_contributors(contributors)
		changed = true
	for location: Vector3i in _composite_sources.keys():
		if locations.has(location):
			continue
		_composite_sources.erase(location)
		_composite_frame.chunks.erase(location)
		changed = true
	if changed:
		_composite_frame.invalidate_bounds()


static func _chunk_contributors(visible_layers: Array[VoxelLayer], frame_index: int, location: Vector3i) -> Array[VoxelFrame.Chunk]:
	var contributors: Array[VoxelFrame.Chunk] = []
	for layer in visible_layers:
		var chunk: VoxelFrame.Chunk = layer.frames[frame_index].chunks.get(location)
		if chunk != null and chunk.occupied_count > 0:
			contributors.append(chunk)
	return contributors


static func _merge_contributors(contributors: Array[VoxelFrame.Chunk]) -> VoxelFrame.Chunk:
	if contributors.is_empty():
		return null
	if contributors.size() == 1:
		return contributors[0]
	var merged := VoxelFrame.Chunk.new()
	merged.location = contributors[0].location
	for chunk in contributors:
		for cell in chunk.world_cells():
			merged.store(cell, chunk.get_material(cell))
	merged.bounds_dirty = true
	merged.voxel_revision = 1
	return merged


static func _source_signature(contributors: Array[VoxelFrame.Chunk]) -> Array:
	var signature := []
	signature.resize(contributors.size() * 2)
	for index in contributors.size():
		var chunk := contributors[index]
		signature[index * 2] = chunk.get_instance_id()
		signature[index * 2 + 1] = chunk.voxel_revision
	return signature


func is_empty() -> bool:
	for layer in layers:
		for cel_frame in layer.frames:
			if cel_frame.count() > 0:
				return false
	return true


func add_frame(from_frame: int = -1) -> VoxelFrame:
	var delay := 100
	if from_frame >= 0 and from_frame < frame_count():
		delay = frame_delays[from_frame]
	elif not frame_delays.is_empty():
		delay = frame_delays.back()
	var old_last := frame_count() - 1
	frame_delays.append(delay)
	var added: VoxelFrame = null
	for layer in layers:
		var next: VoxelFrame
		if from_frame >= 0 and from_frame < layer.frames.size():
			next = layer.frames[from_frame].copy_frame()
		else:
			next = VoxelFrame.new()
		layer.frames.append(next)
		if layer == active_layer():
			added = next
	_extend_end_tags(old_last)
	invalidate_composite()
	return added


func duplicate_frame(i: int) -> void:
	if i < 0 or i >= frame_count():
		return
	for layer in layers:
		if i < layer.frames.size():
			layer.frames.insert(i + 1, layer.frames[i].copy_frame())
		else:
			layer.frames.insert(i + 1, VoxelFrame.new())
	frame_delays.insert(i + 1, frame_delays[i])
	_extend_end_tags(frame_count() - 2)
	invalidate_composite()


func _extend_end_tags(old_last: int) -> void:
	var new_last := frame_count() - 1
	if new_last <= old_last:
		return
	for tag in tags:
		if tag.to >= old_last:
			tag.to = new_last


func remove_frame(i: int) -> void:
	if frame_count() <= 1:
		return
	if i < 0 or i >= frame_count():
		return
	frame_delays.remove_at(i)
	for layer in layers:
		if i < layer.frames.size():
			layer.frames.remove_at(i)
	_shift_tags_after_remove(i)
	_bounds_dirty = true
	invalidate_composite()
	edit_frame = clampi(edit_frame, 0, frame_count() - 1)
	edit_tag = clampi(edit_tag, -1, tags.size() - 1)


func move_frame_block(from: int, count: int, to: int) -> void:
	var size := frame_count()
	if count < 1 or from < 0 or from + count > size:
		return
	var target := clampi(to, 0, size - count)
	if target == from:
		return
	_move_block(frame_delays, from, count, target)
	for layer in layers:
		if layer.frames.size() == size:
			_move_block(layer.frames, from, count, target)
	_bounds_dirty = true
	invalidate_composite()


static func _move_block(source: Array, from: int, count: int, to: int) -> void:
	var block := source.slice(from, from + count)
	for index in count:
		source.remove_at(from)
	for index in count:
		source.insert(to + index, block[index])


func _shift_tags_after_remove(i: int) -> void:
	var last := frame_count() - 1
	for tag in tags:
		if tag.from > i:
			tag.from -= 1
		if tag.to >= i:
			tag.to -= 1
		tag.from = clampi(tag.from, 0, last)
		tag.to = clampi(tag.to, 0, last)
		if tag.from > tag.to:
			tag.to = tag.from


func add_tag(name: String, from: int, to: int, loop_mode := AnimationTag.LoopMode.FORWARD, repeats := 0) -> int:
	var tag := AnimationTag.new()
	tag.name = name
	tag.from = clampi(from, 0, frame_count() - 1)
	tag.to = clampi(to, tag.from, frame_count() - 1)
	tag.loop_mode = loop_mode
	tag.repeats = repeats
	tags.append(tag)
	return tags.size() - 1

func get_tag(i:int) -> AnimationTag:
	if i >= 0 and i < tags.size():
		return tags[i]
	return null

func has_size() -> bool:
	return size.x > 0 or size.y > 0 or size.z > 0


func axis_cell_range(axis: int) -> Vector2i:
	var extent := size[axis]
	if extent <= 0:
		return Vector2i.ZERO
	var first := -(extent >> 1)
	return Vector2i(first, first + extent)


func workspace_bounds() -> AABB:
	var content := bounds()
	var box := AABB(Vector3.ONE * -4.5, Vector3.ONE * 8.0)
	if content.has_volume():
		box = AABB(content.position - Vector3.ONE, content.size + Vector3.ONE * 2.0)
	for axis in 3:
		if size[axis] <= 0:
			continue
		var cell_range := axis_cell_range(axis)
		box.position[axis] = float(cell_range.x) - 0.5
		box.size[axis] = float(size[axis])
	return box


func bounds() -> AABB:
	if _bounds_dirty:
		_rescan_bounds()
	return _bounds


func invalidate_bounds() -> void:
	_bounds_dirty = true


func _rescan_bounds() -> void:
	var started := Time.get_ticks_usec()
	var b := AABB()
	for layer in layers:
		if not layer.visible:
			continue
		for f in layer.frames:
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


func paint(frame: int, cell: Vector3i, cell_material: PackedFloat32Array) -> void:
	set_cell(frame, cell, cell_material)


func set_cell(frame: int, cell: Vector3i, cell_material: PackedFloat32Array) -> void:
	if VoxelFrame.is_empty(cell_material):
		erase(frame, cell)
		return
	var cel_frame := cel(edit_layer, frame)
	if cel_frame == null:
		return
	cel_frame.set_cell(cell, cell_material)
	var layer := active_layer()
	if layer != null and layer.visible:
		_grow_bounds(cell)
	else:
		_bounds_dirty = true


func erase(frame: int, cell: Vector3i) -> void:
	var cel_frame := cel(edit_layer, frame)
	if cel_frame == null or not cel_frame.has(cell):
		return
	cel_frame.set_cell(cell, VoxelFrame.material(Color.TRANSPARENT))
	var layer := active_layer()
	if layer != null and layer.visible:
		_may_shrink_bounds(frame, cell)
	else:
		_bounds_dirty = true


func get_color_at(frame: int, cell: Vector3i) -> Color:
	var cel_frame := cel(edit_layer, frame)
	return cel_frame.get_color(cell) if cel_frame != null else Color.TRANSPARENT


func has_cell(frame: int, cell: Vector3i) -> bool:
	var cel_frame := cel(edit_layer, frame)
	return cel_frame != null and cel_frame.has(cell)


func get_color(index: int) -> Color:
	if index >= 0 and index < palette.size():
		return VoxelFrame.material_color(palette[index])
	return Color.MAGENTA
