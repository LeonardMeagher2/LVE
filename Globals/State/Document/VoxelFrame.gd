class_name VoxelFrame
extends Resource

@export var delay_ms := 100

# Version 3 stores sparse chunk roots, one material table per chunk, and flattened octree nodes.
@export_storage var voxel_data: PackedByteArray:
	get:
		return _encode()
	set(value):
		if not value.is_empty():
			_decode(value)

const CHUNK_SIZE := 16
const STORAGE_VERSION := 3
const STORAGE_RECORD_SIZE := 3
const VERSION_2_RECORD_SIZE := 5
const VERSION_1_RECORD_SIZE := 3
# One material holds nine floats. The color alpha stays live for the mesher and the export.
const MATERIAL_STRIDE := 9
const MATERIAL_COLOR := 0
const MATERIAL_EMISSION := 4
const MATERIAL_METALLIC := 7
const MATERIAL_ROUGHNESS := 8
const DEFAULT_EMISSION := Color.BLACK
const DEFAULT_METALLIC := 0.0
const DEFAULT_ROUGHNESS := 1.0
const DIRECTIONS := [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP, Vector3i.DOWN, Vector3i.BACK, Vector3i.FORWARD]


# Build one material. A transparent color erases the voxel.
static func material(color: Color, emission: Color = DEFAULT_EMISSION, metallic: float = DEFAULT_METALLIC, roughness: float = DEFAULT_ROUGHNESS) -> PackedFloat32Array:
	return PackedFloat32Array([color.r, color.g, color.b, color.a, emission.r, emission.g, emission.b, metallic, roughness])


static func is_empty(cell_material: PackedFloat32Array) -> bool:
	return material_color(cell_material) == Color.TRANSPARENT


static func material_color(cell_material: PackedFloat32Array) -> Color:
	return Color(cell_material[MATERIAL_COLOR], cell_material[MATERIAL_COLOR + 1], cell_material[MATERIAL_COLOR + 2], cell_material[MATERIAL_COLOR + 3])


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
	var applied_cells := {}
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
		applied_cells = edit_context.expand(changes, frame, existing_only, matching_color, self) if edit_context else changes
		if not checkpoint(0):
			return []
		return frame.set_cells(applied_cells, self)

	func estimate_work(original_work: int) -> int:
		var work := original_work
		if edit_context:
			for axis in 3:
				if edit_context.axes & (1 << axis):
					work *= 2
		return work

