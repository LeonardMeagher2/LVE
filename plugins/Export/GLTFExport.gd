extends RefCounted


var host: Node
var _export_job: ExportJob
var _export_root: Node3D
var _export_operation_id := 0


func _init(owner_node: Node) -> void:
	host = owner_node


class ExportJob extends VoxelFrame.EditJob:
	const WELD_EPSILON := 0.00001
	const DISSOLVE_LINK_LIMIT := 16
	const ATLAS := preload("res://Globals/Rendering/VoxelAtlas.gd")
	const SURFACE := preload("res://Globals/Rendering/VoxelSurface.gd")
	var frames: Array[VoxelFrame] = []
	var frame_delays: PackedInt32Array = []
	var tags: Array[AnimationTag] = []
	var frame_surfaces: Array[Array] = []
	var frame_atlases: Array[RefCounted] = []
	var error := OK
	var center_origin := true
	var smooth_normals := false
	var ao_strength := 1.0
	var unlit := false
	var mesh_style := 0

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
			if mesh_style == 1:
				var bounds := _build_marching_frame(frame)
				if error != OK:
					return
				min_position = min_position.min(bounds[0])
				max_position = max_position.max(bounds[1])
				vertex_count += bounds[2]
				completed += frame.chunks.size()
				continue
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
				mesh_job.ao_strength = ao_strength
				mesh_job.texture_materials = false
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
			if mesh_style == 1:
				continue
			var welded := _weld_frame(frame_surfaces[frame_index], frame_index)
			if welded.is_empty():
				return
			stage("Preparing frame %d/%d surfaces" % [frame_index + 1, frames.size()], -1)
			var surface := SURFACE.new()
			surface.run(welded, frames[frame_index], Vector3.ZERO, checkpoint, smooth_normals, ao_strength)
			error = surface.error
			if error != OK:
				return
			frame_surfaces[frame_index] = surface.arrays
			frame_atlases.append(surface.atlas)
			vertex_count += surface.arrays[Mesh.ARRAY_VERTEX].size()
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

	func _build_marching_frame(frame: VoxelFrame) -> Array:
		var positions := PackedVector3Array()
		var normals := PackedVector3Array()
		var colors := PackedColorArray()
		var indices := PackedInt32Array()
		var vertex_materials := PackedInt32Array()
		var material_table := PackedFloat32Array()
		var material_ids := {}
		var completed := 0
		for chunk_location: Vector3i in frame.chunks:
			if not checkpoint(completed):
				error = ERR_UNAVAILABLE
				return [Vector3.ZERO, Vector3.ZERO, 0]
			var mesh_job := VoxelMarchingMeshBuilder.new()
			mesh_job.source_frame = frame
			mesh_job.chunk_location = chunk_location
			mesh_job.smooth_normals = smooth_normals
			mesh_job.ao_strength = ao_strength
			mesh_job.skip_atlas = true
			mesh_job.dissolve_limited = false
			mesh_job.run()
			var source_positions: PackedVector3Array = mesh_job.surface_arrays[Mesh.ARRAY_VERTEX]
			if not source_positions.is_empty():
				var first_vertex := positions.size()
				var origin := Vector3(chunk_location * VoxelFrame.CHUNK_SIZE)
				for position: Vector3 in source_positions:
					positions.append(position + origin)
				normals.append_array(mesh_job.surface_arrays[Mesh.ARRAY_NORMAL])
				if ao_strength > 0.0:
					colors.append_array(mesh_job.surface_arrays[Mesh.ARRAY_COLOR])
				for triangle_index: int in mesh_job.surface_arrays[Mesh.ARRAY_INDEX]:
					indices.append(first_vertex + triangle_index)
				var local_materials: PackedInt32Array = mesh_job.vertex_materials
				var source_table: PackedFloat32Array = mesh_job.material_table
				for vertex in source_positions.size():
					var local_id: int = local_materials[vertex]
					var values := source_table.slice(local_id * VoxelFrame.MATERIAL_STRIDE, (local_id + 1) * VoxelFrame.MATERIAL_STRIDE)
					var frame_id: int = material_ids.get(values, -1)
					if frame_id < 0:
						frame_id = material_table.size() / VoxelFrame.MATERIAL_STRIDE
						material_ids[values] = frame_id
						material_table.append_array(values)
					vertex_materials.append(frame_id)
			completed += 1
		if indices.is_empty():
			return [Vector3.ZERO, Vector3.ZERO, 0]
		var welded := _weld_marching(positions, normals, colors, vertex_materials, indices)
		if welded.is_empty():
			error = ERR_UNAVAILABLE
			return [Vector3.ZERO, Vector3.ZERO, 0]
		positions = welded[0]
		normals = welded[1]
		colors = welded[2]
		vertex_materials = welded[3]
		indices = welded[4]
		if smooth_normals:
			var dissolver := VoxelMarchingMeshBuilder.new()
			dissolver.dissolve_link_limit = DISSOLVE_LINK_LIMIT
			var fill := colors
			if fill.size() != positions.size():
				fill = PackedColorArray()
				fill.resize(positions.size())
				fill.fill(Color.WHITE)
			var dissolved := dissolver.dissolve_surface(positions, normals, colors if colors.size() == positions.size() else fill, vertex_materials, indices)
			positions = dissolved[0]
			normals = dissolved[1]
			colors = dissolved[2]
			indices = dissolved[3]
			vertex_materials = dissolved[4]
		var min_position := Vector3(INF, INF, INF)
		var max_position := Vector3(-INF, -INF, -INF)
		for position: Vector3 in positions:
			min_position = min_position.min(position)
			max_position = max_position.max(position)
		var atlas := ATLAS.new()
		var used := {}
		for id: int in vertex_materials:
			used[id] = true
		var used_ids: Array = used.keys()
		used_ids.sort()
		var patch_of := {}
		for id: int in used_ids:
			var base := id * VoxelFrame.MATERIAL_STRIDE
			var patch := atlas.add_patch(material_table.slice(base, base + VoxelFrame.MATERIAL_STRIDE), Vector2i.ONE, checkpoint)
			if patch < 0:
				error = ERR_UNAVAILABLE
				return [Vector3.ZERO, Vector3.ZERO, 0]
			patch_of[id] = patch
		var bake_error := atlas.bake(checkpoint)
		if bake_error != OK:
			error = bake_error
			return [Vector3.ZERO, Vector3.ZERO, 0]
		var uvs := PackedVector2Array()
		uvs.resize(vertex_materials.size())
		for vertex in vertex_materials.size():
			var corners: PackedVector2Array = atlas.patch_uvs(patch_of[vertex_materials[vertex]])
			uvs[vertex] = (corners[0] + corners[2]) * 0.5
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = positions
		arrays[Mesh.ARRAY_NORMAL] = normals
		if ao_strength > 0.0:
			arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_INDEX] = indices
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		frame_surfaces.append(arrays)
		frame_atlases.append(atlas)
		return [min_position, max_position, positions.size()]


	func _weld_marching(positions: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, vertex_materials: PackedInt32Array, indices: PackedInt32Array) -> Array:
		var count := positions.size()
		var vertex_map := PackedInt32Array()
		vertex_map.resize(count)
		var merged_positions := PackedVector3Array()
		var merged_normals := PackedVector3Array()
		var merged_colors := PackedColorArray()
		var merged_materials := PackedInt32Array()
		var merged_counts := PackedInt32Array()
		var wants_colours := not colors.is_empty()
		var buckets := {}
		stage("Welding frame vertices", count)
		for vertex in count:
			if vertex % 2048 == 0 and not checkpoint(vertex):
				return []
			var position := positions[vertex]
			var material := vertex_materials[vertex]
			var key := Vector4i(roundi(position.x * 1024.0), roundi(position.y * 1024.0), roundi(position.z * 1024.0), material)
			var target := -1
			if smooth_normals:
				target = buckets.get(key, -1)
			else:
				var normal := normals[vertex]
				var normal_key := Vector3i(roundi(normal.x * 1024.0), roundi(normal.y * 1024.0), roundi(normal.z * 1024.0))
				var by_normal: Dictionary = buckets.get(key, {})
				target = by_normal.get(normal_key, -1)
				if target >= 0:
					vertex_map[vertex] = target
					continue
				by_normal[normal_key] = merged_positions.size()
				buckets[key] = by_normal
				target = -1
			if target < 0:
				vertex_map[vertex] = merged_positions.size()
				merged_positions.append(position)
				merged_normals.append(normals[vertex])
				merged_colors.append(colors[vertex] if wants_colours else Color.WHITE)
				merged_materials.append(material)
				merged_counts.append(1)
				if smooth_normals:
					buckets[key] = merged_positions.size() - 1
				continue
			vertex_map[vertex] = target
			merged_normals[target] = merged_normals[target] + normals[vertex]
			if wants_colours:
				merged_colors[target] = merged_colors[target] + colors[vertex]
			merged_counts[target] += 1
		if smooth_normals:
			for vertex in merged_normals.size():
				var normal := merged_normals[vertex]
				merged_normals[vertex] = normal.normalized() if normal.length_squared() > 0.0000000001 else Vector3.UP
				if wants_colours:
					var divisor := float(maxi(merged_counts[vertex], 1))
					merged_colors[vertex] = merged_colors[vertex] / divisor
		var merged_indices := PackedInt32Array()
		merged_indices.resize(indices.size())
		for index in indices.size():
			merged_indices[index] = vertex_map[indices[index]]
		return [merged_positions, merged_normals, merged_colors, merged_materials, merged_indices]


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
		var vertex_map := PackedInt32Array()
		vertex_map.resize(source_positions.size())
		var buckets := {}
		stage("Welding frame %d/%d vertices" % [frame_index + 1, frames.size()], source_positions.size())
		for vertex_index in source_positions.size():
			if vertex_index % 256 == 0 and not checkpoint(vertex_index):
				return []
			var position := source_positions[vertex_index]
			var bucket := Vector3i((position / WELD_EPSILON).floor())
			var match_index := _weld_match(positions, normals, colors, buckets, bucket, position, source_normals[vertex_index], source_colors[vertex_index])
			if match_index == -1:
				match_index = positions.size()
				positions.append(position)
				normals.append(source_normals[vertex_index])
				colors.append(source_colors[vertex_index])
				if not buckets.has(bucket):
					buckets[bucket] = []
				buckets[bucket].append(match_index)
			vertex_map[vertex_index] = match_index
		var indices := PackedInt32Array()
		indices.resize(source_indices.size())
		for index in source_indices.size():
			indices[index] = vertex_map[source_indices[index]]
		var welded := arrays.duplicate()
		welded[Mesh.ARRAY_VERTEX] = positions
		welded[Mesh.ARRAY_NORMAL] = normals
		welded[Mesh.ARRAY_COLOR] = colors
		welded[Mesh.ARRAY_INDEX] = indices
		return welded


	func _weld_match(positions: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, buckets: Dictionary, bucket: Vector3i, position: Vector3, normal: Vector3, color: Color) -> int:
		var match_index := _bucket_match(positions, normals, colors, buckets, bucket, position, normal, color)
		if match_index != -1:
			return match_index
		for x in range(-1, 2):
			for y in range(-1, 2):
				for z in range(-1, 2):
					if x == 0 and y == 0 and z == 0:
						continue
					match_index = _bucket_match(positions, normals, colors, buckets, bucket + Vector3i(x, y, z), position, normal, color)
					if match_index != -1:
						return match_index
		return -1


	func _bucket_match(positions: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, buckets: Dictionary, key: Vector3i, position: Vector3, normal: Vector3, color: Color) -> int:
		if not buckets.has(key):
			return -1
		for candidate: int in buckets[key]:
			if normals[candidate] == normal and colors[candidate] == color and positions[candidate].distance_squared_to(position) <= WELD_EPSILON * WELD_EPSILON:
				return candidate
		return -1


	func _simplify_frame(arrays: Array, frame_index: int) -> Array:
		var quad_count: int = arrays[Mesh.ARRAY_INDEX].size() / 6
		stage("Simplifying frame %d/%d" % [frame_index + 1, frames.size()], quad_count)
		return SURFACE.merge(arrays, checkpoint)


