class_name VoxelTool
extends Node3D

## Base class for an interactive voxel tool.
##
## A tool handles pointer input in the 3D viewport and writes to the current
## frame. It owns one edit at a time through [VoxelEditTransaction]. A subclass
## overrides [method apply] to change cells. It can override [method pick_start],
## [method pick_drag], and [method update_visual] to change the pick and cursor.
##
## The base class opens an edit on a left press and closes it on release. It
## refuses input while another edit is active.

var _plane: StrokePlane = null
var _last_target := VoxelPicking.NONE
var _stroke_active := false
var _cells_dirty := false
var _affected: Array[Vector3i] = []
# The tool's owned edit handle, or null. The handle stays with the tool for the
# whole edit, so a cancel can only roll back this tool's own edit.
var _edit: VoxelEditTransaction


func _unhandled_input(event: InputEvent) -> void:
	if not _accepts(event):
		return
	var input_viewport := get_viewport()
	if input_viewport == null:
		return
	if State.edit_busy(self):
		input_viewport.set_input_as_handled()
		return
	var pos := Vector2.ZERO
	if event is InputEventMouse:
		pos = (event as InputEventMouse).position
	if handle_input(event, pos):
		input_viewport.set_input_as_handled()


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


## Handles one input event for this tool. Returns [code]true[/code] when the
## tool consumes the event.
func handle_input(event: InputEvent, pos: Vector2) -> bool:
	var r := _ray(pos)
	var origin: Vector3 = r[0]
	var dir: Vector3 = r[1]
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return false
		if mb.pressed:
			if _stroke_active:
				return true
			if open_stroke() == null:
				return false
			var pick := _pick_start(origin, dir)
			if pick == null:
				abort_stroke()
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
	if State.document.has_cell(State.current_frame, c):
		return c
	return VoxelPicking.NONE


## Returns [code]true[/code] when the two colors match. An epsilon above zero
## allows that much difference on each channel.
func colors_equal(a: Color, b: Color, epsilon:float = 0.0) -> bool:
	if epsilon <= 0.0:
		return a == b
	return (
		absf(a.r - b.r) <= epsilon and absf(a.g - b.g) <= epsilon and
		absf(a.b - b.b) <= epsilon and absf(a.a - b.a) <= epsilon
	)

## Applies the tool to one cell. Returns [code]true[/code] when the tool
## changed the model. The base version does nothing.
func apply(_target: Vector3i, _hit: Vector3i) -> bool:
	return false


## Returns the cells that [method apply] can change for this pick. The base
## version returns the target cell and the hit cell.
func applied_cells(target: Vector3i, hit: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	if target != VoxelPicking.NONE:
		out.append(target)
	if hit != VoxelPicking.NONE and hit != target:
		out.append(hit)
	return out


func _end() -> void:
	_flush_cells()
	# Clear the input state before the close signals, so a handler that opens a new
	# stroke keeps its own input state.
	_plane = null
	_last_target = VoxelPicking.NONE
	_stroke_active = false
	close_stroke()


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


# Open this tool's owned edit. Returns null when an edit is already active or the
# current frame is missing. The caller must not mutate the model or mark a stroke
# active until this returns non-null. A retained handle that a document reset
# closed is dropped, so the tool acquires a fresh edit when State allows.
## Opens this tool's owned edit. Returns null while another edit is active or
## the current frame is missing. The caller must check the result before it
## mutates the model.
func open_stroke() -> VoxelEditTransaction:
	if _edit != null and _edit.is_closed():
		_edit = null
	if _edit == null:
		_edit = State.begin_edit()
	return _edit


# Close this tool's edit and record it as one history action. The tool handle is
# cleared before the call, so a handler that opens a new stroke during the history
# signal keeps its own handle.
## Closes this tool's edit and records one history action. The default action is
## [code]Stroke[/code]. Does nothing when the tool holds no edit.
func close_stroke(action: String = "Stroke") -> void:
	var tx := _edit
	if tx == null:
		return
	_edit = null
	State.finish_edit(tx, action)


# Roll this tool's edit back. Does nothing when the tool holds no edit. The tool
# handle is cleared before the call, so a handler that opens a new stroke during
# the restore signal keeps its own handle.
## Rolls this tool's edit back. Does nothing when the tool holds no edit.
func abort_stroke() -> void:
	var tx := _edit
	if tx == null:
		return
	_edit = null
	State.cancel_edit(tx)


func _pick_start(origin: Vector3, dir: Vector3) -> PickResult:
	return pick_start(_request(origin, dir, null))


func _pick_drag(origin: Vector3, dir: Vector3) -> PickResult:
	return pick_drag(_request(origin, dir, _plane))


func _request(origin: Vector3, dir: Vector3, plane: StrokePlane) -> PickRequest:
	var req := PickRequest.new()
	req.origin = origin
	req.dir = dir
	req.frame = State.get_current_voxel_frame()
	req.plane = plane
	req.forward = _forward()
	return req


## Returns the press pick for this request. Override it to change the pick.
func pick_start(request: PickRequest) -> PickResult:
	return VoxelPicking.start_pick(request.origin, request.dir, request.frame, request.forward)


## Returns the drag pick for this request. Override it to change the pick.
func pick_drag(request: PickRequest) -> PickResult:
	return VoxelPicking.drag_pick(request.origin, request.dir, request.frame, request.plane)


## Updates the tool cursor for one pick. The base version moves the node to the
## picked cell and hides it when the pick misses.
func update_visual(pick: PickResult) -> void:
	if pick.target == VoxelPicking.NONE:
		visible = false
		return
	position = Vector3(pick.target)
	visible = true


