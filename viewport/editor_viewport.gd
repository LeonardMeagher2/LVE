class_name EditorViewport
extends Node3D

signal zoom_changed(percent: float)
signal frame_displayed(index: int)

var _tool: VoxelTool
var _tools := {}
var _anim_library: AnimationLibrary

@onready var _camera: Camera3D = $Camera3D
@onready var _multi: MultiMesh = $Voxels.multimesh
@onready var _grid_root: Node3D = $GridRoot
@onready var _tool_layer: Node3D = $ToolLayer
@onready var _selection_layer: Node3D = $SelectionLayer
@onready var _selection_outline: MeshInstance3D = $SelectionLayer/SelectionOutline
@onready var _anim_player: AnimationPlayer = $AnimationPlayer

@export var grid_mat: StandardMaterial3D
@export var base_mat: StandardMaterial3D

var _yaw := deg_to_rad(-90.0)
var _pitch := deg_to_rad(45.0)
var _dist := 24.0
var _target := Vector3.ZERO
var _init_dist := 24.0
var _orbiting := false
var _panning := false

var frame_index := 0:
	set(value):
		frame_index = value
		if State.document != null and value >= 0 and value < State.document.frames.size():
			sync_to(value)
			frame_displayed.emit(value)


func _ready() -> void:
	($Light as DirectionalLight3D).rotation_degrees = Vector3(-50.0, -35.0, 0.0)
	_anim_library = AnimationLibrary.new()
	_anim_player.add_animation_library("", _anim_library)
	_rebuild_animation()
	State.cells_changed.connect(_rebuild_grid)
	State.frame_changed.connect(_rebuild_grid)


func set_tool(t: ToolInfo) -> void:
	if _tool != null:
		_tool.visible = false
		_tool.on_deactivated()
	if t == null or t.scene.is_empty():
		_tool = null
		return
	_tool = _tools.get(t.id)
	if _tool == null:
		var scene := load(t.scene)
		if scene == null:
			_tool = null
			return
		_tool = scene.instantiate()
		_tool.info = t
		_tool_layer.add_child(_tool)
		_tools[t.id] = _tool
	_tool.visible = true
	_tool.on_activated()


func configure() -> void:
	_init_dist = _frame_distance(State.document)
	_dist = _init_dist
	_target = _frame_target(State.document)
	_rebuild_grid()
	_update_camera()


func reset_view() -> void:
	_yaw = deg_to_rad(-90.0)
	_pitch = deg_to_rad(45.0)
	_init_dist = _frame_distance(State.document)
	_dist = _init_dist
	_target = _frame_target(State.document)
	_update_camera()


func _frame_distance(d: VoxiDocument) -> float:
	var b := d.bounds()
	if b.has_volume():
		return maxf(b.size.x, b.size.z) * 1.5
	return 24.0


func _frame_target(d: VoxiDocument) -> Vector3:
	var b := d.bounds()
	if b.has_volume():
		return Vector3(b.get_center().x, b.position.y + b.size.y * 0.25, b.get_center().z)
	return Vector3(8, 4, 8)


func set_grid_visible(v: bool) -> void:
	_grid_root.visible = v


func toggle_grid() -> void:
	set_grid_visible(not _grid_root.visible)


func sync_to(frame_index: int) -> void:
	var d := State.document
	var frame: VoxelFrame = d.frames[frame_index]
	var keys: Array = frame.cells.keys()
	_multi.instance_count = keys.size()
	for i in keys.size():
		var c: Vector3i = keys[i]
		_multi.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(c)))
		_multi.set_instance_color(i, d.color_of(int(frame.cells[c])))


func play_preview() -> void:
	_rebuild_animation()
	_anim_player.play("preview")
	_anim_player.seek(_frame_time(State.current_frame), true)


func stop_preview() -> void:
	if _anim_player.is_playing():
		_anim_player.stop()
	frame_index = State.current_frame


func is_playing() -> bool:
	return _anim_player.is_playing()


func _rebuild_animation() -> void:
	var d := State.document
	if d == null:
		return
	var anim := Animation.new()
	anim.loop_mode = Animation.LOOP_LINEAR
	anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(0, NodePath(".:frame_index"))
	anim.track_set_interpolation_type(0, Animation.INTERPOLATION_NEAREST)
	var t := 0.0
	for i in d.frames.size():
		anim.track_insert_key(0, t, i)
		t += float(d.frames[i].delay_ms) / 1000.0
	anim.length = t
	if _anim_library.has_animation("preview"):
		_anim_library.remove_animation("preview")
	_anim_library.add_animation("preview", anim)


func _frame_time(frame_index: int) -> float:
	var t := 0.0
	for i in frame_index:
		t += float(State.document.frames[i].delay_ms) / 1000.0
	return t


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_RIGHT:
				_orbiting = mb.pressed
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_MIDDLE:
				_panning = mb.pressed
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_UP:
				_zoom(0.85)
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_DOWN:
				_zoom(1.0 / 0.85)
				get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var mask := mm.button_mask
		if mask & MOUSE_BUTTON_MASK_MIDDLE or (mask & MOUSE_BUTTON_MASK_RIGHT and mm.shift_pressed):
			_pan(mm.relative)
			get_viewport().set_input_as_handled()
		elif mask & MOUSE_BUTTON_MASK_RIGHT:
			_orbit(mm.relative)
			get_viewport().set_input_as_handled()


