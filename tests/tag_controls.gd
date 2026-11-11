extends "res://tests/test.gd"

# One process runs the tag-control tests. Each test keeps the steps and checks of
# its original scene. The user arguments after `--` name the tests to run, so an
# old scene name still selects its own test.


func _ready() -> void:
	test("can select, rename, and remove tags while keeping a default tag", _tags_ui, "tags_ui")
	test("can edit a tag's loop mode and repeats", _tag_loop_ui, "tag_loop_ui")


# Each test starts from a fresh one-frame document with its default tag.
func before_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.current_frame = 0
	State.active_tag = 0


# An emitted rename signal leaves the dialog open, so close it before the next
# test. Nothing else here changes focus, the pointer, or a popup.
func after_test() -> void:
	var dialog: ConfirmationDialog = _tag_row().get_node_or_null("%TagRenameDialog")
	if dialog != null and dialog.visible:
		dialog.hide()


# Shared controls. Both tests read the same tag row.
func _tag_row() -> Node:
	return main.find_child("TagRow", true, false)


func _dropdown() -> OptionButton:
	return _tag_row().get_node("%TagDropdown")


func _actions_popup() -> PopupMenu:
	return _tag_row().get_node("%TagActions").get_popup()


# Shared fixture: add frames beside the first one.
func _add_frames(extra: int) -> void:
	for i in extra:
		State.add_frame()


