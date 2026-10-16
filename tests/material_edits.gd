extends "res://tests/test.gd"

const MATERIAL := {"emission": Color(1, 0.5, 0.25), "metallic": 1.0, "roughness": 0.25}

var clipboard: Node
var frame: VoxelFrame
var changed_emits := 0
var original_clipboard := ""


func _ready() -> void:
	timeout = 30.0
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		original_clipboard = DisplayServer.clipboard_get()
	test("Material edits undo and travel through the clipboard", _run)


func _run() -> void:
	step("Given a voxel and a material stroke", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i(2, 0, 0), Color.RED)
		State.undo_redo.clear_history()
		State.begin_stroke()
		frame.set_materials({Vector3i(2, 0, 0): MATERIAL})
		State.end_stroke("Material")
	)
	step("Then the material change is undoable", func():
		expect(_same_material(frame.get_material(Vector3i(2, 0, 0)), MATERIAL), "the voxel keeps its new material")
		expect(frame.get_color(Vector3i(2, 0, 0)) == Color.RED, "the voxel keeps its color")
		State.undo_redo.undo()
		expect(frame.get_material(Vector3i(2, 0, 0)) == VoxelFrame.DEFAULT_MATERIAL, "undo restores the default material")
		expect(frame.get_color(Vector3i(2, 0, 0)) == Color.RED, "undo keeps the voxel color")
	)
	step("Then redo restores the material and refreshes the view", func():
		changed_emits = 0
		State.cells_changed.connect(_on_cells_changed)
		State.undo_redo.redo()
		State.cells_changed.disconnect(_on_cells_changed)
		expect(_same_material(frame.get_material(Vector3i(2, 0, 0)), MATERIAL), "redo restores the new material")
		expect(changed_emits > 0, "the redo tells the view to redraw")
	)
	step("Given a metal voxel in the copy selection", func():
		clipboard = plugin("ClipboardPlugin")
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i(2, 0, 0), Color.RED)
		frame.set_materials({Vector3i(2, 0, 0): MATERIAL})
		State.selection.add(Vector3i(2, 0, 0))
		State.selection_changed.emit()
		clipboard.copy_voxels()
	)
	step("When the user pastes it on a plain voxel", func():
		clipboard._pattern = {}
		clipboard._selection_pattern = {}
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i(10, 0, 0), Color.BLUE)
		State.selection.add(Vector3i(-20, 0, 0))
		State.selection_changed.emit()
		clipboard.paste_voxels()
	)
	while clipboard._import_job:
		await get_tree().process_frame
	step("Then the pasted voxel keeps the color and the material", func():
		_place(Vector3i(10, 0, 0))
		expect(frame.get_color(Vector3i(10, 0, 0)) == Color.RED, "the pasted voxel keeps its color")
		expect(_same_material(frame.get_material(Vector3i(10, 0, 0)), MATERIAL), "the pasted voxel keeps its material")
	)
	step("Given a plain green voxel copied over a metal voxel", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i(2, 0, 0), Color.GREEN)
		State.selection.add(Vector3i(2, 0, 0))
		State.selection_changed.emit()
		clipboard.copy_voxels()
		clipboard._pattern = {}
		clipboard._selection_pattern = {}
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i(10, 0, 0), Color.BLUE)
		frame.set_materials({Vector3i(10, 0, 0): MATERIAL})
		State.selection.add(Vector3i(-20, 0, 0))
		State.selection_changed.emit()
		clipboard.paste_voxels()
	)
	while clipboard._import_job:
		await get_tree().process_frame
	step("Then the pasted voxel replaces the metal voxel", func():
		_place(Vector3i(10, 0, 0))
		expect(frame.get_color(Vector3i(10, 0, 0)) == Color.GREEN, "the pasted voxel takes the source color")
		expect(frame.get_material(Vector3i(10, 0, 0)) == VoxelFrame.DEFAULT_MATERIAL, "the pasted voxel takes the default material")
	)
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		DisplayServer.clipboard_set(original_clipboard)


func _place(center: Vector3i) -> void:
	clipboard._paste_tool._update_endpoint(center)
	var event := InputEventKey.new()
	event.keycode = KEY_ENTER
	event.pressed = true
	clipboard._paste_tool.handle_input(event, Vector2.ZERO)


func _on_cells_changed(_frame: int, _affected: Array[Vector3i]) -> void:
	changed_emits += 1


func _same_material(actual: Dictionary, expected: Dictionary) -> bool:
	var actual_emission: Color = actual.emission
	var expected_emission: Color = expected.emission
	return actual_emission.r == expected_emission.r and actual_emission.g == expected_emission.g and actual_emission.b == expected_emission.b and actual.metallic == expected.metallic and actual.roughness == expected.roughness
