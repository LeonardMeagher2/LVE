class_name VoxelMeshBuilder
extends RefCounted


const CHUNK_SIZE := VoxelFrame.CHUNK_SIZE
const PADDED_CHUNK_SIZE := CHUNK_SIZE + 2
const PADDED_AXIS_STRIDE := [1, PADDED_CHUNK_SIZE, PADDED_CHUNK_SIZE * PADDED_CHUNK_SIZE]
const PADDED_ORIGIN := 1 + PADDED_CHUNK_SIZE * (1 + PADDED_CHUNK_SIZE)
const SURFACE := preload("./VoxelSurface.gd")

var source_frame: VoxelFrame
var chunk_location := Vector3i.ZERO
var low_poly := false
var shared_atlas: RefCounted
var shared_uvs := {}
var smooth_normals := false
var ao_strength := 0.0
var texture_materials := true
var slice_axis := -1
var slice_index := 0
var slice_count := 1
var worker_task_id := -1
var surface_arrays: Array = []
var geometry_bytes := 0
var atlas_size := Vector2i.ZERO
var atlas_albedo := PackedByteArray()
var atlas_orm := PackedByteArray()
var atlas_emission := PackedByteArray()
var atlas: RefCounted
var enclosed_shortcut := true
var enclosed_culled := false
var profile := false
var snapshot_us := 0
var scan_us := 0
var finish_us := 0
var snapshot_chunks := 0
var snapshot_cells := 0
var snapshot_decodes := 0
var scan_queries := 0
var group_count := 0


