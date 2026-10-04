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
	if get_color(cell_position) == color:
		return
	var chunk_location := chunk_position(cell_position)
	var chunk: Chunk = chunks.get(chunk_location)
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
