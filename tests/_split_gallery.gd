extends "res://tests/test.gd"


const MARCH := preload("res://Globals/Rendering/VoxelMarchingMeshBuilder.gd")
const IMAGE_RENDERER := preload("res://Globals/VoxelImageRenderer/VoxelImageRenderer.gd")
const VIEWPORT_SCENE := preload("res://Globals/VoxelImageRenderer/RendererViewport.tscn")
const OUTPUT_DIR := "res://.tests/_split_gallery"
const MODELS := [
	"Turkey.lve",
	"me.lve",
	"egypt.lve",
	"noodle_stand.lve",
	"sword_and_shield.lve",
	"flamingo.lve",
	"Krab.lve",
]
const JOIN_ALIGNMENT := 0.5
const FACE_OFFSETS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]


func _ready() -> void:
	test("render grouped surfaces for several models", _run, "split_gallery", {"timeout": 900.0})


func _run() -> void:
	var viewport: SubViewport = VIEWPORT_SCENE.instantiate()
	viewport.size = Vector2i(640, 640)
	add_child(viewport)
	await get_tree().process_frame
	var node3d: Node3D = viewport.get_node("Node3D")
	var camera: Camera3D = viewport.get_node("Node3D/Camera3D")
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true
	material.roughness = 1.0
	var directory := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(directory)
	var rendered := 0
	for name: String in MODELS:
		var document := VoxelDocument.load_file("res://LVE-prototypes/" + name)
		if document == null:
			continue
		var frame := document.active_layer().frames[0]
		var groups := _classify_voxels(frame)
		var union := _build(frame, false, false, [])
		var grouped := _build(frame, true, false, groups)
		var solid := _solid_cells(frame)
		var stripped := _remove_inner(grouped["arrays"], solid)
		var union_metrics := _metrics(union["arrays"])
		var grouped_metrics := _metrics(grouped["arrays"])
		var stripped_metrics := _metrics(stripped)
		print("MEASURE gallery %s: groups=%d union_ms=%d grouped_ms=%d union_triangles=%d grouped_triangles=%d stripped_triangles=%d stripped_unpaired=%d stripped_duplicates=%d" % [
			name, groups.size(), union["ms"], grouped["ms"], union_metrics.triangles, grouped_metrics.triangles,
			stripped_metrics.triangles, stripped_metrics.unpaired, stripped_metrics.duplicates,
		])
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, stripped)
		var instance := MeshInstance3D.new()
		instance.mesh = mesh
		instance.material_override = material
		node3d.add_child(instance)
		var framer = IMAGE_RENDERER.new()
		framer.frame_camera(camera, _bounds(union["arrays"]), -40.0, 30.0, true)
		framer.free()
		for draw in 2:
			viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
			await RenderingServer.frame_post_draw
		viewport.get_texture().get_image().save_png(directory + "/" + name.get_basename() + "_grouped.png")
		instance.queue_free()
		await get_tree().process_frame
		rendered += 1
	viewport.queue_free()
	expect(rendered > 0, "the gallery renders")


func _build(frame: VoxelFrame, per_material: bool, hard_boundaries: bool, groups: Array) -> Dictionary:
	var started := Time.get_ticks_msec()
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for location: Vector3i in frame.chunks:
		var builder = MARCH.new()
		builder.source_frame = frame
		builder.chunk_location = location
		builder.per_material = per_material
		builder.hard_boundaries = hard_boundaries
		builder.material_groups = groups
		builder.run()
		var offset := Vector3(location * VoxelFrame.CHUNK_SIZE)
		var first := positions.size()
		for position: Vector3 in builder.surface_arrays[Mesh.ARRAY_VERTEX]:
			positions.append(position + offset)
		normals.append_array(builder.surface_arrays[Mesh.ARRAY_NORMAL])
		colors.append_array(builder.surface_arrays[Mesh.ARRAY_COLOR])
		for vertex: int in builder.surface_arrays[Mesh.ARRAY_INDEX]:
			indices.append(first + vertex)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	return {"arrays": arrays, "ms": Time.get_ticks_msec() - started}


func _solid_cells(frame: VoxelFrame) -> Dictionary:
	var cells := {}
	for location: Vector3i in frame.chunks:
		var chunk: VoxelFrame.Chunk = frame.chunks[location]
		var rows = chunk.occupancy_rows()
		for row in rows.masks.size():
			var mask: int = rows.masks[row]
			var local_y: int = row % VoxelFrame.CHUNK_SIZE
			var local_z: int = row / VoxelFrame.CHUNK_SIZE
			while mask != 0:
				var local_x: int = VoxelFrame.Chunk.first_column(mask)
				mask &= mask - 1
				var id: int = chunk.cell_id_at_slot(row * VoxelFrame.CHUNK_SIZE + local_x)
				if id == 0:
					continue
				cells[location * VoxelFrame.CHUNK_SIZE + Vector3i(local_x, local_y, local_z)] = true
	return cells


func _remove_inner(arrays: Array, solid: Dictionary) -> Array:
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var kept := PackedInt32Array()
	for offset in range(0, indices.size(), 3):
		var first := indices[offset]
		var second := indices[offset + 1]
		var third := indices[offset + 2]
		var normal := normals[first]
		var centre := (positions[first] + positions[second] + positions[third]) / 3.0
		if _inside(centre + normal * 0.35, solid) and _inside(centre - normal * 0.35, solid):
			continue
		kept.append(first)
		kept.append(second)
		kept.append(third)
	var result := []
	result.resize(Mesh.ARRAY_MAX)
	result[Mesh.ARRAY_VERTEX] = positions
	result[Mesh.ARRAY_NORMAL] = normals
	result[Mesh.ARRAY_COLOR] = arrays[Mesh.ARRAY_COLOR]
	result[Mesh.ARRAY_INDEX] = kept
	return result


