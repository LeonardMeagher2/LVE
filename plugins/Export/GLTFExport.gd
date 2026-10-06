extends RefCounted

var host: Node
var _export_job: ExportJob
var _export_root: Node3D
var _export_operation_id := 0


func _init(owner_node: Node) -> void:
	host = owner_node


class ExportJob extends VoxelFrame.EditJob:
	const WELD_EPSILON := 0.00001
	var frames: Array[VoxelFrame] = []
	var tags: Array[AnimationTag] = []
	var frame_surfaces: Array[Array] = []
	var has_transparency := false
	var center_origin := true
	var smooth_normals := false

	func run() -> void:
		var total := 0
		for frame in frames:
			total += frame.chunks.size()
		stage("Building export meshes", total)
		var completed := 0
		var min_position := Vector3(INF, INF, INF)
		var max_position := Vector3(-INF, -INF, -INF)
		var vertex_count := 0
		for frame in frames:
			var positions := PackedVector3Array()
			var normals := PackedVector3Array()
			var colors := PackedColorArray()
			var indices := PackedInt32Array()
			for chunk_location: Vector3i in frame.chunks:
				if not checkpoint(completed):
					return
				var mesh_job := VoxelMeshBuilder.new()
				mesh_job.source_frame = frame
				mesh_job.chunk_location = chunk_location
				mesh_job.smooth_normals = smooth_normals
				mesh_job.run()
				var first_vertex := positions.size()
				var origin := Vector3(chunk_location * VoxelFrame.CHUNK_SIZE)
				for position: Vector3 in mesh_job.surface_arrays[Mesh.ARRAY_VERTEX]:
					var world_position := position + origin
					positions.append(world_position)
					min_position = min_position.min(world_position)
					max_position = max_position.max(world_position)
				normals.append_array(mesh_job.surface_arrays[Mesh.ARRAY_NORMAL])
				for color: Color in mesh_job.surface_arrays[Mesh.ARRAY_COLOR]:
					colors.append(color.srgb_to_linear())
					has_transparency = has_transparency or color.a < 1.0
				for triangle_index: int in mesh_job.surface_arrays[Mesh.ARRAY_INDEX]:
					indices.append(first_vertex + triangle_index)
				completed += 1
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = positions
			arrays[Mesh.ARRAY_NORMAL] = normals
			arrays[Mesh.ARRAY_COLOR] = colors
			arrays[Mesh.ARRAY_INDEX] = indices
			frame_surfaces.append(arrays)
		checkpoint(completed)
		for frame_index in frame_surfaces.size():
			var welded := _weld_frame(frame_surfaces[frame_index], frame_index)
			if welded.is_empty():
				return
			var simplified := welded if smooth_normals else _simplify_frame(welded, frame_index)
			if simplified.is_empty():
				return
			frame_surfaces[frame_index] = simplified if smooth_normals else _weld_frame(simplified, frame_index)
			if frame_surfaces[frame_index].is_empty():
				return
			vertex_count += frame_surfaces[frame_index][Mesh.ARRAY_VERTEX].size()
		if vertex_count == 0:
			return
		var center := (min_position + max_position) * 0.5
		if not center_origin:
			center = Vector3.ZERO
		stage("Centering export meshes", vertex_count)
		completed = 0
		for arrays in frame_surfaces:
			var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for vertex_index in positions.size():
				positions[vertex_index] -= center
				completed += 1
				if completed % 4096 == 0 and not checkpoint(completed):
					return
			arrays[Mesh.ARRAY_VERTEX] = positions
		checkpoint(completed)

	func _weld_frame(arrays: Array, frame_index: int) -> Array:
		var source_positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if source_positions.is_empty():
			return arrays
		var source_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var source_colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var source_indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var positions := PackedVector3Array()
		var normals := PackedVector3Array()
		var colors := PackedColorArray()
		var remap := PackedInt32Array()
		remap.resize(source_positions.size())
		var buckets := {}
		stage("Welding frame %d/%d vertices" % [frame_index + 1, frames.size()], source_positions.size())
		for vertex_index in source_positions.size():
			if vertex_index % 256 == 0 and not checkpoint(vertex_index):
				return []
			var position := source_positions[vertex_index]
			var bucket := Vector3i((position / WELD_EPSILON).floor())
			var match_index := -1
			for x in range(-1, 2):
				for y in range(-1, 2):
					for z in range(-1, 2):
						for candidate: int in buckets.get(bucket + Vector3i(x, y, z), []):
							if normals[candidate] == source_normals[vertex_index] and colors[candidate] == source_colors[vertex_index] and positions[candidate].distance_squared_to(position) <= WELD_EPSILON * WELD_EPSILON:
								match_index = candidate
								break
						if match_index != -1:
							break
					if match_index != -1:
						break
				if match_index != -1:
					break
			if match_index == -1:
				match_index = positions.size()
				positions.append(position)
				normals.append(source_normals[vertex_index])
				colors.append(source_colors[vertex_index])
				if not buckets.has(bucket):
					buckets[bucket] = []
				buckets[bucket].append(match_index)
			remap[vertex_index] = match_index
		var indices := PackedInt32Array()
		indices.resize(source_indices.size())
		for index in source_indices.size():
			indices[index] = remap[source_indices[index]]
		var welded := arrays.duplicate()
		welded[Mesh.ARRAY_VERTEX] = positions
		welded[Mesh.ARRAY_NORMAL] = normals
		welded[Mesh.ARRAY_COLOR] = colors
		welded[Mesh.ARRAY_INDEX] = indices
		return welded


	func _simplify_frame(arrays: Array, frame_index: int) -> Array:
		var source_positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if source_positions.is_empty():
			return arrays
		var source_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var source_colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var source_indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var quad_count: int = arrays[Mesh.ARRAY_INDEX].size() / 6
		stage("Simplifying frame %d/%d" % [frame_index + 1, frames.size()], quad_count)
		# Sparse face masks merge chunk boundaries without scanning empty frame bounds.
		var planes := {}
		var face_count := 0
		for quad_index in quad_count:
			if not checkpoint(quad_index):
				return []
			var first_vertex := source_indices[quad_index * 6]
			var origin := source_positions[first_vertex]
			var normal := source_normals[first_vertex]
			var axis := 0 if normal.x != 0 else (1 if normal.y != 0 else 2)
			var column_axis := (axis + 1) % 3
			var row_axis := (axis + 2) % 3
			var plane_key := Vector3i(axis, int(normal[axis]), roundi(origin[axis] * 2))
			var face_cells: Dictionary = planes.get(plane_key, {})
			planes[plane_key] = face_cells
			var column := roundi(origin[column_axis] + 0.5)
			var row := roundi(origin[row_axis] + 0.5)
			var column_vertex := source_indices[quad_index * 6 + (2 if normal[axis] > 0 else 1)]
			var row_vertex := source_indices[quad_index * 6 + (4 if normal[axis] > 0 else 5)]
			var width := roundi(source_positions[column_vertex][column_axis] - origin[column_axis])
			var height := roundi(source_positions[row_vertex][row_axis] - origin[row_axis])
			for row_offset in height:
				for column_offset in width:
					face_cells[Vector2i(column + column_offset, row + row_offset)] = source_colors[first_vertex]
			face_count += width * height
		stage("Merging frame %d/%d surfaces" % [frame_index + 1, frames.size()], face_count)
		var positions := PackedVector3Array()
		var normals := PackedVector3Array()
		var colors := PackedColorArray()
		var indices := PackedInt32Array()
		var completed := 0
		for plane_key: Vector3i in planes:
			var face_cells: Dictionary = planes[plane_key]
			var face_positions := face_cells.keys()
			face_positions.sort_custom(func(first, second): return first.y < second.y or (first.y == second.y and first.x < second.x))
			var column_axis := (plane_key.x + 1) % 3
			var row_axis := (plane_key.x + 2) % 3
			var normal := Vector3.ZERO
			normal[plane_key.x] = plane_key.y
			for face_position: Vector2i in face_positions:
				if not face_cells.has(face_position):
					continue
				if not checkpoint(completed):
					return []
				var color: Color = face_cells[face_position]
				var width := 1
				while face_cells.get(face_position + Vector2i(width, 0), Color.TRANSPARENT) == color:
					width += 1
				var height := 1
				var row_matches := true
				while row_matches:
					for column_offset in width:
						if face_cells.get(face_position + Vector2i(column_offset, height), Color.TRANSPARENT) != color:
							row_matches = false
							break
					if row_matches:
						height += 1
				var origin := Vector3.ZERO
				origin[plane_key.x] = plane_key.z * 0.5
				origin[column_axis] = face_position.x - 0.5
				origin[row_axis] = face_position.y - 0.5
				var column_edge := Vector3.ZERO
				var row_edge := Vector3.ZERO
				column_edge[column_axis] = width
				row_edge[row_axis] = height
				var first_vertex := positions.size()
				positions.append_array(PackedVector3Array([origin, origin + column_edge, origin + column_edge + row_edge, origin + row_edge]))
				for _corner in 4:
					normals.append(normal)
					colors.append(color)
				if plane_key.y > 0:
					indices.append_array(PackedInt32Array([first_vertex, first_vertex + 2, first_vertex + 1, first_vertex, first_vertex + 3, first_vertex + 2]))
				else:
					indices.append_array(PackedInt32Array([first_vertex, first_vertex + 1, first_vertex + 2, first_vertex, first_vertex + 2, first_vertex + 3]))
				for row_offset in height:
					for column_offset in width:
						face_cells.erase(face_position + Vector2i(column_offset, row_offset))
					completed += width
					if not checkpoint(completed):
						return []
		if indices.size() >= arrays[Mesh.ARRAY_INDEX].size():
			return arrays
		var simplified := arrays.duplicate()
		simplified[Mesh.ARRAY_VERTEX] = positions
		simplified[Mesh.ARRAY_NORMAL] = normals
		simplified[Mesh.ARRAY_COLOR] = colors
		simplified[Mesh.ARRAY_INDEX] = indices
		return simplified


