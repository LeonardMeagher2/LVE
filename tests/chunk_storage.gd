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
	step("Given a solid chunk and a separate negative-coordinate voxel", func():
		State.document = VoxiDocument.new()
		original = State.get_current_voxel_frame()
		for z in 16:
			for y in 16:
				for x in 16:
					State.paint(Vector3i(x, y, z), Color.RED)
		State.paint(Vector3i(-17, 3, -1), Color(0.25, 0.5, 0.75, 0.5))
		State.duplicate_frame()
		duplicate = State.get_current_voxel_frame()
		State.undo_redo.clear_history()
	)
	step("When the user edits the duplicate and undoes the edit from another frame", func():
		State.begin_stroke()
		for z in 16:
			for y in 16:
				for x in 16:
					State.paint(Vector3i(x, y, z), Color.BLUE)
		State.end_stroke()
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
		var error := ResourceSaver.save(duplicate, "user://chunk_storage_test.tres")
		expect(error == OK, "the chunk resource saves")
		restored = ResourceLoader.load("user://chunk_storage_test.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
		DirAccess.remove_absolute("user://chunk_storage_test.tres")
	)
	step("Then the compact file preserves every voxel and color", func():
		expect(data.size() < 2048, "the uniform chunk uses less than two kilobytes")
		expect(restored != null, "the chunk resource loads")
		if restored:
			expect(restored.count() == 4097, "the file restores all occupied cells")
			expect(restored.get_color(Vector3i(15, 15, 15)) == Color.BLUE, "the solid region keeps its blue color")
			expect(restored.get_color(Vector3i(-17, 3, -1)) == Color(0.25, 0.5, 0.75, 0.5), "the sparse voxel keeps its position and alpha")
		expect(original.get_color(Vector3i.ZERO) == Color.RED, "redo leaves the original frame red")
		print("Chunk history: undo %s us, redo %s us, storage %s bytes" % [undo_us, redo_us, data.size()])
	)
	step("When the user paints a transparent color and cancels", func():
		State.current_frame = 1
		State.begin_stroke()
		State.paint(Vector3i.ZERO, Color.TRANSPARENT)
		expect(not duplicate.has(Vector3i.ZERO), "transparent paint erases the voxel")
		State.cancel_stroke()
		expect(duplicate.get_color(Vector3i.ZERO) == Color.BLUE, "cancel restores the blue voxel")
	)