func _tags_ui() -> void:
	step("Given a document with three frames", func():
		_add_frames(2)
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

	step("When the user undoes the added tag", func():
		State.undo_redo.undo()
	)

	step("Then the added tag is gone and the first is selected", func():
		expect(State.document.tags.size() == 1, "the document holds one tag")
		expect(_dropdown().item_count == 1, "the dropdown shows one item")
		expect(State.active_tag == 0, "the first tag is selected again")
	)

	step("When the user redoes the added tag", func():
		State.undo_redo.redo()
	)

	step("Then the added tag returns and is selected", func():
		expect(State.document.tags.size() == 2, "the document holds two tags")
		expect(_dropdown().item_count == 2, "the dropdown shows two items")
		expect(State.active_tag == 1, "the new tag is selected again")
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

	step("When the user undoes the rename", func():
		State.undo_redo.undo()
	)

	step("Then the tag name returns to Default", func():
		expect(State.document.tags[0].name == "Default", "the tag is named Default again")
		expect(_dropdown().get_item_text(0) == "Default", "the dropdown item returns to Default")
	)

	step("When the user redoes the rename", func():
		State.undo_redo.redo()
	)

	step("Then the tag is renamed again", func():
		expect(State.document.tags[0].name == "Spin", "the tag is named Spin again")
		expect(_dropdown().get_item_text(0) == "Spin", "the dropdown item returns to Spin")
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

	step("When the user undoes the removal", func():
		State.undo_redo.undo()
	)

	step("Then the removed tag returns and is selected", func():
		expect(State.document.tags.size() == 2, "the document holds two tags")
		expect(_dropdown().item_count == 2, "the dropdown shows two items")
		expect(State.document.tags[0].name == "Spin", "the removed tag returns to the front")
		expect(State.active_tag == 0, "the removed tag is selected again")
	)

	step("When the user redoes the removal", func():
		State.undo_redo.redo()
	)

	step("Then the tag is removed again", func():
		expect(State.document.tags.size() == 1, "the document holds one tag")
		expect(_dropdown().item_count == 1, "the dropdown shows one item")
	)

	step("When the user tries to remove the last tag", func():
		_actions_popup().id_pressed.emit(2)
	)

	step("Then the last tag stays", func():
		expect(State.document.tags.size() == 1, "the document still holds one tag")
		expect(_dropdown().is_visible_in_tree(), "the dropdown stays visible")
	)


func _tag_loop_ui() -> void:
	step("Given a document with three frames", func():
		_add_frames(2)
	)

	step("Then the default tag loops forward forever", func():
		expect(State.active_tag == 0, "the default tag is selected")
		expect(State.get_active_tag().loop_mode == AnimationTag.LoopMode.FORWARD, "the tag loops forward")
		expect(_loop_menu().is_visible_in_tree(), "the loop menu is shown")
		expect(_loop_menu().icon.resource_path.ends_with("loop_forward.svg"), "the loop menu shows the forward icon")
		expect(State.get_active_tag().repeats == 0, "the repeats count is zero (infinite)")
		expect(not _actions_popup().is_item_checked(4), "the repeats checkbox is unchecked")
		expect(not _repeats_spin().is_visible_in_tree(), "the repeats spinbox is hidden")
	)

	step("When the user enables the repeats field from the tag menu", func():
		_actions_popup().id_pressed.emit(3)
	)

	step("Then the repeats spinbox appears and starts at one", func():
		expect(_actions_popup().is_item_checked(4), "the repeats checkbox is checked")
		expect(_repeats_spin().is_visible_in_tree(), "the repeats spinbox is shown")
		expect(_repeats_spin().value == 1.0, "the repeats count starts at one")
		expect(State.get_active_tag().repeats == 1, "the tag repeats once")
	)

	step("When the user picks ping-pong from the loop menu", func():
		_loop_menu().get_popup().id_pressed.emit(AnimationTag.LoopMode.PING_PONG)
	)

	step("Then the active tag loops ping-pong", func():
		expect(State.get_active_tag().loop_mode == AnimationTag.LoopMode.PING_PONG, "the tag loops ping-pong")
		expect(_loop_menu().icon.resource_path.ends_with("loop_ping_pong.svg"), "the loop menu shows the ping-pong icon")
	)

	step("When the user undoes the loop mode change", func():
		State.undo_redo.undo()
	)

	step("Then the tag loops forward again", func():
		expect(State.get_active_tag().loop_mode == AnimationTag.LoopMode.FORWARD, "the tag loops forward")
		expect(_loop_menu().icon.resource_path.ends_with("loop_forward.svg"), "the loop menu shows the forward icon")
	)

	step("When the user redoes the loop mode change", func():
		State.undo_redo.redo()
	)

	step("Then the tag loops ping-pong again", func():
		expect(State.get_active_tag().loop_mode == AnimationTag.LoopMode.PING_PONG, "the tag loops ping-pong")
	)

	step("When the user sets repeats to three", func():
		_repeats_spin().value = 3
	)

	step("Then the active tag repeats three times", func():
		expect(State.get_active_tag().repeats == 3, "the tag repeats three times")
	)

	step("When the user undoes the repeats change", func():
		State.undo_redo.undo()
	)

	step("Then the tag repeats once again", func():
		expect(State.get_active_tag().repeats == 1, "the tag repeats once")
		expect(_repeats_spin().value == 1.0, "the spinbox shows one")
	)

	step("When the user redoes the repeats change", func():
		State.undo_redo.redo()
	)

	step("Then the tag repeats three times again", func():
		expect(State.get_active_tag().repeats == 3, "the tag repeats three times")
		expect(_repeats_spin().value == 3.0, "the spinbox shows three")
	)

	step("When the user plays the tag", func():
		State.current_frame = 0
		State.play_tag(0)
	)

	step("Then playback uses the edited values", func():
		State.playback.advance()
		expect(State.current_frame == 1, "playback steps forward")
		State.playback.advance()
		expect(State.current_frame == 2, "playback reaches the ping-pong end")
		State.playback.advance()
		expect(State.current_frame == 1, "playback bounces back")
		State.stop()
	)

	step("When the user disables the repeats field", func():
		_actions_popup().id_pressed.emit(3)
	)

	step("Then the spinbox hides and the tag is infinite", func():
		expect(not _repeats_spin().is_visible_in_tree(), "the repeats spinbox is hidden")
		expect(State.get_active_tag().repeats == 0, "the tag loops forever")
	)

	step("When the user enables the repeats field again", func():
		_actions_popup().id_pressed.emit(3)
	)

	step("Then the count starts at one again", func():
		expect(_repeats_spin().is_visible_in_tree(), "the repeats spinbox is shown")
		expect(_repeats_spin().value == 1.0, "the repeats count starts at one")
	)

	step("When the user adds a second tag", func():
		_actions_popup().id_pressed.emit(0)
	)

	step("Then the controls follow the new tag", func():
		expect(_loop_menu().icon.resource_path.ends_with("loop_forward.svg"), "the new tag loops forward")
		expect(State.get_active_tag().repeats == 0, "the new tag loops forever")
		expect(not _actions_popup().is_item_checked(4), "the repeats checkbox is unchecked")
		expect(not _repeats_spin().is_visible_in_tree(), "the repeats spinbox is hidden")
	)

	step("When the user picks the first tag again", func():
		_dropdown().item_selected.emit(0)
	)

	step("Then the repeats field reflects the first tag", func():
		expect(State.get_active_tag().repeats == 1, "the first tag repeats once")
		expect(_actions_popup().is_item_checked(4), "the repeats checkbox is checked")
		expect(_repeats_spin().is_visible_in_tree(), "the repeats spinbox is shown")
		expect(_repeats_spin().value == 1.0, "the repeats count shows one")
	)

	step("When the user deselects the tag", func():
		State.deselect_tag()
	)

	step("Then the loop and repeat controls hide", func():
		expect(not _loop_menu().is_visible_in_tree(), "the loop menu is hidden")
		expect(not _repeats_spin().is_visible_in_tree(), "the repeats spinbox is hidden")
	)


# Controls used by one test only.
func _name_edit() -> LineEdit:
	return _tag_row().get_node("%TagRenameInput")


func _rename_dialog() -> ConfirmationDialog:
	return _tag_row().get_node("%TagRenameDialog")


func _frame_cells() -> Array:
	var out: Array = []
	var grid := main.find_child("FrameGrid", true, false)
	for child in grid.get_children():
		if child is AnimationFrame:
			out.append(child)
	return out


func _loop_menu() -> MenuButton:
	return _tag_row().get_node("%LoopMenu")


func _repeats_spin() -> SpinBox:
	return _tag_row().get_node("%RepeatsSpin")
