class_name VoxelSelection
extends RefCounted

var cells := {}


func clear() -> void:
	cells.clear()


func add(c: Vector3i) -> void:
	cells[c] = true


func remove(c: Vector3i) -> void:
	cells.erase(c)


func contains(c: Vector3i) -> bool:
	return cells.has(c)


func is_empty() -> bool:
	return cells.is_empty()


func to_array() -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for c in cells:
		out.append(c)
	return out


func from_box(a: Vector3i, b: Vector3i) -> void:
	var lo := Vector3i(mini(a.x, b.x), mini(a.y, b.y), mini(a.z, b.z))
	var hi := Vector3i(maxi(a.x, b.x), maxi(a.y, b.y), maxi(a.z, b.z))
	cells.clear()
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			for z in range(lo.z, hi.z + 1):
				cells[Vector3i(x, y, z)] = true


func union(other: VoxelSelection) -> void:
	for c in other.cells:
		cells[c] = true
