class_name GridRenderer
extends Node3D

@export var grid_mat: StandardMaterial3D
@export var base_mat: StandardMaterial3D


func _ready() -> void:
	State.cells_changed.connect(rebuild)
	State.frame_changed.connect(rebuild)


func rebuild() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	var g := State.document.grid_size
	var cx := g
	var cz := g

	var lines := PackedVector3Array()
	for i in cx + 1:
		lines.append(Vector3(i - 0.5, -0.5, -0.5))
		lines.append(Vector3(i - 0.5, -0.5, cz - 0.5))
	for i in cz + 1:
		lines.append(Vector3(-0.5, -0.5, i - 0.5))
		lines.append(Vector3(cx - 0.5, -0.5, i - 0.5))
	var line_mesh := ArrayMesh.new()
	line_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, MeshUtil.vertex_arrays(lines))
	var li := MeshInstance3D.new()
	li.mesh = line_mesh
	li.material_override = grid_mat
	add_child(li)

	var quad := PackedVector3Array([
		Vector3(-0.5, -0.502, -0.5),
		Vector3(cx - 0.5, -0.502, -0.5),
		Vector3(cx - 0.5, -0.502, cz - 0.5),
		Vector3(-0.5, -0.502, cz - 0.5),
	])
	var quad_mesh := ArrayMesh.new()
	quad_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLE_STRIP, MeshUtil.vertex_arrays(quad))
	var qi := MeshInstance3D.new()
	qi.mesh = quad_mesh
	qi.material_override = base_mat
	add_child(qi)
