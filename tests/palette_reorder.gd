extends "res://tests/test.gd"

var grid: HFlowContainer
var frame: VoxelFrame
var drag_data: Variant


func _ready() -> void:
	test("dragging palette swatches reorders colors with undo and preserves the working color", _run)


func _run() -> void:
	step("Given three swatches with blue as the working color", func():
		grid = main.find_child("PalettePanel", true, false).get_node("%SwatchGrid")
		State.document = VoxiDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i.ZERO, Color.MAGENTA)
		State.document.palette.assign([Color.RED, Color.GREEN, Color.BLUE])
		State.palette_changed.emit()
		State.set_color(Color.BLUE)
		State.undo_redo.clear_history()
	)
	step("When the user drags the blue swatch onto the red swatch", func():
		drag_data = grid.get_child(2)._get_drag_data(Vector2.ZERO)
		expect(drag_data != null, "the blue swatch starts a drag")
		expect(grid.get_child(0)._can_drop_data(Vector2.ZERO, drag_data), "the red swatch accepts the palette drag")
		grid.get_child(0)._drop_data(Vector2.ZERO, drag_data)
	)
	step("Then blue becomes the first swatch", func():
		expect(State.get_palette() == PackedColorArray([Color.BLUE, Color.RED, Color.GREEN]), "the palette moves blue to the first position")
		expect(grid.get_child(0).color == Color.BLUE and grid.get_child(0).button_pressed, "the moved blue swatch remains selected")
		expect(State.current_color == Color.BLUE, "reordering preserves the working color")
		expect(frame.get_color(Vector3i.ZERO) == Color.MAGENTA, "reordering preserves voxel colors")
	)
	step("When the user undoes the palette drag", func():
		State.undo_redo.undo()
	)
	step("Then the original swatch order returns", func():
		expect(State.get_palette() == PackedColorArray([Color.RED, Color.GREEN, Color.BLUE]), "undo restores the original palette order")
		expect(grid.get_child(2).button_pressed, "undo keeps the blue swatch selected")
	)
	step("When the user redoes the palette drag", func():
		State.undo_redo.redo()
	)
	step("Then blue returns to the first position", func():
		expect(State.get_palette() == PackedColorArray([Color.BLUE, Color.RED, Color.GREEN]), "redo restores the reordered palette")
	)
	step("When the user drags the first swatch onto the last swatch", func():
		drag_data = grid.get_child(0)._get_drag_data(Vector2.ZERO)
		grid.get_child(2)._drop_data(Vector2.ZERO, drag_data)
	)
	step("Then blue becomes the last swatch", func():
		expect(State.get_palette() == PackedColorArray([Color.RED, Color.GREEN, Color.BLUE]), "the palette moves blue to the last position")
	)
	step("When the user drops a swatch onto itself", func():
		State.undo_redo.clear_history()
		drag_data = grid.get_child(1)._get_drag_data(Vector2.ZERO)
		grid.get_child(1)._drop_data(Vector2.ZERO, drag_data)
	)
	step("Then the palette keeps its order and history", func():
		expect(State.get_palette() == PackedColorArray([Color.RED, Color.GREEN, Color.BLUE]), "dropping onto the same swatch preserves the order")
		expect(not State.undo_redo.has_undo(), "dropping onto the same swatch adds no undo action")
		expect(not grid.get_child(0)._can_drop_data(Vector2.ZERO, {"type": "voxi_frame", "from": 1}), "palette swatches reject animation frame drags")
	)
	step("When the user opens another document during a palette drag", func():
		drag_data = grid.get_child(2)._get_drag_data(Vector2.ZERO)
		State.document = VoxiDocument.new()
		State.document.palette.assign([Color.RED, Color.GREEN, Color.BLUE])
		State.palette_changed.emit()
		grid.get_child(0)._drop_data(Vector2.ZERO, drag_data)
	)
	step("Then the old drag preserves the new document palette", func():
		expect(not grid.get_child(0)._can_drop_data(Vector2.ZERO, drag_data), "the new document rejects the old palette drag")
		expect(State.get_palette() == PackedColorArray([Color.RED, Color.GREEN, Color.BLUE]), "the new document keeps its palette order")
		expect(not State.undo_redo.has_undo(), "the rejected drag adds no undo action")
	)
	step("When a foreground edit is running", func():
		drag_data = grid.get_child(2)._get_drag_data(Vector2.ZERO)
		var operation_id := State.begin_operation("Editing", -1, true, self)
		expect(grid.get_child(0)._get_drag_data(Vector2.ZERO) == null, "palette drags wait for the foreground edit")
		expect(not grid.get_child(0)._can_drop_data(Vector2.ZERO, drag_data), "palette drops wait for the foreground edit")
		State.finish_operation(operation_id)
	)
