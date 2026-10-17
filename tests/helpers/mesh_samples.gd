extends RefCounted


static func uv_at(arrays: Array, point: Vector3, face_normal: Vector3) -> Variant:
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	for offset in range(0, indices.size(), 3):
		var a := positions[indices[offset]]
		var ab := positions[indices[offset + 1]] - a
		var ac := positions[indices[offset + 2]] - a
		var normal := -ab.cross(ac).normalized()
		if normal.dot(face_normal) < 0.99 or absf(normal.dot(point - a)) > 0.001:
			continue
		var denominator := ab.dot(ab) * ac.dot(ac) - ab.dot(ac) * ab.dot(ac)
		if denominator <= 0.000001:
			continue
		var v := (ac.dot(ac) * (point - a).dot(ab) - ab.dot(ac) * (point - a).dot(ac)) / denominator
		var w := (ab.dot(ab) * (point - a).dot(ac) - ab.dot(ac) * (point - a).dot(ab)) / denominator
		if v >= -0.00001 and w >= -0.00001 and v + w <= 1.00001:
			return uvs[indices[offset]] * (1.0 - v - w) + uvs[indices[offset + 1]] * v + uvs[indices[offset + 2]] * w
	return null
