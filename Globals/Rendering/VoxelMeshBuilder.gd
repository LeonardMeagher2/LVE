class_name VoxelMeshBuilder
extends RefCounted

## Builds the mesh arrays of one chunk.
##
## The builder reads a padded snapshot of the chunk and its border. It emits
## colored vertex arrays or a texture-atlas surface. State owns the worker
## launch, and [method run] is the worker body.

## The chunk edge length in cells.
const CHUNK_SIZE := VoxelFrame.CHUNK_SIZE
## The padded chunk edge length, with one border cell on each side.
const PADDED_CHUNK_SIZE := CHUNK_SIZE + 2
const SURFACE := preload("./VoxelSurface.gd")

## The frame to read. A run clears it, so the worker does not hold the frame.
var source_frame: VoxelFrame
## The chunk coordinate to build.
var chunk_location := Vector3i.ZERO
## Whether the mesh uses smooth corner normals.
var smooth_normals := false
## Whether the mesh uses the texture atlas instead of vertex colors.
var texture_materials := true
## The worker pool task id, or -1 when no worker runs.
var worker_task_id := -1
## The built mesh arrays, indexed by [enum Mesh.ArrayType].
var surface_arrays: Array = []
## The estimated vertex and index byte count.
var geometry_bytes := 0
## The atlas size in pixels, or zero when no atlas exists.
var atlas_size := Vector2i.ZERO
## The albedo image data of the atlas.
var atlas_albedo := PackedByteArray()
## The finish image data of the atlas.
var atlas_orm := PackedByteArray()
## The emission image data of the atlas.
var atlas_emission := PackedByteArray()
## The built atlas, or null when the mesh uses vertex colors.
var atlas: RefCounted


## Builds the mesh arrays for one chunk. This is the worker body.
func run() -> void:
	var frame := source_frame
	var snapshot := _snapshot(source_frame, chunk_location, smooth_normals)
	var padded_cell_colors: PackedColorArray = snapshot[0]
	var padded_cell_materials: PackedInt32Array = snapshot[1]
	var materials: PackedFloat32Array = snapshot[2]
	# One bit per padded plane. Only the chunk's own cells emit faces, so a plane
	# with no occupied voxel skips its whole 16 by 16 scan.
	var occupied_planes: PackedInt32Array = snapshot[3]
	source_frame = null
	if texture_materials and frame != null:
		# Collect the exposed faces straight from the snapshot. The greedy pass
		# would merge them only for the cleanup to split them into single cells.
		var groups := _collect_groups(padded_cell_colors, padded_cell_materials, materials, occupied_planes)
		var surface := SURFACE.new()
		# The padded material map already holds occupancy for the chunk and its
		# neighbor border, so the smooth corner normals read it there instead of
		# hashing the frame once per corner.
		surface.run_groups(groups, frame, Vector3(chunk_location * CHUNK_SIZE), Callable(), smooth_normals, padded_cell_materials)
		surface_arrays = surface.arrays
		atlas = surface.atlas
		atlas_size = atlas.size
		if atlas.albedo:
			atlas_albedo = atlas.albedo.get_data()
			atlas_orm = atlas.orm.get_data()
			atlas_emission = atlas.emission.get_data()
		geometry_bytes = surface_arrays[Mesh.ARRAY_VERTEX].size() * 32 + surface_arrays[Mesh.ARRAY_INDEX].size() * 4
		return
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
	surface_arrays.resize(Mesh.ARRAY_MAX)
	surface_arrays[Mesh.ARRAY_VERTEX] = vertex_positions
	surface_arrays[Mesh.ARRAY_NORMAL] = vertex_normals
	surface_arrays[Mesh.ARRAY_COLOR] = vertex_colors
	surface_arrays[Mesh.ARRAY_INDEX] = triangle_indices
	geometry_bytes = vertex_positions.size() * 40 + triangle_indices.size() * 4
	if texture_materials:
		# Use the same seam-bounded planar cleanup and bake as the full-frame exporter.
		var surface := SURFACE.new()
		surface.run(surface_arrays, frame, Vector3(chunk_location * CHUNK_SIZE), Callable(), smooth_normals)
		surface_arrays = surface.arrays
		atlas = surface.atlas
		atlas_size = atlas.size
		if atlas.albedo:
			atlas_albedo = atlas.albedo.get_data()
			atlas_orm = atlas.orm.get_data()
			atlas_emission = atlas.emission.get_data()
		geometry_bytes = surface_arrays[Mesh.ARRAY_VERTEX].size() * 32 + surface_arrays[Mesh.ARRAY_INDEX].size() * 4


# Collect the exposed faces of this chunk straight from the padded snapshot,
# grouped by plane and material. The scan follows the greedy pass, so the
# groups are created in the same order and the mesh matches vertex for vertex.
func _collect_groups(padded_cell_colors: PackedColorArray, padded_cell_materials: PackedInt32Array, materials: PackedFloat32Array, occupied_planes: PackedInt32Array) -> Dictionary:
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
						# The greedy pass emits this face under the same rule.
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


## Returns the chunk offsets that a mesh of this chunk reads. A smooth mesh
## reads all 26 neighbors. A flat mesh reads only the six face neighbors.
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


# Build the padded snapshot of one chunk plus its neighbor border. Returns
# [padded colors, padded material ids, material table, occupied planes].
# A nonzero padded material id marks an occupied cell for the whole padded
# volume, including the border. The smooth corner normals read occupancy from
# that map, so they match `VoxelFrame.has` for every stored voxel.
static func _snapshot(frame: VoxelFrame, location: Vector3i, use_smooth_normals: bool) -> Array:
	var padded_cell_colors := PackedColorArray()
	padded_cell_colors.resize(PADDED_CHUNK_SIZE * PADDED_CHUNK_SIZE * PADDED_CHUNK_SIZE)
	padded_cell_colors.fill(Color.TRANSPARENT)
	var padded_cell_materials := PackedInt32Array()
	padded_cell_materials.resize(padded_cell_colors.size())
	var materials := VoxelFrame.material(Color.TRANSPARENT)
	var material_ids := {}
	var occupied_planes := PackedInt32Array([0, 0, 0])
	var padded_origin := location * CHUNK_SIZE - Vector3i.ONE
	for offset in neighbor_offsets(use_smooth_normals):
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
						# Only the chunk's own cells need a real material id. A
						# border cell marks occupancy alone, which the smooth
						# corner normals read as a nonzero slot.
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
