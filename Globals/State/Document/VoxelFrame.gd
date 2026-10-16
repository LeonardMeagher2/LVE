class_name VoxelFrame
extends Resource

@export var delay_ms := 100

# Version 2 stores sparse chunk roots, color tables, material tables, and flattened octree nodes.
@export_storage var voxel_data: PackedByteArray:
	get:
		return _encode()
	set(value):
		if not value.is_empty():
			_decode(value)

const CHUNK_SIZE := 16
const STORAGE_VERSION := 2
const STORAGE_RECORD_SIZE := 5
const VERSION_1_RECORD_SIZE := 3
# The default material keeps no per-cell data. Version 1 content uses it.
const DEFAULT_MATERIAL := {"emission": Color.BLACK, "metallic": 0.0, "roughness": 1.0}
const DIRECTIONS := [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP, Vector3i.DOWN, Vector3i.BACK, Vector3i.FORWARD]

class EditContext extends RefCounted:
	var axes := 0
	var origin_twice := Vector3i.ZERO
	var selection := {}

	func expand(changes: Dictionary, frame: VoxelFrame, existing_only: bool, matching_color: Variant, job: EditJob = null) -> Dictionary:
		if axes == 0 and selection.is_empty() and not existing_only and matching_color == null:
			return changes
		var expanded := {}
		var masks: Array[int] = []
		for mask in 8:
			if (mask & ~axes) == 0:
				masks.append(mask)
		var completed := 0
		for cell: Vector3i in changes:
			for mask in masks:
				var destination := reflect(cell, mask)
				if _allows(destination, frame, existing_only, matching_color):
					expanded[destination] = changes[cell]
				completed += 1
				if job and completed % 4096 == 0 and not job.checkpoint(completed):
					return {}
		if axes == 0:
			return expanded
		# Preserve original colors where the original and reflected patterns overlap.
		for cell: Vector3i in changes:
			if _allows(cell, frame, existing_only, matching_color):
				expanded[cell] = changes[cell]
			completed += 1
			if job and completed % 4096 == 0 and not job.checkpoint(completed):
				return {}
		return expanded

	func reflect(cell: Vector3i, mask: int) -> Vector3i:
		var destination := cell
		for axis in 3:
			if mask & (1 << axis):
				destination[axis] = origin_twice[axis] - cell[axis]
		return destination

	func _allows(cell: Vector3i, frame: VoxelFrame, existing_only: bool, matching_color: Variant) -> bool:
		return (selection.is_empty() or selection.has(cell)) and (not existing_only or frame.has(cell)) and (matching_color == null or frame.get_color(cell) == matching_color)

class EditJob extends RefCounted:
	var worker_task_id := -1
	var edit_context: EditContext
	var applied_cell_colors := {}
	var _label := "Preparing edit"
	var _completed := 0
	var _total := -1
	var _cancel_requested := false
	var _progress_lock := Mutex.new()

	func stage(label: String, total: int) -> void:
		_progress_lock.lock()
		_label = label
		_completed = 0
		_total = total
		_progress_lock.unlock()

	func checkpoint(completed: int) -> bool:
		_progress_lock.lock()
		_completed = completed
		var keep_running := not _cancel_requested
		_progress_lock.unlock()
		return keep_running

	func progress() -> Array:
		_progress_lock.lock()
		var result := [_label, _completed, _total]
		_progress_lock.unlock()
		return result

	func cancel() -> void:
		_progress_lock.lock()
		_cancel_requested = true
		_progress_lock.unlock()

	func apply_cells(frame: VoxelFrame, changes: Dictionary, existing_only := false, matching_color: Variant = null) -> Array[Vector3i]:
		applied_cell_colors = edit_context.expand(changes, frame, existing_only, matching_color, self) if edit_context else changes
		if not checkpoint(0):
			return []
		return frame.set_cells(applied_cell_colors, self)

	func estimate_work(original_work: int) -> int:
		var work := original_work
		if edit_context:
			for axis in 3:
				if edit_context.axes & (1 << axis):
					work *= 2
		return work

