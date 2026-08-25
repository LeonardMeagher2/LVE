class_name PlaneTool
extends VoxelTool

var _dragging := false
var _grab_point := Vector3.ZERO
var _drag_normal := Vector3.BACK
var _fill: MeshInstance3D
var _border: MeshInstance3D


func _ready() -> void:
	super._ready()
	State.floor_plane_changed.connect(_sync_visual)
	State.document_changed.connect(_sync_visual)


func on_activated() -> void:
	super.on_activated()
	_sync_visual()


func on_deactivated() -> void:
	super.on_deactivated()
	_dragging = false


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


func _sync_visual() -> void:
	if visual == null or _fill == null:
		return
	var a := State.floor_axis
	var u := (a + 1) % 3
	var v := (a + 2) % 3
	var bounds := State.document.bounds()
	var lo := GridRenderer.span_lo(bounds)
	var hi := GridRenderer.span_hi(bounds)
	var nu := hi[u] - lo[u]
	var nv := hi[v] - lo[v]

	var quad := PackedVector3Array([
		GridRenderer._vec(u, v, 0.0, 0.0),
		GridRenderer._vec(u, v, nu, 0.0),
		GridRenderer._vec(u, v, nu, nv),
		GridRenderer._vec(u, v, 0.0, nv),
	])
	var fill_mesh := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.add_triangle_fan(quad)
	st.commit(fill_mesh)
	_fill.mesh = fill_mesh

	var lines := PackedVector3Array()
	for i in 4:
		lines.append(quad[i])
		lines.append(quad[(i + 1) % 4])
	var line_mesh := ArrayMesh.new()
	line_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, MeshUtil.vertex_arrays(lines))
	_border.mesh = line_mesh

	var p := Vector3.ZERO
	p[a] = float(State.floor_index) - 0.5
	p[u] = lo[u]
	p[v] = lo[v]
	position = p


func _on_color_changed(c: Color) -> void:
	super._on_color_changed(c)
	if _hover_mat:
		_hover_mat.albedo_color = Color(c, 0.10)


func _build_visual() -> Node3D:
	_hover_mat = StandardMaterial3D.new()
	_hover_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hover_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hover_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_hover_mat.albedo_color = Color(State.current_color, 0.10)
	_fill = MeshInstance3D.new()
	_fill.mesh = ArrayMesh.new()
	_fill.material_override = _hover_mat
	_fill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_outline_mat = load("res://viewport/hover_line.tres") as StandardMaterial3D
	_border = MeshInstance3D.new()
	_border.mesh = ArrayMesh.new()
	_border.material_override = _outline_mat
	_border.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var root := Node3D.new()
	root.add_child(_fill)
	root.add_child(_border)
	return root


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
