class_name RangeCell
extends HBoxContainer

var column_index := 0
var _is_from := false
var _is_to := false
var _dragging := false
var _drag_from := false
var _drag_tag := -1
var _drag_range := Vector2i.ZERO


func set_column_index(i: int) -> void:
	column_index = i


func _ready() -> void:
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


# Handle the pointer in the GUI stage. The GUI keeps the pointer on the pressed
# cell until the release, so this receives the drag outside the cell. It also
# needs the release, because the release clears that state. A mouse event consumed
# in the input stage stops before the GUI, so a drag must not use _input.
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_begin_drag(event)
		elif _dragging:
			_dragging = false
			State.commit_tag_range(_drag_tag, _drag_range)
	elif event is InputEventMouseMotion and _dragging:
		_drag_range_to(event)


func _begin_drag(mb: InputEventMouseButton) -> void:
	if _dragging or (not _is_from and not _is_to):
		return
	_drag_from = _is_from and (not _is_to or mb.position.x < size.x * 0.5)
	_dragging = true
	_drag_tag = State.active_tag
	var tag := State.get_active_tag()
	_drag_range = Vector2i(tag.from, tag.to)
	accept_event()


func _drag_range_to(mm: InputEventMouseMotion) -> void:
	var tag: AnimationTag = State.get_active_tag()
	if tag == null or State.active_tag != _drag_tag:
		return
	# _column_from_x compares against the grid position, so pass the same space.
	var col := _column_from_x((get_global_transform() * mm.position).x)
	var from := col if _drag_from else tag.from
	var to := tag.to if _drag_from else col
	if from == tag.from and to == tag.to:
		return
	State.set_tag_range(from, to, false)


func _column_from_x(x: float) -> int:
	var grid := get_parent()
	var n := State.get_frame_count()
	if n <= 1:
		return 0
	var pitch: float = grid.get_child(1).global_position.x - grid.get_child(0).global_position.x
	var base: float = grid.global_position.x
	return clampi(roundi((x - base - pitch * 0.5) / pitch), 0, n - 1)