class Chunk extends RefCounted:
	# One slot holds one voxel material. An erase leaves a hole that compaction removes.
	var cells: Dictionary = {}
	var materials := PackedFloat32Array()
	var voxel_revision := 0
	var occupied_bounds := AABB()
	var bounds_dirty := false
	var serialized_record: Array = []
	var positions_by_color: Dictionary = {}

	func copy() -> Chunk:
		var chunk_copy := Chunk.new()
		chunk_copy.cells = cells.duplicate()
		chunk_copy.materials = materials.duplicate()
		chunk_copy.voxel_revision = voxel_revision
		chunk_copy.occupied_bounds = occupied_bounds
		chunk_copy.bounds_dirty = bounds_dirty
		return chunk_copy

	func matches(cell_position: Vector3i, cell_material: PackedFloat32Array) -> bool:
		var slot: int = cells.get(cell_position, -1)
		if slot < 0:
			return false
		var base := slot * MATERIAL_STRIDE
		for offset in MATERIAL_STRIDE:
			if materials[base + offset] != cell_material[offset]:
				return false
		return true

	# Compare by content. Two equal chunks can number their slots differently.
	func equals(other: Chunk) -> bool:
		if cells.size() != other.cells.size():
			return false
		for cell_position in cells:
			var other_slot: int = other.cells.get(cell_position, -1)
			if other_slot < 0:
				return false
			var slot: int = cells[cell_position]
			var base := slot * MATERIAL_STRIDE
			var other_base := other_slot * MATERIAL_STRIDE
			for offset in MATERIAL_STRIDE:
				if materials[base + offset] != other.materials[other_base + offset]:
					return false
		return true

	func store(cell_position: Vector3i, cell_material: PackedFloat32Array) -> void:
		var slot: int = cells.get(cell_position, -1)
		if slot < 0:
			cells[cell_position] = materials.size() / MATERIAL_STRIDE
			materials.append_array(cell_material)
			return
		var base := slot * MATERIAL_STRIDE
		for offset in MATERIAL_STRIDE:
			materials[base + offset] = cell_material[offset]

	func erase(cell_position: Vector3i) -> void:
		var slot: int = cells.get(cell_position, -1)
		if slot < 0:
			return
		cells.erase(cell_position)
		if materials.size() > cells.size() * MATERIAL_STRIDE * 2:
			_compact()

	# Drop the holes left by erases. The slot map is rebuilt in place.
	func _compact() -> void:
		var compacted := PackedFloat32Array()
		compacted.resize(cells.size() * MATERIAL_STRIDE)
		var next_slot := 0
		for cell_position in cells.keys():
			var slot: int = cells[cell_position]
			var base := slot * MATERIAL_STRIDE
			for offset in MATERIAL_STRIDE:
				compacted[next_slot * MATERIAL_STRIDE + offset] = materials[base + offset]
			cells[cell_position] = next_slot
			next_slot += 1
		materials = compacted

	func get_color(cell_position: Vector3i) -> Color:
		var slot: int = cells.get(cell_position, -1)
		if slot < 0:
			return Color.TRANSPARENT
		var base := slot * MATERIAL_STRIDE
		return Color(materials[base], materials[base + 1], materials[base + 2], materials[base + 3])

	func get_emission(cell_position: Vector3i) -> Color:
		var slot: int = cells.get(cell_position, -1)
		if slot < 0:
			return DEFAULT_EMISSION
		var base := slot * MATERIAL_STRIDE + MATERIAL_EMISSION
		return Color(materials[base], materials[base + 1], materials[base + 2])

	func get_metallic(cell_position: Vector3i) -> float:
		var slot: int = cells.get(cell_position, -1)
		return materials[slot * MATERIAL_STRIDE + MATERIAL_METALLIC] if slot >= 0 else DEFAULT_METALLIC

	func get_roughness(cell_position: Vector3i) -> float:
		var slot: int = cells.get(cell_position, -1)
		return materials[slot * MATERIAL_STRIDE + MATERIAL_ROUGHNESS] if slot >= 0 else DEFAULT_ROUGHNESS

	func get_bounds() -> AABB:
		if bounds_dirty:
			occupied_bounds = AABB()
			for cell_position in cells:
				var cell_bounds := AABB(Vector3(cell_position) - Vector3.ONE * 0.5, Vector3.ONE)
				occupied_bounds = occupied_bounds.merge(cell_bounds) if occupied_bounds.has_volume() else cell_bounds
			bounds_dirty = false
		return occupied_bounds

var chunks: Dictionary = {}
var _shared_chunks: Dictionary = {}


func count() -> int:
	var cell_count := 0
	for chunk in chunks.values():
		cell_count += chunk.cells.size()
	return cell_count


static func chunk_position(cell_position: Vector3i) -> Vector3i:
	return Vector3i(floori(cell_position.x / float(CHUNK_SIZE)), floori(cell_position.y / float(CHUNK_SIZE)), floori(cell_position.z / float(CHUNK_SIZE)))


func clear() -> void:
	chunks = {}
	_shared_chunks = {}


func has(cell_position: Vector3i) -> bool:
	var chunk: Chunk = chunks.get(chunk_position(cell_position))
	return chunk != null and chunk.cells.has(cell_position)


func get_color(cell_position: Vector3i) -> Color:
	var chunk: Chunk = chunks.get(chunk_position(cell_position))
	return chunk.get_color(cell_position) if chunk else Color.TRANSPARENT


func get_emission(cell_position: Vector3i) -> Color:
	var chunk: Chunk = chunks.get(chunk_position(cell_position))
	return chunk.get_emission(cell_position) if chunk else DEFAULT_EMISSION


func get_metallic(cell_position: Vector3i) -> float:
	var chunk: Chunk = chunks.get(chunk_position(cell_position))
	return chunk.get_metallic(cell_position) if chunk else DEFAULT_METALLIC


