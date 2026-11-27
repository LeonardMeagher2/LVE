extends RefCounted


const NEIGHBORS: Array[Vector3i] = [
	Vector3i(-1, -1, -1), Vector3i(0, -1, -1), Vector3i(1, -1, -1),
	Vector3i(-1, 0, -1), Vector3i(0, 0, -1), Vector3i(1, 0, -1),
	Vector3i(-1, 1, -1), Vector3i(0, 1, -1), Vector3i(1, 1, -1),
	Vector3i(-1, -1, 0), Vector3i(0, -1, 0), Vector3i(1, -1, 0),
	Vector3i(-1, 0, 0), Vector3i(0, 0, 0), Vector3i(1, 0, 0),
	Vector3i(-1, 1, 0), Vector3i(0, 1, 0), Vector3i(1, 1, 0),
	Vector3i(-1, -1, 1), Vector3i(0, -1, 1), Vector3i(1, -1, 1),
	Vector3i(-1, 0, 1), Vector3i(0, 0, 1), Vector3i(1, 0, 1),
	Vector3i(-1, 1, 1), Vector3i(0, 1, 1), Vector3i(1, 1, 1),
]
const MATERIAL_COLORS := [
	Color(0.85, 0.2, 0.15),
	Color(0.2, 0.65, 0.25),
	Color(0.2, 0.35, 0.9),
	Color(0.95, 0.8, 0.2),
]


static func sphere_cells(radius: int, material_count: int) -> Dictionary:
	var cells := {}
	var limit := radius * radius
	for z in range(-radius, radius + 1):
		for y in range(-radius, radius + 1):
			for x in range(-radius, radius + 1):
				if x * x + y * y + z * z > limit:
					continue
				var slot := absi(x * 3 + y * 5 + z * 7) % material_count
				cells[Vector3i(x, y, z)] = MATERIAL_COLORS[slot]
	return cells


static func sphere_materials(radius: int, material_count: int) -> Dictionary:
	var colors := sphere_cells(radius, material_count)
	var cells := {}
	for cell: Vector3i in colors:
		cells[cell] = VoxelFrame.material(colors[cell])
	return cells


static func sphere_frame(radius: int, material_count: int) -> VoxelFrame:
	var frame := VoxelFrame.new()
	frame.set_cells(sphere_materials(radius, material_count))
	return frame


static func requested_locations(frame: VoxelFrame) -> Array[Vector3i]:
	var seen := {}
	for location: Vector3i in frame.chunks:
		for offset: Vector3i in NEIGHBORS:
			seen[location + offset] = true
	var locations: Array[Vector3i] = []
	for location: Vector3i in seen:
		locations.append(location)
	locations.sort_custom(func(first: Vector3i, second: Vector3i) -> bool:
		if first.x != second.x:
			return first.x < second.x
		if first.y != second.y:
			return first.y < second.y
		return first.z < second.z)
	return locations


static func geometry_hash(arrays: Array, location: Vector3i, rolling: int) -> int:
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if positions.is_empty():
		return rolling
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	rolling = rolling * 33 + location.x
	rolling = rolling * 33 + location.y
	rolling = rolling * 33 + location.z
	for index in positions.size():
		rolling = rolling * 33 + roundi(positions[index].x * 1024.0)
		rolling = rolling * 33 + roundi(positions[index].y * 1024.0)
		rolling = rolling * 33 + roundi(positions[index].z * 1024.0)
		rolling = rolling * 33 + roundi(normals[index].x * 1024.0)
		rolling = rolling * 33 + roundi(normals[index].y * 1024.0)
		rolling = rolling * 33 + roundi(normals[index].z * 1024.0)
		rolling = rolling * 33 + roundi(colors[index].r * 255.0)
		rolling = rolling * 33 + roundi(colors[index].g * 255.0)
		rolling = rolling * 33 + roundi(colors[index].b * 255.0)
		rolling = rolling * 33 + roundi(colors[index].a * 255.0)
	for value: int in indices:
		rolling = rolling * 33 + value
	return rolling


static func cells_hash(cells: Dictionary) -> int:
	var locations: Array = cells.keys()
	locations.sort_custom(func(first: Vector3i, second: Vector3i) -> bool:
		if first.x != second.x:
			return first.x < second.x
		if first.y != second.y:
			return first.y < second.y
		return first.z < second.z)
	var rolling := 5381
	for location: Vector3i in locations:
		var material: PackedFloat32Array = cells[location]
		rolling = rolling * 33 + location.x
		rolling = rolling * 33 + location.y
		rolling = rolling * 33 + location.z
		for value: float in material:
			rolling = rolling * 33 + roundi(value * 1000.0)
	return rolling
