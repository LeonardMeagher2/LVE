extends RefCounted

## The frozen read path of one chunk, kept for a differential test.
##
## This is a verbatim copy of the padded snapshot, the face scan, and the face
## group collection that [VoxelMeshBuilder] used before the strided index and
## overlap-only rewrites. The parity test builds every case twice, once through
## the production builder and once through this file, and compares the arrays,
## the atlas, and the geometry bytes. Do not change this code to follow a
## production change. It is the reference, and its answers are frozen.

const CHUNK_SIZE := 16
const PADDED_CHUNK_SIZE := 18
const SURFACE := preload("res://Globals/Rendering/VoxelSurface.gd")


## Builds one chunk through the frozen body. Returns
## [code]{arrays, atlas_size, geometry_bytes}[/code].
static func build(frame: VoxelFrame, location: Vector3i, smooth: bool, texture_materials: bool) -> Dictionary:
	var snapshot := snapshot(frame, location, smooth)
	var padded_cell_colors: PackedColorArray = snapshot[0]
	var padded_cell_materials: PackedInt32Array = snapshot[1]
	var materials: PackedFloat32Array = snapshot[2]
	var occupied_planes: PackedInt32Array = snapshot[3]
	if texture_materials and frame != null:
		var groups := groups(padded_cell_colors, padded_cell_materials, materials, occupied_planes)
		var surface := SURFACE.new()
		surface.run_groups(groups, frame, Vector3(location * CHUNK_SIZE), Callable(), smooth, padded_cell_materials)
		var arrays: Array = surface.arrays
		return {
			"arrays": arrays,
			"atlas_size": surface.atlas.size,
			"geometry_bytes": arrays[Mesh.ARRAY_VERTEX].size() * 32 + arrays[Mesh.ARRAY_INDEX].size() * 4,
		}
	var greedy := _greedy(padded_cell_colors, padded_cell_materials, materials, occupied_planes, smooth)
	return {
		"arrays": greedy[0],
		"atlas_size": Vector2i.ZERO,
		"geometry_bytes": greedy[1],
	}


# The frozen padded snapshot of one chunk plus its neighbor border.
static func snapshot(frame: VoxelFrame, location: Vector3i, use_smooth_normals: bool) -> Array:
	var padded_cell_colors := PackedColorArray()
	padded_cell_colors.resize(PADDED_CHUNK_SIZE * PADDED_CHUNK_SIZE * PADDED_CHUNK_SIZE)
	padded_cell_colors.fill(Color.TRANSPARENT)
	var padded_cell_materials := PackedInt32Array()
	padded_cell_materials.resize(padded_cell_colors.size())
	var materials := VoxelFrame.material(Color.TRANSPARENT)
	var material_ids := {}
	var occupied_planes := PackedInt32Array([0, 0, 0])
	var padded_origin := location * CHUNK_SIZE - Vector3i.ONE
	for offset in _neighbor_offsets(use_smooth_normals):
		var neighbor: VoxelFrame.Chunk = frame.chunks.get(location + offset)
		if neighbor == null:
			continue
		var grid := neighbor.grid
		var neighbor_materials := neighbor.materials
		var origin_delta := neighbor.location * CHUNK_SIZE - padded_origin
		for local_z in CHUNK_SIZE:
			var z_row := origin_delta.z + local_z
			if z_row < 0 or z_row >= PADDED_CHUNK_SIZE:
				continue
			for local_y in CHUNK_SIZE:
				var y_row := origin_delta.y + local_y
				if y_row < 0 or y_row >= PADDED_CHUNK_SIZE:
					continue
				var grid_row := local_y * CHUNK_SIZE + local_z * CHUNK_SIZE * CHUNK_SIZE
				for local_x in CHUNK_SIZE:
					var x_row := origin_delta.x + local_x
					if x_row < 0 or x_row >= PADDED_CHUNK_SIZE:
						continue
					var id := grid[grid_row + local_x]
					if id == 0:
						continue
					var sample_index := x_row + PADDED_CHUNK_SIZE * (y_row + PADDED_CHUNK_SIZE * z_row)
					var base := (id - 1) * VoxelFrame.MATERIAL_STRIDE
					padded_cell_colors[sample_index] = Color(neighbor_materials[base], neighbor_materials[base + 1], neighbor_materials[base + 2], neighbor_materials[base + 3])
					if offset != Vector3i.ZERO:
						padded_cell_materials[sample_index] = 1
						continue
					occupied_planes[0] |= 1 << (origin_delta.x + local_x)
					occupied_planes[1] |= 1 << (origin_delta.y + local_y)
					occupied_planes[2] |= 1 << (origin_delta.z + local_z)
					var cell_material := neighbor_materials.slice(base, base + VoxelFrame.MATERIAL_STRIDE)
					var material_id: int = material_ids.get(cell_material, -1)
					if material_id < 0:
						material_id = materials.size() / VoxelFrame.MATERIAL_STRIDE
						material_ids[cell_material] = material_id
						materials.append_array(cell_material)
					padded_cell_materials[sample_index] = material_id
	return [padded_cell_colors, padded_cell_materials, materials, occupied_planes]