func get_roughness(cell_position: Vector3i) -> float:
	var chunk: Chunk = chunks.get(chunk_position(cell_position))
	return chunk.get_roughness(cell_position) if chunk else DEFAULT_ROUGHNESS


# One write supplies the whole material. A transparent color erases the voxel.
func set_cell(cell_position: Vector3i, cell_material: PackedFloat32Array) -> void:
	var chunk_location := chunk_position(cell_position)
	var chunk: Chunk = chunks.get(chunk_location)
	var erased := is_empty(cell_material)
	var slot: int = chunk.cells.get(cell_position, -1) if chunk else -1
	if erased:
		if slot < 0:
			return
	elif slot >= 0 and chunk.matches(cell_position, cell_material):
		return
	if chunk == null:
		chunk = Chunk.new()
		chunks[chunk_location] = chunk
	elif _shared_chunks.has(chunk_location):
		chunk = chunk.copy()
		chunks[chunk_location] = chunk
		_shared_chunks.erase(chunk_location)
	if erased:
		chunk.erase(cell_position)
		var min_cell := Vector3i(chunk.occupied_bounds.position + Vector3.ONE * 0.5)
		var max_cell := Vector3i(chunk.occupied_bounds.end - Vector3.ONE * 0.5)
		if cell_position.x == min_cell.x or cell_position.y == min_cell.y or cell_position.z == min_cell.z or cell_position.x == max_cell.x or cell_position.y == max_cell.y or cell_position.z == max_cell.z:
			chunk.bounds_dirty = true
	else:
		chunk.store(cell_position, cell_material)
		if not chunk.bounds_dirty:
			var cell_bounds := AABB(Vector3(cell_position) - Vector3.ONE * 0.5, Vector3.ONE)
			chunk.occupied_bounds = chunk.occupied_bounds.merge(cell_bounds) if chunk.occupied_bounds.has_volume() else cell_bounds
	chunk.voxel_revision += 1
	chunk.serialized_record.clear()
	chunk.positions_by_color.clear()
	if chunk.cells.is_empty():
		chunks.erase(chunk_location)


# Batch writes copy and invalidate each changed chunk once. Return changed chunk positions.
func set_cells(cell_materials: Dictionary, edit_job: EditJob = null) -> Array[Vector3i]:
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
			var cell_material: PackedFloat32Array = chunk_changes[cell_position]
			var erased := is_empty(cell_material)
			var slot: int = chunk.cells.get(cell_position, -1) if chunk else -1
			if erased and slot < 0:
				continue
			if not erased and slot >= 0 and chunk.matches(cell_position, cell_material):
				continue
			if not has_changed:
				if chunk == null:
					chunk = Chunk.new()
				elif _shared_chunks.has(chunk_location):
					chunk = chunk.copy()
				chunks[chunk_location] = chunk
				_shared_chunks.erase(chunk_location)
				has_changed = true
			if erased:
				chunk.erase(cell_position)
			else:
				chunk.store(cell_position, cell_material)
		completed += chunk_changes.size()
		if not has_changed:
			continue
		chunk.voxel_revision += 1
		chunk.serialized_record.clear()
		chunk.positions_by_color.clear()
		chunk.bounds_dirty = true
		if chunk.cells.is_empty():
			chunks.erase(chunk_location)
		else:
			chunk.get_bounds()
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
		for cell_position in chunk.cells:
			cell_positions.append(cell_position)
	return cell_positions


func cells_with_color(color: Color) -> Array[Vector3i]:
	var matching_positions: Array[Vector3i] = []
	for chunk in chunks.values():
		if chunk.positions_by_color.is_empty():
			for cell_position in chunk.cells:
				var cell_color: Color = chunk.get_color(cell_position)
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


