extends RefCounted


const ATLAS := preload("./VoxelAtlas.gd")
const REGION := preload("./VoxelPlanarRegion.gd")
const PADDED_CHUNK_SIZE := VoxelFrame.CHUNK_SIZE + 2
const CORNER_RANGE := VoxelFrame.CHUNK_SIZE + 1
const AO_LEVELS: Array[float] = [0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0]
var arrays: Array = []
var atlas: RefCounted
var error: Error = OK
var profile := false
var protect_us := 0
var triangulate_us := 0
var vertices_us := 0
var atlas_us := 0
var uvs_us := 0
var loops_us := 0
var simplify_us := 0
var protect_inner_us := 0
var normal_us := 0


func run(source_arrays: Array, frame: VoxelFrame, origin := Vector3.ZERO, checkpoint := Callable(), smooth_normals := false, ao_strength := 0.0) -> void:
	atlas = ATLAS.new()
	error = OK
	checkpoint = _latched_checkpoint(checkpoint)
	var timers := {}
	if profile:
		timers = {"protect": 0, "triangulate": 0, "vertices": 0}
	arrays = _build(source_arrays, frame, origin, atlas, checkpoint, smooth_normals, ao_strength, timers)
	if profile:
		protect_us = timers.get("protect", 0)
		triangulate_us = timers.get("triangulate", 0)
		vertices_us = timers.get("vertices", 0)
		loops_us = timers.get("raw_loops", 0)
		simplify_us = timers.get("simplify", 0)
		protect_inner_us = timers.get("protect_inner", 0)
		normal_us = timers.get("normal", 0)
	if arrays.is_empty():
		error = ERR_UNAVAILABLE
		return
	var bake_started := Time.get_ticks_usec() if profile else 0
	error = atlas.bake(checkpoint)
	if profile:
		atlas_us = Time.get_ticks_usec() - bake_started
	var uvs_started := Time.get_ticks_usec() if profile else 0
	if error == OK and not _finish_uvs(arrays, atlas, checkpoint):
		arrays = []
		error = ERR_UNAVAILABLE
	if profile:
		uvs_us = Time.get_ticks_usec() - uvs_started


func run_groups(groups: Dictionary, frame: VoxelFrame, origin := Vector3.ZERO, checkpoint := Callable(), smooth_normals := false, corner_occupancy: Variant = null, ao_strength := 0.0) -> void:
	atlas = ATLAS.new()
	error = OK
	checkpoint = _latched_checkpoint(checkpoint)
	var timers := {}
	if profile:
		timers = {"protect": 0, "triangulate": 0, "vertices": 0}
	arrays = _finish(groups, frame, origin, atlas, checkpoint, smooth_normals, corner_occupancy, ao_strength, timers)
	if profile:
		protect_us = timers.get("protect", 0)
		triangulate_us = timers.get("triangulate", 0)
		vertices_us = timers.get("vertices", 0)
		loops_us = timers.get("raw_loops", 0)
		simplify_us = timers.get("simplify", 0)
		protect_inner_us = timers.get("protect_inner", 0)
		normal_us = timers.get("normal", 0)
	if arrays.is_empty():
		error = ERR_UNAVAILABLE
		return
	var bake_started := Time.get_ticks_usec() if profile else 0
	error = atlas.bake(checkpoint)
	if profile:
		atlas_us = Time.get_ticks_usec() - bake_started
	var uvs_started := Time.get_ticks_usec() if profile else 0
	if error == OK and not _finish_uvs(arrays, atlas, checkpoint):
		arrays = []
		error = ERR_UNAVAILABLE
	if profile:
		uvs_us = Time.get_ticks_usec() - uvs_started


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


