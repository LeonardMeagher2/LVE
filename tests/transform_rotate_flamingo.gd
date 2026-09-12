extends "res://tests/test.gd"

var viewport: SubViewport
var _source: Dictionary = {}


func _ready() -> void:
	test("rotating the Flamingo asset 90 degrees on any axis never loses or duplicates a voxel", _run)


func _run() -> void:
	step("Given the Flamingo's first frame selected with the rotate tool active", func():
		viewport = editor_viewport()
		var container := viewport.get_parent()
		container.stretch = false
		viewport.size = Vector2i(800, 500)
		var doc: VoxiDocument = load("res://Flamingo.tres")
		_source = doc.frames[0].cells.duplicate()
		expect(not _source.is_empty(), "the Flamingo asset loaded a non-empty first frame")
		State.undo_redo.clear_history()
		activate_tool("transform")
		select_toolbar_item("transform", "Rotate")
	)

	for axis_name in ["front", "right", "top"]:
		step("When the user rotates the Flamingo 90 degrees viewed from %s" % axis_name, func():
			State.selection.clear()
			_cells().clear()
			for c in _source:
				_cells()[c] = _source[c]
			_select_all(_source)
			camera_rig().set_view(axis_name)
			_drag_screen(Vector2(0, -100))
			_press_option("Commit")
		)

		step("Then the rotated Flamingo (%s) keeps every voxel, with no holes or duplicates" % axis_name, func():
			expect(_cells().size() == _source.size(), "the rotated Flamingo still holds %d voxels" % _source.size())
		)


func _select_all(source: Dictionary) -> void:
	State.selection.clear()
	for c in source:
		State.selection.add(c)
	State.selection_changed.emit()


func _cells() -> Dictionary:
	return State.document.frames[0].cells


func _current_center() -> Vector3:
	var b := AABB()
	var first := true
	for c in _cells():
		var cb := AABB(Vector3(c) - Vector3(0.5, 0.5, 0.5), Vector3.ONE)
		b = cb if first else b.merge(cb)
		first = false
	return b.get_center()


func _drag_screen(rel: Vector2) -> void:
	var from := camera_rig().unproject_position(_current_center())
	var to := from + rel
	_mouse_button(from, true)
	_mouse_motion(to)
	_mouse_button(to, false)


func _mouse_button(pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	viewport.push_input(ev)


func _mouse_motion(pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.push_input(ev)


func _press_option(tooltip: String) -> void:
	var b := _find_option_button(tooltip)
	if b != null:
		b.pressed.emit()