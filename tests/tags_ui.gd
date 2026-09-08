extends "res://tests/test.gd"


func _ready() -> void:
	test("can add, select, rename, and remove tags with the dropdown and edit mode", _run)


func _tag_row() -> Node:
	return main.find_child("TagRow", true, false)


func _dropdown() -> OptionButton:
	return _tag_row().get_node("%TagDropdown")


func _name_edit() -> LineEdit:
	return _tag_row().get_node("%TagNameEdit")


func _edit_toggle() -> Button:
	return main.find_child("EditToggle", true, false)


func _tag_add_button() -> Node:
	return main.find_child("TagAdd", true, false)


func _tag_del_button() -> Node:
	return main.find_child("TagDel", true, false)


func _frame_cells() -> Array:
	var out: Array = []
	var grid := main.find_child("FrameGrid", true, false)
	for child in grid.get_children():
		if child is AnimationFrame:
			out.append(child)
	return out


func _run() -> void:
	step("Given a document with three frames", func():
		State.document.add_frame()
		State.document.add_frame()
	)

	step("When the user adds a tag", func():
		_tag_add_button().pressed.emit()
	)

	step("Then the dropdown shows the tag", func():
		expect(State.document.tags.size() == 1, "the document holds one tag")
		expect(_dropdown().item_count == 1, "the dropdown shows one item")
		expect(_dropdown().get_item_text(0) == "Tag", "the item is named Tag")
		expect(State.active_tag == 0, "the new tag is selected")
		expect(_dropdown().selected == 0, "the dropdown selection follows the tag")
	)

	step("When the user adds a second tag", func():
		_tag_add_button().pressed.emit()
	)

	step("Then two tags exist and the dropdown shows both", func():
		expect(State.document.tags.size() == 2, "the document holds two tags")
		expect(_dropdown().item_count == 2, "the dropdown shows two items")
		expect(State.active_tag == 1, "the second tag is selected")
		expect(_dropdown().selected == 1, "the dropdown selection follows the tag")
	)

	step("When the user picks the first tag from the dropdown", func():
		_dropdown().item_selected.emit(0)
	)

	step("Then the first tag becomes selected", func():
		expect(State.active_tag == 0, "the first tag is selected")
		expect(_dropdown().selected == 0, "the dropdown selection updates")
	)

	step("Then the delay fields are hidden and the edit toggle is shown", func():
		for cell in _frame_cells():
			expect(not cell.get_node("%Delay").is_visible_in_tree(), "the delay field is hidden")
		expect(_edit_toggle().is_visible_in_tree(), "the edit toggle is shown")
	)

	step("When the user toggles edit mode on", func():
		_edit_toggle().button_pressed = true
	)

	step("Then the dropdown becomes a name field and edit controls appear", func():
		expect(State.edit_mode, "edit mode is on")
		expect(not _dropdown().is_visible_in_tree(), "the dropdown is hidden")
		expect(_name_edit().is_visible_in_tree(), "the name field is shown")
		expect(_name_edit().text == "Tag", "the name field holds the tag name")
		for cell in _frame_cells():
			expect(cell.get_node("%Delay").is_visible_in_tree(), "the delay field is shown")
		var grid := main.find_child("FrameGrid", true, false)
		expect(grid.get_child_count() > _frame_cells().size(), "the range row is shown")
	)

	step("When the user renames the tag", func():
		_tag_row()._on_name_text_changed("Spin")
	)

	step("Then the tag is renamed and the dropdown updates", func():
		expect(State.document.tags[0].name == "Spin", "the tag is renamed to Spin")
		expect(_dropdown().get_item_text(0) == "Spin", "the dropdown item updates")
	)

	step("When the user toggles edit mode off", func():
		_edit_toggle().button_pressed = false
	)

	step("Then the dropdown returns and edit controls hide", func():
		expect(not State.edit_mode, "edit mode is off")
		expect(_dropdown().is_visible_in_tree(), "the dropdown is shown")
		expect(not _name_edit().is_visible_in_tree(), "the name field is hidden")
		for cell in _frame_cells():
			expect(not cell.get_node("%Delay").is_visible_in_tree(), "the delay field is hidden")
		var grid := main.find_child("FrameGrid", true, false)
		expect(grid.get_child_count() == _frame_cells().size(), "the range row is hidden")
	)

	step("When the user removes the active tag", func():
		_tag_del_button().pressed.emit()
	)

	step("Then the dropdown holds one item", func():
		expect(State.document.tags.size() == 1, "one tag remains")
		expect(_dropdown().item_count == 1, "the dropdown shows one item")
	)

	step("When the user removes the last tag", func():
		_tag_del_button().pressed.emit()
	)

	step("Then the dropdown hides when there are no tags", func():
		expect(State.document.tags.is_empty(), "no tags remain")
		expect(not _dropdown().is_visible_in_tree(), "the dropdown is hidden")
		expect(not _name_edit().is_visible_in_tree(), "no name field is shown")
	)

	step("When the user toggles edit mode on without a tag", func():
		_edit_toggle().button_pressed = true
	)

	step("Then the delay fields appear and the tag controls stay hidden", func():
		expect(State.edit_mode, "edit mode is on")
		for cell in _frame_cells():
			expect(cell.get_node("%Delay").is_visible_in_tree(), "the delay field is shown")
		expect(not _dropdown().is_visible_in_tree(), "the dropdown stays hidden")
		expect(not _name_edit().is_visible_in_tree(), "no rename field is shown")
	)