static func _build(source_arrays: Array, frame: VoxelFrame, world_origin: Vector3, bake: RefCounted, checkpoint: Callable, smooth_normals: bool, ao_strength := 0.0, timers := {}) -> Array:
	if not checkpoint.call(0):
		return []
	var groups: Variant = _groups_from_arrays(source_arrays, frame, world_origin, checkpoint, smooth_normals, ao_strength)
	if groups == null:
		return []
	return _finish(groups, frame, world_origin, bake, checkpoint, smooth_normals, null, ao_strength, timers)


static func _groups_from_arrays(source_arrays: Array, frame: VoxelFrame, world_origin: Vector3, checkpoint: Callable, smooth_normals: bool, ao_strength := 0.0) -> Variant:
	var use_corner_normals := smooth_normals and frame != null
	var use_ao := ao_strength > 0.0 and frame != null
	var groups := {}
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


static func _finish(groups: Dictionary, frame: VoxelFrame, world_origin: Vector3, bake: RefCounted, checkpoint: Callable, smooth_normals: bool, corner_occupancy: Variant = null, ao_strength := 0.0, timers := {}) -> Array:
	var use_corner_normals := smooth_normals and (frame != null or corner_occupancy != null)
	var use_ao := ao_strength > 0.0 and frame != null
	var result := []
	result.resize(Mesh.ARRAY_MAX)
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var patch_ids := PackedInt32Array()
	var protect_started := Time.get_ticks_usec() if not timers.is_empty() else 0
	var protected := _protect_groups(groups, checkpoint, timers)
	if not timers.is_empty():
		timers["protect"] = Time.get_ticks_usec() - protect_started
	if protected.is_empty():
		return []
	var triangulate_started := Time.get_ticks_usec() if not timers.is_empty() else 0
	if not _triangulate_groups(groups, protected, checkpoint):
		return []
	if not timers.is_empty():
		timers["triangulate"] = Time.get_ticks_usec() - triangulate_started
	var vertices := {}
	var corner_cache := {}
	var normal_time := 0
	var corner_table := PackedFloat32Array()
	var corner_seen := PackedByteArray()
	var use_corner_table := false
	if use_corner_normals and corner_occupancy != null:
		var corner_count := CORNER_RANGE * CORNER_RANGE * CORNER_RANGE
		corner_table.resize(corner_count * 3)
		corner_seen.resize(corner_count)
		use_corner_table = true
	var vertex_map := PackedInt32Array()
	var vertices_started := Time.get_ticks_usec() if not timers.is_empty() else 0
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
		var flat: bool = not use_corner_normals and group.normals.is_empty()
		var axis0: int = plane.x
		var plane_z := plane.z * 0.5
		var plane_slot := floori(plane.z * 0.5) + 1
		var group_vertices = {} if flat and not use_ao else null
		var second := 2 if plane.y > 0 else 1
		var third := 1 if plane.y > 0 else 2
		for polygon: Dictionary in group.polygons:
			vertex_map.clear()
			for point: Vector2 in polygon.points:
				var dbl := Vector3i.ZERO
				if axis0 == 0:
					dbl.x = plane.z
					dbl.y = roundi(2.0 * point.x - 1.0)
					dbl.z = roundi(2.0 * point.y - 1.0)
				elif axis0 == 1:
					dbl.y = plane.z
					dbl.x = roundi(2.0 * point.y - 1.0)
					dbl.z = roundi(2.0 * point.x - 1.0)
				else:
					dbl.z = plane.z
					dbl.x = roundi(2.0 * point.x - 1.0)
					dbl.y = roundi(2.0 * point.y - 1.0)
				var position := Vector3.ZERO
				if not use_corner_table:
					if axis0 == 0:
						position.x = plane_z
						position.y = point.x - 0.5
						position.z = point.y - 0.5
					elif axis0 == 1:
						position.y = plane_z
						position.x = point.y - 0.5
						position.z = point.x - 0.5
					else:
						position.z = plane_z
						position.x = point.x - 0.5
						position.y = point.y - 0.5
				var normal: Vector3
				if flat:
					normal = fallback_normal
				elif use_corner_table:
					var normal_started := Time.get_ticks_usec() if not timers.is_empty() else 0
					var cx := 0
					var cy := 0
					var cz := 0
					if axis0 == 0:
						cx = plane_slot
						cy = floori(point.x - 0.5) + 1
						cz = floori(point.y - 0.5) + 1
					elif axis0 == 1:
						cx = floori(point.y - 0.5) + 1
						cy = plane_slot
						cz = floori(point.x - 0.5) + 1
					else:
						cx = floori(point.x - 0.5) + 1
						cy = floori(point.y - 0.5) + 1
						cz = plane_slot
					var base := (cz * CORNER_RANGE + cy) * CORNER_RANGE + cx
					if corner_seen[base] == 0:
						var corner_normal := _corner_normal_occupied(Vector3i(cx, cy, cz), corner_occupancy)
						var nb := base * 3
						corner_table[nb] = corner_normal.x
						corner_table[nb + 1] = corner_normal.y
						corner_table[nb + 2] = corner_normal.z
						if corner_normal.is_zero_approx():
							corner_seen[base] = 1
							normal = fallback_normal
						else:
							corner_seen[base] = 2
							normal = corner_normal
					elif corner_seen[base] == 2:
						normal = Vector3(corner_table[base * 3], corner_table[base * 3 + 1], corner_table[base * 3 + 2])
					else:
						normal = fallback_normal
					if not timers.is_empty():
						normal_time += Time.get_ticks_usec() - normal_started
				else:
					var normal_started := Time.get_ticks_usec() if not timers.is_empty() else 0
					normal = _vertex_normal(group, frame, use_corner_normals, point, position, world_origin, fallback_normal, corner_occupancy, corner_cache)
					if not timers.is_empty():
						normal_time += Time.get_ticks_usec() - normal_started
				var ao := 1.0
				if use_ao:
					var level: int = corners.get(Vector2i(roundi(point.x), roundi(point.y)), 3)
					ao = 1.0 - (1.0 - AO_LEVELS[level]) * ao_strength
				if flat and not use_ao:
					var existing: int = group_vertices.get(dbl, -1)
					if existing < 0:
						existing = positions.size()
						group_vertices[dbl] = existing
						positions.append(position)
						normals.append(fallback_normal)
						patch_ids.append(patch)
					vertex_map.append(existing)
				else:
					var key := [dbl, normal, patch, roundi(ao * 255.0)] if use_ao else [dbl, normal, patch]
					var existing: int = vertices.get(key, -1)
					if existing < 0:
						existing = positions.size()
						vertices[key] = existing
						if use_corner_table:
							if axis0 == 0:
								position.x = plane_z
								position.y = point.x - 0.5
								position.z = point.y - 0.5
							elif axis0 == 1:
								position.y = plane_z
								position.x = point.y - 0.5
								position.z = point.x - 0.5
							else:
								position.z = plane_z
								position.x = point.x - 0.5
								position.y = point.y - 0.5
						positions.append(position)
						normals.append(normal)
						if use_ao:
							colors.append(Color(ao, ao, ao, 1.0))
						patch_ids.append(patch)
					vertex_map.append(existing)
			var offset := 0
			var index_count: int = polygon.indices.size()
			while offset < index_count:
				indices.append(vertex_map[polygon.indices[offset]])
				indices.append(vertex_map[polygon.indices[offset + second]])
				indices.append(vertex_map[polygon.indices[offset + third]])
				offset += 3
	if not timers.is_empty():
		timers["vertices"] = Time.get_ticks_usec() - vertices_started
		timers["normal"] = normal_time
	result[Mesh.ARRAY_VERTEX] = positions
	result[Mesh.ARRAY_NORMAL] = normals
	if use_ao:
		result[Mesh.ARRAY_COLOR] = colors
	result[Mesh.ARRAY_INDEX] = indices
	result[Mesh.ARRAY_TEX_UV] = patch_ids
	return result


