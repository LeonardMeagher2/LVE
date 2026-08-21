class_name MeshUtil
extends RefCounted


static func vertex_arrays(points: PackedVector3Array) -> Array:
	var a := Array()
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = points
	return a