# A record holds one material table and one octree of material ids. Id 0 is empty.
static func _encode_chunk(chunk: Chunk, chunk_location: Vector3i) -> Array:
	var material_table := material(Color.TRANSPARENT)
	var material_ids := {}
	material_ids[material_table.slice(0, MATERIAL_STRIDE)] = 0
	var cell_ids := PackedInt32Array()
	cell_ids.resize(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE)
	for cell_position in chunk.cells:
		var slot: int = chunk.cells[cell_position]
		var cell_material := chunk.materials.slice(slot * MATERIAL_STRIDE, (slot + 1) * MATERIAL_STRIDE)
		var material_id: int = material_ids.get(cell_material, -1)
		if material_id < 0:
			material_id = material_table.size() / MATERIAL_STRIDE
			material_ids[cell_material] = material_id
			material_table.append_array(cell_material)
		var local_cell: Vector3i = cell_position - chunk_location * CHUNK_SIZE
		cell_ids[local_cell.x + CHUNK_SIZE * (local_cell.y + CHUNK_SIZE * local_cell.z)] = material_id
	var octree_nodes := PackedInt32Array()
	_encode_region(cell_ids, Vector3i.ZERO, CHUNK_SIZE, octree_nodes)
	return [chunk_location, material_table, octree_nodes]


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
	var version: int = serialized_frame[0]
	var restored_chunks := {}
	for serialized_chunk in serialized_frame[1]:
		var chunk_location: Vector3i = serialized_chunk[0]
		var chunk := Chunk.new()
		var chunk_origin := chunk_location * CHUNK_SIZE
		var octree_nodes: PackedInt32Array = serialized_chunk[serialized_chunk.size() - 1]
		if version == STORAGE_VERSION:
			_decode_materials(octree_nodes, [0], serialized_chunk[1], chunk_origin, CHUNK_SIZE, chunk)
		else:
			var emission_table := PackedColorArray()
			var finish_table := PackedColorArray()
			if version == 2:
				emission_table = serialized_chunk[2]
				finish_table = serialized_chunk[3]
			_decode_region(octree_nodes, [0], serialized_chunk[1], emission_table, finish_table, chunk_origin, CHUNK_SIZE, chunk)
		chunk.bounds_dirty = true
		if version == STORAGE_VERSION:
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
	var version: int = data[0]
	var locations := {}
	var occupied := 0
	for record in data[1]:
		if not _valid_record(record, version):
			return -1
		var location: Vector3i = record[0]
		if absi(location.x) > MAX_CHUNK_COORDINATE or absi(location.y) > MAX_CHUNK_COORDINATE or absi(location.z) > MAX_CHUNK_COORDINATE or locations.has(location):
			return -1
		locations[location] = true
		var value_count := -1
		if version == STORAGE_VERSION:
			var material_table: PackedFloat32Array = record[1]
			if not _valid_material_values(material_table):
				return -1
			value_count = material_table.size() / MATERIAL_STRIDE
		else:
			var color_table: PackedColorArray = record[1]
			if not _valid_colors(color_table):
				return -1
			var emission_table := PackedColorArray()
			var finish_table := PackedColorArray()
			if version == 2:
				emission_table = record[2]
				finish_table = record[3]
				if not _valid_material_table(emission_table, finish_table):
					return -1
			value_count = color_table.size() * (emission_table.size() + 1)
		var nodes: PackedInt32Array = record[record.size() - 1]
		if nodes.is_empty() or nodes.size() > 4681:
			return -1
		var cursor := [0]
		var chunk_count := _validate_region(nodes, cursor, value_count, CHUNK_SIZE)
		if chunk_count < 0 or cursor[0] != nodes.size():
			return -1
		occupied += chunk_count
		if occupied > voxel_limit:
			return -1
	return occupied


static func _valid_record(record: Variant, version: int) -> bool:
	var record_size := STORAGE_RECORD_SIZE if version == STORAGE_VERSION else (VERSION_2_RECORD_SIZE if version == 2 else VERSION_1_RECORD_SIZE)
	if not record is Array or record.size() != record_size or not record[0] is Vector3i:
		return false
	if version == STORAGE_VERSION:
		return record[1] is PackedFloat32Array and record[2] is PackedInt32Array
	if version == 2:
		return record[1] is PackedColorArray and record[2] is PackedColorArray and record[3] is PackedColorArray and record[4] is PackedInt32Array
	return record[1] is PackedColorArray and record[2] is PackedInt32Array


