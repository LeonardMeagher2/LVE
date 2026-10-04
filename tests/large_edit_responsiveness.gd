extends "res://tests/test.gd"

var tool: Node
var measuring := false
var last_frame_us := 0
var longest_frame_us := 0
var observed_frames := 0
var notifications := 0


func _ready() -> void:
	timeout = 30.0
	test("a large scale keeps processing frames and preserves undo", _run)


func _process(_delta: float) -> void:
	if not measuring:
		return
	var now := Time.get_ticks_usec()
	longest_frame_us = maxi(longest_frame_us, now - last_frame_us)
	last_frame_us = now
	observed_frames += 1


func _run() -> void:
	step("Given a selected solid block with 32768 voxels", func():
		State.document = VoxiDocument.new()
		var frame := State.get_current_voxel_frame()
		for z in 32:
			for y in 32:
				for x in 32:
					var cell_position := Vector3i(x, y, z)
					frame.set_cell(cell_position, Color.RED)
					State.selection.add(cell_position)
		camera_rig().set_view("front")
		activate_tool("transform")
		select_toolbar_item("transform", "Scale")
		tool = plugin("TransformPlugin")._current_tool
		State.cells_changed.connect(func(_frame, _affected): notifications += 1)
		State.chunks_changed.connect(func(_frame, _affected): notifications += 1)
	)
	var started_us := Time.get_ticks_usec()
	last_frame_us = started_us
	measuring = true
	step("When the user doubles the block", func():
		_drag(Vector2(32, 32), Vector2(64, 64))
		tool._commit()
	)
	while not tool.is_settled():
		await get_tree().process_frame
	await get_tree().process_frame
	measuring = false
	var edit_us := Time.get_ticks_usec() - started_us
	var edit_notifications := notifications
	var renderer := viewport_scene().get_node("VoxelRenderer")
	while not renderer.is_settled():
		await get_tree().process_frame
	var visible_us := Time.get_ticks_usec() - started_us
	step("Then the exact scaled block is one undo action", func():
		expect(State.get_current_voxel_frame().count() == 262144, "the scaled block contains 262144 voxels")
		expect(observed_frames > 1, "frames continue during the large edit")
		expect(edit_notifications == 1, "the completed preview sends one edit notification")
		expect(State.undo_redo.has_undo(), "the scale has an undo action")
		State.undo_redo.undo()
		expect(State.get_current_voxel_frame().count() == 32768, "undo restores all source voxels")
		State.undo_redo.redo()
		expect(State.get_current_voxel_frame().count() == 262144, "redo restores all scaled voxels")
		print("Large scale: edit %d ms, visible %d ms, longest edit frame %d ms, frames %d, edit notifications %d" % [edit_us / 1000, visible_us / 1000, longest_frame_us / 1000, observed_frames, edit_notifications])
	)


func _drag(press_offset: Vector2, drag_offset: Vector2) -> void:
	var pivot := State.get_current_voxel_frame().get_bounds().get_center()
	var from := camera_rig().unproject_position(pivot + Vector3(press_offset.x, press_offset.y, 0))
	var to := camera_rig().unproject_position(pivot + Vector3(drag_offset.x, drag_offset.y, 0))
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	tool.handle_input(press, from)
	var motion := InputEventMouseMotion.new()
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	tool.handle_input(motion, to)
	press.pressed = false
	tool.handle_input(press, to)
