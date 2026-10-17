extends "res://tests/test.gd"

var panel: Node = null
var grid: Node = null


func _ready() -> void:
	test("the palette marks the selected material and restores indexed edits with undo", _run)


func _marked(i: int) -> bool:
	var b := grid.get_child(i) as Button
	return b.button_pressed


func _run() -> void:
	step("Given a palette with one red swatch", func():
		panel = main.find_child("PalettePanel", true, false)
		grid = panel.get_node("%SwatchGrid")
		State.document = VoxelDocument.new()
		State.document.palette.assign([VoxelFrame.material(Color.RED)])
		panel._rebuild_swatches()
	)

	step("When the working color becomes red", func():
		State.set_color(Color.RED)
	)

	step("Then the red swatch is marked", func():
		expect(grid.get_child_count() == 1, "one swatch exists")
		expect(_marked(0), "matching swatch is marked")
		expect(State.current_palette_index == 0, "the matching material selects its palette index")
	)

	step("When the working color becomes blue", func():
		State.set_color(Color.BLUE)
	)

	step("Then no swatch is marked", func():
		expect(not _marked(0), "no swatch is marked")
		expect(State.current_palette_index == -1, "the unsaved material has no palette index")
		expect(State.get_palette() == [VoxelFrame.material(Color.RED)], "setting the working color preserves the palette")
	)

	step("When the user clicks the red swatch", func():
		var b := grid.get_child(0) as Button
		b.button_pressed = true
	)

	step("Then the red swatch is marked again", func():
		expect(_marked(0), "clicked swatch is marked")
		expect(State.current_color == Color.RED, "the working color is the swatch color")
		expect(State.current_palette_index == 0, "clicking the swatch selects its index")
		State.undo_redo.clear_history()
	)

	step("When the user picks blue", func():
		State.set_color(Color.BLUE)
	)

	step("Then blue is the working color", func():
		expect(State.current_color == Color.BLUE, "the working color is blue")
		expect(not _marked(0), "no swatch matches blue")
	)

	step("When the user undoes the color change", func():
		State.undo_redo.undo()
	)

	step("Then the selected red material returns", func():
		expect(State.current_material == VoxelFrame.material(Color.RED), "undo restores the selected red material")
		expect(State.current_palette_index == 0, "undo restores the selected palette index")
	)

	step("When the user redoes the color change", func():
		State.undo_redo.redo()
	)

	step("Then blue is the working color again", func():
		expect(State.current_color == Color.BLUE, "the working color is blue again")
	)

	step("When the user picks green and adds it to the palette", func():
		State.set_color(Color.GREEN)
		State.add_material()
	)

	step("Then the palette gains a green swatch", func():
		expect(grid.get_child_count() == 2, "two swatches exist")
		expect((grid.get_child(1) as Button).color == Color.GREEN, "the new swatch is green")
		expect(State.current_palette_index == 1, "the new material selects its appended index")
	)

	step("When the user undoes the added swatch", func():
		State.undo_redo.undo()
	)

	step("Then the palette loses the green swatch", func():
		expect(grid.get_child_count() == 1, "one swatch remains")
	)

	step("When the user redoes the added swatch", func():
		State.undo_redo.redo()
	)

	step("Then the green swatch returns", func():
		expect(grid.get_child_count() == 2, "two swatches exist")
		expect((grid.get_child(1) as Button).color == Color.GREEN, "the green swatch is back")
	)

	step("When the user removes the selected material", func():
		State.remove_palette_entry()
	)

	step("Then the green swatch leaves the palette", func():
		expect(grid.get_child_count() == 1, "one swatch remains")
		expect(State.current_palette_index == 0 and State.current_color == Color.RED, "removal selects the remaining red swatch")
	)

	step("When the user undoes the removal", func():
		State.undo_redo.undo()
	)

	step("Then the green swatch returns at its index", func():
		expect(grid.get_child_count() == 2, "two swatches exist")
		expect((grid.get_child(1) as Button).color == Color.GREEN, "the green swatch is back")
		expect(State.current_palette_index == 1, "undo restores the removed material selection")
	)

	step("When the user redoes the removal", func():
		State.undo_redo.redo()
	)

	step("Then the green swatch leaves again", func():
		expect(grid.get_child_count() == 1, "one swatch remains")
	)