static var EMPTY_DICT := {}


static func _protect_groups(groups: Dictionary, checkpoint: Callable, timers := {}) -> Dictionary:
	var protected_positions := {}
	var protected_planes := {}
	var loops_us := 0
	var simplify_us := 0
	var uses_planes := false
	for group: Dictionary in groups.values():
		if not checkpoint.call(0):
			return {}
		var plane: Vector3i = group.plane
		protected_planes[plane] = {}
		var axis0: int = plane.x
		var t0 := Time.get_ticks_usec() if not timers.is_empty() else 0
		group.raw_loops = REGION.raw_loops(group.cells, checkpoint)
		var t1 := Time.get_ticks_usec() if not timers.is_empty() else 0
		loops_us += t1 - t0
		var turns := 0
		for loop: PackedVector2Array in group.raw_loops:
			var t2 := Time.get_ticks_usec() if not timers.is_empty() else 0
			var size := loop.size()
			if size > 0:
				var previous: Vector2 = loop[size - 1]
				for index in size:
					var point: Vector2 = loop[index]
					var next: Vector2
					if index + 1 < size:
						next = loop[index + 1]
					else:
						next = loop[0]
					if (point - previous).cross(next - point) != 0.0:
						turns += 1
						var dbl := Vector3i.ZERO
						if axis0 == 0:
							dbl.x = plane.z
							dbl.y = roundi(2.0 * point.x - 1.0)
							dbl.z = roundi(2.0 * point.y - 1.0)
						elif axis0 == 1:
							dbl.y = plane.z
							dbl.x = roundi(2.0 * point.y - 1.0)
							dbl.z = roundi(2.0 * point.x - 1.0)
						else:
							dbl.z = plane.z
							dbl.x = roundi(2.0 * point.x - 1.0)
							dbl.y = roundi(2.0 * point.y - 1.0)
						protected_positions[dbl] = true
					previous = point
			if not timers.is_empty():
				simplify_us += Time.get_ticks_usec() - t2
		group.unit_loops = turns == group.cells.size() * 4
		if not group.unit_loops:
			uses_planes = true
	if not timers.is_empty():
		timers["raw_loops"] = loops_us
		timers["simplify"] = simplify_us
	if uses_planes:
		var t3 := Time.get_ticks_usec() if not timers.is_empty() else 0
		_protect(protected_positions, protected_planes)
		if not timers.is_empty():
			timers["protect_inner"] = Time.get_ticks_usec() - t3
	return {"positions": protected_positions, "planes": protected_planes}


