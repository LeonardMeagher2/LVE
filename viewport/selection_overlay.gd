class_name SelectionOverlay
extends Node3D

@onready var _outline: MeshInstance3D = $SelectionOutline


func sync_selection(selection: VoxelSelection) -> void:
	if selection == null or selection.is_empty():
		_outline.visible = false
		return
	var lo := Vector3i(0, 0, 0)
	var hi := Vector3i(0, 0, 0)
	var first := true
	for c in selection.cells:
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
	var a := Vector3(lo.x, lo.y, lo.z)
	var b := Vector3(hi.x + 1, hi.y + 1, hi.z + 1)
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
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, MeshUtil.vertex_arrays(lines))
	_outline.mesh = mesh
	_outline.visible = true
