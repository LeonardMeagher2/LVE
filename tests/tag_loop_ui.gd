extends "res://tests/test.gd"


func _ready() -> void:
	test("can edit a tag's loop mode and repeats", _run)


func _tag_row() -> Node:
	return main.find_child("TagRow", true, false)


func _loop_menu() -> MenuButton:
	return _tag_row().get_node("%LoopMenu")


func _repeats_spin() -> SpinBox:
	return _tag_row().get_node("%RepeatsSpin")


func _actions_popup() -> PopupMenu:
	return _tag_row().get_node("%TagActions").get_popup()


func _dropdown() -> OptionButton:
	return _tag_row().get_node("%TagDropdown")


func _run() -> void:
	step("Given a document with three frames", func():
		State.add_frame()
		State.add_frame()
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
