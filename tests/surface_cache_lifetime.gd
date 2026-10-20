extends "res://tests/test.gd"

var scene_renderer: VoxelRenderer
var enclosed_voxel := Vector3i(24, 24, 24)
var enclosed_chunk := Vector3i(1, 1, 1)
var visible_surface_count := 0
var edit: VoxelEditTransaction


func _ready() -> void:
	timeout = 30.0
	test("enclosed voxel edits keep the surface cache bounded and discard inactive display records", _run)


func _run() -> void:
	step("Given a solid block with a fully enclosed center chunk", func():
		State.document = VoxelDocument.new()
		for z in 48:
			for y in 48:
				for x in 48:
					State.paint(Vector3i(x, y, z), VoxelFrame.material(Color.RED))
		scene_renderer = load("res://ui/Viewport/VoxelRenderer.tscn").instantiate()
		main.add_child(scene_renderer)
	)
	await _settle()
	step("Then the enclosed chunk has no mesh node", func():
		visible_surface_count = _visible_count()
		expect(visible_surface_count > 0, "the block's exterior surfaces are visible")
		expect(scene_renderer._displayed_surface_keys.has(enclosed_chunk), "the enclosed chunk has a completed display record")
		expect(not scene_renderer._chunk_instances.has(enclosed_chunk), "the enclosed chunk needs no mesh node")
	)
	step("Given more empty history results than the cache can retain", func():
		# Seed completed empty results without generating thousands of redundant meshes.
		for history_index in range(VoxelRenderer.SURFACE_CACHE_LIMIT_ENTRIES + 1):
			VoxelRenderer._cache_surface(_history_key(history_index), null, 0, null)
	)
	step("Then empty results evict old entries without hiding active surfaces", func():
		expect(VoxelRenderer._surface_cache.size() == VoxelRenderer.SURFACE_CACHE_LIMIT_ENTRIES, "empty results stay within the entry limit")
		expect(VoxelRenderer._surface_cache_bytes == 0, "the empty results have zero geometry bytes")
		expect(not VoxelRenderer._surface_cache.has(_history_key(0)), "the oldest empty result is evicted")
		expect(VoxelRenderer._surface_cache.has(_history_key(VoxelRenderer.SURFACE_CACHE_LIMIT_ENTRIES)), "the latest empty result is retained")
		expect(_visible_count() == visible_surface_count, "eviction keeps active surfaces visible")
	)
	step("When the user recolors an enclosed voxel repeatedly", func():
		edit = State.begin_edit()
	)
	for color in [Color.BLUE, Color.GREEN, Color.YELLOW]:
		State.paint(enclosed_voxel, VoxelFrame.material(color))
		var affected_cells: Array[Vector3i] = [enclosed_voxel]
		State.cells_changed.emit(0, affected_cells)
		await _settle()
		var surface_key: PackedInt64Array = scene_renderer._displayed_surface_keys[enclosed_chunk]
		expect(VoxelRenderer._surface_cache.size() <= VoxelRenderer.SURFACE_CACHE_LIMIT_ENTRIES, "the edited chunk keeps the cache within its entry limit")
		expect(VoxelRenderer._surface_cache.has(surface_key), "the edited chunk's completed result is cached")
		if VoxelRenderer._surface_cache.has(surface_key):
			expect(VoxelRenderer._surface_cache[surface_key].surface == null, "the edited enclosed chunk still has no exposed faces")
		expect(_visible_count() == visible_surface_count, "interior edits keep the exterior surfaces visible")
	State.finish_edit(edit)
	step("When the user switches to an empty frame", func():
		State.add_frame()
	)
	step("Then all previous display records are removed", func():
		expect(scene_renderer._displayed_surface_keys.is_empty(), "the empty frame has no stale display records")
		expect(_visible_count() == 0, "the empty frame has no visible surfaces")
	)
	step("When the user returns to the solid frame", func():
		State.current_frame = 0
	)
	await _settle()
	step("Then the solid frame restores its surfaces", func():
		expect(_visible_count() == visible_surface_count, "the solid frame restores every exterior surface")
		expect(scene_renderer._displayed_surface_keys.has(enclosed_chunk), "the enclosed chunk has its current display record")
	)
	step("When the user starts a new document", func():
		State.document = VoxelDocument.new()
	)
	step("Then the new document has no display records from the previous document", func():
		expect(scene_renderer._displayed_surface_keys.is_empty(), "the new document has no stale display records")
		expect(_visible_count() == 0, "the new document has no previous surfaces")
	)


func _settle() -> void:
	while not scene_renderer.is_settled():
		await get_tree().process_frame


# A distinct cache key per seeded history entry.
func _history_key(index: int) -> PackedInt64Array:
	return PackedInt64Array([index + 1, 1])


func _visible_count() -> int:
	var surface_count := 0
	for child in scene_renderer.get_children():
		if child is MeshInstance3D and child.visible:
			surface_count += 1
	return surface_count
