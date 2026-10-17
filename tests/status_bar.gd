extends "res://tests/test.gd"

var status: EditorStatusBar


func _ready() -> void:
	test("the status bar shows the current document dimensions", _run)


func _run() -> void:
	State.document = VoxelDocument.new()
	step("Given the status bar and an empty document", func():
		status = load("res://ui/StatusBar/status_bar.tscn").instantiate()
		main.add_child(status)
	)
	await get_tree().process_frame
	step("Then the empty document shows zero dimensions", func():
		expect(status.get_node("StatusRight").text.begins_with("0×0×0"), "the empty document shows zero dimensions")
	)
	step("When a voxel is painted", func():
		State.document.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var affected: Array[Vector3i] = []
		State.cells_changed.emit(State.current_frame, affected)
	)
	await get_tree().process_frame
	step("Then the status bar shows the new dimensions", func():
		expect(status.get_node("StatusRight").text.begins_with("1×1×1"), "painting a voxel updates the shown dimensions")
	)
	step("When the only voxel is erased", func():
		State.document.erase(0, Vector3i.ZERO)
		var affected: Array[Vector3i] = []
		State.chunks_changed.emit(State.current_frame, affected)
	)
	await get_tree().process_frame
	step("Then the status bar returns to zero dimensions", func():
		expect(status.get_node("StatusRight").text.begins_with("0×0×0"), "erasing the last voxel shrinks the shown dimensions")
	)