func run() -> void:
	if low_poly:
		var low_poly_started_us := Time.get_ticks_usec() if profile else 0
		var mesher := VoxelLowPolyMesh.new()
		mesher.smooth_normals = smooth_normals
		mesher.ao_strength = ao_strength
		mesher.build_region(source_frame, chunk_location * CHUNK_SIZE, Vector3i.ONE * CHUNK_SIZE, shared_atlas, shared_uvs)
		surface_arrays = mesher.arrays
		atlas = mesher.atlas
		atlas_size = atlas.size if atlas != null else Vector2i.ZERO
		if atlas != null and atlas.albedo:
			atlas_albedo = atlas.albedo.get_data()
			atlas_orm = atlas.orm.get_data()
			atlas_emission = atlas.emission.get_data()
		geometry_bytes = surface_arrays[Mesh.ARRAY_VERTEX].size() * 48 + surface_arrays[Mesh.ARRAY_INDEX].size() * 4
		if profile:
			scan_us += Time.get_ticks_usec() - low_poly_started_us
		source_frame = null
		return
	var frame := source_frame
	if enclosed_shortcut and slice_axis < 0 and frame != null and _enclosed(frame, chunk_location):
		enclosed_culled = true
		source_frame = null
		_finish_enclosed(frame)
		return
	var snapshot_started_us := Time.get_ticks_usec() if profile else 0
	var snapshot := _snapshot(source_frame, chunk_location, smooth_normals or ao_strength > 0.0, profile, slice_axis, slice_index, slice_count)
	var padded_cell_colors: PackedColorArray = snapshot[0]
	var padded_cell_materials: PackedInt32Array = snapshot[1]
	var materials: PackedFloat32Array = snapshot[2]
	var occupied_planes: PackedInt32Array = snapshot[3]
	if profile:
		snapshot_us += Time.get_ticks_usec() - snapshot_started_us
		var reads: Array = snapshot[4]
		snapshot_chunks += reads[0]
		snapshot_cells += reads[1]
		snapshot_decodes += reads[2]
		scan_queries += _scan_query_count(occupied_planes)
	var chunk: VoxelFrame.Chunk = frame.chunks.get(chunk_location) if frame != null else null
	var sparse := chunk != null and chunk.is_sparse()
	var sparse_layers: Array = _sparse_layers(chunk) if sparse else []
	source_frame = null
	if texture_materials and frame != null:
		var collect_started_us := Time.get_ticks_usec() if profile else 0
		var groups: Dictionary
		if sparse:
			groups = _collect_groups_sparse(sparse_layers, padded_cell_colors, padded_cell_materials, materials, occupied_planes, ao_strength)
		else:
			groups = _collect_groups(padded_cell_colors, padded_cell_materials, materials, occupied_planes, ao_strength)
		if profile:
			scan_us += Time.get_ticks_usec() - collect_started_us
			group_count += groups.size()
		var surface_started_us := Time.get_ticks_usec() if profile else 0
		var surface := SURFACE.new()
		surface.run_groups(groups, frame, Vector3(chunk_location * CHUNK_SIZE), Callable(), smooth_normals, padded_cell_materials, ao_strength)
		if profile:
			finish_us += Time.get_ticks_usec() - surface_started_us
		surface_arrays = surface.arrays
		atlas = surface.atlas
		atlas_size = atlas.size
		if atlas.albedo:
			atlas_albedo = atlas.albedo.get_data()
			atlas_orm = atlas.orm.get_data()
			atlas_emission = atlas.emission.get_data()
		geometry_bytes = surface_arrays[Mesh.ARRAY_VERTEX].size() * (48 if ao_strength > 0.0 else 32) + surface_arrays[Mesh.ARRAY_INDEX].size() * 4
		return
	var greedy_started_us := Time.get_ticks_usec() if profile else 0
	var greedy: Array
	if sparse:
		greedy = _greedy_sparse(chunk, sparse_layers, padded_cell_colors, padded_cell_materials, materials, occupied_planes)
	else:
		greedy = _greedy_dense(padded_cell_colors, padded_cell_materials, materials, occupied_planes)
	if profile:
		scan_us += Time.get_ticks_usec() - greedy_started_us
	var vertex_positions: PackedVector3Array = greedy[0]
	var vertex_normals: PackedVector3Array = greedy[1]
	var vertex_colors: PackedColorArray = greedy[2]
	var triangle_indices: PackedInt32Array = greedy[3]
	surface_arrays.resize(Mesh.ARRAY_MAX)
	surface_arrays[Mesh.ARRAY_VERTEX] = vertex_positions
	surface_arrays[Mesh.ARRAY_NORMAL] = vertex_normals
	surface_arrays[Mesh.ARRAY_COLOR] = vertex_colors
	surface_arrays[Mesh.ARRAY_INDEX] = triangle_indices
	geometry_bytes = vertex_positions.size() * 40 + triangle_indices.size() * 4
	if texture_materials:
		var surface_started_us := Time.get_ticks_usec() if profile else 0
		var surface := SURFACE.new()
		surface.run(surface_arrays, frame, Vector3(chunk_location * CHUNK_SIZE), Callable(), smooth_normals, ao_strength)
		if profile:
			finish_us += Time.get_ticks_usec() - surface_started_us
		surface_arrays = surface.arrays
		atlas = surface.atlas
		atlas_size = atlas.size
		if atlas.albedo:
			atlas_albedo = atlas.albedo.get_data()
			atlas_orm = atlas.orm.get_data()
			atlas_emission = atlas.emission.get_data()
		geometry_bytes = surface_arrays[Mesh.ARRAY_VERTEX].size() * (48 if ao_strength > 0.0 else 32) + surface_arrays[Mesh.ARRAY_INDEX].size() * 4


func _greedy_dense(padded_cell_colors: PackedColorArray, padded_cell_materials: PackedInt32Array, materials: PackedFloat32Array, occupied_planes: PackedInt32Array) -> Array:
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
		var column_stride: int = PADDED_AXIS_STRIDE[column_axis]
		var row_stride: int = PADDED_AXIS_STRIDE[row_axis]
		var face_stride: int = PADDED_AXIS_STRIDE[face_axis]
		for face_sign: int in [-1, 1]:
			var neighbor_step := face_sign * face_stride
			var face_normal := Vector3.ZERO
			face_normal[face_axis] = face_sign
			for layer_index in CHUNK_SIZE:
				if occupied_planes[face_axis] & (1 << (layer_index + 1)) == 0:
					continue
				var layer_base := PADDED_ORIGIN + layer_index * face_stride
				for row in CHUNK_SIZE:
					var row_base := layer_base + row * row_stride
					for column in CHUNK_SIZE:
						var sample_index := row_base + column * column_stride
						var voxel_color := padded_cell_colors[sample_index]
						var neighbor_color := padded_cell_colors[sample_index + neighbor_step]
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
						while column + quad_width < CHUNK_SIZE and face_materials[column + quad_width + CHUNK_SIZE * row] == material_id:
							quad_width += 1
						var quad_height := 1
						var row_matches := true
						while row + quad_height < CHUNK_SIZE and row_matches:
							for column_offset in quad_width:
								var next_material := face_materials[column + column_offset + CHUNK_SIZE * (row + quad_height)]
								if next_material != material_id:
									row_matches = false
									break
							if row_matches:
								quad_height += 1
						_emit_quad(face_axis, face_sign, layer_index, column_axis, row_axis, column, row, quad_width, quad_height, material_id, face_normal, materials, padded_cell_colors, corner_normals, vertex_positions, vertex_normals, vertex_colors, triangle_indices)
						for row_offset in quad_height:
							for column_offset in quad_width:
								face_materials[column + column_offset + CHUNK_SIZE * (row + row_offset)] = 0
						column += quad_width
					row += 1
	return [vertex_positions, vertex_normals, vertex_colors, triangle_indices]


