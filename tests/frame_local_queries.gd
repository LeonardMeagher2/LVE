extends "res://tests/test.gd"

# Focused checks for the frame-local data APIs.
#
# `copy_chunks` returns a frozen subset of present chunks without scanning the
# whole chunk dictionary. `get_bounds` caches the merged bounds and invalidates
# on every frame write, clear, restore, and decode. A raw chunk add or remove is
# caught by the chunk count guard. A raw chunk entry change must call
# `invalidate_bounds`, which repairs the bounds only.

var BLUE: PackedFloat32Array = VoxelFrame.material(Color.BLUE)
var GREEN: PackedFloat32Array = VoxelFrame.material(Color.GREEN)

var _undo_subset_chunk: VoxelFrame.Chunk
var _saved_document: VoxelDocument
var _saved_selection := {}


func _setup_test() -> void:
	# The undo case needs the global document and history. Back them up, so the
	# cases stay independently selectable and the scene leaves State as it found
	# it.
	_saved_document = State.document
	_saved_selection = State.selection.all_cells()
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	await get_tree().process_frame


func _cleanup_test() -> void:
	State.stop()
	State.undo_redo.clear_history()
	State.selection.restore(_saved_selection)
	if _saved_document != null:
		State.document = _saved_document
	await get_tree().process_frame


func _ready() -> void:
	timeout = 30.0
	test("a full and a subset snapshot coexist and stay frozen", _full_and_subset, "frame_copy_chunks_coexist")
	test("several disjoint subsets stay independent", _disjoint_subsets, "frame_copy_chunks_disjoint")
	test("undo and redo leave the subset frozen", _copy_undo, "frame_copy_chunks_undo")
	test("missing and duplicate chunk keys are harmless", _missing_and_duplicates, "frame_copy_chunks_keys")
	test("the subset bounds cover only the captured chunks", _subset_bounds, "frame_copy_chunks_bounds")
	test("the bounds cache follows writes, clear, restore, and decode", _bounds_writes, "frame_bounds_writes")
	test("the bounds cache follows a same-count move through the API", _bounds_move, "frame_bounds_move")
	test("raw chunk add and remove are caught by the count guard", _bounds_raw_count, "frame_bounds_raw_count")
	test("a chunk method edit with invalidate_bounds refreshes the cache", _bounds_raw_edit, "frame_bounds_raw_edit")
	test("an empty chunk entry never pulls the bounds to the origin", _bounds_empty_chunk, "frame_bounds_empty_chunk")
	test("negative coordinates keep exact bounds", _bounds_negative, "frame_bounds_negative")


func _cell(location: Vector3i) -> Vector3i:
	return location * VoxelFrame.CHUNK_SIZE + Vector3i(8, 8, 8)


func _seed_frame(locations: Array[Vector3i]) -> VoxelFrame:
	var frame := VoxelFrame.new()
	frame.delay_ms = 123
	for location in locations:
		frame.set_cell(_cell(location), BLUE)
	return frame


func _full_and_subset() -> void:
	var zero := Vector3i.ZERO
	var one := Vector3i(1, 0, 0)
	var frame := _seed_frame([zero, one, Vector3i(0, 1, 0)])
	var full := frame.copy_frame()
	var subset := frame.copy_chunks([zero, one])
	step("Given a full snapshot and a subset of the same frame", func():
		expect(full.chunks.size() == 3, "the full snapshot holds every chunk")
		expect(subset.chunks.size() == 2, "the subset holds the requested present chunks")
		expect(subset.delay_ms == frame.delay_ms, "the subset keeps the frame delay")
		expect(subset.chunks[zero] == frame.chunks[zero], "the subset shares the live chunk object")
	)
	step("When the source writes and erases a captured chunk", func():
		var subset_chunk: VoxelFrame.Chunk = subset.chunks[zero]
		var full_chunk: VoxelFrame.Chunk = full.chunks[zero]
		frame.set_cell(_cell(zero), GREEN)
		expect(frame.get_color(_cell(zero)) == Color.GREEN, "the source took the new color")
		expect(subset_chunk.get_color(_cell(zero)) == Color.BLUE, "the subset chunk stays blue")
		expect(full_chunk.get_color(_cell(zero)) == Color.BLUE, "the full snapshot stays blue")
		expect(subset.chunks[zero] == subset_chunk, "the subset keeps its chunk identity")
		expect(full.chunks[zero] == full_chunk, "the full snapshot keeps its chunk identity")
		frame.set_cell(_cell(zero), VoxelFrame.material(Color.TRANSPARENT))
		expect(not frame.has(_cell(zero)), "the source erased the cell")
		expect(subset_chunk.get_color(_cell(zero)) == Color.BLUE, "the erased cell stays in the subset")
		expect(full_chunk.get_color(_cell(zero)) == Color.BLUE, "the erased cell stays in the full snapshot")
	)
	step("When the source bulk-repaints a captured chunk", func():
		var subset_chunk: VoxelFrame.Chunk = subset.chunks[one]
		var full_chunk: VoxelFrame.Chunk = full.chunks[one]
		var changes := {}
		for x in VoxelFrame.CHUNK_SIZE:
			for y in VoxelFrame.CHUNK_SIZE:
				for z in VoxelFrame.CHUNK_SIZE:
					changes[one * VoxelFrame.CHUNK_SIZE + Vector3i(x, y, z)] = GREEN
		frame.set_cells(changes, null, GREEN)
		expect(frame.get_color(_cell(one)) == Color.GREEN, "the source bulk repaint wrote the chunk")
		expect(subset_chunk.get_color(_cell(one)) == Color.BLUE, "the subset bulk chunk stays blue")
		expect(full_chunk.get_color(_cell(one)) == Color.BLUE, "the full bulk chunk stays blue")
	)


