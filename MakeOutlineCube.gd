@tool
extends EditorScript

func _run() -> void:
	var s := 0.5
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
	ResourceSaver.save(m, "res://ui/OutlineCube.tres")
