extends VoxelTool


const HANDLE_SIZE_PX := 24.0
const HANDLE_HOVER_SCALE := 1.25
const HANDLE_DRAG_SCALE := 1.15
const HANDLE_GHOST_SCALE := 0.8
const HANDLE_HOVER_RADIUS_PX := 17.0
const HANDLE_HALF := 0.5
const HANDLE_CROSS_ARM := 0.22
const VoxelLineMesh := preload("res://Globals/Rendering/VoxelLineMesh.gd")

var active := false:
	set(value):
		if value == active:
			return
		active = value
		if not active:
			_dragging = false
			_hovered = false
			_pointer_pos = Vector2.INF
			_hide_drag_visuals()
			_sync_cursor()
		if is_inside_tree():
			_rebuild()
			_sync_cursor()

var _dragging := false
var _hovered := false
var _pointer_pos := Vector2.INF
var _start_origin := Vector3.ZERO
var _grab_point := Vector3.ZERO
var _drag_normal := Vector3.FORWARD
var _origin_mesh: ArrayMesh
var _cursor_shape := Input.CURSOR_ARROW


func _enter_tree() -> void:
	State.symmetry_changed.connect(_rebuild)
	State.document_changed.connect(_rebuild)
	State.cells_changed.connect(_on_cells_changed)
	State.chunks_changed.connect(_on_cells_changed)


func _ready() -> void:
	_setup_handle()
	_setup_plane_borders()
	_rebuild()


func _exit_tree() -> void:
	_dragging = false
	_set_cursor(Input.CURSOR_ARROW)
	_push_far_bounds(AABB())
	State.symmetry_changed.disconnect(_rebuild)
	State.document_changed.disconnect(_rebuild)
	State.cells_changed.disconnect(_on_cells_changed)
	State.chunks_changed.disconnect(_on_cells_changed)


func _on_cells_changed(_layer: int, _frame: int, _cells: Array[Vector3i]) -> void:
	_rebuild()


func _setup_handle() -> void:
	_origin_mesh = VoxelLineMesh.build(_origin_outline())
	$Origin.mesh = _origin_mesh
	$Origin.material_override = _line_material(1.0)
	$OriginGhost.mesh = _origin_mesh
	$OriginGhost.material_override = _line_material(0.45)
	$DragLine.material_override = _line_material(0.65)
	_hide_drag_visuals()
	_sync_cursor()


func _setup_plane_borders() -> void:
	for axis in 3:
		var plane: MeshInstance3D = get_node(["XPlane", "YPlane", "ZPlane"][axis])
		var border := MeshInstance3D.new()
		border.name = "Border"
		border.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		var color: Color = plane.material_override.albedo_color
		color.a = 1.0
		material.albedo_color = color
		material.no_depth_test = true
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		material.render_priority = 2
		border.material_override = material
		plane.add_child(border)


func _rebuild() -> void:
	visible = active or State.symmetry_axes != 0
	$Origin.visible = active
	if not visible:
		_hide_drag_visuals()
		_push_far_bounds(AABB())
		return
	position = State.symmetry_origin
	if not active:
		_hide_drag_visuals()
	var bounds := State.document.bounds()
	var lo := bounds.position - Vector3.ONE if bounds.has_volume() else Vector3.ONE * -4
	var hi := bounds.end + Vector3.ONE if bounds.has_volume() else Vector3.ONE * 4
	lo = lo.min(position - Vector3.ONE * 4)
	hi = hi.max(position + Vector3.ONE * 4)
	for axis in 3:
		var plane: MeshInstance3D = get_node(["XPlane", "YPlane", "ZPlane"][axis])
		plane.visible = bool(State.symmetry_axes & (1 << axis))
		var u := (axis + 1) % 3
		var v := (axis + 2) % 3
		var vertices := PackedVector3Array()
		for corner in [Vector2.ZERO, Vector2.RIGHT, Vector2.ONE, Vector2.DOWN]:
			var vertex := Vector3.ZERO
			vertex[u] = lerpf(lo[u], hi[u], corner.x) - position[u]
			vertex[v] = lerpf(lo[v], hi[v], corner.y) - position[v]
			vertices.append(vertex)
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
		var surface := ArrayMesh.new()
		surface.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		plane.mesh = surface
		var border: MeshInstance3D = plane.get_node_or_null("Border")
		if border != null:
			var border_vertices := PackedVector3Array()
			for index in 4:
				border_vertices.append(vertices[index])
				border_vertices.append(vertices[(index + 1) % 4])
			border.mesh = VoxelLineMesh.build(border_vertices)
	_push_far_bounds(AABB(lo, hi - lo))


