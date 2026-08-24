class_name VoxelTool
extends Node3D

var info: ToolInfo

var visual: Node3D = null
var _hover_mat: StandardMaterial3D
var _outline_mat: StandardMaterial3D

var _plane: StrokePlane = null
var _last_target := State.NONE
var _stroke_active := false
var _stroke_before: Dictionary = {}
var _pixel_stroke := PixelPerfectStroke.new()


func _ready() -> void:
	visual = _build_visual()
	add_child(visual)
	visual.visible = false
	State.color_changed.connect(_on_color_changed)
	_on_color_changed(State.current_color)


func _unhandled_input(event: InputEvent) -> void:
	if State.tool != info:
		return
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


func on_activated() -> void:
	visual.visible = false


func on_deactivated() -> void:
	visual.visible = false


func hide_visual() -> void:
	if visual:
		visual.visible = false


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
			if pick.target != State.NONE:
				_apply_pick(pick.target, pick.hit)
				if _use_pixel_perfect():
					_pixel_stroke.reset()
					_pixel_stroke.feed(pick.target)
			update_visual(pick)
		else:
			if _stroke_active:
				_stroke_active = false
				_end()
		return true
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _stroke_active and _plane != null and mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			var pick := _pick_drag(origin, dir)
			if pick.target != _last_target and pick.target != State.NONE:
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
	if apply(target, hit):
		State.cells_changed.emit()


func _apply_stroke_to(to: Vector3i) -> void:
	if _use_pixel_perfect():
		for c in _pixel_stroke.feed(to):
			_apply_pick(c, _hit_at(c))
	else:
		for c in StrokeLine.cells(_last_target, to):
			if c == _last_target:
				continue
			_apply_pick(c, _hit_at(c))


func _hit_at(c: Vector3i) -> Vector3i:
	if State.document.frames[State.current_frame].cells.has(c):
		return c
	return State.NONE


func _use_pixel_perfect() -> bool:
	return State.get_tool_option(info, "pixel_perfect") == true


func apply(_target: Vector3i, _hit: Vector3i) -> bool:
	return false


func _end() -> void:
	if _use_pixel_perfect():
		for c in _pixel_stroke.flush():
			_apply_pick(c, _hit_at(c))
	end_stroke()
	_plane = null
	_last_target = State.NONE
	_stroke_active = false


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
		"palette": State.document.palette.duplicate(),
		"selection": State.selection.cells.duplicate(true),
	}


func _stroke_differs(before: Dictionary, after: Dictionary) -> bool:
	return _dicts_equal(before["cells"], after["cells"]) == false \
		or before["palette"] != after["palette"] \
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
	State.document.frames[i].cells = (s["cells"] as Dictionary).duplicate(true)
	State.document.palette = (s["palette"] as PackedColorArray).duplicate()
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


func _on_color_changed(c: Color) -> void:
	if _hover_mat:
		_hover_mat.albedo_color = Color(c, 0.4)
	if _outline_mat:
		_outline_mat.albedo_color = c


func update_visual(pick: PickResult) -> void:
	if visual == null:
		return
	if pick.target == State.NONE:
		visual.visible = false
		return
	visual.position = Vector3(pick.target)
	visual.visible = true


func _build_visual() -> Node3D:
	_hover_mat = load("res://viewport/hover_fill.tres") as StandardMaterial3D
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * 1.04
	mesh.material = _hover_mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_outline_mat = load("res://viewport/hover_line.tres") as StandardMaterial3D
	var out := MeshInstance3D.new()
	out.mesh = _outline_mesh()
	out.material_override = _outline_mat
	out.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var root := Node3D.new()
	root.add_child(mi)
	root.add_child(out)
	return root


func _outline_mesh() -> ArrayMesh:
	var s := 0.54
	var corners := PackedVector3Array([
		Vector3(-s, -s, -s), Vector3(s, -s, -s), Vector3(s, s, -s), Vector3(-s, s, -s),
		Vector3(-s, -s, s), Vector3(s, -s, s), Vector3(s, s, s), Vector3(-s, s, s),
	])
	var lines := PackedVector3Array()
	for i in 4:
		lines.append(corners[i])
		lines.append(corners[(i + 1) % 4])
		lines.append(corners[i + 4])
		lines.append(corners[4 + (i + 1) % 4])
		lines.append(corners[i])
		lines.append(corners[i + 4])
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, MeshUtil.vertex_arrays(lines))
	return m
