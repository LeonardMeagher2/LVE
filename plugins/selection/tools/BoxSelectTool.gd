extends "./SelectTool.gd"

var _corner := VoxelPicking.NONE
var _box_end := VoxelPicking.NONE
var _shift: bool = false


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
			_shift = event.shift_pressed
			var pick := _pick_start(origin, dir)
			_plane = pick.plane
			_corner = pick.target
			_box_end = pick.target
			_last_target = pick.target
			_stroke_active = true
			_update_rubber()
			return true
		else:
			if _stroke_active:
				_stroke_active = false
				if _box_end == _corner and _corner == VoxelPicking.NONE:
					if _settings.mode == _settings.SelectMode.REPLACE:
						State.selection.clear()
						State.selection_changed.emit()
				else:
					_commit_box()
				visible = false
				_end()
			return true
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _stroke_active and _plane != null and mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			var pick := _pick_drag(origin, dir)
			if pick.target != VoxelPicking.NONE:
				_box_end = pick.target
				_update_rubber()
			return true
		if mm.button_mask == 0:
			update_visual(_pick_start(origin, dir))
			return true
		return false
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.is_action_pressed("ui_cancel"):
			if _stroke_active:
				_stroke_active = false
				visible = false
				_end()
			else:
				begin_stroke()
				State.selection.clear()
				State.selection_changed.emit()
				_end()
			return true
		return false
	return false


func _commit_box() -> void:
	if _corner == VoxelPicking.NONE or _box_end == VoxelPicking.NONE:
		return
	var box := VoxelSelection.new()
	box.from_box(_corner, _box_end)
	State.selection.restore(_apply_mode(box).capture())
	State.selection_changed.emit()


func _update_rubber() -> void:
	if _corner == VoxelPicking.NONE or _box_end == VoxelPicking.NONE:
		visible = false
		return
	var drag := VoxelSelection.new()
	drag.from_box(_corner, _box_end)
	$SelectionPreview.show_selection(drag)
