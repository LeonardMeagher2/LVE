extends RefCounted

## Builds a texture-atlas mesh from greedy face groups.
##
## The surface cleans up the planar regions, protects the seam turns, and bakes
## an atlas. [method run] converts a greedy mesh. [method run_groups] accepts
## groups that a caller collected from a frame. [method merge] combines several
## meshes into one surface.

const ATLAS := preload("./VoxelAtlas.gd")
const REGION := preload("./VoxelPlanarRegion.gd")
# Matches the padded chunk size in VoxelMeshBuilder. The snapshot corner normals
# read the padded material map with this stride.
## The padded chunk edge length, with one border cell on each side.
const PADDED_CHUNK_SIZE := VoxelFrame.CHUNK_SIZE + 2
## The linear vertex color of each ambient occlusion level, from enclosed to
## free. The strength scales the occlusion, so an unoccluded corner always
## stays at one.
const AO_LEVELS: Array[float] = [0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0]
## The built mesh arrays, indexed by [enum Mesh.ArrayType].
var arrays: Array = []
## The baked atlas, or null before a run.
var atlas: RefCounted
## The result of the last run. A cancel or a failed bake sets
## [constant ERR_UNAVAILABLE].
var error: Error = OK


## Builds one surface from a greedy mesh. [param origin] offsets the mesh in
## world space. [param checkpoint] cancels the work.
func run(source_arrays: Array, frame: VoxelFrame, origin := Vector3.ZERO, checkpoint := Callable(), smooth_normals := false, ao_strength := 0.0) -> void:
	atlas = ATLAS.new()
	error = OK
	checkpoint = _latched_checkpoint(checkpoint)
	arrays = _build(source_arrays, frame, origin, atlas, checkpoint, smooth_normals, ao_strength)
	if arrays.is_empty():
		error = ERR_UNAVAILABLE
		return
	error = atlas.bake(checkpoint)
	if error == OK and not _finish_uvs(arrays, atlas, checkpoint):
		arrays = []
		error = ERR_UNAVAILABLE


# Clean up groups that a caller collected straight from a frame. A caller that
# collected from a padded snapshot passes its padded material map as
# `corner_occupancy`, so the smooth normals need no frame lookup.
## Builds one surface from groups that a caller collected from a frame.
## [param corner_occupancy] supplies the padded occupancy map for the smooth
## normals.
func run_groups(groups: Dictionary, frame: VoxelFrame, origin := Vector3.ZERO, checkpoint := Callable(), smooth_normals := false, corner_occupancy: Variant = null, ao_strength := 0.0) -> void:
	atlas = ATLAS.new()
	error = OK
	checkpoint = _latched_checkpoint(checkpoint)
	arrays = _finish(groups, frame, origin, atlas, checkpoint, smooth_normals, corner_occupancy, ao_strength)
	if arrays.is_empty():
		error = ERR_UNAVAILABLE
		return
	error = atlas.bake(checkpoint)
	if error == OK and not _finish_uvs(arrays, atlas, checkpoint):
		arrays = []
		error = ERR_UNAVAILABLE


## Combines several meshes into one surface. Returns an empty array on a cancel
## or a failed bake.
static func merge(source_arrays: Array, checkpoint := Callable()) -> Array:
	checkpoint = _latched_checkpoint(checkpoint)
	var bake := ATLAS.new()
	var result := _build(source_arrays, null, Vector3.ZERO, bake, checkpoint, false, 0.0)
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


static func _build(source_arrays: Array, frame: VoxelFrame, world_origin: Vector3, bake: RefCounted, checkpoint: Callable, smooth_normals: bool, ao_strength := 0.0) -> Array:
	if not checkpoint.call(0):
		return []
	var groups: Variant = _groups_from_arrays(source_arrays, frame, world_origin, checkpoint, smooth_normals, ao_strength)
	if groups == null:
		return []
	return _finish(groups, frame, world_origin, bake, checkpoint, smooth_normals, null, ao_strength)


