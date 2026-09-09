extends "res://tests/test.gd"


func _ready() -> void:
	test("can select, rename, and remove tags while keeping a default tag", _run)


func _tag_row() -> Node:
	return main.find_child("TagRow", true, false)


func _dropdown() -> OptionButton:
	return _tag_row().get_node("%TagDropdown")


func _name_edit() -> LineEdit:
	return _tag_row().get_node("%TagRenameInput")


func _rename_dialog() -> ConfirmationDialog:
	return _tag_row().get_node("%TagRenameDialog")


func _actions_popup() -> PopupMenu:
	return _tag_row().get_node("%TagActions").get_popup()


func _frame_cells() -> Array:
	var out: Array = []
	var grid := main.find_child("FrameGrid", true, false)
	for child in grid.get_children():
		if child is AnimationFrame:
			out.append(child)
	return out


func _run() -> void:
	step("Given a document with three frames", func():
		State.add_frame()
		State.add_frame()
	)

	step("Then the default tag is selected and editable", func():
		expect(State.document.tags.size() == 1, "the document holds one tag")
		expect(_dropdown().item_count == 1, "the dropdown shows one item")
		expect(_dropdown().get_item_text(0) == "Default", "the item is named Default")
		expect(State.active_tag == 0, "the default tag is selected")
		expect(_actions_popup().is_item_disabled(2), "the delete action is disabled with one tag")
		for cell in _frame_cells():
			expect(cell.get_node("%Delay").is_visible_in_tree(), "the delay field is shown")
		var grid := main.find_child("FrameGrid", true, false)
		expect(grid.get_child_count() > _frame_cells().size(), "the range row is shown")
	)

	step("When the user adds a tag from the tag menu", func():
		_actions_popup().id_pressed.emit(0)
	)

	step("Then two tags exist and the new one is selected", func():
		expect(State.document.tags.size() == 2, "the document holds two tags")
		expect(_dropdown().item_count == 2, "the dropdown shows two items")
		expect(State.active_tag == 1, "the new tag is selected")
		expect(not _actions_popup().is_item_disabled(2), "the delete action is enabled")
	)

	step("When the user picks the first tag from the dropdown", func():
		_dropdown().item_selected.emit(0)
	)

	step("Then the first tag becomes selected", func():
		expect(State.active_tag == 0, "the first tag is selected")
		expect(_dropdown().selected == 0, "the dropdown selection updates")
	)

	step("When the user renames the tag from the tag menu", func():
		_actions_popup().id_pressed.emit(1)
	)

	step("Then a rename dialog opens with the tag name", func():
		expect(_rename_dialog().visible, "the rename dialog is shown")
		expect(_name_edit().text == "Default", "the dialog holds the tag name")
	)

	step("When the user types a new name and confirms", func():
		_name_edit().text = "Spin"
		_rename_dialog().confirmed.emit()
	)

	step("Then the tag is renamed and the dropdown updates", func():
		expect(State.document.tags[0].name == "Spin", "the tag is renamed to Spin")
		expect(_dropdown().get_item_text(0) == "Spin", "the dropdown item updates")
	)

	step("When the user opens the rename dialog and cancels", func():
		_actions_popup().id_pressed.emit(1)
		_name_edit().text = "Cancelled"
		_rename_dialog().canceled.emit()
	)

	step("Then the tag keeps its name", func():
		expect(State.document.tags[0].name == "Spin", "the tag keeps the name Spin")
		expect(_dropdown().get_item_text(0) == "Spin", "the dropdown item stays Spin")
	)

	step("When the user removes the selected tag", func():
		_actions_popup().id_pressed.emit(2)
	)

	step("Then one tag remains and cannot be removed", func():
		expect(State.document.tags.size() == 1, "one tag remains")
		expect(_dropdown().item_count == 1, "the dropdown shows one item")
		expect(_actions_popup().is_item_disabled(2), "the delete action is disabled again")
	)

	step("When the user tries to remove the last tag", func():
		_actions_popup().id_pressed.emit(2)
	)

	step("Then the last tag stays", func():
		expect(State.document.tags.size() == 1, "the document still holds one tag")
		expect(_dropdown().is_visible_in_tree(), "the dropdown stays visible")
	)
