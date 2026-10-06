class_name VoxelMeshBuilder
extends RefCounted

const CHUNK_SIZE := VoxelFrame.CHUNK_SIZE
const PADDED_CHUNK_SIZE := CHUNK_SIZE + 2

var source_frame: VoxelFrame
var chunk_location := Vector3i.ZERO
var worker_task_id := -1
var surface_arrays: Array = []
var geometry_bytes := 0


func run() -> void:
	var padded_cell_colors := _snapshot(source_frame, chunk_location)
	source_frame = null
	var vertex_positions := PackedVector3Array()
	var vertex_normals := PackedVector3Array()
	var vertex_colors := PackedColorArray()
	var triangle_indices := PackedInt32Array()
	var face_colors := PackedColorArray()
	face_colors.resize(CHUNK_SIZE * CHUNK_SIZE)
	for face_axis in 3:
		var column_axis := (face_axis + 1) % 3
		var row_axis := (face_axis + 2) % 3
		for face_sign in [-1, 1]:
			var face_normal := Vector3.ZERO
			face_normal[face_axis] = face_sign
			for layer_index in CHUNK_SIZE:
				for row in CHUNK_SIZE:
					for column in CHUNK_SIZE:
						var sample_position := Vector3i.ONE
						sample_position[face_axis] += layer_index
						sample_position[column_axis] += column
						sample_position[row_axis] += row
						var voxel_color := padded_cell_colors[sample_position.x + PADDED_CHUNK_SIZE * (sample_position.y + PADDED_CHUNK_SIZE * sample_position.z)]
						sample_position[face_axis] += face_sign
						var neighbor_color := padded_cell_colors[sample_position.x + PADDED_CHUNK_SIZE * (sample_position.y + PADDED_CHUNK_SIZE * sample_position.z)]
						face_colors[column + CHUNK_SIZE * row] = voxel_color if voxel_color != Color.TRANSPARENT and neighbor_color.a < 1.0 and neighbor_color != voxel_color else Color.TRANSPARENT
				var row := 0
				while row < CHUNK_SIZE:
					var column := 0
					while column < CHUNK_SIZE:
						var face_color := face_colors[column + CHUNK_SIZE * row]
						if face_color == Color.TRANSPARENT:
							column += 1
							continue
						var quad_width := 1
						while column + quad_width < CHUNK_SIZE and face_colors[column + quad_width + CHUNK_SIZE * row] == face_color:
							quad_width += 1
						var quad_height := 1
						var row_matches := true
						while row + quad_height < CHUNK_SIZE and row_matches:
							for column_offset in quad_width:
								if face_colors[column + column_offset + CHUNK_SIZE * (row + quad_height)] != face_color:
									row_matches = false
									break
							if row_matches:
								quad_height += 1
						var face_origin := Vector3.ZERO
						face_origin[face_axis] = layer_index + face_sign * 0.5
						face_origin[column_axis] = column - 0.5
						face_origin[row_axis] = row - 0.5
						var column_edge := Vector3.ZERO
						var row_edge := Vector3.ZERO
						column_edge[column_axis] = quad_width
						row_edge[row_axis] = quad_height
						var first_vertex := vertex_positions.size()
						vertex_positions.append_array(PackedVector3Array([face_origin, face_origin + column_edge, face_origin + column_edge + row_edge, face_origin + row_edge]))
						for _vertex_corner in 4:
							vertex_normals.append(face_normal)
							vertex_colors.append(face_color)
						if face_sign > 0:
							triangle_indices.append_array(PackedInt32Array([first_vertex, first_vertex + 2, first_vertex + 1, first_vertex, first_vertex + 3, first_vertex + 2]))
						else:
							triangle_indices.append_array(PackedInt32Array([first_vertex, first_vertex + 1, first_vertex + 2, first_vertex, first_vertex + 2, first_vertex + 3]))
						for row_offset in quad_height:
							for column_offset in quad_width:
								face_colors[column + column_offset + CHUNK_SIZE * (row + row_offset)] = Color.TRANSPARENT
						column += quad_width
					row += 1
	surface_arrays.resize(Mesh.ARRAY_MAX)
	surface_arrays[Mesh.ARRAY_VERTEX] = vertex_positions
	surface_arrays[Mesh.ARRAY_NORMAL] = vertex_normals
	surface_arrays[Mesh.ARRAY_COLOR] = vertex_colors
	surface_arrays[Mesh.ARRAY_INDEX] = triangle_indices
	geometry_bytes = vertex_positions.size() * 40 + triangle_indices.size() * 4


static func _snapshot(source_frame: VoxelFrame, chunk_location: Vector3i) -> PackedColorArray:
	var padded_cell_colors := PackedColorArray()
	padded_cell_colors.resize(PADDED_CHUNK_SIZE * PADDED_CHUNK_SIZE * PADDED_CHUNK_SIZE)
	padded_cell_colors.fill(Color.TRANSPARENT)
	var padded_origin := chunk_location * CHUNK_SIZE - Vector3i.ONE
	var sampled_chunks: Array = [chunk_location]
	for direction in VoxelFrame.DIRECTIONS:
		sampled_chunks.append(chunk_location + direction)
	for sampled_location in sampled_chunks:
		var chunk: VoxelFrame.Chunk = source_frame.chunks.get(sampled_location)
		if chunk == null:
			continue
		for cell_position in chunk.cell_colors:
			var sample_position: Vector3i = cell_position - padded_origin
			if sample_position.x >= 0 and sample_position.y >= 0 and sample_position.z >= 0 and sample_position.x < PADDED_CHUNK_SIZE and sample_position.y < PADDED_CHUNK_SIZE and sample_position.z < PADDED_CHUNK_SIZE:
				padded_cell_colors[sample_position.x + PADDED_CHUNK_SIZE * (sample_position.y + PADDED_CHUNK_SIZE * sample_position.z)] = chunk.cell_colors[cell_position]
	return padded_cell_colors