func _greedy_sparse(chunk: VoxelFrame.Chunk, layers: Array, padded_cell_colors: PackedColorArray, padded_cell_materials: PackedInt32Array, materials: PackedFloat32Array, occupied_planes: PackedInt32Array) -> Array:
	var vertex_positions := PackedVector3Array()
	var vertex_normals := PackedVector3Array()
	var vertex_colors := PackedColorArray()
	var triangle_indices := PackedInt32Array()
	var face_materials := PackedInt32Array()
	var face_mask := PackedInt32Array()
	var corner_normals := {}
	face_materials.resize(CHUNK_SIZE * CHUNK_SIZE)
	face_mask.resize(CHUNK_SIZE)
	for face_axis in 3:
		var column_axis := (face_axis + 1) % 3
		var row_axis := (face_axis + 2) % 3
		var column_stride: int = PADDED_AXIS_STRIDE[column_axis]
		var row_stride: int = PADDED_AXIS_STRIDE[row_axis]
		var face_stride: int = PADDED_AXIS_STRIDE[face_axis]
		var layer_cells: Dictionary = layers[face_axis]
		for face_sign: int in [-1, 1]:
			var neighbor_step := face_sign * face_stride
			var face_normal := Vector3.ZERO
			face_normal[face_axis] = face_sign
			for layer_index in CHUNK_SIZE:
				if occupied_planes[face_axis] & (1 << (layer_index + 1)) == 0:
					continue
				var cells: Array = layer_cells.get(layer_index, [])
				if cells.is_empty():
					continue
				face_mask.fill(0)
				for cell: Vector3i in cells:
					if not _cell_in_slice(cell):
						continue
					var sample_index := PADDED_ORIGIN + cell.x * PADDED_AXIS_STRIDE[0] + cell.y * PADDED_AXIS_STRIDE[1] + cell.z * PADDED_AXIS_STRIDE[2]
					var voxel_color := padded_cell_colors[sample_index]
					if voxel_color == Color.TRANSPARENT:
						continue
					var neighbor_color := padded_cell_colors[sample_index + neighbor_step]
					if not (neighbor_color.a < 1.0 and neighbor_color != voxel_color):
						continue
					var material_id := padded_cell_materials[sample_index]
					if material_id == 0:
						continue
					var column := cell[column_axis]
					var row := cell[row_axis]
					face_materials[column + CHUNK_SIZE * row] = material_id
					face_mask[row] |= 1 << column
				var row := 0
				while row < CHUNK_SIZE:
					var row_mask := face_mask[row]
					if row_mask == 0:
						row += 1
						continue
					var column := 0
					while column < CHUNK_SIZE:
						var remaining := row_mask >> column
						if remaining == 0:
							break
						column += VoxelFrame.Chunk.first_column(remaining)
						var material_id := face_materials[column + CHUNK_SIZE * row]
						var quad_width := 1
						while column + quad_width < CHUNK_SIZE and face_materials[column + quad_width + CHUNK_SIZE * row] == material_id:
							quad_width += 1
						var quad_height := 1
						var row_matches := true
						while row + quad_height < CHUNK_SIZE and row_matches:
							for column_offset in quad_width:
								var next_material := face_materials[column + column_offset + CHUNK_SIZE * (row + quad_height)]
								if next_material != material_id:
									row_matches = false
									break
							if row_matches:
								quad_height += 1
						_emit_quad(face_axis, face_sign, layer_index, column_axis, row_axis, column, row, quad_width, quad_height, material_id, face_normal, materials, padded_cell_colors, corner_normals, vertex_positions, vertex_normals, vertex_colors, triangle_indices)
						for row_offset in quad_height:
							for column_offset in quad_width:
								face_materials[column + column_offset + CHUNK_SIZE * (row + row_offset)] = 0
								face_mask[row + row_offset] &= ~(1 << (column + column_offset))
						column += quad_width
					row += 1
	return [vertex_positions, vertex_normals, vertex_colors, triangle_indices]


