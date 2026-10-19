extends "res://tests/test.gd"

var viewport: SubViewport
var clipboard: Node
var frame: VoxelFrame
var source_selection := {}
var original_clipboard := ""


func _ready() -> void:
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		original_clipboard = DisplayServer.clipboard_get()
	test("UI buttons cancel pending edits while right-drag rotates the view", _run)


func _run() -> void:
	step("Given copied voxels and a target document", func():
		viewport = editor_viewport()
		viewport.get_parent().stretch = false
		viewport.size = Vector2i(800, 500)
		clipboard = plugin("ClipboardPlugin")
		State.document = VoxelDocument.new()
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		clipboard.copy_voxels()
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i(-8, 0, 0), VoxelFrame.material(Color.GREEN))
		State.selection.add(Vector3i(-6, 0, 0))
		State.selection_changed.emit()
		source_selection = State.selection.capture()
		camera_rig().set_view("top")
		camera_rig().is_orthogonal = true
	)
	step("Then Cancel Paste is hidden while no paste is pending", func():
		var button: Button = clipboard._options.get_node("CancelPaste")
		expect(not button.visible, "Cancel Paste is hidden while idle")
		expect(button.text.is_empty() and button.icon != null, "Cancel Paste uses an icon")
	)
	step("When the user starts a paste and presses Cancel Paste", func():
		clipboard.paste_voxels()
		expect(clipboard._options.get_node("CancelPaste").visible, "Cancel Paste is visible during placement")
		clipboard._options.get_node("CancelPaste").pressed.emit()
	)
	await get_tree().process_frame
	step("Then the button discards the paste preview", _expect_cancelled_paste)
	step("When the user rotates the view during another paste", func():
		clipboard.paste_voxels()
		_orbit()
		expect(clipboard._paste_tool._active, "view rotation keeps the paste pending")
		expect(State.selection.capture() == source_selection, "view rotation preserves the target selection")
		clipboard._options.get_node("CancelPaste").pressed.emit()
	)
	await get_tree().process_frame
	step("Then Cancel Paste still discards the preview", _expect_cancelled_paste)
	step("When the user requests clipboard text and presses Cancel Paste", func():
		clipboard._pattern = {}
		clipboard.paste_voxels()
		expect(clipboard._options.get_node("CancelPaste").visible, "Cancel Paste is visible while the clipboard is read or placed")
		clipboard._options.get_node("CancelPaste").pressed.emit()
	)
	while clipboard._import_job:
		await get_tree().process_frame
	await get_tree().process_frame
	step("Then cancelled clipboard work cannot start a new paste", _expect_cancelled_paste)
	step("Given the Line tool with an empty document", func():
		State.document = VoxelDocument.new()
		select_toolbar_item("Toolbar", "Line")
		camera_rig().set_view("top")
	)
	step("When the user starts a two-click line and rotates the view", func():
		_button(Vector3.ZERO, MOUSE_BUTTON_LEFT, true)
		_button(Vector3.ZERO, MOUSE_BUTTON_LEFT, false)
		_orbit()
	)
	step("Then the line stays pending until Escape cancels it", func():
		expect(State.get_current_voxel_frame().count() == 0, "view rotation leaves the line document empty")
		expect(plugin("BrushPlugin")._line_tool.visible, "view rotation retains the pending line preview")
		var event := InputEventKey.new()
		event.keycode = KEY_ESCAPE
		event.pressed = true
		viewport.push_input(event)
		expect(not plugin("BrushPlugin")._line_tool.visible, "Escape hides the pending line preview")
		expect(not State.undo_redo.has_undo(), "the cancelled line adds no undo action")
	)
	for tool_name in ["Move", "Rotate", "Scale"]:
		step("Given a selected shape and the %s tool" % tool_name, func():
			State.document = VoxelDocument.new()
			frame = State.get_current_voxel_frame()
			frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
			State.selection.from_box(Vector3i.ZERO, Vector3i(2, 1, 0))
			State.selection_changed.emit()
			source_selection = State.selection.capture()
			camera_rig().set_view("front")
			activate_tool("transform")
			select_toolbar_item("transform", tool_name)
			plugin("TransformPlugin")._current_tool._settings.snap = true
			plugin("TransformPlugin")._current_tool._settings.uniform = false
		)
		step("When the user previews %s and rotates the view" % tool_name, func():
			if tool_name == "Move":
				_drag(Vector3.ZERO, Vector3(2, 0, 0))
			elif tool_name == "Rotate":
				_drag(Vector3(5, 0.5, 0), Vector3(1, 4.5, 0))
			else:
				_drag(Vector3(5, 4.5, 0), Vector3(9, 8.5, 0))
			expect(plugin("TransformPlugin")._current_tool._settings.transforming, "the transform waits for confirmation")
			_orbit()
			expect(plugin("TransformPlugin")._current_tool._settings.transforming, "view rotation keeps the transform pending")
		)
		step("When the user presses the transform Cancel button", func():
			plugin("TransformPlugin")._options.get_node("cancel").pressed.emit()
		)
		step("Then the button restores the original shape and selection", func():
			expect(frame.count() == 1 and frame.get_color(Vector3i.ZERO) == Color.RED, "the cancelled transform restores the source voxel")
			expect(State.selection.capture() == source_selection, "the cancelled transform restores the full selection")
			expect(not State.undo_redo.has_undo(), "the cancelled transform adds no undo action")
			expect(not plugin("TransformPlugin")._current_tool._settings.transforming, "the cancelled transform leaves no pending confirmation")
		)
	step("When the user drags the right mouse button with no pending edit", func():
		_orbit()
	)
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		DisplayServer.clipboard_set(original_clipboard)


func _expect_cancelled_paste() -> void:
	expect(frame.count() == 1 and frame.get_color(Vector3i(-8, 0, 0)) == Color.GREEN, "the cancelled paste preserves the target voxels")
	expect(State.selection.capture() == source_selection, "the cancelled paste preserves the target selection")
	expect(not State.undo_redo.has_undo(), "the cancelled paste adds no undo action")
	expect(not State.edit_busy(), "the cancelled paste releases editing")
	expect(not clipboard._paste_tool.is_inside_tree(), "the cancelled paste removes its preview tool")
	expect(not clipboard._options.get_node("CancelPaste").visible, "the cancelled paste hides Cancel Paste")


func _orbit() -> void:
	var before := camera_rig().transform
	_button(Vector3.ZERO, MOUSE_BUTTON_RIGHT, true)
	var event := InputEventMouseMotion.new()
	event.button_mask = MOUSE_BUTTON_MASK_RIGHT
	event.relative = Vector2(20, 0)
	viewport.push_input(event)
	_button(Vector3.ZERO, MOUSE_BUTTON_RIGHT, false)
	expect(camera_rig().transform != before, "right-drag rotates the camera")


func _drag(first: Vector3, last: Vector3) -> void:
	_button(first, MOUSE_BUTTON_LEFT, true)
	var event := InputEventMouseMotion.new()
	event.position = camera_rig().unproject_position(last)
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.push_input(event)
	_button(last, MOUSE_BUTTON_LEFT, false)


func _button(world: Vector3, button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	event.position = camera_rig().unproject_position(world)
	event.button_mask = (MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT) if pressed else 0
	viewport.push_input(event)
