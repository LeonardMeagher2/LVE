class_name VoxelMeshBuilder
extends RefCounted

const CHUNK_SIZE := VoxelFrame.CHUNK_SIZE
const PADDED_CHUNK_SIZE := CHUNK_SIZE + 2
const SURFACE := preload("./VoxelSurface.gd")

var source_frame: VoxelFrame
var chunk_location := Vector3i.ZERO
var smooth_normals := false
var texture_materials := true
var worker_task_id := -1
var surface_arrays: Array = []
var geometry_bytes := 0
var atlas_size := Vector2i.ZERO
var atlas_albedo := PackedByteArray()
var atlas_orm := PackedByteArray()
var atlas_emission := PackedByteArray()
var atlas: RefCounted


func run() -> void:
	var frame := source_frame
	var snapshot := _snapshot(source_frame, chunk_location, smooth_normals)
	var padded_cell_colors: PackedColorArray = snapshot[0]
	var padded_cell_materials: PackedInt32Array = snapshot[1]
	var materials: PackedFloat32Array = snapshot[2]
	source_frame = null
	var vertex_positions := PackedVector3Array()
	var vertex_normals := PackedVector3Array()
	var vertex_colors := PackedColorArray()
	var triangle_indices := PackedInt32Array()
	var face_materials := PackedInt32Array()
	var corner_normals := {}
	face_materials.resize(CHUNK_SIZE * CHUNK_SIZE)
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
						var sample_index := sample_position.x + PADDED_CHUNK_SIZE * (sample_position.y + PADDED_CHUNK_SIZE * sample_position.z)
						var voxel_color := padded_cell_colors[sample_index]
						sample_position[face_axis] += face_sign
						var neighbor_color := padded_cell_colors[sample_position.x + PADDED_CHUNK_SIZE * (sample_position.y + PADDED_CHUNK_SIZE * sample_position.z)]
						face_materials[column + CHUNK_SIZE * row] = padded_cell_materials[sample_index] if voxel_color != Color.TRANSPARENT and neighbor_color.a < 1.0 and neighbor_color != voxel_color else 0
				var row := 0
				while row < CHUNK_SIZE:
					var column := 0
					while column < CHUNK_SIZE:
						var material_id := face_materials[column + CHUNK_SIZE * row]
						if material_id == 0:
							column += 1
							continue
						var quad_width := 1
						while not smooth_normals and column + quad_width < CHUNK_SIZE and face_materials[column + quad_width + CHUNK_SIZE * row] == material_id:
							quad_width += 1
						var quad_height := 1
						var row_matches := true
						while not smooth_normals and row + quad_height < CHUNK_SIZE and row_matches:
							for column_offset in quad_width:
								var next_material := face_materials[column + column_offset + CHUNK_SIZE * (row + quad_height)]
								if next_material != material_id:
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
						var base := material_id * VoxelFrame.MATERIAL_STRIDE
						var face_color := Color(materials[base], materials[base + 1], materials[base + 2], materials[base + 3])
						vertex_positions.append_array(PackedVector3Array([face_origin, face_origin + column_edge, face_origin + column_edge + row_edge, face_origin + row_edge]))
						for vertex_corner in 4:
							var normal := face_normal
							if smooth_normals:
								var corner := Vector3i(vertex_positions[first_vertex + vertex_corner].floor())
								if not corner_normals.has(corner):
									corner_normals[corner] = _corner_normal(corner, padded_cell_colors)
								normal = corner_normals[corner]
								if normal.is_zero_approx():
									normal = face_normal
							vertex_normals.append(normal)
							vertex_colors.append(face_color)
						if face_sign > 0:
							triangle_indices.append_array(PackedInt32Array([first_vertex, first_vertex + 2, first_vertex + 1, first_vertex, first_vertex + 3, first_vertex + 2]))
						else:
							triangle_indices.append_array(PackedInt32Array([first_vertex, first_vertex + 1, first_vertex + 2, first_vertex, first_vertex + 2, first_vertex + 3]))
						for row_offset in quad_height:
							for column_offset in quad_width:
								face_materials[column + column_offset + CHUNK_SIZE * (row + row_offset)] = 0
						column += quad_width
					row += 1
	surface_arrays.resize(Mesh.ARRAY_MAX)
	surface_arrays[Mesh.ARRAY_VERTEX] = vertex_positions
	surface_arrays[Mesh.ARRAY_NORMAL] = vertex_normals
	surface_arrays[Mesh.ARRAY_COLOR] = vertex_colors
	surface_arrays[Mesh.ARRAY_INDEX] = triangle_indices
	geometry_bytes = vertex_positions.size() * 40 + triangle_indices.size() * 4
	if texture_materials:
		# Use the same seam-bounded planar cleanup and bake as the full-frame exporter.
		var surface := SURFACE.new()
		surface.run(surface_arrays, frame, Vector3(chunk_location * CHUNK_SIZE))
		surface_arrays = surface.arrays
		atlas = surface.atlas
		atlas_size = atlas.size
		if atlas.albedo:
			atlas_albedo = atlas.albedo.get_data()
			atlas_orm = atlas.orm.get_data()
			atlas_emission = atlas.emission.get_data()
		geometry_bytes = surface_arrays[Mesh.ARRAY_VERTEX].size() * 32 + surface_arrays[Mesh.ARRAY_INDEX].size() * 4