static func _triangulate_groups(groups: Dictionary, protected: Dictionary, checkpoint: Callable) -> bool:
	var protected_positions: Dictionary = protected.positions
	var protected_planes: Dictionary = protected.planes
	while true:
		var added := {}
		for group: Dictionary in groups.values():
			if not checkpoint.call(0):
				return false
			group.polygons = REGION.triangulate(group.cells, protected_planes[group.plane], checkpoint, group.raw_loops, group.unit_loops)
			if group.polygons.is_empty():
				return false
			if not group.unit_loops:
				var grp_axis0: int = group.plane.x
				var grp_axis1: int = (group.plane.x + 1) % 3
				var grp_axis2: int = (group.plane.x + 2) % 3
				var grp_plane_z: int = group.plane.z
				for polygon: Dictionary in group.polygons:
					for point: Vector2 in polygon.points:
						var corner := Vector3i.ZERO
						corner[grp_axis0] = grp_plane_z
						corner[grp_axis1] = roundi(2.0 * point.x - 1.0)
						corner[grp_axis2] = roundi(2.0 * point.y - 1.0)
						if not protected_positions.has(corner):
							protected_positions[corner] = true
							added[corner] = true
		if added.is_empty():
			break
		_protect(added, protected_planes)
	return true


static func _vertex_normal(group: Dictionary, frame: VoxelFrame, use_corner_normals: bool, point: Vector2, local_position: Vector3, world_origin: Vector3, fallback_normal: Vector3, corner_occupancy: Variant, corner_cache: Dictionary) -> Vector3:
	if not use_corner_normals:
		var flat: Vector3 = group.normals.get(Vector2i(point), fallback_normal)
		return fallback_normal if flat.is_zero_approx() else flat
	var corner: Vector3i
	var cached: Variant
	if corner_occupancy != null:
		corner = Vector3i(floori(local_position.x), floori(local_position.y), floori(local_position.z)) + Vector3i.ONE
		cached = corner_cache.get(corner, null)
		if cached == null:
			cached = _corner_normal_occupied(corner, corner_occupancy)
			corner_cache[corner] = cached
	else:
		var world_position := local_position + world_origin
		corner = Vector3i(floori(world_position.x), floori(world_position.y), floori(world_position.z))
		cached = corner_cache.get(corner, null)
		if cached == null:
			cached = _corner_normal(frame, world_position)
			corner_cache[corner] = cached
	var normal: Vector3 = cached
	return fallback_normal if normal.is_zero_approx() else normal


