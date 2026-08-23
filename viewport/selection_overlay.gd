class_name SelectionOverlay
extends MeshInstance3D


func _ready() -> void:
	State.selection_changed.connect(sync_selection)


func sync_selection() -> void:
	if State.selection == null or State.selection.is_empty():
		visible = false
		return
	var sel := State.selection
	var edges := []
	for c in sel.cells:
		edges.append_array(_boundary_edges(c, sel))
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, MeshUtil.vertex_arrays(_merged_outline(edges)))
	mesh = m
	visible = true


func _boundary_edges(c: Vector3i, sel: VoxelSelection) -> Array:
	var edges := []
	for axis in 3:
		var u := (axis + 1) % 3
		var v := (axis + 2) % 3
		for su in [-1, 1]:
			for sv in [-1, 1]:
				var na := _shifted(c, u, su)
				var nb := _shifted(c, v, sv)
				if sel.contains(na) and sel.contains(nb):
					continue
				var nd := _shifted(na, v, sv)
				if sel.contains(na) != sel.contains(nb) and not sel.contains(nd):
					continue
				edges.append([axis, c[u] * 2 + su, c[v] * 2 + sv, c[axis] * 2 - 1, c[axis] * 2 + 1])
	return edges


func _shifted(c: Vector3i, comp: int, s: int) -> Vector3i:
	var r := c
	r[comp] += s
	return r


func _merged_outline(edges: Array) -> PackedVector3Array:
	var groups := {}
	for e in edges:
		var key := Vector3i(e[0], e[1], e[2])
		if not groups.has(key):
			groups[key] = []
		groups[key].append(Vector2i(e[3], e[4]))
	var out := PackedVector3Array()
	for key in groups:
		var runs: Array = groups[key]
		runs.sort_custom(func(x, y): return x.x < y.x)
		var cur: Vector2i = runs[0]
		for i in range(1, runs.size()):
			var r: Vector2i = runs[i]
			if r.x <= cur.y:
				cur.y = maxi(cur.y, r.y)
			else:
				_emit_run(out, key.x, key.y, key.z, cur)
				cur = r
		_emit_run(out, key.x, key.y, key.z, cur)
	return out


func _emit_run(out: PackedVector3Array, axis: int, iu: int, iv: int, run: Vector2i) -> void:
	var u := (axis + 1) % 3
	var v := (axis + 2) % 3
	var a := Vector3.ZERO
	var b := Vector3.ZERO
	a[axis] = run.x * 0.5
	b[axis] = run.y * 0.5
	a[u] = iu * 0.5
	b[u] = iu * 0.5
	a[v] = iv * 0.5
	b[v] = iv * 0.5
	out.append(a)
	out.append(b)