func _emit_quad(face_axis: int, face_sign: int, layer_index: int, column_axis: int, row_axis: int, column: int, row: int, quad_width: int, quad_height: int, material_id: int, face_normal: Vector3, materials: PackedFloat32Array, padded_cell_colors: PackedColorArray, corner_normals: Dictionary, vertex_positions: PackedVector3Array, vertex_normals: PackedVector3Array, vertex_colors: PackedColorArray, triangle_indices: PackedInt32Array) -> void:
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
	vertex_positions.resize(first_vertex + 4)
	vertex_positions[first_vertex] = face_origin
	vertex_positions[first_vertex + 1] = face_origin + column_edge
	vertex_positions[first_vertex + 2] = face_origin + column_edge + row_edge
	vertex_positions[first_vertex + 3] = face_origin + row_edge
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
	var index_start := triangle_indices.size()
	triangle_indices.resize(index_start + 6)
	if face_sign > 0:
		triangle_indices[index_start] = first_vertex
		triangle_indices[index_start + 1] = first_vertex + 2
		triangle_indices[index_start + 2] = first_vertex + 1
		triangle_indices[index_start + 3] = first_vertex
		triangle_indices[index_start + 4] = first_vertex + 3
		triangle_indices[index_start + 5] = first_vertex + 2
	else:
		triangle_indices[index_start] = first_vertex
		triangle_indices[index_start + 1] = first_vertex + 1
		triangle_indices[index_start + 2] = first_vertex + 2
		triangle_indices[index_start + 3] = first_vertex
		triangle_indices[index_start + 4] = first_vertex + 2
		triangle_indices[index_start + 5] = first_vertex + 3


static func _sparse_layers(chunk: VoxelFrame.Chunk) -> Array:
	var layers: Array = [{}, {}, {}]
	var rows := chunk.occupancy_rows()
	for row in rows.masks.size():
		var mask := rows.masks[row]
		if mask == 0:
			continue
		var local_y := row % CHUNK_SIZE
		var local_z := row / CHUNK_SIZE
		while mask != 0:
			var local_x := VoxelFrame.Chunk.first_column(mask)
			mask &= mask - 1
			var cell := Vector3i(local_x, local_y, local_z)
			for axis in 3:
				var layer: int = cell[axis]
				var cells: Array = layers[axis].get(layer, [])
				cells.append(cell)
				layers[axis][layer] = cells
	for axis in 3:
		var row_axis := (axis + 2) % 3
		var column_axis := (axis + 1) % 3
		for layer in layers[axis]:
			layers[axis][layer].sort_custom(func(first: Vector3i, second: Vector3i) -> bool:
				if first[row_axis] != second[row_axis]:
					return first[row_axis] < second[row_axis]
				return first[column_axis] < second[column_axis]
			)
	return layers


func _cell_in_slice(cell: Vector3i) -> bool:
	if slice_axis < 0:
		return true
	var layer := cell[slice_axis] + chunk_location[slice_axis] * CHUNK_SIZE
	return layer >= slice_index and layer < slice_index + slice_count