static func _ao_level(first: bool, second: bool, diagonal: bool) -> int:
	if first and second:
		return 0
	return 3 - (1 if first else 0) - (1 if second else 0) - (1 if diagonal else 0)


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


static func _store_ao_corners(corners: Dictionary, point: Vector2i, code: int) -> void:
	corners[point] = code & 3
	corners[point + Vector2i(1, 0)] = (code >> 2) & 3
	corners[point + Vector2i(0, 1)] = (code >> 4) & 3
	corners[point + Vector2i(1, 1)] = (code >> 6) & 3


static func _corner_normal(frame: VoxelFrame, world_position: Vector3) -> Vector3:
	var base := Vector3i(floori(world_position.x), floori(world_position.y), floori(world_position.z))
	var nx := 0.0
	var ny := 0.0
	var nz := 0.0
	for z in 2:
		for y in 2:
			for x in 2:
				if frame.has(base + Vector3i(x, y, z)):
					nx += 0.5 - x
					ny += 0.5 - y
					nz += 0.5 - z
	return Vector3(nx, ny, nz).normalized()


static func _corner_normal_occupied(padded_corner: Vector3i, padded_occupancy: PackedInt32Array) -> Vector3:
	var nx := 0.0
	var ny := 0.0
	var nz := 0.0
	var base := padded_corner.x + PADDED_CHUNK_SIZE * (padded_corner.y + PADDED_CHUNK_SIZE * padded_corner.z)
	var s2 := PADDED_CHUNK_SIZE * PADDED_CHUNK_SIZE
	for z in 2:
		var idx_z := s2 * z
		for y in 2:
			var idx_y := PADDED_CHUNK_SIZE * y
			for x in 2:
				if padded_occupancy[base + x + idx_y + idx_z] != 0:
					nx += 0.5 - x
					ny += 0.5 - y
					nz += 0.5 - z
	return Vector3(nx, ny, nz).normalized()


static func _protect(positions: Dictionary, planes: Dictionary) -> void:
	for point: Vector3i in positions:
		var px := point.x
		var py := point.y
		var pz := point.z
		for sign_value in [-1, 1]:
			var plane := Vector3i(0, sign_value, px)
			if planes.has(plane):
				planes[plane][Vector2i((py + 1) / 2, (pz + 1) / 2)] = true
		for sign_value in [-1, 1]:
			var plane := Vector3i(1, sign_value, py)
			if planes.has(plane):
				planes[plane][Vector2i((pz + 1) / 2, (px + 1) / 2)] = true
		for sign_value in [-1, 1]:
			var plane := Vector3i(2, sign_value, pz)
			if planes.has(plane):
				planes[plane][Vector2i((px + 1) / 2, (py + 1) / 2)] = true


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
			samples[patch] = (corners[0] + corners[2]) * 0.5
		uvs.append(samples[patch])
	target[Mesh.ARRAY_TEX_UV] = uvs
	return true
