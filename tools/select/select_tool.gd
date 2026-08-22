class_name SelectTool
extends VoxelTool

var _corner := State.NONE
var _box_end := State.NONE
var _shift := false
var _rubber_mat: StandardMaterial3D


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
				if _box_end == _corner:
					if not State.selection.is_empty():
						State.selection.clear()
						State.selection_changed.emit()
					else:
						_commit_box()
				else:
					_commit_box()
				hide_visual()
				_end()
			return true
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _stroke_active and _plane != null and mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			var pick := _pick_drag(origin, dir)
			if pick.target != State.NONE:
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
				hide_visual()
				_end()
			else:
				begin_stroke()
				State.selection.clear()
				State.selection_changed.emit()
				_end()
			return true
		return false
	return false


func update_visual(pick: PickResult) -> void:
	if visual == null:
		return
	if pick.target == State.NONE:
		visual.visible = false
		return
	(visual as MeshInstance3D).mesh.size = Vector3.ONE * 1.04
	visual.position = Vector3(pick.target)
	visual.visible = true


func _commit_box() -> void:
	if _corner == State.NONE or _box_end == State.NONE:
		return
	if _shift:
		var box := VoxelSelection.new()
		box.from_box(_corner, _box_end)
		State.selection.union(box)
	else:
		State.selection.from_box(_corner, _box_end)
	State.selection_changed.emit()


func _update_rubber() -> void:
	if visual == null:
		return
	if _corner == State.NONE or _box_end == State.NONE:
		visual.visible = false
		return
	var lo := Vector3i(mini(_corner.x, _box_end.x), mini(_corner.y, _box_end.y), mini(_corner.z, _box_end.z))
	var hi := Vector3i(maxi(_corner.x, _box_end.x), maxi(_corner.y, _box_end.y), maxi(_corner.z, _box_end.z))
	var size := Vector3(hi.x - lo.x + 1, hi.y - lo.y + 1, hi.z - lo.z + 1)
	var center := Vector3(lo) + Vector3(hi - lo) * 0.5
	(visual as MeshInstance3D).mesh.size = size + Vector3(0.04, 0.04, 0.04)
	visual.position = center
	visual.visible = true


func _build_visual() -> Node3D:
	_rubber_mat = StandardMaterial3D.new()
	_rubber_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_rubber_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_rubber_mat.albedo_color = Color(0.4, 0.7, 1.0, 0.25)
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * 1.04
	mesh.material = _rubber_mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi
