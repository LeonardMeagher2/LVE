extends "res://tests/test.gd"

var original: VoxelFrame
var duplicate: VoxelFrame
var restored: VoxelFrame
var data := PackedByteArray()
var undo_us := 0
var redo_us := 0


func _ready() -> void:
	timeout = 30.0
	test("large edits restore chunk versions and save uniform regions as compact octrees", _run)


func _run() -> void:
	step("Given a chunk size that matches the chunk-position shift", func():
		# `chunk_position` shifts instead of dividing, so the two constants must
		# agree. This fails loudly if either one moves.
		expect(VoxelFrame.CHUNK_SIZE == 1 << VoxelFrame.CHUNK_SHIFT, "the chunk shift is the base-two logarithm of the chunk size")
		expect(VoxelFrame.chunk_position(Vector3i(-1, -17, 15)) == Vector3i(-1, -2, 0), "the chunk position floors toward negative infinity")
	)
	step("Given a solid chunk and a separate negative-coordinate voxel", func():
		State.document = VoxelDocument.new()
		original = State.get_current_voxel_frame()
		for z in 16:
			for y in 16:
				for x in 16:
					State.paint(Vector3i(x, y, z), VoxelFrame.material(Color.RED))
		State.paint(Vector3i(-17, 3, -1), VoxelFrame.material(Color(0.25, 0.5, 0.75, 0.5)))
		data = original.voxel_data
		State.duplicate_frame()
		duplicate = State.get_current_voxel_frame()
		State.undo_redo.clear_history()
	)
	step("When the user edits the duplicate and undoes the edit from another frame", func():
		var tx := State.begin_edit()
		var replacement_colors := {}
		for z in 16:
			for y in 16:
				for x in 16:
					replacement_colors[Vector3i(x, y, z)] = VoxelFrame.material(Color.BLUE)
		duplicate.set_cells(replacement_colors)
		State.finish_edit(tx)
		State.current_frame = 0
		var started := Time.get_ticks_usec()
		State.undo_redo.undo()
		undo_us = Time.get_ticks_usec() - started
	)
	step("Then the original and the restored duplicate share the original voxel version", func():
		expect(original.get_color(Vector3i.ZERO) == Color.RED, "the original keeps its red voxel")
		expect(duplicate.get_color(Vector3i.ZERO) == Color.RED, "undo restores the duplicate's red voxel")
		expect(original.chunks[Vector3i.ZERO] == duplicate.chunks[Vector3i.ZERO], "undo restores the shared chunk")
	)
	step("When the user redoes the edit and saves the duplicate", func():
		var started := Time.get_ticks_usec()
		State.undo_redo.redo()
		redo_us = Time.get_ticks_usec() - started
		data = duplicate.voxel_data
		var document := VoxelDocument.new()
		document.frames.assign([duplicate])
		var error := document.save_file("user://chunk_storage_test.lve")
		expect(error == OK, "the compact document saves")
		var loaded := VoxelDocument.load_file("user://chunk_storage_test.lve")
		restored = loaded.frames[0] if loaded else null
		DirAccess.remove_absolute("user://chunk_storage_test.lve")
	)
	step("Then the compact file preserves every voxel and color", func():
		expect(data.size() < 2048, "the uniform chunk uses less than two kilobytes")
		expect(restored != null, "the compact document loads")
		if restored:
			expect(restored.count() == 4097, "the file restores all occupied cells")
			expect(restored.get_color(Vector3i(15, 15, 15)) == Color.BLUE, "the solid region keeps its blue color")
			expect(restored.get_color(Vector3i(-17, 3, -1)) == Color(0.25, 0.5, 0.75, 0.5), "the sparse voxel keeps its position and alpha")
		expect(original.get_color(Vector3i.ZERO) == Color.RED, "redo leaves the original frame red")
		print("Chunk history: undo %s us, redo %s us, storage %s bytes" % [undo_us, redo_us, data.size()])
	)
	step("When the user paints a transparent color and cancels", func():
		State.current_frame = 1
		var tx := State.begin_edit()
		State.paint(Vector3i.ZERO, VoxelFrame.material(Color.TRANSPARENT))
		expect(not duplicate.has(Vector3i.ZERO), "transparent paint erases the voxel")
		State.cancel_edit(tx)
		expect(duplicate.get_color(Vector3i.ZERO) == Color.BLUE, "cancel restores the blue voxel")
	)
	step("When the user erases voxels across chunk boundaries and cancels", func():
		var tx := State.begin_edit()
		duplicate.set_cells({Vector3i.ZERO: VoxelFrame.material(Color.TRANSPARENT), Vector3i(-17, 3, -1): VoxelFrame.material(Color.TRANSPARENT)})
		expect(duplicate.count() == 4095, "the batch erases both occupied voxels")
		expect(duplicate.get_bounds() == AABB(Vector3.ONE * -0.5, Vector3.ONE * 16), "the batch updates the occupied bounds")
		State.cancel_edit(tx)
		expect(duplicate.count() == 4097, "cancel restores both erased voxels")
		expect(duplicate.get_bounds() == original.get_bounds(), "cancel restores the original bounds")
	)
	step("When a chunk that one fill wrote is repainted cell by cell", func():
		State.document = VoxelDocument.new()
		var frame := State.get_current_voxel_frame()
		var material := VoxelFrame.material(Color.RED)
		var batch := {}
		for z in 16:
			for y in 16:
				for x in 16:
					batch[Vector3i(x, y, z)] = material
		frame.set_cells(batch)
		var filled: VoxelFrame.Chunk = frame.chunks[Vector3i.ZERO]
		expect(filled.materials.size() / VoxelFrame.MATERIAL_STRIDE == 1, "the fill leaves one material entry for the whole chunk")
		# A repaint gives each edited cell its own entry. A repaint-only workload
		# never erases, so the reclamation has to run on the write path or the table
		# grows with every edit.
		var blue := VoxelFrame.material(Color.BLUE)
		for index in 100:
			var repaint := {}
			for step in 100:
				repaint[Vector3i((index * 100 + step) % 16, (index * 100 + step) / 16 % 16, index % 16)] = blue
			frame.set_cells(repaint)
		var repainted: VoxelFrame.Chunk = frame.chunks[Vector3i.ZERO]
		expect(repainted.materials.size() / VoxelFrame.MATERIAL_STRIDE <= repainted.occupied_count * 2, "repeated repaints keep the material table bounded")
	)
