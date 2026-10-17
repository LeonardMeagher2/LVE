extends RefCounted

const ATLAS := preload("./VoxelAtlas.gd")
const REGION := preload("./VoxelPlanarRegion.gd")
var arrays: Array = []
var atlas: RefCounted
var error: Error = OK


func run(source_arrays: Array, frame: VoxelFrame, origin := Vector3.ZERO, checkpoint := Callable(), smooth_normals := false) -> void:
	atlas = ATLAS.new()
	error = OK
	checkpoint = _latched_checkpoint(checkpoint)
	arrays = _build(source_arrays, frame, origin, atlas, checkpoint, smooth_normals)
	if arrays.is_empty():
		error = ERR_UNAVAILABLE
		return
	error = atlas.bake(checkpoint)
	if error == OK and not _finish_uvs(arrays, atlas, checkpoint):
		arrays = []
		error = ERR_UNAVAILABLE


static func merge(source_arrays: Array, checkpoint := Callable()) -> Array:
	checkpoint = _latched_checkpoint(checkpoint)
	var bake := ATLAS.new()
	var result := _build(source_arrays, null, Vector3.ZERO, bake, checkpoint, false)
	if result.is_empty() or bake.bake(checkpoint) != OK:
		return []
	if not _finish_uvs(result, bake, checkpoint):
		return []
	return result


static func _latched_checkpoint(checkpoint: Callable) -> Callable:
	var state := {"cancelled": false}
	return func(progress: int) -> bool:
		if not state.cancelled and checkpoint.is_valid():
			state.cancelled = not checkpoint.call(progress)
		return not state.cancelled


static func _build(source_arrays: Array, frame: VoxelFrame, world_origin: Vector3, bake: RefCounted, checkpoint: Callable, smooth_normals: bool) -> Array:
	if not checkpoint.call(0):
		return []
	# A smooth normal depends only on the corner of the voxel lattice, so the
	# cleanup reads it from the frame instead of a merged quad's interpolation.
	var use_corner_normals := smooth_normals and frame != null
	var result := []
	result.resize(Mesh.ARRAY_MAX)
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var patch_ids := PackedInt32Array()
	var groups := {}
	# Sparse face masks merge chunk boundaries without scanning empty frame bounds.
	if not source_arrays.is_empty():
		var source_positions: PackedVector3Array = source_arrays[Mesh.ARRAY_VERTEX]
		var source_normals: PackedVector3Array = source_arrays[Mesh.ARRAY_NORMAL]
		var source_indices: PackedInt32Array = source_arrays[Mesh.ARRAY_INDEX]
		for offset in range(0, source_indices.size(), 6):
			if not checkpoint.call(offset / 6):
				return []
			var first := source_indices[offset]
			var origin := source_positions[first]
			var edge_a := source_positions[source_indices[offset + 1]] - origin
			var edge_b := source_positions[source_indices[offset + 2]] - origin
			# Derive the face axis from geometry, not from the optional smooth normals.
			var normal := -edge_a.cross(edge_b).normalized()
			var axis := normal.abs().max_axis_index()
			var plane := Vector3i(axis, roundi(normal[axis]), roundi(origin[axis] * 2))
			var column_axis := (axis + 1) % 3
			var row_axis := (axis + 2) % 3
			var corners := [0, 2, 1, 4] if plane.y > 0 else [0, 1, 2, 5]
			var width := roundi(source_positions[source_indices[offset + corners[1]]][column_axis] - origin[column_axis])
			var height := roundi(source_positions[source_indices[offset + corners[3]]][row_axis] - origin[row_axis])
			var face_normals := PackedVector3Array()
			for corner: int in corners:
				face_normals.append(source_normals[source_indices[offset + corner]])
			var start := Vector2i(roundi(origin[column_axis] + 0.5), roundi(origin[row_axis] + 0.5))
			for y in height:
				if not checkpoint.call(offset / 6):
					return []
				for x in width:
					var point := start + Vector2i(x, y)
					var material: PackedFloat32Array
					if frame:
						var sample := origin + world_origin
						sample[axis] -= plane.y * 0.5
						sample[column_axis] += x + 0.5
						sample[row_axis] += y + 0.5
						var cell := Vector3i(sample.round())
						var chunk: VoxelFrame.Chunk = frame.chunks[VoxelFrame.chunk_position(cell)]
						var base: int = chunk.cells[cell] * VoxelFrame.MATERIAL_STRIDE
						material = chunk.materials.slice(base, base + VoxelFrame.MATERIAL_STRIDE)
					else:
						material = VoxelFrame.material(source_arrays[Mesh.ARRAY_COLOR][first])
					var key := [plane, material]
					if not groups.has(key):
						groups[key] = {"plane": plane, "material": material, "cells": {}, "normals": {}}
					var group: Dictionary = groups[key]
					group.cells[point] = true
					if not use_corner_normals:
						for corner in 4:
							var corner_offset := Vector2i(1 if corner in [1, 2] else 0, 1 if corner in [2, 3] else 0)
							var uv := Vector2(Vector2i(x, y) + corner_offset) / Vector2(width, height)
							group.normals[point + corner_offset] = _interpolate_normal(face_normals, uv)
	# Keep turns from every material and plane on all incident polygon boundaries.
	# This prevents a dissolved edge from skipping a seam junction on another face.
	var protected_positions := {}
	var protected_planes := {}
	for group: Dictionary in groups.values():
		if not checkpoint.call(0):
			return []
		var plane: Vector3i = group.plane
		protected_planes[plane] = {}
		for contour: PackedVector2Array in REGION.contours(group.cells, checkpoint):
			for point: Vector2 in contour:
				protected_positions[Vector3i((_position(plane, point) * 2).round())] = true
	_protect(protected_positions, protected_planes)
	while true:
		var added := {}
		for group: Dictionary in groups.values():
			if not checkpoint.call(0):
				return []
			group.polygons = REGION.triangulate(group.cells, protected_planes[group.plane], checkpoint)
			if group.polygons.is_empty():
				return []
			for polygon: Dictionary in group.polygons:
				for point: Vector2 in polygon.points:
					var corner := Vector3i((_position(group.plane, point) * 2).round())
					if not protected_positions.has(corner):
						protected_positions[corner] = true
						added[corner] = true
		if added.is_empty():
			break
		# Hole cuts can introduce corners on another face's boundary. Share those too.
		_protect(added, protected_planes)
	var vertices := {}
	for group: Dictionary in groups.values():
		if not checkpoint.call(0):
			return []
		var plane: Vector3i = group.plane
		var patch: int = bake.add_patch(group.material, Vector2i.ONE, checkpoint)
		if patch < 0:
			return []
		var fallback_normal := Vector3.ZERO
		fallback_normal[plane.x] = plane.y
		for polygon: Dictionary in group.polygons:
			var vertex_map := PackedInt32Array()
			for point: Vector2 in polygon.points:
				var position := _position(plane, point)
				var normal: Vector3 = _vertex_normal(group, frame, use_corner_normals, point, position + world_origin, fallback_normal)
				var key := [Vector3i((position * 2).round()), normal, patch]
				if not vertices.has(key):
					vertices[key] = positions.size()
					positions.append(position)
					normals.append(normal)
					patch_ids.append(patch)
				vertex_map.append(vertices[key])
			for offset in range(0, polygon.indices.size(), 3):
				indices.append(vertex_map[polygon.indices[offset]])
				indices.append(vertex_map[polygon.indices[offset + (2 if plane.y > 0 else 1)]])
				indices.append(vertex_map[polygon.indices[offset + (1 if plane.y > 0 else 2)]])
	result[Mesh.ARRAY_VERTEX] = positions
	result[Mesh.ARRAY_NORMAL] = normals
	result[Mesh.ARRAY_INDEX] = indices
	# Replace the temporary patch ids with UV coordinates after atlas packing.
	result[Mesh.ARRAY_TEX_UV] = patch_ids
	return result