class Chunk extends RefCounted:
	var cell_colors: Dictionary = {}
	# Only occupied cells with a non-default material appear here.
	var cell_materials: Dictionary = {}
	var voxel_revision := 0
	var occupied_bounds := AABB()
	var bounds_dirty := false
	var serialized_record: Array = []
	var positions_by_color: Dictionary = {}

	func copy() -> Chunk:
		var chunk_copy := Chunk.new()
		chunk_copy.cell_colors = cell_colors.duplicate()
		chunk_copy.cell_materials = cell_materials.duplicate()
		chunk_copy.voxel_revision = voxel_revision
		chunk_copy.occupied_bounds = occupied_bounds
		chunk_copy.bounds_dirty = bounds_dirty
		return chunk_copy

	func get_bounds() -> AABB:
		if bounds_dirty:
			occupied_bounds = AABB()
			for cell_position in cell_colors:
				var cell_bounds := AABB(Vector3(cell_position) - Vector3.ONE * 0.5, Vector3.ONE)
				occupied_bounds = occupied_bounds.merge(cell_bounds) if occupied_bounds.has_volume() else cell_bounds
			bounds_dirty = false
		return occupied_bounds

var chunks: Dictionary = {}
var _shared_chunks: Dictionary = {}


func count() -> int:
	var cell_count := 0
	for chunk in chunks.values():
		cell_count += chunk.cell_colors.size()
	return cell_count


static func chunk_position(cell_position: Vector3i) -> Vector3i:
	return Vector3i(floori(cell_position.x / float(CHUNK_SIZE)), floori(cell_position.y / float(CHUNK_SIZE)), floori(cell_position.z / float(CHUNK_SIZE)))


func clear() -> void:
	chunks = {}
	_shared_chunks = {}


func has(cell_position: Vector3i) -> bool:
	var chunk: Chunk = chunks.get(chunk_position(cell_position))
	return chunk != null and chunk.cell_colors.has(cell_position)


func get_color(cell_position: Vector3i) -> Color:
	var chunk: Chunk = chunks.get(chunk_position(cell_position))
	return chunk.cell_colors.get(cell_position, Color.TRANSPARENT) if chunk else Color.TRANSPARENT


func get_material(cell_position: Vector3i) -> Dictionary:
	var chunk: Chunk = chunks.get(chunk_position(cell_position))
	return chunk.cell_materials.get(cell_position, DEFAULT_MATERIAL) if chunk else DEFAULT_MATERIAL


func set_cell(cell_position: Vector3i, color: Color) -> void:
	var chunk_location := chunk_position(cell_position)
	var chunk: Chunk = chunks.get(chunk_location)
	var previous_color: Color = chunk.cell_colors.get(cell_position, Color.TRANSPARENT) if chunk else Color.TRANSPARENT
	if previous_color == color:
		return
	if chunk == null:
		chunk = Chunk.new()
		chunks[chunk_location] = chunk
	elif _shared_chunks.has(chunk_location):
		chunk = chunk.copy()
		chunks[chunk_location] = chunk
		_shared_chunks.erase(chunk_location)
	if color == Color.TRANSPARENT:
		chunk.cell_colors.erase(cell_position)
		chunk.cell_materials.erase(cell_position)
		var min_cell := Vector3i(chunk.occupied_bounds.position + Vector3.ONE * 0.5)
		var max_cell := Vector3i(chunk.occupied_bounds.end - Vector3.ONE * 0.5)
		if cell_position.x == min_cell.x or cell_position.y == min_cell.y or cell_position.z == min_cell.z or cell_position.x == max_cell.x or cell_position.y == max_cell.y or cell_position.z == max_cell.z:
			chunk.bounds_dirty = true
	else:
		chunk.cell_colors[cell_position] = color
		if not chunk.bounds_dirty:
			var cell_bounds := AABB(Vector3(cell_position) - Vector3.ONE * 0.5, Vector3.ONE)
			chunk.occupied_bounds = chunk.occupied_bounds.merge(cell_bounds) if chunk.occupied_bounds.has_volume() else cell_bounds
	chunk.voxel_revision += 1
	chunk.serialized_record.clear()
	chunk.positions_by_color.clear()
	if chunk.cell_colors.is_empty():
		chunks.erase(chunk_location)