func _disjoint_subsets() -> void:
	var zero := Vector3i.ZERO
	var one := Vector3i(1, 0, 0)
	var two := Vector3i(2, 0, 0)
	var three := Vector3i(3, 0, 0)
	var frame := _seed_frame([zero, one, two, three])
	var first := frame.copy_chunks([zero, one])
	var second := frame.copy_chunks([two, three])
	step("Given two disjoint subsets", func():
		expect(first.chunks.size() == 2 and second.chunks.size() == 2, "each subset holds its two chunks")
	)
	step("When the source and one subset write", func():
		var first_chunk: VoxelFrame.Chunk = first.chunks[zero]
		var second_chunk: VoxelFrame.Chunk = second.chunks[two]
		frame.set_cell(_cell(zero), GREEN)
		expect(first_chunk.get_color(_cell(zero)) == Color.BLUE, "the first subset stays frozen after the source write")
		expect(second_chunk.get_color(_cell(two)) == Color.BLUE, "the second subset is unaffected")
		first.set_cell(_cell(zero), VoxelFrame.material(Color.RED))
		expect(first.get_color(_cell(zero)) == Color.RED, "the first subset took its own write")
		expect(frame.get_color(_cell(zero)) == Color.GREEN, "the source kept its own color")
		expect(first.chunks[zero] != frame.chunks[zero], "the subset write copied the chunk")
		expect(second_chunk.get_color(_cell(two)) == Color.BLUE, "the second subset still stays frozen")
		second.set_cell(_cell(two), VoxelFrame.material(Color.RED))
		expect(second.get_color(_cell(two)) == Color.RED, "the second subset took its own write")
		expect(second.chunks[two] != frame.chunks[two], "the second subset write copied its chunk")
		expect(second_chunk.get_color(_cell(two)) == Color.BLUE, "the second subset chunk stays frozen")
		expect(first_chunk.get_color(_cell(zero)) == Color.BLUE, "the second write leaves the first subset frozen")
		expect(frame.get_color(_cell(two)) == Color.BLUE, "the source stays blue after the second subset write")
	)


func _copy_undo() -> void:
	step("Given a subset and an edit on the live frame", func():
		var live := State.get_current_voxel_frame()
		live.set_cell(_cell(Vector3i.ZERO), BLUE)
		var subset := live.copy_chunks([Vector3i.ZERO])
		_undo_subset_chunk = subset.chunks[Vector3i.ZERO]
		var tx := State.begin_edit()
		live.set_cell(_cell(Vector3i.ZERO), GREEN)
		State.finish_edit(tx)
		expect(live.get_color(_cell(Vector3i.ZERO)) == Color.GREEN, "the edit wrote the live frame")
		expect(_undo_subset_chunk.get_color(_cell(Vector3i.ZERO)) == Color.BLUE, "the subset stays blue before undo")
	)
	step("When the edit is undone and redone", func():
		State.undo()
		expect(State.get_current_voxel_frame().get_color(_cell(Vector3i.ZERO)) == Color.BLUE, "undo restores the live frame")
		expect(_undo_subset_chunk.get_color(_cell(Vector3i.ZERO)) == Color.BLUE, "the subset stays blue after undo")
		State.redo()
		expect(State.get_current_voxel_frame().get_color(_cell(Vector3i.ZERO)) == Color.GREEN, "redo writes the live frame")
		expect(_undo_subset_chunk.get_color(_cell(Vector3i.ZERO)) == Color.BLUE, "the subset stays blue after redo")
	)


