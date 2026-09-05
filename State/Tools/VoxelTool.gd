class_name VoxelTool
extends Node3D

var _plane: StrokePlane = null
var _last_target := VoxelPicking.NONE
var _stroke_active := false
var _stroke_before: Dictionary = {}
var _cells_dirty := false
var _affected: Array[Vector3i] = []


func _unhandled_input(event: InputEvent) -> void:
	if not _accepts(event):
		return
	var pos := Vector2.ZERO
	if event is InputEventMouse:
		pos = (event as InputEventMouse).position
	if handle_input(event, pos):
		get_viewport().set_input_as_handled()


func _ray(pos: Vector2) -> Array:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return [Vector3.ZERO, Vector3.ZERO]
	return [cam.project_ray_origin(pos), cam.project_ray_normal(pos)]


func _forward() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return Vector3.BACK
	return -cam.basis.z


func _accepts(event: InputEvent) -> bool:
	return event is InputEventMouseButton or event is InputEventMouseMotion or event is InputEventKey


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
			if not pick:
				return false
			_plane = pick.plane
			_last_target = pick.target
			_stroke_active = true
			if pick.target != VoxelPicking.NONE:
				_apply_pick(pick.target, pick.hit)
			update_visual(pick)
		else:
			if _stroke_active:
				_end()
		return true
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _stroke_active and _plane != null and mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			var pick := _pick_drag(origin, dir)
			if pick.target != _last_target and pick.target != VoxelPicking.NONE:
				_apply_stroke_to(pick.target)
				_last_target = pick.target
			update_visual(pick)
			return true
		if mm.button_mask == 0:
			update_visual(_pick_start(origin, dir))
			return true
		return false
	return false


func _apply_pick(target: Vector3i, hit: Vector3i) -> void:
	apply(target, hit)
	for c in applied_cells(target, hit):
		_affected.append(c)
	_flush_cells()


func _apply_stroke_to(to: Vector3i) -> void:
	for c in StrokeLine.cells(_last_target, to):
		if c == _last_target:
			continue
		_apply_pick(c, _hit_at(c))


func _hit_at(c: Vector3i) -> Vector3i:
	if State.document.frames[State.current_frame].cells.has(c):
		return c
	return VoxelPicking.NONE


func colors_equal(a: Color, b: Color, epsilon:float = 0.0) -> bool:
	if epsilon <= 0.0:
		return a == b
	return (
		absf(a.r - b.r) <= epsilon and absf(a.g - b.g) <= epsilon and
		absf(a.b - b.b) <= epsilon and absf(a.a - b.a) <= epsilon
	)

func apply(_target: Vector3i, _hit: Vector3i) -> bool:
	return false


func applied_cells(target: Vector3i, hit: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	if target != VoxelPicking.NONE:
		out.append(target)
	if hit != VoxelPicking.NONE and hit != target:
		out.append(hit)
	return out


func _end() -> void:
	_flush_cells()
	end_stroke()
	_plane = null
	_last_target = VoxelPicking.NONE
	_stroke_active = false


func _flush_cells() -> void:
	if _cells_dirty:
		return
	_cells_dirty = true
	call_deferred("_do_flush")


func _do_flush() -> void:
	_cells_dirty = false
	if _affected.is_empty():
		return
	State.cells_changed.emit(State.current_frame, _affected)
	_affected.clear()


func begin_stroke() -> void:
	_stroke_before = _capture()


func end_stroke() -> void:
	if not _stroke_before.is_empty():
		var after := _capture()
		if _stroke_differs(_stroke_before, after):
			State.undo_redo.create_action("Stroke")
			State.undo_redo.add_undo_method(_restore_snapshot.bind(_stroke_before))
			State.undo_redo.add_do_method(_restore_snapshot.bind(after))
			State.undo_redo.commit_action(false)
	_stroke_before = {}


func _capture() -> Dictionary:
	return {
		"frame": State.current_frame,
		"cells": State.document.frames[State.current_frame].cells.duplicate(true),
		"selection": State.selection.cells.duplicate(true),
	}


func _stroke_differs(before: Dictionary, after: Dictionary) -> bool:
	return _dicts_equal(before["cells"], after["cells"]) == false \
		or _dicts_equal(before["selection"], after["selection"]) == false


func _dicts_equal(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a:
		if not b.has(k) or a[k] != b[k]:
			return false
	return true


func _restore_snapshot(s: Dictionary) -> void:
	var i: int = s["frame"]
	if i < 0 or i >= State.document.frames.size():
		i = State.current_frame
	State.document.replace_cells(i, (s["cells"] as Dictionary).duplicate(true))
	State.selection.cells = (s["selection"] as Dictionary).duplicate(true)
	State.notify_restored()


func _pick_start(origin: Vector3, dir: Vector3) -> PickResult:
	return pick_start(_request(origin, dir, null))


func _pick_drag(origin: Vector3, dir: Vector3) -> PickResult:
	return pick_drag(_request(origin, dir, _plane))


func _request(origin: Vector3, dir: Vector3, plane: StrokePlane) -> PickRequest:
	var req := PickRequest.new()
	req.origin = origin
	req.dir = dir
	req.cells = State.document.frames[State.current_frame].cells
	req.plane = plane
	req.forward = _forward()
	return req


func pick_start(request: PickRequest) -> PickResult:
	return VoxelPicking.start_pick(request.origin, request.dir, request.cells, request.forward)


func pick_drag(request: PickRequest) -> PickResult:
	return VoxelPicking.drag_pick(request.origin, request.dir, request.cells, request.plane)


func update_visual(pick: PickResult) -> void:
	if pick.target == VoxelPicking.NONE:
		visible = false
		return
	position = Vector3(pick.target)
	visible = true


