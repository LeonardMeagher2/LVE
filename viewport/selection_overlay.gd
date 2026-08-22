class_name SelectionOverlay
extends MeshInstance3D

func _ready() -> void:
	State.selection_changed.connect(sync_selection)

func sync_selection() -> void:
	if State.selection == null or State.selection.is_empty():
		visible = false
		return
	var lo := Vector3i(0, 0, 0)
	var hi := Vector3i(0, 0, 0)
	var first := true
	for c in State.selection.cells:
		if first:
			lo = c
			hi = c
			first = false
			continue
		lo.x = mini(lo.x, c.x)
		lo.y = mini(lo.y, c.y)
		lo.z = mini(lo.z, c.z)
		hi.x = maxi(hi.x, c.x)
		hi.y = maxi(hi.y, c.y)
		hi.z = maxi(hi.z, c.z)
	var a := Vector3(lo) - Vector3(0.5, 0.5, 0.5)
	var b := Vector3(hi) + Vector3(0.5, 0.5, 0.5)
	var corners := PackedVector3Array([
		a, Vector3(b.x, a.y, a.z), Vector3(b.x, b.y, a.z), Vector3(a.x, b.y, a.z),
		Vector3(a.x, a.y, b.z), Vector3(b.x, a.y, b.z), b, Vector3(a.x, b.y, b.z),
	])
	var lines := PackedVector3Array()
	for i in 4:
		lines.append(corners[i])
		lines.append(corners[(i + 1) % 4])
		lines.append(corners[i + 4])
		lines.append(corners[4 + (i + 1) % 4])
		lines.append(corners[i])
		lines.append(corners[i + 4])
	mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, MeshUtil.vertex_arrays(lines))
	visible = true