func _inside(point: Vector3, solid: Dictionary) -> bool:
	return solid.has(Vector3i(roundi(point.x), roundi(point.y), roundi(point.z)))


func _classify_voxels(frame: VoxelFrame) -> Array:
	var cells := {}
	for location: Vector3i in frame.chunks:
		var chunk: VoxelFrame.Chunk = frame.chunks[location]
		var rows = chunk.occupancy_rows()
		for row in rows.masks.size():
			var mask: int = rows.masks[row]
			var local_y: int = row % VoxelFrame.CHUNK_SIZE
			var local_z: int = row / VoxelFrame.CHUNK_SIZE
			while mask != 0:
				var local_x: int = VoxelFrame.Chunk.first_column(mask)
				mask &= mask - 1
				var id: int = chunk.cell_id_at_slot(row * VoxelFrame.CHUNK_SIZE + local_x)
				if id == 0:
					continue
				var key := _material_key(chunk.materials, id)
				cells[location * VoxelFrame.CHUNK_SIZE + Vector3i(local_x, local_y, local_z)] = key
	var normals := {}
	var keys := {}
	for cell: Vector3i in cells:
		normals[cell] = _face_normal(cell, cells)
		keys[cells[cell]] = true
	var pair_sums := {}
	var pair_counts := {}
	var parent := {}
	for key: String in keys:
		parent[key] = key
	var axes: Array[Vector3i] = [Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 0, 1)]
	for cell: Vector3i in cells:
		for axis: Vector3i in axes:
			var other := cell + axis
			if not cells.has(other):
				continue
			var first_key: String = cells[cell]
			var second_key: String = cells[other]
			if first_key == second_key:
				continue
			var first_normal: Vector3 = normals[cell]
			var second_normal: Vector3 = normals[other]
			var surface := first_normal + second_normal
			if surface.length_squared() < 0.0001:
				continue
			surface = surface.normalized()
			var alignment := absf(surface.dot(Vector3(axis)))
			var pair := first_key + "|" + second_key
			if second_key < first_key:
				pair = second_key + "|" + first_key
			pair_sums[pair] = pair_sums.get(pair, 0.0) + alignment
			pair_counts[pair] = pair_counts.get(pair, 0) + 1
	for pair: String in pair_counts:
		var average: float = pair_sums[pair] / pair_counts[pair]
		var parts: PackedStringArray = pair.split("|")
		if average < JOIN_ALIGNMENT:
			_union(parent, parts[0], parts[1])
	var grouped := {}
	for key: String in keys:
		var root := _find(parent, key)
		if not grouped.has(root):
			grouped[root] = []
		grouped[root].append(key)
	return grouped.values()


func _material_key(materials: PackedFloat32Array, id: int) -> String:
	var base := (id - 1) * VoxelFrame.MATERIAL_STRIDE
	var parts := PackedStringArray()
	for offset in VoxelFrame.MATERIAL_STRIDE:
		parts.append(String.num(materials[base + offset], 3))
	return ",".join(parts)


func _face_normal(cell: Vector3i, cells: Dictionary) -> Vector3:
	var normal := Vector3.ZERO
	for offset: Vector3i in FACE_OFFSETS:
		if not cells.has(cell + offset):
			normal += Vector3(offset)
	if normal.length_squared() > 0.0:
		normal = normal.normalized()
	return normal


func _find(parent: Dictionary, key: String) -> String:
	var root: String = key
	while parent[root] != root:
		root = parent[root]
	while parent[key] != root:
		var next: String = parent[key]
		parent[key] = root
		key = next
	return root


func _union(parent: Dictionary, first: String, second: String) -> void:
	var first_root := _find(parent, first)
	var second_root := _find(parent, second)
	if first_root != second_root:
		parent[second_root] = first_root


func _metrics(arrays: Array) -> Dictionary:
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var welded := {}
	var canonical := PackedInt32Array()
	canonical.resize(positions.size())
	for index in positions.size():
		var key := Vector3i(roundi(positions[index].x * 1024.0), roundi(positions[index].y * 1024.0), roundi(positions[index].z * 1024.0))
		if not welded.has(key):
			welded[key] = welded.size()
		canonical[index] = welded[key]
	var edges := {}
	for offset in range(0, indices.size(), 3):
		for corner in 3:
			var start := canonical[indices[offset + corner]]
			var end := canonical[indices[offset + (corner + 1) % 3]]
			edges[Vector2i(start, end)] = edges.get(Vector2i(start, end), 0) + 1
	var unpaired := 0
	for key: Vector2i in edges:
		if not edges.has(Vector2i(key.y, key.x)) or edges[key] != edges[Vector2i(key.y, key.x)]:
			unpaired += 1
	var seen := {}
	var duplicates := 0
	for offset in range(0, indices.size(), 3):
		var corners := [canonical[indices[offset]], canonical[indices[offset + 1]], canonical[indices[offset + 2]]]
		corners.sort()
		var key := Vector3i(corners[0], corners[1], corners[2])
		seen[key] = seen.get(key, 0) + 1
		if seen[key] > 1:
			duplicates += 1
	return {"triangles": indices.size() / 3, "unpaired": unpaired, "duplicates": duplicates}


func _bounds(arrays: Array) -> AABB:
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var box := AABB(positions[0], Vector3.ZERO)
	for position in positions:
		box = box.expand(position)
	return box