func cancel() -> void:
	if _export_job and _export_job.worker_task_id >= 0:
		_export_job.cancel()
		_export_job.wait_for_worker()
	_finish_export()


func export_gltf(path: String, center_origin := true, tag_index := -1, overrides := {}) -> Error:
	if State.edit_busy() or _export_job:
		return ERR_BUSY
	State.stop()
	var job := ExportJob.new()
	job.center_origin = center_origin
	job.smooth_normals = bool(overrides.get("smooth_normals", State.document.smooth_normals))
	job.ao_strength = clampf(float(overrides.get("ao", State.document.ao_strength)), 0.0, 1.0)
	job.unlit = bool(overrides.get("unlit", false))
	job.mesh_style = State.document.mesh_style
	var selected_tag := State.document.get_tag(tag_index)
	var first := selected_tag.from if selected_tag else 0
	var last := selected_tag.to if selected_tag else State.get_frame_count() - 1
	for index in range(first, last + 1):
		job.frames.append(State.get_composite_voxel_frame(index).copy_frame())
		job.frame_delays.append(State.document.frame_delay(index))
	for index in State.document.tags.size():
		if selected_tag and index != tag_index:
			continue
		var tag: AnimationTag = State.document.tags[index].duplicate()
		tag.from -= first
		tag.to -= first
		job.tags.append(tag)
	_export_job = job
	_export_operation_id = State.begin_operation("Exporting", -1, true, host, cancel)
	var operation_id := _export_operation_id
	job.worker_task_id = WorkerThreadPool.add_task(job.run, false, "glTF export meshes")
	while job.worker_task_id >= 0 and not WorkerThreadPool.is_task_completed(job.worker_task_id):
		if not State.has_operation(operation_id):
			job.cancel()
		var progress := job.progress()
		State.update_operation(_export_operation_id, progress[1], progress[2], progress[0])
		await State.get_tree().process_frame
	if job.worker_task_id < 0:
		return ERR_UNAVAILABLE
	job.wait_for_worker()
	if _export_job != job:
		return ERR_UNAVAILABLE
	if not is_instance_valid(host) or not host.is_inside_tree() or not State.has_operation(operation_id):
		_finish_export()
		return ERR_UNAVAILABLE
	if job.error != OK:
		var error: Error = job.error
		_finish_export()
		push_error("LVE: export texture atlas exceeds %d pixels" % job.ATLAS.MAX_SIZE)
		return error
	_export_root = Node3D.new()
	_export_root.name = "LVE"
	var slice_started_us := Time.get_ticks_usec()
	for frame_index in job.frames.size():
		State.update_operation(_export_operation_id, frame_index, job.frames.size(), "Preparing glTF scene")
		var frame_node: Node3D
		var arrays := job.frame_surfaces[frame_index]
		if not arrays[Mesh.ARRAY_VERTEX].is_empty():
			var material: StandardMaterial3D = job.frame_atlases[frame_index].create_material()
			if job.unlit:
				material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			if job.ao_strength > 0.0:
				material.vertex_color_use_as_albedo = true
				material.vertex_color_is_srgb = false
			var frame_mesh := ArrayMesh.new()
			frame_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			frame_mesh.surface_set_material(0, material)
			var mesh_instance := MeshInstance3D.new()
			mesh_instance.mesh = frame_mesh
			frame_node = mesh_instance
		else:
			frame_node = Node3D.new()
		frame_node.name = "Frame_%d" % frame_index
		if frame_index != 0:
			frame_node.scale = Vector3.ONE * 0.000001
		_export_root.add_child(frame_node)
		frame_node.owner = _export_root
		if Time.get_ticks_usec() - slice_started_us >= State.WORK_SLICE_US:
			await State.get_tree().process_frame
			if _export_job != job:
				return ERR_UNAVAILABLE
			if not is_instance_valid(host) or not host.is_inside_tree() or not State.has_operation(operation_id):
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
		_add_export_clip(library, tag.name, _tag_sequence(tag), job.frames, job.frame_delays, tag.repeats == 0)
	State.update_operation(_export_operation_id, 0, -1, "Writing glTF")
	var gltf_document := GLTFDocument.new()
	gltf_document.root_node_mode = GLTFDocument.ROOT_NODE_MODE_KEEP_ROOT
	var gltf_state := GLTFState.new()
	var error := gltf_document.append_from_scene(_export_root, gltf_state)
	if error == OK:
		error = gltf_document.write_to_filesystem(gltf_state, path)
	_finish_export()
	if error != OK:
		push_error("LVE: glTF export failed: %s" % error_string(error))
	return error


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


func _add_export_clip(library: AnimationLibrary, clip_name: String, sequence: Array[int], frames: Array[VoxelFrame], frame_delays: PackedInt32Array, looping: bool) -> void:
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
		time += maxf(frame_delays[frame_index] if frame_index < frame_delays.size() else 100, 1.0) / 1000.0
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
