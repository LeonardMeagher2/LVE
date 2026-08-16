class_name EditorViewport
extends Node3D

const NONE := Vector3i(-1000000, -1000000, -1000000)
const BG_COLOR := Color(0.13, 0.14, 0.16)
const GRID_COLOR := Color(0.32, 0.35, 0.42, 0.9)
const BASE_COLOR := Color(0.17, 0.185, 0.21)

signal tool_pressed(target: Vector3i, hit: Vector3i, is_drag: bool)
signal tool_released
signal zoom_changed(percent: float)

var doc: VoxelAnimation
var displayed_frame: VoxelFrame

var world_origin := Vector3.ZERO

var _camera: Camera3D
var _multi: MultiMesh
var _grid_root := Node3D.new()
var _ghost: MeshInstance3D
var _ghost_mat: StandardMaterial3D
var _ghost_valid := false

var _yaw := deg_to_rad(-45.0)
var _pitch := deg_to_rad(28.0)
var _dist := 24.0
var _target := Vector3.ZERO
var _init_dist := 24.0
var _orbiting := false
var _panning := false
var _painting := false
var _last_target := NONE


func _ready() -> void:
	var env_world := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.57, 0.62)
	env.ambient_light_energy = 1.2
	env_world.environment = env
	add_child(env_world)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50.0, -35.0, 0.0)
	light.shadow_enabled = true
	add_child(light)

	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_camera.fov = 45.0
	add_child(_camera)

	add_child(_grid_root)

	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	box.material = mat
	_multi = MultiMesh.new()
	_multi.transform_format = MultiMesh.TRANSFORM_3D
	_multi.use_colors = true
	_multi.mesh = box
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _multi
	add_child(mmi)

	var gbox := BoxMesh.new()
	gbox.size = Vector3(1.04, 1.04, 1.04)
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.albedo_color = Color(0.7, 0.7, 0.7, 0.4)
	gbox.material = _ghost_mat
	_ghost = MeshInstance3D.new()
	_ghost.mesh = gbox
	_ghost.visible = false
	_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ghost)


func configure(d: VoxelAnimation) -> void:
	doc = d
	world_origin = Vector3(-d.grid_size.x * 0.5, 0.0, -d.grid_size.z * 0.5)
	_init_dist = maxf(d.grid_size.x, d.grid_size.z) * 1.5
	_dist = _init_dist
	_target = Vector3(0.0, d.grid_size.y * 0.25, 0.0)
	_rebuild_grid()
	_update_camera()


func reset_view() -> void:
	_yaw = deg_to_rad(-45.0)
	_pitch = deg_to_rad(28.0)
	_dist = _init_dist
	if doc:
		_target = Vector3(0.0, doc.grid_size.y * 0.25, 0.0)
	_update_camera()


func set_grid_visible(v: bool) -> void:
	_grid_root.visible = v


func toggle_grid() -> void:
	set_grid_visible(not _grid_root.visible)


func set_ghost_color(c: Color) -> void:
	if _ghost_mat:
		_ghost_mat.albedo_color = c


func sync_to(d: VoxelAnimation, frame_index: int) -> void:
	doc = d
	displayed_frame = d.frames[frame_index]
	var keys: Array = displayed_frame.cells.keys()
	_multi.instance_count = keys.size()
	for i in keys.size():
		var c: Vector3i = keys[i]
		_multi.set_instance_transform(i, Transform3D(Basis.IDENTITY, world_origin + Vector3(c)))
		_multi.set_instance_color(i, d.color_of(int(displayed_frame.cells[c])))


func handle_input(event: InputEvent, pos: Vector2) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					var pick := _pick(pos)
					_painting = true
					_last_target = pick.target
					tool_pressed.emit(pick.target, pick.hit, false)
				elif _painting:
					_painting = false
					tool_released.emit()
			MOUSE_BUTTON_RIGHT:
				_orbiting = mb.pressed
			MOUSE_BUTTON_MIDDLE:
				_panning = mb.pressed
			MOUSE_BUTTON_WHEEL_UP:
				_zoom(0.85)
			MOUSE_BUTTON_WHEEL_DOWN:
				_zoom(1.0 / 0.85)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var mask := mm.button_mask
		if mask & MOUSE_BUTTON_MASK_MIDDLE or (mask & MOUSE_BUTTON_MASK_RIGHT and mm.shift_pressed):
			_pan(mm.relative)
		elif mask & MOUSE_BUTTON_MASK_RIGHT:
			_orbit(mm.relative)
		if mask & MOUSE_BUTTON_MASK_LEFT and _painting:
			var pick := _pick(pos)
			if pick.target != _last_target:
				_last_target = pick.target
				tool_pressed.emit(pick.target, pick.hit, true)
		elif mask == 0:
			_update_ghost(_pick(pos))


func _update_ghost(pick: Dictionary) -> void:
	if pick.target == NONE:
		_ghost_valid = false
		_ghost.visible = false
		return
	_ghost.position = world_origin + Vector3(pick.target)
	_ghost_valid = true
	_ghost.visible = true


func _orbit(rel: Vector2) -> void:
	_yaw += rel.x * 0.01
	_pitch = clampf(_pitch + rel.y * 0.01, deg_to_rad(-89.0), deg_to_rad(89.0))
	_update_camera()


