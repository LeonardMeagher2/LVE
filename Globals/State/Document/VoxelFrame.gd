class_name VoxelFrame
extends Resource

@export var delay_ms := 100

# Version 1 stores sparse chunk roots, color tables, and flattened octree nodes.
@export_storage var voxel_data: PackedByteArray:
	get:
		return _encode()
	set(value):
		if not value.is_empty():
			_decode(value)

const CHUNK_SIZE := 16
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
	var voxel_revision := 0
	var occupied_bounds := AABB()
	var bounds_dirty := false
	var serialized_record: Array = []
	var positions_by_color: Dictionary = {}

	func copy() -> Chunk:
		var chunk_copy := Chunk.new()
		chunk_copy.cell_colors = cell_colors.duplicate()
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
		var changed := false
		for cell_position in chunk_changes:
			var color: Color = chunk_changes[cell_position]
			var previous_color: Color = chunk.cell_colors.get(cell_position, Color.TRANSPARENT) if chunk else Color.TRANSPARENT
			if previous_color == color:
				continue
			if not changed:
				if chunk == null:
					chunk = Chunk.new()
				elif _shared_chunks.has(chunk_location):
					chunk = chunk.copy()
				chunks[chunk_location] = chunk
				_shared_chunks.erase(chunk_location)
				changed = true
			if color == Color.TRANSPARENT:
				chunk.cell_colors.erase(cell_position)
			else:
				chunk.cell_colors[cell_position] = color
		completed += chunk_changes.size()
		if not changed:
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
	var serialized_chunks: Array = []
	for chunk_location in chunks:
		var chunk: Chunk = chunks[chunk_location]
		if chunk.serialized_record.is_empty():
			var color_table := PackedColorArray([Color.TRANSPARENT])
			var color_ids := {Color.TRANSPARENT: 0}
			var cell_color_ids := PackedInt32Array()
			cell_color_ids.resize(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE)
			for cell_position in chunk.cell_colors:
				var cell_color: Color = chunk.cell_colors[cell_position]
				if not color_ids.has(cell_color):
					color_ids[cell_color] = color_table.size()
					color_table.append(cell_color)
				var local_cell: Vector3i = cell_position - chunk_location * CHUNK_SIZE
				cell_color_ids[local_cell.x + CHUNK_SIZE * (local_cell.y + CHUNK_SIZE * local_cell.z)] = color_ids[cell_color]
			var octree_nodes := PackedInt32Array()
			_encode_region(cell_color_ids, Vector3i.ZERO, CHUNK_SIZE, octree_nodes)
			chunk.serialized_record = [chunk_location, color_table, octree_nodes]
		serialized_chunks.append(chunk.serialized_record)
	return var_to_bytes([1, serialized_chunks])


static func _encode_region(cell_color_ids: PackedInt32Array, region_origin: Vector3i, region_size: int, octree_nodes: PackedInt32Array) -> void:
	var region_color_id := cell_color_ids[region_origin.x + CHUNK_SIZE * (region_origin.y + CHUNK_SIZE * region_origin.z)]
	var is_uniform := true
	for z in range(region_origin.z, region_origin.z + region_size):
		for y in range(region_origin.y, region_origin.y + region_size):
			for x in range(region_origin.x, region_origin.x + region_size):
				if cell_color_ids[x + CHUNK_SIZE * (y + CHUNK_SIZE * z)] != region_color_id:
					is_uniform = false
		if not is_uniform:
			break
	if is_uniform:
		octree_nodes.append(region_color_id)
		return
	octree_nodes.append(-1)
	var child_size := region_size >> 1
	for child_index in 8:
		var child_offset := Vector3i(child_index & 1, (child_index >> 1) & 1, (child_index >> 2) & 1) * child_size
		_encode_region(cell_color_ids, region_origin + child_offset, child_size, octree_nodes)


func _decode(encoded_voxels: PackedByteArray) -> void:
	var serialized_frame: Array = bytes_to_var(encoded_voxels)
	if serialized_frame.size() != 2 or serialized_frame[0] != 1:
		push_error("Unsupported voxel storage version")
		return
	var restored_chunks := {}
	for serialized_chunk in serialized_frame[1]:
		var chunk_location: Vector3i = serialized_chunk[0]
		var chunk := Chunk.new()
		_decode_region(serialized_chunk[2], [0], serialized_chunk[1], chunk_location * CHUNK_SIZE, CHUNK_SIZE, chunk.cell_colors)
		chunk.bounds_dirty = true
		chunk.serialized_record = serialized_chunk
		restored_chunks[chunk_location] = chunk
	restore(restored_chunks)


static func _decode_region(octree_nodes: PackedInt32Array, node_cursor: Array, color_table: PackedColorArray, region_origin: Vector3i, region_size: int, restored_colors: Dictionary) -> void:
	var region_color_id := octree_nodes[node_cursor[0]]
	node_cursor[0] += 1
	if region_color_id == 0:
		return
	if region_color_id > 0:
		for z in range(region_origin.z, region_origin.z + region_size):
			for y in range(region_origin.y, region_origin.y + region_size):
				for x in range(region_origin.x, region_origin.x + region_size):
					restored_colors[Vector3i(x, y, z)] = color_table[region_color_id]
		return
	var child_size := region_size >> 1
	for child_index in 8:
		var child_offset := Vector3i(child_index & 1, (child_index >> 1) & 1, (child_index >> 2) & 1) * child_size
		_decode_region(octree_nodes, node_cursor, color_table, region_origin + child_offset, child_size, restored_colors)