func _missing_and_duplicates() -> void:
	var zero := Vector3i.ZERO
	var missing := Vector3i(9, 9, 9)
	var frame := _seed_frame([zero])
	step("Given missing and duplicate locations", func():
		var subset := frame.copy_chunks([zero, zero, missing])
		expect(subset.chunks.size() == 1, "the duplicate and the missing key change nothing")
		expect(subset.chunks.has(zero), "the present key is captured")
		expect(not subset.chunks.has(missing), "the missing key is absent")
		expect(not frame.chunks.has(missing), "the missing key is not created in the source")
		expect(not frame._shared_chunks.has(missing), "the missing key is not marked shared")
		var empty := frame.copy_chunks([])
		expect(empty.chunks.is_empty(), "an empty request returns an empty frame")
		frame.set_cell(_cell(missing), BLUE)
		expect(frame.chunks.has(missing), "the source can create the missing chunk later")
		expect(not subset.chunks.has(missing), "the later chunk never leaks into the snapshot")
	)


func _subset_bounds() -> void:
	var zero := Vector3i.ZERO
	var far := Vector3i(10, 0, 0)
	var frame := _seed_frame([zero, far])
	# Warm the source cache before the copy. A read-only subset must not dirty
	# the source bounds cache.
	var live_bounds := frame.get_bounds()
	var subset := frame.copy_chunks([zero])
	step("Given a frame with a near and a far chunk", func():
		expect(not frame._bounds_dirty, "copying a subset leaves the source bounds cache clean")
		expect(_same_aabb(frame.get_bounds(), live_bounds), "copying a subset keeps the source bounds")
		var full_bounds := frame.get_bounds()
		var subset_bounds := subset.get_bounds()
		expect(full_bounds.has_volume(), "the full frame has bounds")
		expect(subset_bounds.has_volume(), "the subset has bounds")
		expect(not _same_aabb(full_bounds, subset_bounds), "the subset does not reuse the full bounds")
		expect(subset_bounds.size.is_equal_approx(Vector3.ONE), "the subset bounds cover its one voxel")
		expect(subset_bounds.position.is_equal_approx(Vector3(_cell(zero)) - Vector3.ONE * 0.5), "the subset bounds start at its voxel")
	)


func _bounds_writes() -> void:
	var zero := Vector3i.ZERO
	var far := Vector3i(100, 0, 0)
	var frame := VoxelFrame.new()
	step("Given a frame with one voxel", func():
		frame.set_cell(zero, BLUE)
		expect(frame.get_bounds().size.is_equal_approx(Vector3.ONE), "the first bounds cover one voxel")
	)
	step("When a far voxel is added and then erased", func():
		frame.set_cell(far, BLUE)
		expect(frame.get_bounds().size.x > 100.0, "the cache follows the added voxel")
		frame.set_cell(far, GREEN)
		expect(frame.get_bounds().size.x > 100.0, "a material-only write keeps the far bounds")
		frame.set_cell(far, VoxelFrame.material(Color.TRANSPARENT))
		expect(frame.get_bounds().size.is_equal_approx(Vector3.ONE), "the cache follows the erase")
	)
	step("When a bulk write, clear, and restore change the frame", func():
		frame.set_cells({Vector3i(50, 0, 0): BLUE}, null, BLUE)
		expect(frame.get_bounds().size.x > 50.0, "the bulk write reaches the cache")
		var snapshot := frame.capture()
		frame.set_cell(Vector3i(200, 0, 0), BLUE)
		expect(frame.get_bounds().size.x > 200.0, "the later write reaches the cache")
		frame.restore(snapshot)
		expect(frame.get_bounds().size.x > 50.0 and frame.get_bounds().size.x < 200.0, "the restore refreshes the cache")
		frame.clear()
		expect(not frame.get_bounds().has_volume(), "clear drops the bounds")
	)
	step("When a decoded frame is queried", func():
		var source := _seed_frame([zero, Vector3i(2, 0, 0)])
		var data := source.storage_data()
		var loaded := VoxelFrame.new()
		loaded.restore_storage(data)
		expect(_same_aabb(loaded.get_bounds(), source.get_bounds()), "the decoded frame reports the same bounds")
	)