# Batch writes copy and invalidate each changed chunk once. Return changed chunk positions.
func set_cells(cell_colors: Dictionary, edit_job: EditJob = null) -> Array[Vector3i]:
	var changes_by_chunk := {}
	var completed := 0
	for cell_position: Vector3i in cell_colors:
		var chunk_location := chunk_position(cell_position)
		if not changes_by_chunk.has(chunk_location):
			changes_by_chunk[chunk_location] = {}
		changes_by_chunk[chunk_location][cell_position] = cell_colors[cell_position]
		completed += 1
		if edit_job and completed % 4096 == 0 and not edit_job.checkpoint(0):
			return []
	var changed_chunks: Array[Vector3i] = []
	completed = 0
	for chunk_location: Vector3i in changes_by_chunk:
		if edit_job and not edit_job.checkpoint(completed):
			return []
		var chunk: Chunk = chunks.get(chunk_location)
		var chunk_changes: Dictionary = changes_by_chunk[chunk_location]
		var has_changed := false
		for cell_position in chunk_changes:
			var color: Color = chunk_changes[cell_position]
			var previous_color: Color = chunk.cell_colors.get(cell_position, Color.TRANSPARENT) if chunk else Color.TRANSPARENT
			if previous_color == color:
				continue
			if not has_changed:
				if chunk == null:
					chunk = Chunk.new()
				elif _shared_chunks.has(chunk_location):
					chunk = chunk.copy()
				chunks[chunk_location] = chunk
				_shared_chunks.erase(chunk_location)
				has_changed = true
			if color == Color.TRANSPARENT:
				chunk.cell_colors.erase(cell_position)
				chunk.cell_materials.erase(cell_position)
			else:
				chunk.cell_colors[cell_position] = color
		completed += chunk_changes.size()
		if not has_changed:
			continue
		chunk.voxel_revision += 1
		chunk.serialized_record.clear()
		chunk.positions_by_color.clear()
		chunk.bounds_dirty = true
		if chunk.cell_colors.is_empty():
			chunks.erase(chunk_location)
		else:
			chunk.get_bounds()
		changed_chunks.append(chunk_location)
	if edit_job:
		edit_job.checkpoint(completed)
	return changed_chunks


# Batch material writes apply to occupied cells only. Return changed chunk positions.
func set_materials(cell_materials: Dictionary, edit_job: EditJob = null) -> Array[Vector3i]:
	var changes_by_chunk := {}
	var completed := 0
	for cell_position: Vector3i in cell_materials:
		var chunk_location := chunk_position(cell_position)
		if not changes_by_chunk.has(chunk_location):
			changes_by_chunk[chunk_location] = {}
		changes_by_chunk[chunk_location][cell_position] = cell_materials[cell_position]
		completed += 1
		if edit_job and completed % 4096 == 0 and not edit_job.checkpoint(0):
			return []
	var changed_chunks: Array[Vector3i] = []
	completed = 0
	for chunk_location: Vector3i in changes_by_chunk:
		if edit_job and not edit_job.checkpoint(completed):
			return []
		var chunk: Chunk = chunks.get(chunk_location)
		var chunk_changes: Dictionary = changes_by_chunk[chunk_location]
		var has_changed := false
		for cell_position in chunk_changes:
			if chunk == null or not chunk.cell_colors.has(cell_position):
				continue
			var material: Dictionary = chunk_changes[cell_position]
			var previous_material: Dictionary = chunk.cell_materials.get(cell_position, DEFAULT_MATERIAL)
			if previous_material == material:
				continue
			if not has_changed:
				if _shared_chunks.has(chunk_location):
					chunk = chunk.copy()
				chunks[chunk_location] = chunk
				_shared_chunks.erase(chunk_location)
				has_changed = true
			if material == DEFAULT_MATERIAL:
				chunk.cell_materials.erase(cell_position)
			else:
				chunk.cell_materials[cell_position] = material
		completed += chunk_changes.size()
		if not has_changed:
			continue
		chunk.voxel_revision += 1
		chunk.serialized_record.clear()
		changed_chunks.append(chunk_location)
	if edit_job:
		edit_job.checkpoint(completed)
	return changed_chunks


