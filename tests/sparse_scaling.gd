extends "res://tests/test.gd"

var tool: Node
var elapsed_ms := 0


func _ready() -> void:
	test("scaling distant voxels preserves their blocks without scanning the empty volume", _run)


func _run() -> void:
	step("Given two selected voxels in distant chunks", func():
		State.document = VoxelDocument.new()
		State.paint(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.paint(Vector3i(255, 255, 255), VoxelFrame.material(Color.GREEN))
		State.selection.add(Vector3i.ZERO)
		State.selection.add(Vector3i(255, 255, 255))
		camera_rig().set_view("front")
		camera_rig().center_active()
		activate_tool("transform")
		select_toolbar_item("transform", "Scale")
		tool = plugin("TransformPlugin")._current_tool
	)
	var started := Time.get_ticks_msec()
	step("When the user doubles the sparse selection", func():
		_drag(2)
	)
	while not tool.is_settled():
		await get_tree().process_frame
	elapsed_ms = Time.get_ticks_msec() - started
	step("Then the two exact colored blocks appear promptly", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 16, "the two source voxels become sixteen destination voxels")
		for z in 2:
			for y in 2:
				for x in 2:
					var offset := Vector3i(x, y, z)
					expect(frame.get_color(Vector3i.ONE * -128 + offset) == Color.RED, "the first block keeps its red color")
					expect(frame.get_color(Vector3i.ONE * 382 + offset) == Color.GREEN, "the second block keeps its green color")
		expect(elapsed_ms < 2000, "the sparse scale completes within two seconds")
		State.undo_redo.undo()
		expect(frame.count() == 2, "undo restores the two distant source voxels")
		print("Sparse scale: %d ms" % elapsed_ms)
	)
	step("When the user mirrors the sparse selection", func():
		_drag(-1)
	)
	await _settle()
	step("Then the distant voxels keep their exact mirrored positions", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 2, "mirroring preserves both distant voxels")
		expect(frame.get_color(Vector3i.ONE * 254) == Color.RED, "the first voxel reaches its mirrored position")
		expect(frame.get_color(Vector3i.ONE * -1) == Color.GREEN, "the second voxel reaches its mirrored position")
		State.undo_redo.undo()
	)
	step("When the user doubles only the visible axes", func():
		press_option("Scale uniformly")
		_drag(2)
	)
	await _settle()
	step("Then both sparse blocks keep their original depth layers", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 8, "the sparse two-axis scale contains eight voxels")
		expect(frame.get_color(Vector3i(-128, -128, 0)) == Color.RED, "the first block keeps its original depth")
		expect(frame.get_color(Vector3i(383, 383, 255)) == Color.GREEN, "the second block keeps its original depth")
	)


func _drag(factor: float) -> void:
	var pivot := Vector3.ONE * 127.5
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	tool.handle_input(press, camera_rig().unproject_position(pivot + Vector3(256, 256, 0)))
	var motion := InputEventMouseMotion.new()
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	tool.handle_input(motion, camera_rig().unproject_position(pivot + Vector3(256, 256, 0) * factor))
	press.pressed = false
	tool.handle_input(press, Vector2.ZERO)
	tool._commit()


func _settle() -> void:
	while not tool.is_settled():
		await get_tree().process_frame