func _push_far_bounds(box: AABB) -> void:
	var viewport := get_viewport()
	if viewport == null:
		return
	var camera := viewport.get_camera_3d()
	if not camera is EditorCameraRig:
		return
	if box.has_surface():
		camera.set_helper_far_bounds(&"symmetry", box)
	else:
		camera.clear_helper_far_bounds(&"symmetry")


func _process(_delta: float) -> void:
	if not active:
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	if not _dragging:
		_update_hover(_pointer_pos)
	_pose_origin_handle(camera)
	_update_transient_visuals(camera)


func _accepts(event: InputEvent) -> bool:
	return active and super._accepts(event)


func handle_input(event: InputEvent, pos: Vector2) -> bool:
	if not active:
		return false
	if event.is_action_pressed("ui_cancel") and _dragging:
		_cancel_drag(true)
		_update_hover(_pointer_pos)
		return true
	if event is InputEventKey and event.pressed and not event.echo and not (event.ctrl_pressed or event.alt_pressed or event.meta_pressed):
		for axis in 3:
			if event.is_action_pressed(["axis_x", "axis_y", "axis_z"][axis]):
				State.symmetry_axes ^= 1 << axis
				return true
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed:
			var handled := _dragging
			if handled:
				_end_drag(pos)
			return handled
		_start_origin = State.symmetry_origin
		var ray := _ray(pos)
		_drag_normal = VoxelPicking.view_plane(Vector3i(_start_origin), ray[0], _forward()).normal
		_grab_point = _drag_point(pos)
		var dragging := _grab_point != Vector3.INF
		if dragging:
			_pointer_pos = pos
			_update_hover(pos)
			_dragging = true
			_sync_cursor()
			var camera := get_viewport().get_camera_3d()
			if camera != null:
				_pose_origin_handle(camera)
				_update_transient_visuals(camera)
		return dragging
	if event is InputEventMouseMotion:
		_pointer_pos = pos
		if _dragging:
			if (event.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
				_end_drag(pos)
				return false
			var hit := _drag_point(pos)
			if hit != Vector3.INF:
				State.symmetry_origin = _start_origin + hit - _grab_point
				var camera := get_viewport().get_camera_3d()
				if camera != null:
					_pose_origin_handle(camera)
					_update_transient_visuals(camera)
			return true
		_update_hover(pos)
		return false
	return false


func _handle_scale() -> float:
	if _dragging:
		return HANDLE_DRAG_SCALE
	return HANDLE_HOVER_SCALE if _hovered else 1.0


func _update_hover(pos: Vector2) -> void:
	if _dragging:
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null or pos == Vector2.INF or camera.is_position_behind(global_position):
		_set_hovered(false)
		return
	_set_hovered(camera.unproject_position(global_position).distance_to(pos) <= HANDLE_HOVER_RADIUS_PX)


func _set_hovered(value: bool) -> void:
	if value == _hovered:
		return
	_hovered = value
	_sync_cursor()


func _pose_origin_handle(camera: Camera3D) -> void:
	var behind := camera.is_position_behind(global_position)
	$Origin.visible = active and not behind
	if behind:
		return
	var pixel_size := _screen_pixel_size(camera)
	if pixel_size <= 0.0:
		return
	var scale := HANDLE_SIZE_PX * _handle_scale() / pixel_size
	var basis := camera.global_transform.basis.orthonormalized()
	$Origin.global_transform = Transform3D(basis.scaled(Vector3.ONE * scale), global_position)


func _pose_ghost(camera: Camera3D) -> void:
	var pixel_size := _screen_pixel_size(camera)
	if pixel_size <= 0.0:
		return
	var scale := HANDLE_SIZE_PX * HANDLE_GHOST_SCALE / pixel_size
	var basis := camera.global_transform.basis.orthonormalized()
	$OriginGhost.global_transform = Transform3D(basis.scaled(Vector3.ONE * scale), _start_origin)


func _update_transient_visuals(camera: Camera3D) -> void:
	var moved := _dragging and _start_origin.distance_squared_to(global_position) > 0.0
	$OriginGhost.visible = moved
	$DragLine.visible = moved
	if not moved:
		return
	_pose_ghost(camera)
	$DragLine.mesh = VoxelLineMesh.build(PackedVector3Array([to_local(_start_origin), Vector3.ZERO]))


func _hide_drag_visuals() -> void:
	$OriginGhost.visible = false
	$DragLine.visible = false


func _end_drag(pos: Vector2) -> void:
	_dragging = false
	_hide_drag_visuals()
	_pointer_pos = pos
	_update_hover(pos)
	_sync_cursor()


func _cancel_drag(restore: bool) -> void:
	if not _dragging:
		return
	_dragging = false
	if restore:
		State.symmetry_origin = _start_origin
	_hide_drag_visuals()
	_sync_cursor()


func _origin_outline() -> PackedVector3Array:
	var vertices := PackedVector3Array()
	var corners := [
		Vector3(-HANDLE_HALF, -HANDLE_HALF, 0.0),
		Vector3(HANDLE_HALF, -HANDLE_HALF, 0.0),
		Vector3(HANDLE_HALF, HANDLE_HALF, 0.0),
		Vector3(-HANDLE_HALF, HANDLE_HALF, 0.0),
	]
	for index in 4:
		vertices.append(corners[index])
		vertices.append(corners[(index + 1) % 4])
	vertices.append(Vector3(-HANDLE_CROSS_ARM, 0.0, 0.0))
	vertices.append(Vector3(HANDLE_CROSS_ARM, 0.0, 0.0))
	vertices.append(Vector3(0.0, -HANDLE_CROSS_ARM, 0.0))
	vertices.append(Vector3(0.0, HANDLE_CROSS_ARM, 0.0))
	return vertices


func _line_material(alpha: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 1.0, 1.0, alpha)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if alpha < 1.0 else BaseMaterial3D.TRANSPARENCY_DISABLED
	material.no_depth_test = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	material.render_priority = 2
	return material


func _screen_pixel_size(camera: Camera3D) -> float:
	var screen := camera.unproject_position(global_position)
	var right := camera.unproject_position(global_position + camera.global_transform.basis.x)
	return screen.distance_to(right)


func _sync_cursor() -> void:
	_set_cursor(Input.CURSOR_DRAG if _dragging else (Input.CURSOR_MOVE if _hovered else Input.CURSOR_ARROW))


func _set_cursor(shape: int) -> void:
	if shape == _cursor_shape:
		return
	_cursor_shape = shape
	Input.set_default_cursor_shape(shape)


func _drag_point(pos: Vector2) -> Vector3:
	var ray := _ray(pos)
	var origin: Vector3 = ray[0]
	var direction: Vector3 = ray[1]
	var denominator := direction.dot(_drag_normal)
	if absf(denominator) < 1e-8:
		return Vector3.INF
	var distance := (_start_origin.dot(_drag_normal) - origin.dot(_drag_normal)) / denominator
	return origin + direction * distance if distance > 0.0 else Vector3.INF