func capture() -> Dictionary:
	_shared_chunks = chunks.duplicate()
	return chunks.duplicate()


func restore(chunk_snapshot: Dictionary) -> void:
	chunks = chunk_snapshot.duplicate()
	_shared_chunks = chunks.duplicate()


func copy_frame() -> VoxelFrame:
	var frame_copy := VoxelFrame.new()
	frame_copy.restore(capture())
	frame_copy.delay_ms = delay_ms
	return frame_copy


func positions() -> Array[Vector3i]:
	var cell_positions: Array[Vector3i] = []
	for chunk in chunks.values():
		for cell_position in chunk.cell_colors:
			cell_positions.append(cell_position)
	return cell_positions


func cells_with_color(color: Color) -> Array[Vector3i]:
	var matching_positions: Array[Vector3i] = []
	for chunk in chunks.values():
		if chunk.positions_by_color.is_empty():
			for cell_position in chunk.cell_colors:
				var cell_color: Color = chunk.cell_colors[cell_position]
				if not chunk.positions_by_color.has(cell_color):
					chunk.positions_by_color[cell_color] = []
				chunk.positions_by_color[cell_color].append(cell_position)
		for cell_position in chunk.positions_by_color.get(color, []):
			matching_positions.append(cell_position)
	return matching_positions


func get_bounds() -> AABB:
	var frame_bounds := AABB()
	for chunk in chunks.values():
		var chunk_bounds: AABB = chunk.get_bounds()
		frame_bounds = frame_bounds.merge(chunk_bounds) if frame_bounds.has_volume() else chunk_bounds
	return frame_bounds


func _encode() -> PackedByteArray:
	return var_to_bytes(storage_data())


func storage_data() -> Array:
	var serialized_chunks: Array = []
	for chunk_location in chunks:
		var chunk: Chunk = chunks[chunk_location]
		if chunk.serialized_record.size() != STORAGE_RECORD_SIZE:
			chunk.serialized_record = _encode_chunk(chunk, chunk_location)
		serialized_chunks.append(chunk.serialized_record)
	return [STORAGE_VERSION, serialized_chunks]


# A record holds the color table, the material tables, and one octree of combined cell value ids.
static func _encode_chunk(chunk: Chunk, chunk_location: Vector3i) -> Array:
	var color_table := PackedColorArray([Color.TRANSPARENT])
	var color_ids := {Color.TRANSPARENT: 0}
	var emission_table := PackedColorArray()
	var finish_table := PackedColorArray()
	var material_ids := {}
	for cell_position in chunk.cell_materials:
		var material: Dictionary = chunk.cell_materials[cell_position]
		if material_ids.has(material):
			continue
		material_ids[material] = material_ids.size() + 1
		emission_table.append(material.emission)
		finish_table.append(Color(material.metallic, material.roughness, 0.0, 0.0))
	# The default material holds id 0. A chunk without materials stores color ids alone.
	var material_count := material_ids.size() + 1
	var cell_value_ids := PackedInt32Array()
	cell_value_ids.resize(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE)
	for cell_position in chunk.cell_colors:
		var cell_color: Color = chunk.cell_colors[cell_position]
		if not color_ids.has(cell_color):
			color_ids[cell_color] = color_table.size()
			color_table.append(cell_color)
		var material_id := 0
		if chunk.cell_materials.has(cell_position):
			material_id = material_ids[chunk.cell_materials[cell_position]]
		var local_cell: Vector3i = cell_position - chunk_location * CHUNK_SIZE
		cell_value_ids[local_cell.x + CHUNK_SIZE * (local_cell.y + CHUNK_SIZE * local_cell.z)] = color_ids[cell_color] * material_count + material_id
	var octree_nodes := PackedInt32Array()
	_encode_region(cell_value_ids, Vector3i.ZERO, CHUNK_SIZE, octree_nodes)
	return [chunk_location, color_table, emission_table, finish_table, octree_nodes]