# Group the exposed faces of a greedy mesh by plane and material. A null result
# marks cancellation.
static func _groups_from_arrays(source_arrays: Array, frame: VoxelFrame, world_origin: Vector3, checkpoint: Callable, smooth_normals: bool, ao_strength := 0.0) -> Variant:
	var use_corner_normals := smooth_normals and frame != null
	var use_ao := ao_strength > 0.0 and frame != null
	var groups := {}
	# Sparse face masks merge chunk boundaries without scanning empty frame bounds.
	if not source_arrays.is_empty():
		var source_positions: PackedVector3Array = source_arrays[Mesh.ARRAY_VERTEX]
		var source_normals: PackedVector3Array = source_arrays[Mesh.ARRAY_NORMAL]
		var source_indices: PackedInt32Array = source_arrays[Mesh.ARRAY_INDEX]
		for offset in range(0, source_indices.size(), 6):
			if not checkpoint.call(offset / 6):
				return null
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
					return null
				for x in width:
					var point := start + Vector2i(x, y)
					var material: PackedFloat32Array
					var cell := Vector3i.ZERO
					if frame:
						var sample := origin + world_origin
						sample[axis] -= plane.y * 0.5
						sample[column_axis] += x + 0.5
						sample[row_axis] += y + 0.5
						cell = Vector3i(sample.round())
						var chunk: VoxelFrame.Chunk = frame.chunks[VoxelFrame.chunk_position(cell)]
						material = chunk.get_material(cell)
					else:
						material = VoxelFrame.material(source_arrays[Mesh.ARRAY_COLOR][first])
					# The AO is part of the key, so cells with a different corner
					# shade split into their own group. The merge then stays inside
					# one shade, and the color no longer smears across a large quad.
					var ao_code := _face_ao_code(frame, plane, cell) if use_ao else -1
					var key := [plane, material, ao_code] if use_ao else [plane, material]
					if not groups.has(key):
						groups[key] = {"plane": plane, "material": material, "cells": {}, "normals": {}, "corners": {}}
					var group: Dictionary = groups[key]
					group.cells[point] = true
					if use_ao:
						_store_ao_corners(group.corners, point, ao_code)
					if not use_corner_normals:
						for corner in 4:
							var corner_offset := Vector2i(1 if corner in [1, 2] else 0, 1 if corner in [2, 3] else 0)
							var uv := Vector2(Vector2i(x, y) + corner_offset) / Vector2(width, height)
							group.normals[point + corner_offset] = _interpolate_normal(face_normals, uv)
	return groups


