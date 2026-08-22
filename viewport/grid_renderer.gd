class_name GridRenderer
extends MeshInstance3D

var _last_bounds: AABB
var _built := false

func _ready() -> void:
	rebuild()
	State.cells_changed.connect(rebuild)
	State.document_changed.connect(rebuild)

func rebuild() -> void:
	var bounds := State.document.bounds()
	if _built and bounds == _last_bounds:
		return
	_built = true
	_last_bounds = bounds
	for child in get_children():
		remove_child(child)
		child.queue_free()
	
	var cx := int(bounds.size.x) + 2
	var cz := int(bounds.size.z) + 2
	
	if bounds.has_volume():
		position = bounds.position -Vector3.ONE * 1.5
		position.y = -0.5
	else:
		position = -Vector3(4.5,0.5,4.5)
		cx=8
		cz=8

	var lines := PackedVector3Array()
	for i in cx + 1:
		lines.append(Vector3(i, 0, 0))
		lines.append(Vector3(i, 0, cz))
	for i in cz + 1:
		lines.append(Vector3(0, 0, i))
		lines.append(Vector3(cx, 0, i))
	var line_mesh := ArrayMesh.new()
	line_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, MeshUtil.vertex_arrays(lines))
	
	mesh = line_mesh