static func _encode_region(cell_value_ids: PackedInt32Array, region_origin: Vector3i, region_size: int, octree_nodes: PackedInt32Array) -> void:
	var region_value_id := cell_value_ids[region_origin.x + CHUNK_SIZE * (region_origin.y + CHUNK_SIZE * region_origin.z)]
	var is_uniform := true
	for z in range(region_origin.z, region_origin.z + region_size):
		for y in range(region_origin.y, region_origin.y + region_size):
			for x in range(region_origin.x, region_origin.x + region_size):
				if cell_value_ids[x + CHUNK_SIZE * (y + CHUNK_SIZE * z)] != region_value_id:
					is_uniform = false
		if not is_uniform:
			break
	if is_uniform:
		octree_nodes.append(region_value_id)
		return
	octree_nodes.append(-1)
	var child_size := region_size >> 1
	for child_index in 8:
		var child_offset := Vector3i(child_index & 1, (child_index >> 1) & 1, (child_index >> 2) & 1) * child_size
		_encode_region(cell_value_ids, region_origin + child_offset, child_size, octree_nodes)


func _decode(encoded_voxels: PackedByteArray) -> void:
	var serialized_frame: Variant = bytes_to_var(encoded_voxels)
	if validate_storage(serialized_frame) < 0:
		push_error("Invalid voxel storage")
		return
	restore_storage(serialized_frame)


# Call only after validate_storage succeeds for the complete document.
func restore_storage(serialized_frame: Array) -> void:
	var restored_chunks := {}
	for serialized_chunk in serialized_frame[1]:
		var chunk_location: Vector3i = serialized_chunk[0]
		var chunk := Chunk.new()
		var emission_table := PackedColorArray()
		var finish_table := PackedColorArray()
		if serialized_chunk.size() == STORAGE_RECORD_SIZE:
			emission_table = serialized_chunk[2]
			finish_table = serialized_chunk[3]
		_decode_region(serialized_chunk[serialized_chunk.size() - 1], [0], serialized_chunk[1], emission_table, finish_table, chunk_location * CHUNK_SIZE, CHUNK_SIZE, chunk.cell_colors, chunk.cell_materials)
		chunk.bounds_dirty = true
		chunk.serialized_record = serialized_chunk
		restored_chunks[chunk_location] = chunk
	restore(restored_chunks)


const MAX_STORED_VOXELS := 4 * 1024 * 1024
const MAX_STORED_CHUNKS := 65536
const MAX_CHUNK_COORDINATE := 65535


# Count occupied leaves before expanding any chunk into voxel dictionaries.
static func validate_storage(data: Variant, voxel_limit := MAX_STORED_VOXELS) -> int:
	if not data is Array or data.size() != 2 or not data[0] is int or data[0] < 1 or data[0] > STORAGE_VERSION or not data[1] is Array:
		return -1
	if data[1].size() > MAX_STORED_CHUNKS:
		return -1
	var record_size := VERSION_1_RECORD_SIZE if data[0] == 1 else STORAGE_RECORD_SIZE
	var locations := {}
	var occupied := 0
	for record in data[1]:
		if not _valid_record(record, record_size):
			return -1
		var location: Vector3i = record[0]
		if absi(location.x) > MAX_CHUNK_COORDINATE or absi(location.y) > MAX_CHUNK_COORDINATE or absi(location.z) > MAX_CHUNK_COORDINATE or locations.has(location):
			return -1
		locations[location] = true
		var colors: PackedColorArray = record[1]
		var emissions := PackedColorArray()
		var finishes := PackedColorArray()
		if record_size == STORAGE_RECORD_SIZE:
			emissions = record[2]
			finishes = record[3]
		var nodes: PackedInt32Array = record[record_size - 1]
		if colors.is_empty() or colors.size() > 4097 or colors[0] != Color.TRANSPARENT or nodes.is_empty() or nodes.size() > 4681:
			return -1
		for color in colors:
			if not is_finite(color.r) or not is_finite(color.g) or not is_finite(color.b) or not is_finite(color.a):
				return -1
			if color.r < 0.0 or color.r > 1.0 or color.g < 0.0 or color.g > 1.0 or color.b < 0.0 or color.b > 1.0 or color.a < 0.0 or color.a > 1.0:
				return -1
		if not _valid_material_table(emissions, finishes):
			return -1
		var cursor := [0]
		var chunk_count := _validate_region(nodes, cursor, colors.size() * (emissions.size() + 1), CHUNK_SIZE)
		if chunk_count < 0 or cursor[0] != nodes.size():
			return -1
		occupied += chunk_count
		if occupied > voxel_limit:
			return -1
	return occupied