func _pan(rel: Vector2) -> void:
	var s := _dist * 0.0016
	_target -= _camera.right * rel.x * s
	_target += _camera.up * rel.y * s
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


func _pick(pos: Vector2) -> Dictionary:
	if not _camera or displayed_frame == null:
		return {"target": NONE, "hit": NONE}
	var origin := _camera.project_ray_origin(pos)
	var dir := _camera.project_ray_normal(pos)
	return _ddq(origin, dir)


func _ddq(o: Vector3, d: Vector3) -> Dictionary:
	var gs := doc.grid_size
	var g := o - world_origin
	var no_hit := {"target": NONE, "hit": NONE}

	var t_ground := INF
	if d.y < -1e-8:
		t_ground = (-0.5 - g.y) / d.y
		if t_ground <= 0.0:
			t_ground = INF

	var cell := Vector3i(floori(g.x), floori(g.y), floori(g.z))
	var step := Vector3i(
		1 if d.x > 0 else -1, 1 if d.y > 0 else -1, 1 if d.z > 0 else -1
	)
	var t_max := Vector3(INF, INF, INF)
	var t_delta := Vector3(INF, INF, INF)
	if d.x != 0.0:
		t_delta.x = absf(1.0 / d.x)
		t_max.x = ((float(cell.x) + (1.0 if step.x > 0 else 0.0)) - g.x) / d.x
	if d.y != 0.0:
		t_delta.y = absf(1.0 / d.y)
		t_max.y = ((float(cell.y) + (1.0 if step.y > 0 else 0.0)) - g.y) / d.y
	if d.z != 0.0:
		t_delta.z = absf(1.0 / d.z)
		t_max.z = ((float(cell.z) + (1.0 if step.z > 0 else 0.0)) - g.z) / d.z

	var t := 0.0
	var entry := Vector3i.ZERO
	for i in 512:
		if _in_bounds(cell) and displayed_frame.cells.has(cell):
			if t_ground < t:
				return _ground_hit(g, d, t_ground)
			var target := cell + entry
			if _in_bounds(target):
				return {"target": target, "hit": cell}
			return no_hit
		if t_max.x < t_max.y and t_max.x < t_max.z:
			cell.x += step.x
			entry = Vector3i(-step.x, 0, 0)
			t = t_max.x
			t_max.x += t_delta.x
		elif t_max.y < t_max.z:
			cell.y += step.y
			entry = Vector3i(0, -step.y, 0)
			t = t_max.y
			t_max.y += t_delta.y
		else:
			cell.z += step.z
			entry = Vector3i(0, 0, -step.z)
			t = t_max.z
			t_max.z += t_delta.z
		if t > t_ground:
			return _ground_hit(g, d, t_ground)
		if cell.x < -2 or cell.y < -2 or cell.z < -2 \
				or cell.x > gs.x + 1 or cell.y > gs.y + 1 or cell.z > gs.z + 1:
			break
	return no_hit


func _ground_hit(g: Vector3, d: Vector3, t: float) -> Dictionary:
	var p := g + d * t
	var cx := int(floori(p.x))
	var cz := int(floori(p.z))
	if cx < 0 or cz < 0 or cx >= doc.grid_size.x or cz >= doc.grid_size.z:
		return {"target": NONE, "hit": NONE}
	return {"target": Vector3i(cx, 0, cz), "hit": NONE}


func _in_bounds(c: Vector3i) -> bool:
	if doc == null:
		return false
	return c.x >= 0 and c.y >= 0 and c.z >= 0 \
		and c.x < doc.grid_size.x and c.y < doc.grid_size.y and c.z < doc.grid_size.z


func _rebuild_grid() -> void:
	for child in _grid_root.get_children():
		_grid_root.remove_child(child)
		child.queue_free()
	var gx := doc.grid_size.x
	var gz := doc.grid_size.z
	var ox := world_origin.x
	var oz := world_origin.z

	var lines := PackedVector3Array()
	for i in gx + 1:
		var x := ox - 0.5 + i
		lines.append(Vector3(x, -0.5, oz - 0.5))
		lines.append(Vector3(x, -0.5, oz - 0.5 + gz))
	for i in gz + 1:
		var z := oz - 0.5 + i
		lines.append(Vector3(ox - 0.5, -0.5, z))
		lines.append(Vector3(ox - 0.5 + gx, -0.5, z))
	var line_mesh := ArrayMesh.new()
	line_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, _vertex_arrays(lines))
	var li := MeshInstance3D.new()
	li.mesh = line_mesh
	li.material_override = _flat_material(GRID_COLOR)
	_grid_root.add_child(li)

	var quad := PackedVector3Array([
		Vector3(ox - 0.5, -0.502, oz - 0.5),
		Vector3(ox - 0.5 + gx, -0.502, oz - 0.5),
		Vector3(ox - 0.5 + gx, -0.502, oz - 0.5 + gz),
		Vector3(ox - 0.5, -0.502, oz - 0.5 + gz),
	])
	var quad_mesh := ArrayMesh.new()
	quad_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLE_STRIP, _vertex_arrays(quad))
	var qi := MeshInstance3D.new()
	qi.mesh = quad_mesh
	qi.material_override = _flat_material(BASE_COLOR)
	_grid_root.add_child(qi)


func _vertex_arrays(points: PackedVector3Array) -> Array:
	var a := Array()
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = points
	return a


func _flat_material(c: Color) -> Material:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	return m
