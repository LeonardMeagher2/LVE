extends "res://tests/test.gd"

var menu_bar: Node
var undo_btn: Button
var redo_btn: Button
var operation := 0


func _ready() -> void:
	test("the menu bar undo and redo buttons follow the edit history", _run)


func _run() -> void:
	step("Given the menu bar and a fresh document", func():
		State.document = VoxelDocument.new()
		menu_bar = main.get_node("Content/VBoxContainer/MenuBar")
		undo_btn = menu_bar.get_node("UndoBtn")
		redo_btn = menu_bar.get_node("RedoBtn")
	)

	step("Then both history buttons are disabled", func():
		expect(undo_btn.disabled, "undo is disabled without history")
		expect(redo_btn.disabled, "redo is disabled without history")
	)

	step("When the user paints a voxel in a stroke", func():
		State.begin_stroke()
		State.paint(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.end_stroke()
	)

	step("Then undo is enabled and redo is disabled", func():
		expect(not undo_btn.disabled, "undo is enabled after a stroke")
		expect(redo_btn.disabled, "redo stays disabled after a new edit")
	)

	step("When the user undoes the stroke", func():
		menu_bar._on_undo_btn_pressed()
	)

	step("Then undo is disabled and redo is enabled", func():
		expect(undo_btn.disabled, "undo is disabled at the start of the history")
		expect(not redo_btn.disabled, "redo is enabled after an undo")
	)

	step("When the user redoes the stroke", func():
		menu_bar._on_redo_btn_pressed()
	)

	step("Then undo is enabled and redo is disabled", func():
		expect(not undo_btn.disabled, "undo is enabled after a redo")
		expect(redo_btn.disabled, "redo is disabled at the end of the history")
	)

	step("When adding a frame records a non-stroke action", func():
		State.add_frame()
	)

	step("Then undo is enabled for the frame action", func():
		expect(not undo_btn.disabled, "undo is enabled after adding a frame")
		expect(redo_btn.disabled, "redo stays disabled after adding a frame")
	)

	step("When a foreground operation starts", func():
		operation = State.begin_operation("Test operation", -1, true, self)
	)

	step("Then both history buttons are disabled while busy", func():
		expect(undo_btn.disabled, "undo is disabled while busy")
		expect(redo_btn.disabled, "redo is disabled while busy")
	)

	step("When the foreground operation finishes", func():
		State.finish_operation(operation)
	)

	step("Then the history buttons follow the history again", func():
		expect(not undo_btn.disabled, "undo is enabled after the operation")
		expect(redo_btn.disabled, "redo is disabled after the operation")
	)
