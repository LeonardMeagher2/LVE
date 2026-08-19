class_name MoveTool
extends VoxelTool

var _grabbed := false
var _grab_target := State.NONE
var _cells: Array[Vector3i] = []


func handle_input(event: InputEvent, pos: Vector2) -> bool:
	var r := _ray(pos)
	var origin: Vector3 = r[0]
	var dir: Vector3 = r[1]
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return false
		if mb.pressed:
			begin_stroke()
			var pick := _pick_start(origin, dir)
			_plane = pick.plane
			_last_target = pick.target
			_stroke_active = true
			if pick.hit != State.NONE and State.selection.contains(pick.hit):
				_grabbed = true
				_cells = State.selection.to_array()
				_grab_target = pick.target
			elif not State.selection.is_empty():
				State.selection.clear()
				State.selection_changed.emit()
			update_visual(pick)
			return true
		else:
			if _stroke_active:
				_stroke_active = false
				_grabbed = false
				_cells = []
				_end()
			return true
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _stroke_active and _plane != null and mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			var pick := _pick_drag(origin, dir)
			if _grabbed and pick.target != _last_target:
				_last_target = pick.target
				if pick.target != State.NONE:
					_move(pick.target)
			update_visual(pick)
			return true
		if mm.button_mask == 0:
			update_visual(_pick_start(origin, dir))
			return true
		return false
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.keycode == KEY_DELETE:
			if _stroke_active:
				return true
			begin_stroke()
			var erased := false
			for c in State.selection.cells:
				if State.document.has_cell(State.current_frame, c):
					State.document.erase(State.current_frame, c)
					erased = true
			if erased:
				State.cells_changed.emit()
			_end()
			return true
		if k.keycode == KEY_ESCAPE:
			if _stroke_active:
				return true
			if not State.selection.is_empty():
				begin_stroke()
				State.selection.clear()
				State.selection_changed.emit()
				_end()
			return true
		if k.keycode == KEY_LEFT or k.keycode == KEY_RIGHT \
			or k.keycode == KEY_UP or k.keycode == KEY_DOWN:
			if _stroke_active or State.selection.is_empty():
				return true
			var nudge := Vector3i.ZERO
			match k.keycode:
				KEY_LEFT:
					nudge = Vector3i(-1, 0, 0)
				KEY_RIGHT:
					nudge = Vector3i(1, 0, 0)
				KEY_UP:
					nudge = Vector3i(0, 1, 0)
				KEY_DOWN:
					nudge = Vector3i(0, -1, 0)
			begin_stroke()
			var moved: Dictionary = {}
			for c in State.selection.cells:
				if State.document.has_cell(State.current_frame, c):
					moved[c] = State.document.frames[State.current_frame].cells[c]
					State.document.erase(State.current_frame, c)
			for c in moved:
				var n: Vector3i = c + nudge
				State.document.set_cell(State.current_frame, n, moved[c])
			if not moved.is_empty():
				State.cells_changed.emit()
			_end()
			return true
		return false
	return false


func _move(target: Vector3i) -> void:
	var offset: Vector3i = target - _grab_target
	var moved := false
	for c in _cells:
		if not State.document.has_cell(State.current_frame, c):
			continue
		var n: Vector3i = c + offset
		if n == c:
			continue
		var color_index: int = State.document.frames[State.current_frame].cells[c]
		State.document.erase(State.current_frame, c)
		State.document.set_cell(State.current_frame, n, color_index)
		moved = true
	if moved:
		State.cells_changed.emit()