func _bounds_move() -> void:
	var zero := Vector3i.ZERO
	var two := Vector3i(2, 0, 0)
	var frame := VoxelFrame.new()
	frame.set_cells({zero: BLUE, two: BLUE})
	step("Given two voxels on the bounds", func():
		var bounds := frame.get_bounds()
		expect(bounds.position.is_equal_approx(Vector3(-0.5, -0.5, -0.5)), "the first bounds start at the first voxel")
		expect(bounds.end.is_equal_approx(Vector3(2.5, 0.5, 0.5)), "the first bounds end at the second voxel")
	)
	step("When a same-count batch moves the low voxel", func():
		frame.set_cells({zero: VoxelFrame.material(Color.TRANSPARENT), Vector3i(1, 0, 0): BLUE})
		var bounds := frame.get_bounds()
		expect(bounds.position.is_equal_approx(Vector3(0.5, -0.5, -0.5)), "the cache follows the moved low voxel")
		expect(bounds.end.is_equal_approx(Vector3(2.5, 0.5, 0.5)), "the high voxel stays")
	)


func _bounds_raw_count() -> void:
	var zero := Vector3i.ZERO
	var far := Vector3i(10, 0, 0)
	var frame := _seed_frame([zero])
	step("Given a cached frame", func():
		expect(frame.get_bounds().size.is_equal_approx(Vector3.ONE), "the cache covers the first chunk")
	)
	step("When a raw chunk add changes the chunk count", func():
		var chunk := VoxelFrame.Chunk.new()
		chunk.location = far
		chunk.store(_cell(far), BLUE)
		chunk.bounds_dirty = true
		frame.chunks[far] = chunk
		expect(frame.get_bounds().size.x > 100.0, "the chunk count guard refreshes the bounds")
	)
	step("When a raw chunk remove changes the chunk count", func():
		frame.chunks.erase(far)
		expect(frame.get_bounds().size.is_equal_approx(Vector3.ONE), "the chunk count guard follows the removal")
	)


func _bounds_raw_edit() -> void:
	var zero := Vector3i.ZERO
	var frame := _seed_frame([zero])
	step("Given a cached frame and a chunk method edit", func():
		expect(frame.get_bounds().size.is_equal_approx(Vector3.ONE), "the cache covers the voxel")
		# Chunk.erase keeps the occupied count and the occupancy revision, so the
		# bounds-only repair is enough here.
		var chunk: VoxelFrame.Chunk = frame.chunks[zero]
		chunk.erase(_cell(zero))
		frame.invalidate_bounds()
		expect(not frame.get_bounds().has_volume(), "invalidate_bounds refreshes the chunk edit")
	)


func _bounds_empty_chunk() -> void:
	var far := Vector3i(10, 0, 0)
	var frame := VoxelFrame.new()
	# A raw entry replacement is the documented mode for a well-formed chunk.
	# These chunks are not shared, so the bounds-only contract is enough.
	var occupied := VoxelFrame.Chunk.new()
	occupied.location = far
	occupied.store(_cell(far), BLUE)
	occupied.bounds_dirty = true
	frame.chunks[far] = occupied
	var empty := VoxelFrame.Chunk.new()
	empty.location = Vector3i.ZERO
	frame.chunks[Vector3i.ZERO] = empty
	step("Given an occupied far chunk and an empty chunk at the origin", func():
		expect(frame.chunks.size() == 2, "the frame holds the occupied and the empty entry")
		var bounds := frame.get_bounds()
		expect(bounds.position.x > 100.0, "the empty chunk does not pull the bounds to the origin")
		expect(bounds.position.is_equal_approx(Vector3(_cell(far)) - Vector3.ONE * 0.5), "the bounds start at the occupied chunk")
		expect(bounds.size.is_equal_approx(Vector3.ONE), "the bounds cover the occupied voxel alone")
	)


func _bounds_negative() -> void:
	var frame := VoxelFrame.new()
	frame.set_cell(Vector3i(-5, -5, -5), BLUE)
	frame.set_cell(Vector3i(-1, -1, -1), BLUE)
	step("Given voxels below the origin", func():
		var bounds := frame.get_bounds()
		expect(bounds.position.is_equal_approx(Vector3(-5.5, -5.5, -5.5)), "the low corner is exact")
		expect(bounds.end.is_equal_approx(Vector3(-0.5, -0.5, -0.5)), "the high corner is exact")
		expect(bounds.size.is_equal_approx(Vector3(5, 5, 5)), "the negative span is exact")
	)


func _same_aabb(first: AABB, second: AABB) -> bool:
	return first.position.is_equal_approx(second.position) and first.size.is_equal_approx(second.size)