# The empty entry holds id 0. Every other entry holds a color.
static func _valid_colors(color_table: PackedColorArray) -> bool:
	if color_table.is_empty() or color_table.size() > 4097 or color_table[0] != Color.TRANSPARENT:
		return false
	for color in color_table:
		if not is_finite(color.r) or not is_finite(color.g) or not is_finite(color.b) or not is_finite(color.a):
			return false
		if color.r < 0.0 or color.r > 1.0 or color.g < 0.0 or color.g > 1.0 or color.b < 0.0 or color.b > 1.0 or color.a < 0.0 or color.a > 1.0:
			return false
	return true


# The empty entry holds id 0. Every other entry holds nine floats in 0 through 1.
static func _valid_material_values(material_table: PackedFloat32Array) -> bool:
	if material_table.size() < MATERIAL_STRIDE or material_table.size() > 4097 * MATERIAL_STRIDE or material_table.size() % MATERIAL_STRIDE != 0:
		return false
	if not is_empty(material_table.slice(0, MATERIAL_STRIDE)):
		return false
	for value in material_table:
		if not is_finite(value) or value < 0.0 or value > 1.0:
			return false
	return true


# Emission stores the glow color. Finish stores metallic and roughness. Alpha is unused.
static func _valid_material_table(emission_table: PackedColorArray, finish_table: PackedColorArray) -> bool:
	if emission_table.size() != finish_table.size() or emission_table.size() > 4096:
		return false
	for index in emission_table.size():
		var emission: Color = emission_table[index]
		var finish: Color = finish_table[index]
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


# Version 1 stores color ids alone. Version 2 packs a color id and a material id.
static func _decode_region(octree_nodes: PackedInt32Array, node_cursor: Array, color_table: PackedColorArray, emission_table: PackedColorArray, finish_table: PackedColorArray, region_origin: Vector3i, region_size: int, chunk: Chunk) -> void:
	var cell_value_id := octree_nodes[node_cursor[0]]
	node_cursor[0] += 1
	if cell_value_id == 0:
		return
	if cell_value_id > 0:
		var material_count := emission_table.size() + 1
		var cell_color: Color = color_table[floori(cell_value_id / float(material_count))]
		var material_id := cell_value_id % material_count
		var cell_material := material(cell_color)
		if material_id != 0:
			var finish: Color = finish_table[material_id - 1]
			cell_material = material(cell_color, emission_table[material_id - 1], finish.r, finish.g)
		for z in range(region_origin.z, region_origin.z + region_size):
			for y in range(region_origin.y, region_origin.y + region_size):
				for x in range(region_origin.x, region_origin.x + region_size):
					chunk.store(Vector3i(x, y, z), cell_material)
		return
	var child_size := region_size >> 1
	for child_index in 8:
		var child_offset := Vector3i(child_index & 1, (child_index >> 1) & 1, (child_index >> 2) & 1) * child_size
		_decode_region(octree_nodes, node_cursor, color_table, emission_table, finish_table, region_origin + child_offset, child_size, chunk)


# Version 3 stores one material id per cell.
static func _decode_materials(octree_nodes: PackedInt32Array, node_cursor: Array, material_table: PackedFloat32Array, region_origin: Vector3i, region_size: int, chunk: Chunk) -> void:
	var material_id := octree_nodes[node_cursor[0]]
	node_cursor[0] += 1
	if material_id == 0:
		return
	if material_id > 0:
		var cell_material := material_table.slice(material_id * MATERIAL_STRIDE, (material_id + 1) * MATERIAL_STRIDE)
		for z in range(region_origin.z, region_origin.z + region_size):
			for y in range(region_origin.y, region_origin.y + region_size):
				for x in range(region_origin.x, region_origin.x + region_size):
					chunk.store(Vector3i(x, y, z), cell_material)
		return
	var child_size := region_size >> 1
	for child_index in 8:
		var child_offset := Vector3i(child_index & 1, (child_index >> 1) & 1, (child_index >> 2) & 1) * child_size
		_decode_materials(octree_nodes, node_cursor, material_table, region_origin + child_offset, child_size, chunk)
