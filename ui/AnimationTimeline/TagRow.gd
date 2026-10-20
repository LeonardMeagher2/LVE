extends HBoxContainer

## The animation tag row.
##
## It selects a tag and edits its name, loop mode, and repeats. It also adds
## and removes tags.

const LOOP_FORWARD_ICON := preload("res://icons/loop_forward.svg")
const LOOP_REVERSE_ICON := preload("res://icons/loop_reverse.svg")
const LOOP_PING_PONG_ICON := preload("res://icons/loop_ping_pong.svg")

const ACTIONS_ADD := 0
const ACTIONS_RENAME := 1
const ACTIONS_DELETE := 2
const ACTIONS_REPEATS := 3
const REPEATS_ITEM_INDEX := 4


func _ready() -> void:
	State.frames_changed.connect(_rebuild_dropdown)
	State.tag_changed.connect(_sync)
	%LoopMenu.get_popup().id_pressed.connect(_on_loop_mode_selected)
	%TagActions.get_popup().id_pressed.connect(_on_action_selected)
	%TagRenameDialog.about_to_popup.connect(_on_rename_dialog_about_to_popup)
	_rebuild_dropdown()


func _rebuild_dropdown() -> void:
	%TagDropdown.clear()
	for tag in State.document.tags:
		%TagDropdown.add_item(tag.name)
	_sync()


func _sync() -> void:
	if %TagDropdown.item_count != State.document.tags.size():
		_rebuild_dropdown()
		return
	%TagDropdown.selected = State.active_tag
	var has_tag := State.get_active_tag() != null
	%TagActions.visible = has_tag
	%LoopMenu.visible = has_tag
	var repeats_on := false
	if has_tag:
		var tag := State.get_active_tag()
		%TagDropdown.set_item_text(State.active_tag, tag.name)
		%LoopMenu.icon = _loop_icon(tag.loop_mode)
		%LoopMenu.tooltip_text = _loop_tooltip(tag.loop_mode)
		repeats_on = tag.repeats > 0
		if repeats_on:
			%RepeatsSpin.set_value_no_signal(tag.repeats)
	%RepeatsSpin.visible = repeats_on
	%TagActions.get_popup().set_item_checked(REPEATS_ITEM_INDEX, repeats_on)
	%TagActions.get_popup().set_item_disabled(ACTIONS_DELETE, not has_tag or State.document.tags.size() <= 1)


func _loop_icon(mode: int) -> Texture2D:
	match mode:
		AnimationTag.LoopMode.REVERSE:
			return LOOP_REVERSE_ICON
		AnimationTag.LoopMode.PING_PONG, AnimationTag.LoopMode.PING_PONG_REVERSE:
			return LOOP_PING_PONG_ICON
	return LOOP_FORWARD_ICON


func _loop_tooltip(mode: int) -> String:
	match mode:
		AnimationTag.LoopMode.REVERSE:
			return "Loop mode: reverse"
		AnimationTag.LoopMode.PING_PONG:
			return "Loop mode: ping-pong"
		AnimationTag.LoopMode.PING_PONG_REVERSE:
			return "Loop mode: ping-pong reverse"
	return "Loop mode: forward"


func _on_tag_selected(index: int) -> void:
	State.select_tag(index)


func _on_action_selected(id: int) -> void:
	match id:
		ACTIONS_ADD:
			State.add_tag("Tag")
		ACTIONS_RENAME:
			_open_rename_dialog()
		ACTIONS_DELETE:
			State.remove_tag()
		ACTIONS_REPEATS:
			var checked: bool = not %TagActions.get_popup().is_item_checked(REPEATS_ITEM_INDEX)
			%TagActions.get_popup().set_item_checked(REPEATS_ITEM_INDEX, checked)
			if State.get_active_tag():
				State.set_tag_repeats(State.active_tag, 1 if checked else 0)


func _open_rename_dialog() -> void:
	if State.get_active_tag() == null:
		return
	%TagRenameDialog.popup_centered()


func _on_rename_dialog_about_to_popup() -> void:
	%TagRenameInput.text = State.get_active_tag().name


func _on_rename_confirmed() -> void:
	if State.get_active_tag() == null:
		return
	var new_name: String = %TagRenameInput.text.strip_edges()
	if new_name.is_empty():
		return
	State.set_tag_name(State.active_tag, new_name)


func _on_loop_mode_selected(mode: int) -> void:
	State.set_tag_loop_mode(State.active_tag, mode)


func _on_repeats_changed(value: float) -> void:
	State.set_tag_repeats(State.active_tag, int(value))