func _finish_enclosed(frame: VoxelFrame) -> void:
	if texture_materials and frame != null:
		var surface := SURFACE.new()
		surface.run_groups({}, frame, Vector3(chunk_location * CHUNK_SIZE), Callable(), smooth_normals, null, ao_strength)
		surface_arrays = surface.arrays
		atlas = surface.atlas
		atlas_size = atlas.size
		if atlas.albedo:
			atlas_albedo = atlas.albedo.get_data()
			atlas_orm = atlas.orm.get_data()
			atlas_emission = atlas.emission.get_data()
		geometry_bytes = surface_arrays[Mesh.ARRAY_VERTEX].size() * (48 if ao_strength > 0.0 else 32) + surface_arrays[Mesh.ARRAY_INDEX].size() * 4
		return
	surface_arrays.resize(Mesh.ARRAY_MAX)
	surface_arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array()
	surface_arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array()
	surface_arrays[Mesh.ARRAY_COLOR] = PackedColorArray()
	surface_arrays[Mesh.ARRAY_INDEX] = PackedInt32Array()
	geometry_bytes = 0
	if texture_materials:
		var surface := SURFACE.new()
		surface.run(surface_arrays, frame, Vector3(chunk_location * CHUNK_SIZE), Callable(), smooth_normals, ao_strength)
		surface_arrays = surface.arrays
		atlas = surface.atlas
		atlas_size = atlas.size
		if atlas.albedo:
			atlas_albedo = atlas.albedo.get_data()
			atlas_orm = atlas.orm.get_data()
			atlas_emission = atlas.emission.get_data()
		geometry_bytes = surface_arrays[Mesh.ARRAY_VERTEX].size() * (48 if ao_strength > 0.0 else 32) + surface_arrays[Mesh.ARRAY_INDEX].size() * 4


static func _enclosed(frame: VoxelFrame, location: Vector3i) -> bool:
	var cells := CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE
	var chunk: VoxelFrame.Chunk = frame.chunks.get(location)
	if chunk == null or chunk.occupied_count != cells:
		return false
	for axis in 3:
		for direction in [1, -1]:
			var neighbor_location := location
			neighbor_location[axis] += direction
			var neighbor: VoxelFrame.Chunk = frame.chunks.get(neighbor_location)
			if neighbor == null or neighbor.occupied_count != cells:
				return false
			if not _opaque_plane(neighbor, axis, 0 if direction > 0 else CHUNK_SIZE - 1):
				return false
	return _opaque_materials(chunk)


static func _opaque_plane(neighbor: VoxelFrame.Chunk, axis: int, layer: int) -> bool:
	var grid := neighbor.grid
	var materials := neighbor.materials
	var first_axis := (axis + 1) % 3
	var second_axis := (axis + 2) % 3
	var first_stride := 1 if first_axis == 0 else (CHUNK_SIZE if first_axis == 1 else CHUNK_SIZE * CHUNK_SIZE)
	var second_stride := 1 if second_axis == 0 else (CHUNK_SIZE if second_axis == 1 else CHUNK_SIZE * CHUNK_SIZE)
	var base := layer * (1 if axis == 0 else (CHUNK_SIZE if axis == 1 else CHUNK_SIZE * CHUNK_SIZE))
	for first in CHUNK_SIZE:
		var row := base + first * first_stride
		for second in CHUNK_SIZE:
			var id := grid[row + second * second_stride]
			if id <= 0:
				return false
			if materials[(id - 1) * VoxelFrame.MATERIAL_STRIDE + 3] < 1.0:
				return false
	return true


static func _opaque_materials(chunk: VoxelFrame.Chunk) -> bool:
	var materials := chunk.materials
	var index := 3
	while index < materials.size():
		if materials[index] < 1.0:
			return false
		index += VoxelFrame.MATERIAL_STRIDE
	return true


