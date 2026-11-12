extends VoxelTool

## The symmetry tool.
##
## It shows the mirror planes and toggles them. The X, Y, and Z keys toggle one
## axis. A drag moves the symmetry origin. It changes no cells.

## Whether the tool is active. A false value stops a drag and rebuilds the
## planes.
var active := false:
	set(value):
		active = value
		if not active:
			_dragging = false
		if is_inside_tree():
			_rebuild()

var _dragging := false
var _start_origin := Vector3.ZERO
var _grab_point := Vector3.ZERO
var _drag_normal := Vector3.FORWARD


func _enter_tree() -> void:
	State.symmetry_changed.connect(_rebuild)
	State.document_changed.connect(_rebuild)
	State.cells_changed.connect(_on_cells_changed)
	State.chunks_changed.connect(_on_cells_changed)


func _ready() -> void:
	_rebuild()


func _exit_tree() -> void:
	_dragging = false
	State.symmetry_changed.disconnect(_rebuild)
	State.document_changed.disconnect(_rebuild)
	State.cells_changed.disconnect(_on_cells_changed)
	State.chunks_changed.disconnect(_on_cells_changed)


func _on_cells_changed(_frame: int, _cells: Array[Vector3i]) -> void:
	_rebuild()


func _rebuild() -> void:
	visible = active or State.symmetry_axes != 0
	# A hidden tool draws nothing, so it must not rebuild its three meshes on
	# every cell change.
	if not visible:
		return
	position = State.symmetry_origin
	$Origin.visible = active
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


func _process(_delta: float) -> void:
	if not active:
		return
	var camera := get_viewport().get_camera_3d()
	if camera:
		var pixel_size := camera.unproject_position(position + camera.global_basis.x).distance_to(camera.unproject_position(position))
		$Origin.scale = Vector3.ONE * (16.0 / maxf(pixel_size, 0.01))


func _accepts(event: InputEvent) -> bool:
	return active and super._accepts(event)


## Handles one input event. The X, Y, and Z keys toggle one mirror axis. A drag
## moves the symmetry origin.
func handle_input(event: InputEvent, pos: Vector2) -> bool:
	if not active:
		return false
	if event is InputEventKey and event.pressed and not event.echo and not (event.ctrl_pressed or event.alt_pressed or event.meta_pressed):
		var axis := [KEY_X, KEY_Y, KEY_Z].find(event.keycode)
		if axis != -1:
			State.symmetry_axes ^= 1 << axis
			return true
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed:
			var handled := _dragging
			_dragging = false
			return handled
		_start_origin = State.symmetry_origin
		var ray := _ray(pos)
		_drag_normal = VoxelPicking.view_plane(Vector3i(_start_origin), ray[0], _forward()).normal
		_grab_point = _drag_point(pos)
		_dragging = _grab_point != Vector3.INF
		return _dragging
	if event is InputEventMouseMotion and _dragging and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		var hit := _drag_point(pos)
		if hit != Vector3.INF:
			State.symmetry_origin = _start_origin + hit - _grab_point
		return true
	return false


func _drag_point(pos: Vector2) -> Vector3:
	var ray := _ray(pos)
	var origin: Vector3 = ray[0]
	var direction: Vector3 = ray[1]
	var denominator := direction.dot(_drag_normal)
	if absf(denominator) < 1e-8:
		return Vector3.INF
	var distance := (_start_origin.dot(_drag_normal) - origin.dot(_drag_normal)) / denominator
	return origin + direction * distance if distance > 0.0 else Vector3.INF