# Clean up the groups and emit one mesh. Shared by the greedy round trip and the
# direct collection from a frame.
static func _finish(groups: Dictionary, frame: VoxelFrame, world_origin: Vector3, bake: RefCounted, checkpoint: Callable, smooth_normals: bool, corner_occupancy: Variant = null, ao_strength := 0.0) -> Array:
	# A smooth normal depends only on the corner of the voxel lattice, so the
	# cleanup reads it from the frame instead of a merged quad's interpolation.
	# A direct build passes the padded snapshot, which carries the same occupancy
	# and avoids one frame lookup per corner.
	var use_corner_normals := smooth_normals and (frame != null or corner_occupancy != null)
	# The AO needs the occupancy around the vertex corner. The frame snapshot has
	# every chunk, so the AO is correct across diagonal chunk borders.
	var use_ao := ao_strength > 0.0 and frame != null
	var result := []
	result.resize(Mesh.ARRAY_MAX)
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var patch_ids := PackedInt32Array()
	var protected := _protect_groups(groups, checkpoint)
	if protected.is_empty():
		return []
	if not _triangulate_groups(groups, protected, checkpoint):
		return []
	# The normal is part of the dedup key. A smooth corner whose occupancy cancels
	# falls back to the plane normal, and two planes that meet at that corner then
	# hold different normals, so they must keep separate vertices. The key is an
	# array that holds a Vector3, which is not cheap, but dropping the normal from
	# it merged those vertices and changed the shading.
	var vertices := {}
	# One corner normal per padded (or world) lattice corner, shared by every
	# group in this build.
	var corner_cache := {}
	for group: Dictionary in groups.values():
		if not checkpoint.call(0):
			return []
		var plane: Vector3i = group.plane
		var patch: int = bake.add_patch(group.material, Vector2i.ONE, checkpoint)
		if patch < 0:
			return []
		var fallback_normal := Vector3.ZERO
		fallback_normal[plane.x] = plane.y
		var corners: Dictionary = group.get("corners", {})
		for polygon: Dictionary in group.polygons:
			var vertex_map := PackedInt32Array()
			for point: Vector2 in polygon.points:
				var position := _position(plane, point)
				var normal: Vector3 = _vertex_normal(group, frame, use_corner_normals, point, position + world_origin, position, fallback_normal, corner_occupancy, corner_cache)
				var ao := 1.0
				if use_ao:
					# The face cell stored one level per lattice corner. Every
					# group cell that holds this vertex agrees, because the level
					# depends only on the corner and the face plane.
					var level: int = corners.get(Vector2i(roundi(point.x), roundi(point.y)), 3)
					ao = 1.0 - (1.0 - AO_LEVELS[level]) * ao_strength
				# The AO is part of the key. The same corner on two faces can hold
				# different AO, so the vertices must stay separate.
				var key := [Vector3i((position * 2).round()), normal, patch, roundi(ao * 255.0)]
				if not vertices.has(key):
					vertices[key] = positions.size()
					positions.append(position)
					normals.append(normal)
					colors.append(Color(ao, ao, ao, 1.0))
					patch_ids.append(patch)
				vertex_map.append(vertices[key])
			for offset in range(0, polygon.indices.size(), 3):
				indices.append(vertex_map[polygon.indices[offset]])
				indices.append(vertex_map[polygon.indices[offset + (2 if plane.y > 0 else 1)]])
				indices.append(vertex_map[polygon.indices[offset + (1 if plane.y > 0 else 2)]])
	result[Mesh.ARRAY_VERTEX] = positions
	result[Mesh.ARRAY_NORMAL] = normals
	if use_ao:
		result[Mesh.ARRAY_COLOR] = colors
	result[Mesh.ARRAY_INDEX] = indices
	# Replace the temporary patch ids with UV coordinates after atlas packing.
	result[Mesh.ARRAY_TEX_UV] = patch_ids
	return result


# Protect the seam turns of every group, and prepare its raw loops. Returns
# {"positions": Dictionary, "planes": Dictionary}, or an empty dictionary when the
# checkpoint cancels.
#
# Keep turns from every material and plane on all incident polygon boundaries.
# This prevents a dissolved edge from skipping a seam junction on another face.
static func _protect_groups(groups: Dictionary, checkpoint: Callable) -> Dictionary:
	var protected_positions := {}
	var protected_planes := {}
	for group: Dictionary in groups.values():
		if not checkpoint.call(0):
			return {}
		var plane: Vector3i = group.plane
		protected_planes[plane] = {}
		# Prepare the raw loops once. The turns protect the seams, and the raw
		# loops feed the triangulation without a second extraction.
		group.raw_loops = REGION.raw_loops(group.cells, checkpoint)
		for loop: PackedVector2Array in group.raw_loops:
			for point: Vector2 in REGION._simplify(loop, {}):
				protected_positions[Vector3i((_position(plane, point) * 2).round())] = true
	_protect(protected_positions, protected_planes)
	return {"positions": protected_positions, "planes": protected_planes}


# Triangulate every group against the protected corners, and share any corner a
# hole cut introduces on another face. Returns false when the checkpoint cancels
# or a group produces no polygon.
static func _triangulate_groups(groups: Dictionary, protected: Dictionary, checkpoint: Callable) -> bool:
	var protected_positions: Dictionary = protected.positions
	var protected_planes: Dictionary = protected.planes
	while true:
		var added := {}
		for group: Dictionary in groups.values():
			if not checkpoint.call(0):
				return false
			group.polygons = REGION.triangulate(group.cells, protected_planes[group.plane], checkpoint, group.raw_loops)
			if group.polygons.is_empty():
				return false
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
	return true