func _collect_groups(padded_cell_colors: PackedColorArray, padded_cell_materials: PackedInt32Array, materials: PackedFloat32Array, occupied_planes: PackedInt32Array, ao_strength := 0.0) -> Dictionary:
	var groups := {}
	var material_cache := {}
	var canonical_cache := {}
	var canonical_by_id := {}
	var next_canonical := 0
	var use_ao := ao_strength > 0.0
	for face_axis in 3:
		var column_stride: int = PADDED_AXIS_STRIDE[(face_axis + 1) % 3]
		var row_stride: int = PADDED_AXIS_STRIDE[(face_axis + 2) % 3]
		var face_stride: int = PADDED_AXIS_STRIDE[face_axis]
		for face_sign: int in [-1, 1]:
			var neighbor_step := face_sign * face_stride
			for layer_index in CHUNK_SIZE:
				if occupied_planes[face_axis] & (1 << (layer_index + 1)) == 0:
					continue
				var layer_base := PADDED_ORIGIN + layer_index * face_stride
				for row in CHUNK_SIZE:
					var row_base := layer_base + row * row_stride
					for column in CHUNK_SIZE:
						var sample_index := row_base + column * column_stride
						var voxel_color := padded_cell_colors[sample_index]
						if voxel_color == Color.TRANSPARENT:
							continue
						var neighbor_color := padded_cell_colors[sample_index + neighbor_step]
						if not (neighbor_color.a < 1.0 and neighbor_color != voxel_color):
							continue
						var material_id := padded_cell_materials[sample_index]
						var material: PackedFloat32Array
						if material_cache.has(material_id):
							material = material_cache[material_id]
						else:
							material = materials.slice(material_id * VoxelFrame.MATERIAL_STRIDE, (material_id + 1) * VoxelFrame.MATERIAL_STRIDE)
							material_cache[material_id] = material
							if canonical_cache.has(material):
								canonical_by_id[material_id] = canonical_cache[material]
							else:
								canonical_cache[material] = next_canonical
								canonical_by_id[material_id] = next_canonical
								next_canonical += 1
						var plane := Vector3i(face_axis, face_sign, 2 * layer_index + face_sign)
						var ao_code := -1
						if use_ao:
							ao_code = _face_ao_code(padded_cell_materials, sample_index + neighbor_step, column_stride, row_stride)
						var plane_index := face_axis * 64 + (32 if face_sign > 0 else 0) + layer_index
						var key := Vector3i(plane_index, ao_code + 1, canonical_by_id[material_id])
						if not groups.has(key):
							groups[key] = {"plane": plane, "material": material, "cells": {}, "normals": {}, "corners": {}}
						var group: Dictionary = groups[key]
						group.cells[Vector2i(column, row)] = true
						if use_ao:
							SURFACE._store_ao_corners(group.corners, Vector2i(column, row), ao_code)
	return groups


func _collect_groups_sparse(layers: Array, padded_cell_colors: PackedColorArray, padded_cell_materials: PackedInt32Array, materials: PackedFloat32Array, occupied_planes: PackedInt32Array, ao_strength := 0.0) -> Dictionary:
	var groups := {}
	var material_cache := {}
	var canonical_cache := {}
	var canonical_by_id := {}
	var next_canonical := 0
	var use_ao := ao_strength > 0.0
	for face_axis in 3:
		var column_axis := (face_axis + 1) % 3
		var row_axis := (face_axis + 2) % 3
		var column_stride: int = PADDED_AXIS_STRIDE[column_axis]
		var row_stride: int = PADDED_AXIS_STRIDE[row_axis]
		var face_stride: int = PADDED_AXIS_STRIDE[face_axis]
		var layer_cells: Dictionary = layers[face_axis]
		for face_sign: int in [-1, 1]:
			var neighbor_step := face_sign * face_stride
			for layer_index in CHUNK_SIZE:
				if occupied_planes[face_axis] & (1 << (layer_index + 1)) == 0:
					continue
				var cells: Array = layer_cells.get(layer_index, [])
				for cell: Vector3i in cells:
					if not _cell_in_slice(cell):
						continue
					var sample_index := PADDED_ORIGIN + cell.x * PADDED_AXIS_STRIDE[0] + cell.y * PADDED_AXIS_STRIDE[1] + cell.z * PADDED_AXIS_STRIDE[2]
					var voxel_color := padded_cell_colors[sample_index]
					if voxel_color == Color.TRANSPARENT:
						continue
					var neighbor_color := padded_cell_colors[sample_index + neighbor_step]
					if not (neighbor_color.a < 1.0 and neighbor_color != voxel_color):
						continue
					var material_id := padded_cell_materials[sample_index]
					if material_id == 0:
						continue
					var material: PackedFloat32Array
					if material_cache.has(material_id):
						material = material_cache[material_id]
					else:
						material = materials.slice(material_id * VoxelFrame.MATERIAL_STRIDE, (material_id + 1) * VoxelFrame.MATERIAL_STRIDE)
						material_cache[material_id] = material
						if canonical_cache.has(material):
							canonical_by_id[material_id] = canonical_cache[material]
						else:
							canonical_cache[material] = next_canonical
							canonical_by_id[material_id] = next_canonical
							next_canonical += 1
					var plane := Vector3i(face_axis, face_sign, 2 * layer_index + face_sign)
					var ao_code := -1
					if use_ao:
						ao_code = _face_ao_code(padded_cell_materials, sample_index + neighbor_step, column_stride, row_stride)
					var plane_index := face_axis * 64 + (32 if face_sign > 0 else 0) + layer_index
					var key := Vector3i(plane_index, ao_code + 1, canonical_by_id[material_id])
					if not groups.has(key):
						groups[key] = {"plane": plane, "material": material, "cells": {}, "normals": {}, "corners": {}}
					var group: Dictionary = groups[key]
					group.cells[Vector2i(cell[column_axis], cell[row_axis])] = true
					if use_ao:
						SURFACE._store_ao_corners(group.corners, Vector2i(cell[column_axis], cell[row_axis]), ao_code)
	return groups


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


