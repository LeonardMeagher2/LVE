class_name RangeCell
extends HBoxContainer

var column_index := 0
var _is_from := false
var _is_to := false
var _dragging := false
var _drag_from := false


func set_column_index(i: int) -> void:
	column_index = i


func _ready() -> void:
	set_process_input(true)
	State.tag_changed.connect(_sync)
	_sync()


func _sync() -> void:
	var tag: AnimationTag = State.get_active_tag()
	if tag == null:
		%Bar.visible = false
		%StartGrip.visible = false
		%EndGrip.visible = false
		_is_from = false
		_is_to = false
		return
	var lo := mini(tag.from, tag.to)
	var hi := maxi(tag.from, tag.to)
	%Bar.visible = column_index >= lo and column_index <= hi
	_is_from = column_index == tag.from
	_is_to = column_index == tag.to
	%StartGrip.visible = _is_from
	%EndGrip.visible = _is_to
	if _is_from:
		%StartGrip.tooltip_text = "Start frame %d" % (tag.from + 1)
	if _is_to:
		%EndGrip.tooltip_text = "End frame %d" % (tag.to + 1)


func _gui_input(event: InputEvent) -> void:
	if _dragging:
		return
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if not _is_from and not _is_to:
		return
	_drag_from = _is_from and (not _is_to or mb.position.x < size.x * 0.5)
	_dragging = true
	accept_event()


func _input(event: InputEvent) -> void:
	if not _dragging:
		return
	var mb := event as InputEventMouseButton
	if mb != null and not mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		_dragging = false
		get_viewport().set_input_as_handled()
		return
	var mm := event as InputEventMouseMotion
	if mm == null:
		return
	var tag: AnimationTag = State.get_active_tag()
	if tag == null:
		return
	var col := _column_from_x(mm.position.x)
	if _drag_from:
		State.set_tag_range(col, tag.to)
	else:
		State.set_tag_range(tag.from, col)


func _column_from_x(x: float) -> int:
	var grid := get_parent()
	var n := State.get_frame_count()
	if n <= 1:
		return 0
	var pitch: float = grid.get_child(1).global_position.x - grid.get_child(0).global_position.x
	var base: float = grid.global_position.x
	return clampi(roundi((x - base - pitch * 0.5) / pitch), 0, n - 1)