func cancel() -> void:
	if _export_job and _export_job.worker_task_id >= 0:
		_export_job.cancel()
		WorkerThreadPool.wait_for_task_completion(_export_job.worker_task_id)
		_export_job.worker_task_id = -1
	_finish_export()


func export_gltf(path: String, center_origin := true, tag_index := -1) -> Error:
	if State.edit_busy() or _export_job:
		return ERR_BUSY
	State.stop()
	var job := ExportJob.new()
	job.center_origin = center_origin
	job.smooth_normals = State.document.smooth_normals
	var selected_tag := State.document.get_tag(tag_index)
	var first := selected_tag.from if selected_tag else 0
	var last := selected_tag.to if selected_tag else State.get_frame_count() - 1
	for index in range(first, last + 1):
		job.frames.append(State.get_voxel_frame(index).copy_frame())
	for index in State.document.tags.size():
		if selected_tag and index != tag_index:
			continue
		var tag: AnimationTag = State.document.tags[index].duplicate()
		tag.from -= first
		tag.to -= first
		job.tags.append(tag)
	_export_job = job
	_export_operation_id = State.begin_operation("Building export meshes", -1, true, host)
	job.worker_task_id = WorkerThreadPool.add_task(job.run, false, "glTF export meshes")
	while job.worker_task_id >= 0 and not WorkerThreadPool.is_task_completed(job.worker_task_id):
		if not State.has_operation(_export_operation_id):
			job.cancel()
		var progress := job.progress()
		State.update_operation(_export_operation_id, progress[1], progress[2], progress[0])
		await State.get_tree().process_frame
	if job.worker_task_id < 0:
		return ERR_UNAVAILABLE
	WorkerThreadPool.wait_for_task_completion(job.worker_task_id)
	job.worker_task_id = -1
	if not is_instance_valid(host) or not host.is_inside_tree() or not State.has_operation(_export_operation_id):
		_finish_export()
		return ERR_UNAVAILABLE
	_export_root = Node3D.new()
	_export_root.name = "Voxi"
	var material: StandardMaterial3D = preload("res://VoxelMaterial.tres").duplicate()
	material.vertex_color_is_srgb = false
	if job.has_transparency:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var slice_started_us := Time.get_ticks_usec()
	for frame_index in job.frames.size():
		State.update_operation(_export_operation_id, frame_index, job.frames.size(), "Preparing glTF scene")
		var frame_node: Node3D
		var arrays := job.frame_surfaces[frame_index]
		if not arrays[Mesh.ARRAY_VERTEX].is_empty():
			var frame_mesh := ArrayMesh.new()
			# Godot 4.7 reads the first primitive's colors after it configures the material.
			# Two real surfaces enable vertex colors on their shared material during import.
			var quad_count: int = arrays[Mesh.ARRAY_INDEX].size() / 6
			var split_quad: int = quad_count / 2
			for quad_range in [Vector2i(0, split_quad), Vector2i(split_quad, quad_count)]:
				var surface_arrays := _surface_slice(arrays, quad_range)
				frame_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_arrays)
				frame_mesh.surface_set_material(frame_mesh.get_surface_count() - 1, material)
			var mesh_instance := MeshInstance3D.new()
			mesh_instance.mesh = frame_mesh
			frame_node = mesh_instance
		else:
			frame_node = Node3D.new()
		frame_node.name = "Frame_%d" % frame_index
		if frame_index != 0:
			# Keep the rest basis invertible. Scale animation keys use exact zero.
			frame_node.scale = Vector3.ONE * 0.000001
		_export_root.add_child(frame_node)
		frame_node.owner = _export_root
		if Time.get_ticks_usec() - slice_started_us >= State.WORK_SLICE_US:
			await State.get_tree().process_frame
			if not is_instance_valid(host) or not host.is_inside_tree() or not State.has_operation(_export_operation_id):
				_finish_export()
				return ERR_UNAVAILABLE
			slice_started_us = Time.get_ticks_usec()
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	_export_root.add_child(player)
	player.owner = _export_root
	var library := AnimationLibrary.new()
	player.add_animation_library("", library)
	for tag in job.tags:
		_add_export_clip(library, tag.name, _tag_sequence(tag), job.frames, tag.repeats == 0)
	State.update_operation(_export_operation_id, 0, -1, "Writing glTF")
	var gltf_document := GLTFDocument.new()
	gltf_document.root_node_mode = GLTFDocument.ROOT_NODE_MODE_KEEP_ROOT
	var gltf_state := GLTFState.new()
	var error := gltf_document.append_from_scene(_export_root, gltf_state)
	if error == OK:
		error = gltf_document.write_to_filesystem(gltf_state, path)
	_finish_export()
	if error != OK:
		push_error("Voxi: glTF export failed: %s" % error_string(error))
	return error