static func _valid_record(record: Variant, record_size: int) -> bool:
	if not record is Array or record.size() != record_size or not record[0] is Vector3i or not record[1] is PackedColorArray:
		return false
	if record_size == VERSION_1_RECORD_SIZE:
		return record[2] is PackedInt32Array
	return record[2] is PackedColorArray and record[3] is PackedColorArray and record[4] is PackedInt32Array


# Emission stores the glow color. Finish stores metallic and roughness. Alpha is unused.
static func _valid_material_table(emissions: PackedColorArray, finishes: PackedColorArray) -> bool:
	if emissions.size() != finishes.size() or emissions.size() > 4096:
		return false
	for index in emissions.size():
		var emission: Color = emissions[index]
		var finish: Color = finishes[index]
		for value in [emission.r, emission.g, emission.b, finish.r, finish.g]:
			if not is_finite(value) or value < 0.0 or value > 1.0:
				return false
	return true


static func _validate_region(nodes: PackedInt32Array, cursor: Array, value_count: int, size: int) -> int:
	if cursor[0] >= nodes.size():
		return -1
	var value_id := nodes[cursor[0]]
	cursor[0] += 1
	if value_id >= 0:
		return (0 if value_id == 0 else size * size * size) if value_id < value_count else -1
	if value_id != -1 or size == 1:
		return -1
	var occupied := 0
	for child in 8:
		var child_count := _validate_region(nodes, cursor, value_count, size >> 1)
		if child_count < 0:
			return -1
		occupied += child_count
	return occupied


static func _decode_region(octree_nodes: PackedInt32Array, node_cursor: Array, color_table: PackedColorArray, emission_table: PackedColorArray, finish_table: PackedColorArray, region_origin: Vector3i, region_size: int, restored_colors: Dictionary, restored_materials: Dictionary) -> void:
	var cell_value_id := octree_nodes[node_cursor[0]]
	node_cursor[0] += 1
	if cell_value_id == 0:
		return
	var material_count := emission_table.size() + 1
	if cell_value_id > 0:
		var cell_color: Color = color_table[floori(cell_value_id / float(material_count))]
		var material_id := cell_value_id % material_count
		var material := {}
		if material_id != 0:
			var finish: Color = finish_table[material_id - 1]
			material = {"emission": emission_table[material_id - 1], "metallic": finish.r, "roughness": finish.g}
		for z in range(region_origin.z, region_origin.z + region_size):
			for y in range(region_origin.y, region_origin.y + region_size):
				for x in range(region_origin.x, region_origin.x + region_size):
					var cell := Vector3i(x, y, z)
					restored_colors[cell] = cell_color
					if material_id != 0:
						restored_materials[cell] = material
		return
	var child_size := region_size >> 1
	for child_index in 8:
		var child_offset := Vector3i(child_index & 1, (child_index >> 1) & 1, (child_index >> 2) & 1) * child_size
		_decode_region(octree_nodes, node_cursor, color_table, emission_table, finish_table, region_origin + child_offset, child_size, restored_colors, restored_materials)