# Read or compute the normal at one polygon vertex. Flat shading keeps the face
# normal. Smooth shading reads the shared voxel corner from the frame once.
static func _vertex_normal(group: Dictionary, frame: VoxelFrame, use_corner_normals: bool, point: Vector2, world_position: Vector3, fallback_normal: Vector3) -> Vector3:
	var corner := Vector2i(point)
	if use_corner_normals and not group.normals.has(corner):
		group.normals[corner] = _corner_normal(frame, world_position)
	var normal: Vector3 = group.normals.get(corner, fallback_normal)
	return fallback_normal if normal.is_zero_approx() else normal


# Average the occupied cells that meet at one voxel corner. A corner normal
# depends only on the lattice corner, so every face that meets there shares it.
static func _corner_normal(frame: VoxelFrame, world_position: Vector3) -> Vector3:
	var base := Vector3i(world_position.floor())
	var normal := Vector3.ZERO
	for z in 2:
		for y in 2:
			for x in 2:
				if frame.has(base + Vector3i(x, y, z)):
					normal += Vector3(0.5 - x, 0.5 - y, 0.5 - z)
	return normal.normalized()


static func _protect(positions: Dictionary, planes: Dictionary) -> void:
	for point: Vector3i in positions:
		for axis in 3:
			for sign_value in [-1, 1]:
				var plane := Vector3i(axis, sign_value, point[axis])
				if planes.has(plane):
					var projected := Vector2i((point[(axis + 1) % 3] + 1) / 2, (point[(axis + 2) % 3] + 1) / 2)
					planes[plane][projected] = true


static func _position(plane: Vector3i, point: Vector2) -> Vector3:
	var position := Vector3.ZERO
	position[plane.x] = plane.z * 0.5
	position[(plane.x + 1) % 3] = point.x - 0.5
	position[(plane.x + 2) % 3] = point.y - 0.5
	return position


static func _interpolate_normal(normals: PackedVector3Array, uv: Vector2) -> Vector3:
	if uv.y <= uv.x:
		return (normals[0] * (1.0 - uv.x) + normals[1] * (uv.x - uv.y) + normals[2] * uv.y).normalized()
	return (normals[0] * (1.0 - uv.y) + normals[2] * uv.x + normals[3] * (uv.y - uv.x)).normalized()


static func _finish_uvs(target: Array, bake: RefCounted, checkpoint: Callable) -> bool:
	var uvs := PackedVector2Array()
	var samples := {}
	for patch: int in target[Mesh.ARRAY_TEX_UV]:
		if uvs.size() % 4096 == 0 and not checkpoint.call(uvs.size()):
			return false
		if not samples.has(patch):
			var corners: PackedVector2Array = bake.patch_uvs(patch)
			# All faces of this material can share a texel center, including arbitrary ngons.
			samples[patch] = (corners[0] + corners[2]) * 0.5
		uvs.append(samples[patch])
	target[Mesh.ARRAY_TEX_UV] = uvs
	return true