func pick_request(pos: Vector2) -> PickRequest:
	var req := PickRequest.new()
	var d := State.document
	if _camera == null or d == null:
		return req
	var fi := clampi(frame_index, 0, d.frames.size() - 1)
	req.origin = _camera.project_ray_origin(pos)
	req.dir = _camera.project_ray_normal(pos)
	req.cells = d.frames[fi].cells
	return req


func sync_selection(selection: VoxelSelection) -> void:
	if selection == null or selection.is_empty():
		_selection_outline.visible = false
		return
	var lo := Vector3i(0, 0, 0)
	var hi := Vector3i(0, 0, 0)
	var first := true
	for c in selection.cells:
		if first:
			lo = c
			hi = c
			first = false
			continue
		lo.x = mini(lo.x, c.x)
		lo.y = mini(lo.y, c.y)
		lo.z = mini(lo.z, c.z)
		hi.x = maxi(hi.x, c.x)
		hi.y = maxi(hi.y, c.y)
		hi.z = maxi(hi.z, c.z)
	var a := Vector3(lo.x, lo.y, lo.z)
	var b := Vector3(hi.x + 1, hi.y + 1, hi.z + 1)
	var corners := PackedVector3Array([
		a, Vector3(b.x, a.y, a.z), Vector3(b.x, b.y, a.z), Vector3(a.x, b.y, a.z),
		Vector3(a.x, a.y, b.z), Vector3(b.x, a.y, b.z), b, Vector3(a.x, b.y, b.z),
	])
	var lines := PackedVector3Array()
	for i in 4:
		lines.append(corners[i])
		lines.append(corners[(i + 1) % 4])
		lines.append(corners[i + 4])
		lines.append(corners[4 + (i + 1) % 4])
		lines.append(corners[i])
		lines.append(corners[i + 4])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, _vertex_arrays(lines))
	_selection_outline.mesh = mesh
	_selection_outline.visible = true


func _orbit(rel: Vector2) -> void:
	_yaw -= rel.x * 0.01
	_pitch = clampf(_pitch + rel.y * 0.01, deg_to_rad(-89.0), deg_to_rad(89.0))
	_update_camera()


func _pan(rel: Vector2) -> void:
	var s := _dist * 0.0016
	_target -= _camera.basis.x * rel.x * s
	_target += _camera.basis.y * rel.y * s
	_update_camera()


func _zoom(factor: float) -> void:
	_dist = clampf(_dist * factor, 4.0, 240.0)
	_update_camera()
	zoom_changed.emit(_init_dist / _dist * 100.0)


func _update_camera() -> void:
	if not _camera:
		return
	var off := Vector3(
		sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)
	) * _dist
	_camera.position = _target + off
	_camera.look_at(_target, Vector3.UP)


func _rebuild_grid() -> void:
	for child in _grid_root.get_children():
		_grid_root.remove_child(child)
		child.queue_free()
	var d := State.document
	var lo := Vector3i.ZERO
	var hi := Vector3i(15, 0, 15)
	var b := d.bounds()
	if b.has_volume():
		lo.x = int(floori(b.position.x))
		lo.z = int(floori(b.position.z))
		hi.x = int(floori(b.end.x)) - 1
		hi.z = int(floori(b.end.z)) - 1
	var cx := hi.x - lo.x + 1
	var cz := hi.z - lo.z + 1

	var lines := PackedVector3Array()
	for i in cx + 1:
		var x := lo.x - 0.5 + i
		lines.append(Vector3(x, -0.5, lo.z - 0.5))
		lines.append(Vector3(x, -0.5, lo.z - 0.5 + cz))
	for i in cz + 1:
		var z := lo.z - 0.5 + i
		lines.append(Vector3(lo.x - 0.5, -0.5, z))
		lines.append(Vector3(lo.x - 0.5 + cx, -0.5, z))
	var line_mesh := ArrayMesh.new()
	line_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, _vertex_arrays(lines))
	var li := MeshInstance3D.new()
	li.mesh = line_mesh
	li.material_override = grid_mat
	_grid_root.add_child(li)

	var quad := PackedVector3Array([
		Vector3(lo.x - 0.5, -0.502, lo.z - 0.5),
		Vector3(lo.x - 0.5 + cx, -0.502, lo.z - 0.5),
		Vector3(lo.x - 0.5 + cx, -0.502, lo.z - 0.5 + cz),
		Vector3(lo.x - 0.5, -0.502, lo.z - 0.5 + cz),
	])
	var quad_mesh := ArrayMesh.new()
	quad_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLE_STRIP, _vertex_arrays(quad))
	var qi := MeshInstance3D.new()
	qi.mesh = quad_mesh
	qi.material_override = base_mat
	_grid_root.add_child(qi)


func _vertex_arrays(points: PackedVector3Array) -> Array:
	var a := Array()
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = points
	return a
