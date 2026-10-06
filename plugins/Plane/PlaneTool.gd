extends VoxelTool

var _dragging := false
var _grab_point := Vector3.ZERO
var _drag_normal := Vector3.BACK


func _enter_tree() -> void:
	State.floor_plane_changed.connect(_sync_cursor_rotation)
	_sync_cursor_rotation()


func _exit_tree() -> void:
	_dragging = false
	if State.floor_plane_changed.is_connected(_sync_cursor_rotation):
		State.floor_plane_changed.disconnect(_sync_cursor_rotation)


func _sync_cursor_rotation() -> void:
	match State.floor_axis:
		Vector3.Axis.AXIS_X:
			$Cursor.basis = Basis(Vector3.FORWARD, -PI / 2)
		Vector3.Axis.AXIS_Z:
			$Cursor.basis = Basis(Vector3.RIGHT, PI / 2)
		_:
			$Cursor.basis = Basis.IDENTITY


func handle_input(event: InputEvent, pos: Vector2) -> bool:
	var r := _ray(pos)
	var origin: Vector3 = r[0]
	var dir: Vector3 = r[1]
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return false
		if mb.pressed:
			var hit := _hit_plane(origin, dir, _axis_normal(), _plane_level())
			if hit == Vector3.INF:
				return false
			_dragging = true
			_drag_normal = _forward()
			_grab_point = hit
			return true
		if _dragging:
			_dragging = false
			return true
		return false
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _dragging and mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			var d := _grab_point.dot(_drag_normal)
			var hit := _hit_plane(origin, dir, _drag_normal, d)
			if hit != Vector3.INF:
				State.floor_index = roundi(hit[State.floor_axis] + 0.5)
			return true
		if mm.button_mask == 0:
			update_visual(_pick_start(origin, dir))
			return true
		return false
	if event is InputEventKey:
		var k := event as InputEventKey
		if not k.pressed or k.echo:
			return false
		if k.ctrl_pressed or k.alt_pressed or k.meta_pressed or k.shift_pressed:
			return false
		match k.keycode:
			KEY_X:
				State.floor_axis = Vector3.Axis.AXIS_X
				return true
			KEY_Y:
				State.floor_axis = Vector3.Axis.AXIS_Y
				return true
			KEY_Z:
				State.floor_axis = Vector3.Axis.AXIS_Z
				return true
		return false
	return false


func _axis_normal() -> Vector3:
	var n := Vector3.ZERO
	n[State.floor_axis] = 1.0
	return n


func _plane_level() -> float:
	return float(State.floor_index) - 0.5


func _hit_plane(origin: Vector3, dir: Vector3, normal: Vector3, d: float) -> Vector3:
	var denom := dir.dot(normal)
	if absf(denom) < 1e-8:
		return Vector3.INF
	var t := (d - origin.dot(normal)) / denom
	if t <= 0.0:
		return Vector3.INF
	return origin + dir * t
