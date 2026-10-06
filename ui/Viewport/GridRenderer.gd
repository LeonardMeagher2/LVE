extends MeshInstance3D

var _last_bounds: AABB
var _last_axis := -1
var _last_index := 0
var _built := false

func _ready() -> void:
	rebuild()
	State.cells_changed.connect(func(_frame, _affected): rebuild())
	State.chunks_changed.connect(func(_frame, _affected): rebuild())
	State.document_changed.connect(rebuild)
	State.floor_plane_changed.connect(rebuild)

func rebuild() -> void:
	var bounds := State.document.bounds()
	var axis := State.floor_axis
	var index := State.floor_index
	if _built and bounds == _last_bounds and axis == _last_axis and index == _last_index:
		return
	_built = true
	_last_bounds = bounds
	_last_axis = axis
	_last_index = index
	var u := (axis + 1) % 3
	var v := (axis + 2) % 3
	var lo := span_lo(bounds)
	var hi := span_hi(bounds)
	var nu := int(hi[u] - lo[u])
	var nv := int(hi[v] - lo[v])

	var vertices := PackedVector3Array([
		_vec(u, v, 0.0, 0.0),
		_vec(u, v, float(nu), 0.0),
		_vec(u, v, float(nu), float(nv)),
		_vec(u, v, 0.0, float(nv)),
	])
	var grid_mesh := ArrayMesh.new()
	var a := Array()
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = vertices
	a[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	grid_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)

	mesh = grid_mesh
	material_override.set_shader_parameter("floor_axis", axis)
	var p := Vector3.ZERO
	p[axis] = float(index) - 0.5
	p[u] = lo[u]
	p[v] = lo[v]
	position = p


static func span_lo(bounds: AABB) -> Vector3:
	if bounds.has_volume():
		return bounds.position - Vector3.ONE * 1.0
	return Vector3.ONE * -4.5


static func span_hi(bounds: AABB) -> Vector3:
	if bounds.has_volume():
		return span_lo(bounds) + bounds.size + Vector3.ONE * 2.0
	return Vector3.ONE * 3.5


static func _vec(u: int, v: int, s: float, t: float) -> Vector3:
	var q := Vector3.ZERO
	q[u] = s
	q[v] = t
	return q