static func _face_ao_code(padded_cell_materials: PackedInt32Array, outside: int, column_stride: int, row_stride: int) -> int:
	var code := 0
	for index in 4:
		var far_column := -1 if (index & 1) == 0 else 1
		var far_row := -1 if (index & 2) == 0 else 1
		var side1 := outside + column_stride * far_column
		var side2 := outside + row_stride * far_row
		var diagonal := outside + column_stride * far_column + row_stride * far_row
		var level: int = SURFACE._ao_level(padded_cell_materials[side1] != 0, padded_cell_materials[side2] != 0, padded_cell_materials[diagonal] != 0)
		code |= level << (index * 2)
	return code


static func _corner_normal(corner: Vector3i, padded_cell_colors: PackedColorArray) -> Vector3:
	var normal := Vector3.ZERO
	for z in 2:
		for y in 2:
			for x in 2:
				var sample := corner + Vector3i.ONE + Vector3i(x, y, z)
				if padded_cell_colors[sample.x + PADDED_CHUNK_SIZE * (sample.y + PADDED_CHUNK_SIZE * sample.z)] != Color.TRANSPARENT:
					normal += Vector3(0.5 - x, 0.5 - y, 0.5 - z)
	return normal.normalized()


static func _snapshot(frame: VoxelFrame, location: Vector3i, use_smooth_normals: bool, count_reads := false, slice_axis := -1, slice_index := 0, slice_count := 1) -> Array:
	var padded_cell_colors := PackedColorArray()
	padded_cell_colors.resize(PADDED_CHUNK_SIZE * PADDED_CHUNK_SIZE * PADDED_CHUNK_SIZE)
	padded_cell_colors.fill(Color.TRANSPARENT)
	var padded_cell_materials := PackedInt32Array()
	padded_cell_materials.resize(padded_cell_colors.size())
	var materials := VoxelFrame.material(Color.TRANSPARENT)
	var material_ids := {}
	var occupied_planes := PackedInt32Array([0, 0, 0])
	var chunks_read := 0
	var cells_read := 0
	var decodes := 0
	var padded_origin := location * CHUNK_SIZE - Vector3i.ONE
	for offset in neighbor_offsets(use_smooth_normals):
		var neighbor: VoxelFrame.Chunk = frame.chunks.get(location + offset)
		if neighbor == null:
			continue
		var grid := neighbor.grid
		var neighbor_materials := neighbor.materials
		var row_ids := {}
		var origin_delta := neighbor.location * CHUNK_SIZE - padded_origin
		var x_first := maxi(0, -origin_delta.x)
		var x_last := mini(CHUNK_SIZE, PADDED_CHUNK_SIZE - origin_delta.x)
		var y_first := maxi(0, -origin_delta.y)
		var y_last := mini(CHUNK_SIZE, PADDED_CHUNK_SIZE - origin_delta.y)
		var z_first := maxi(0, -origin_delta.z)
		var z_last := mini(CHUNK_SIZE, PADDED_CHUNK_SIZE - origin_delta.z)
		if slice_axis >= 0:
			var chunk_base := (location[slice_axis] + offset[slice_axis]) * CHUNK_SIZE
			var local_first := slice_index - chunk_base
			var local_last := local_first + slice_count
			match slice_axis:
				0:
					var x_from := maxi(x_first, local_first)
					var x_to := mini(x_last, local_last)
					if x_from >= x_to:
						continue
					x_first = x_from
					x_last = x_to
				1:
					var y_from := maxi(y_first, local_first)
					var y_to := mini(y_last, local_last)
					if y_from >= y_to:
						continue
					y_first = y_from
					y_last = y_to
				_:
					var z_from := maxi(z_first, local_first)
					var z_to := mini(z_last, local_last)
					if z_from >= z_to:
						continue
					z_first = z_from
					z_last = z_to
		if count_reads:
			chunks_read += 1
		if neighbor.is_sparse():
			var rows := neighbor.occupancy_rows()
			for row in rows.masks.size():
				var mask := rows.masks[row]
				if mask == 0:
					continue
				var local_y := row % CHUNK_SIZE
				var local_z := row / CHUNK_SIZE
				if local_y < y_first or local_y >= y_last or local_z < z_first or local_z >= z_last:
					continue
				while mask != 0:
					var local_x := VoxelFrame.Chunk.first_column(mask)
					mask &= mask - 1
					if local_x < x_first or local_x >= x_last:
						continue
					var id := neighbor.cell_id_at_slot(row * CHUNK_SIZE + local_x)
					if count_reads:
						cells_read += 1
						decodes += 1
					var x_row := origin_delta.x + local_x
					var y_row := origin_delta.y + local_y
					var z_row := origin_delta.z + local_z
					var sample_index := x_row + PADDED_CHUNK_SIZE * (y_row + PADDED_CHUNK_SIZE * z_row)
					var base := (id - 1) * VoxelFrame.MATERIAL_STRIDE
					padded_cell_colors[sample_index] = Color(neighbor_materials[base], neighbor_materials[base + 1], neighbor_materials[base + 2], neighbor_materials[base + 3])
					if offset != Vector3i.ZERO:
						padded_cell_materials[sample_index] = 1
						continue
					occupied_planes[0] |= 1 << (origin_delta.x + local_x)
					occupied_planes[1] |= 1 << (origin_delta.y + local_y)
					occupied_planes[2] |= 1 << (origin_delta.z + local_z)
					var material_id: int = row_ids.get(id, -1)
					if material_id < 0:
						var cell_material := neighbor_materials.slice(base, base + VoxelFrame.MATERIAL_STRIDE)
						material_id = material_ids.get(cell_material, -1)
						if material_id < 0:
							material_id = materials.size() / VoxelFrame.MATERIAL_STRIDE
							material_ids[cell_material] = material_id
							materials.append_array(cell_material)
						row_ids[id] = material_id
					padded_cell_materials[sample_index] = material_id
			continue
		if count_reads:
			cells_read += (x_last - x_first) * (y_last - y_first) * (z_last - z_first)
		for local_z in range(z_first, z_last):
			var z_row := origin_delta.z + local_z
			for local_y in range(y_first, y_last):
				var y_row := origin_delta.y + local_y
				var grid_row := local_y * CHUNK_SIZE + local_z * CHUNK_SIZE * CHUNK_SIZE
				for local_x in range(x_first, x_last):
					var x_row := origin_delta.x + local_x
					var id := grid[grid_row + local_x]
					if id == 0:
						continue
					var sample_index := x_row + PADDED_CHUNK_SIZE * (y_row + PADDED_CHUNK_SIZE * z_row)
					var base := (id - 1) * VoxelFrame.MATERIAL_STRIDE
					if count_reads:
						decodes += 1
					padded_cell_colors[sample_index] = Color(neighbor_materials[base], neighbor_materials[base + 1], neighbor_materials[base + 2], neighbor_materials[base + 3])
					if offset != Vector3i.ZERO:
						padded_cell_materials[sample_index] = 1
						continue
					occupied_planes[0] |= 1 << (origin_delta.x + local_x)
					occupied_planes[1] |= 1 << (origin_delta.y + local_y)
					occupied_planes[2] |= 1 << (origin_delta.z + local_z)
					var material_id: int = row_ids.get(id, -1)
					if material_id < 0:
						var cell_material := neighbor_materials.slice(base, base + VoxelFrame.MATERIAL_STRIDE)
						material_id = material_ids.get(cell_material, -1)
						if material_id < 0:
							material_id = materials.size() / VoxelFrame.MATERIAL_STRIDE
							material_ids[cell_material] = material_id
							materials.append_array(cell_material)
						row_ids[id] = material_id
					padded_cell_materials[sample_index] = material_id
	return [padded_cell_colors, padded_cell_materials, materials, occupied_planes, [chunks_read, cells_read, decodes]]


static func _scan_query_count(occupied_planes: PackedInt32Array) -> int:
	var queries := 0
	for axis in 3:
		var bits := occupied_planes[axis]
		var layers := 0
		while bits != 0:
			layers += bits & 1
			bits >>= 1
		queries += 2 * CHUNK_SIZE * CHUNK_SIZE * layers
	return queries