func _surface_slice(arrays: Array, quad_range: Vector2i) -> Array:
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX].slice(quad_range.x * 6, quad_range.y * 6)
	var remap := {}
	for index in indices.size():
		var source_index := indices[index]
		if not remap.has(source_index):
			remap[source_index] = positions.size()
			positions.append(arrays[Mesh.ARRAY_VERTEX][source_index])
			normals.append(arrays[Mesh.ARRAY_NORMAL][source_index])
			colors.append(arrays[Mesh.ARRAY_COLOR][source_index])
		indices[index] = remap[source_index]
	var surface_arrays := arrays.duplicate()
	surface_arrays[Mesh.ARRAY_VERTEX] = positions
	surface_arrays[Mesh.ARRAY_NORMAL] = normals
	surface_arrays[Mesh.ARRAY_COLOR] = colors
	surface_arrays[Mesh.ARRAY_INDEX] = indices
	return surface_arrays


func _finish_export() -> void:
	_export_job = null
	State.finish_operation(_export_operation_id)
	_export_operation_id = 0
	if is_instance_valid(_export_root):
		_export_root.free()
	_export_root = null


func _tag_sequence(tag: AnimationTag) -> Array[int]:
	var cycle: Array[int] = []
	if tag.loop_mode in [AnimationTag.LoopMode.REVERSE, AnimationTag.LoopMode.PING_PONG_REVERSE]:
		for frame_index in range(tag.to, tag.from - 1, -1):
			cycle.append(frame_index)
		if tag.loop_mode == AnimationTag.LoopMode.PING_PONG_REVERSE:
			for frame_index in range(tag.from + 1, tag.to):
				cycle.append(frame_index)
	else:
		for frame_index in range(tag.from, tag.to + 1):
			cycle.append(frame_index)
		if tag.loop_mode == AnimationTag.LoopMode.PING_PONG:
			for frame_index in range(tag.to - 1, tag.from, -1):
				cycle.append(frame_index)
	var sequence: Array[int] = []
	for _repeat in maxi(tag.repeats, 1):
		sequence.append_array(cycle)
	if tag.loop_mode == AnimationTag.LoopMode.PING_PONG and tag.repeats > 0 and tag.from != tag.to:
		sequence.append(tag.from)
	elif tag.loop_mode == AnimationTag.LoopMode.PING_PONG_REVERSE and tag.repeats > 0 and tag.from != tag.to:
		sequence.append(tag.to)
	return sequence