static func neighbor_offsets(use_smooth_normals: bool) -> Array[Vector3i]:
	var offsets: Array[Vector3i] = [Vector3i.ZERO]
	if not use_smooth_normals:
		offsets.append_array(VoxelFrame.DIRECTIONS)
		return offsets
	for z in range(-1, 2):
		for y in range(-1, 2):
			for x in range(-1, 2):
				var offset := Vector3i(x, y, z)
				if offset != Vector3i.ZERO:
					offsets.append(offset)
	return offsets


static func _corner_normal(corner: Vector3i, padded_cell_colors: PackedColorArray) -> Vector3:
	var normal := Vector3.ZERO
	for z in 2:
		for y in 2:
			for x in 2:
				var sample := corner + Vector3i.ONE + Vector3i(x, y, z)
				if padded_cell_colors[sample.x + PADDED_CHUNK_SIZE * (sample.y + PADDED_CHUNK_SIZE * sample.z)] != Color.TRANSPARENT:
					normal += Vector3(0.5 - x, 0.5 - y, 0.5 - z)
	return normal.normalized()


static func _snapshot(frame: VoxelFrame, location: Vector3i, use_smooth_normals: bool) -> Array:
	var padded_cell_colors := PackedColorArray()
	padded_cell_colors.resize(PADDED_CHUNK_SIZE * PADDED_CHUNK_SIZE * PADDED_CHUNK_SIZE)
	padded_cell_colors.fill(Color.TRANSPARENT)
	var padded_cell_materials := PackedInt32Array()
	padded_cell_materials.resize(padded_cell_colors.size())
	var materials := VoxelFrame.material(Color.TRANSPARENT)
	var material_ids := {}
	var padded_origin := location * CHUNK_SIZE - Vector3i.ONE
	for offset in neighbor_offsets(use_smooth_normals):
		var neighbor: VoxelFrame.Chunk = frame.chunks.get(location + offset)
		if neighbor == null:
			continue
		for cell_position in neighbor.cells:
			var sample_position: Vector3i = cell_position - padded_origin
			if sample_position.x >= 0 and sample_position.y >= 0 and sample_position.z >= 0 and sample_position.x < PADDED_CHUNK_SIZE and sample_position.y < PADDED_CHUNK_SIZE and sample_position.z < PADDED_CHUNK_SIZE:
				var sample_index := sample_position.x + PADDED_CHUNK_SIZE * (sample_position.y + PADDED_CHUNK_SIZE * sample_position.z)
				var slot: int = neighbor.cells[cell_position]
				var base := slot * VoxelFrame.MATERIAL_STRIDE
				padded_cell_colors[sample_index] = Color(neighbor.materials[base], neighbor.materials[base + 1], neighbor.materials[base + 2], neighbor.materials[base + 3])
				if offset != Vector3i.ZERO:
					continue
				var cell_material := neighbor.materials.slice(base, base + VoxelFrame.MATERIAL_STRIDE)
				var material_id: int = material_ids.get(cell_material, -1)
				if material_id < 0:
					material_id = materials.size() / VoxelFrame.MATERIAL_STRIDE
					material_ids[cell_material] = material_id
					materials.append_array(cell_material)
				padded_cell_materials[sample_index] = material_id
	return [padded_cell_colors, padded_cell_materials, materials]