# Read or compute the normal at one polygon vertex. Flat shading keeps the
# interpolated or face normal. Smooth shading reads the shared voxel corner
# once. A padded occupancy map reads the snapshot. Otherwise the frame is read.
static func _vertex_normal(group: Dictionary, frame: VoxelFrame, use_corner_normals: bool, point: Vector2, world_position: Vector3, local_position: Vector3, fallback_normal: Vector3, corner_occupancy: Variant, corner_cache: Dictionary) -> Vector3:
	if not use_corner_normals:
		var flat: Vector3 = group.normals.get(Vector2i(point), fallback_normal)
		return fallback_normal if flat.is_zero_approx() else flat
	var corner: Vector3i
	var normal: Vector3
	if corner_occupancy != null:
		# The padded snapshot starts one cell before the chunk, so the corner
		# shifts by one from the chunk-local lattice corner.
		corner = Vector3i(local_position.floor()) + Vector3i.ONE
		if corner_cache.has(corner):
			normal = corner_cache[corner]
		else:
			normal = _corner_normal_occupied(corner, corner_occupancy)
			corner_cache[corner] = normal
	else:
		corner = Vector3i(world_position.floor())
		if corner_cache.has(corner):
			normal = corner_cache[corner]
		else:
			normal = _corner_normal(frame, world_position)
			corner_cache[corner] = normal
	return fallback_normal if normal.is_zero_approx() else normal


# The classic voxel ambient occlusion level for one face corner. The two cells
# that share an edge with the face cell and the cell that touches only the corner
# darken it. A fully enclosed corner reaches zero, and a free corner reaches
# three. The four levels map to colors through [constant AO_LEVELS].
static func _ao_level(first: bool, second: bool, diagonal: bool) -> int:
	if first and second:
		return 0
	return 3 - (1 if first else 0) - (1 if second else 0) - (1 if diagonal else 0)


# The ambient occlusion code of one cell face. The code holds the four corner
# levels, two bits each, in this order: low tangent1 and low tangent2, high
# tangent1 and low tangent2, low tangent1 and high tangent2, both high. Two
# cells with the same code may merge, so the greedy pass keeps the shade exact.
#
# [param cell] is the face cell centre in world cell coordinates. The cell
# directly in front of the face is never sampled, because an exposed face always
# has an empty direct neighbour.
static func _face_ao_code(frame: VoxelFrame, plane: Vector3i, cell: Vector3i) -> int:
	var axis := plane.x
	var tangent1 := (axis + 1) % 3
	var tangent2 := (axis + 2) % 3
	var outside := cell
	outside[axis] += plane.y
	var code := 0
	for index in 4:
		var far1 := -1 if (index & 1) == 0 else 1
		var far2 := -1 if (index & 2) == 0 else 1
		var side1 := outside
		side1[tangent1] += far1
		var side2 := outside
		side2[tangent2] += far2
		var diagonal := outside
		diagonal[tangent1] += far1
		diagonal[tangent2] += far2
		code |= _ao_level(frame.has(side1), frame.has(side2), frame.has(diagonal)) << (index * 2)
	return code


# Writes the four corner levels of one cell into the group map. [param point] is
# the low corner of the cell in face tangent index space.
static func _store_ao_corners(corners: Dictionary, point: Vector2i, code: int) -> void:
	corners[point] = code & 3
	corners[point + Vector2i(1, 0)] = (code >> 2) & 3
	corners[point + Vector2i(0, 1)] = (code >> 4) & 3
	corners[point + Vector2i(1, 1)] = (code >> 6) & 3


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


# The same corner normal, read from the padded snapshot. `padded_corner` is in
# padded chunk coordinates, where the chunk's first cell sits at one. A nonzero
# padded material id marks an occupied cell, so this matches `VoxelFrame.has`
# for the stored voxels, including stored transparent voxels.
static func _corner_normal_occupied(padded_corner: Vector3i, padded_occupancy: PackedInt32Array) -> Vector3:
	var normal := Vector3.ZERO
	for z in 2:
		for y in 2:
			for x in 2:
				var sample := padded_corner + Vector3i(x, y, z)
				if padded_occupancy[sample.x + PADDED_CHUNK_SIZE * (sample.y + PADDED_CHUNK_SIZE * sample.z)] != 0:
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