# The frozen exposed-face scan. Returns the greedy face material cells.
static func _greedy(padded_cell_colors: PackedColorArray, padded_cell_materials: PackedInt32Array, materials: PackedFloat32Array, occupied_planes: PackedInt32Array, smooth_normals: bool) -> Array:
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
				if occupied_planes[face_axis] & (1 << (layer_index + 1)) == 0:
					continue
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
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertex_positions
	arrays[Mesh.ARRAY_NORMAL] = vertex_normals
	arrays[Mesh.ARRAY_COLOR] = vertex_colors
	arrays[Mesh.ARRAY_INDEX] = triangle_indices
	return [arrays, vertex_positions.size() * 40 + triangle_indices.size() * 4]


# The frozen exposed-face group collection.
static func groups(padded_cell_colors: PackedColorArray, padded_cell_materials: PackedInt32Array, materials: PackedFloat32Array, occupied_planes: PackedInt32Array) -> Dictionary:
	var groups := {}
	var material_cache := {}
	for face_axis in 3:
		var column_axis := (face_axis + 1) % 3
		var row_axis := (face_axis + 2) % 3
		for face_sign: int in [-1, 1]:
			for layer_index in CHUNK_SIZE:
				if occupied_planes[face_axis] & (1 << (layer_index + 1)) == 0:
					continue
				for row in CHUNK_SIZE:
					for column in CHUNK_SIZE:
						var sample_position := Vector3i.ONE
						sample_position[face_axis] += layer_index
						sample_position[column_axis] += column
						sample_position[row_axis] += row
						var sample_index := sample_position.x + PADDED_CHUNK_SIZE * (sample_position.y + PADDED_CHUNK_SIZE * sample_position.z)
						var voxel_color := padded_cell_colors[sample_index]
						if voxel_color == Color.TRANSPARENT:
							continue
						var neighbor_position := sample_position
						neighbor_position[face_axis] += face_sign
						var neighbor_color := padded_cell_colors[neighbor_position.x + PADDED_CHUNK_SIZE * (neighbor_position.y + PADDED_CHUNK_SIZE * neighbor_position.z)]
						if not (neighbor_color.a < 1.0 and neighbor_color != voxel_color):
							continue
						var material_id := padded_cell_materials[sample_index]
						var material: PackedFloat32Array
						if material_cache.has(material_id):
							material = material_cache[material_id]
						else:
							material = materials.slice(material_id * VoxelFrame.MATERIAL_STRIDE, (material_id + 1) * VoxelFrame.MATERIAL_STRIDE)
							material_cache[material_id] = material
						var plane := Vector3i(face_axis, face_sign, 2 * layer_index + face_sign)
						var key := [plane, material]
						if not groups.has(key):
							groups[key] = {"plane": plane, "material": material, "cells": {}, "normals": {}}
						var group: Dictionary = groups[key]
						group.cells[Vector2i(column, row)] = true
	return groups


static func _neighbor_offsets(use_smooth_normals: bool) -> Array[Vector3i]:
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