func _add_export_clip(library: AnimationLibrary, clip_name: String, sequence: Array[int], frames: Array[VoxelFrame], looping: bool) -> void:
	var animation := Animation.new()
	animation.loop_mode = Animation.LOOP_LINEAR if looping else Animation.LOOP_NONE
	for frame_index in frames.size():
		var track := animation.add_track(Animation.TYPE_SCALE_3D)
		animation.track_set_path(track, NodePath("Frame_%d:scale" % frame_index))
		animation.track_set_interpolation_type(track, Animation.INTERPOLATION_NEAREST)
		animation.track_set_interpolation_loop_wrap(track, false)
		animation.scale_track_insert_key(track, 0.0, Vector3.ONE if frame_index == sequence[0] else Vector3.ZERO)
	var time := 0.0
	for step_index in sequence.size():
		var frame_index := sequence[step_index]
		time += maxf(frames[frame_index].delay_ms, 1.0) / 1000.0
		if step_index + 1 < sequence.size():
			var next_frame := sequence[step_index + 1]
			if next_frame != frame_index:
				animation.scale_track_insert_key(frame_index, time, Vector3.ZERO)
				animation.scale_track_insert_key(next_frame, time, Vector3.ONE)
	animation.length = time
	for frame_index in frames.size():
		animation.scale_track_insert_key(frame_index, time, Vector3.ONE if frame_index == sequence.back() else Vector3.ZERO)
	var name_base := clip_name
	for character in ["/", ":", "[", "]", "."]:
		name_base = name_base.replace(character, "_")
	if name_base.is_empty() or name_base == "RESET":
		name_base = "Animation"
	if not looping:
		var lower_name := name_base.to_lower()
		if lower_name.begins_with("loop") or lower_name.begins_with("cycle"):
			name_base = "Clip_" + name_base
		if lower_name.ends_with("loop") or lower_name.ends_with("cycle"):
			name_base += "_once"
	var loop_suffix := "_loop" if looping else ""
	var name_candidate := name_base + loop_suffix
	var suffix := 2
	while library.has_animation(name_candidate):
		name_candidate = "%s_%d%s" % [name_base, suffix, loop_suffix]
		suffix += 1
	library.add_animation(name_candidate, animation)
