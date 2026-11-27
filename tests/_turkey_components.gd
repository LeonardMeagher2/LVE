extends SceneTree


const FACE_OFFSETS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]


func _init() -> void:
	var document := VoxelDocument.load_file("res://LVE-prototypes/Turkey.lve")
	var frame := document.frames[0]
	var cells := {}
	for location: Vector3i in frame.chunks:
		var chunk: VoxelFrame.Chunk = frame.chunks[location]
		var rows = chunk.occupancy_rows()
		for row in rows.masks.size():
			var mask: int = rows.masks[row]
			var local_y: int = row % VoxelFrame.CHUNK_SIZE
			var local_z: int = row / VoxelFrame.CHUNK_SIZE
			while mask != 0:
				var local_x: int = VoxelFrame.Chunk.first_column(mask)
				mask &= mask - 1
				var id: int = chunk.cell_id_at_slot(row * VoxelFrame.CHUNK_SIZE + local_x)
				if id == 0:
					continue
				var base := (id - 1) * VoxelFrame.MATERIAL_STRIDE
				var color := Color(chunk.materials[base], chunk.materials[base + 1], chunk.materials[base + 2], chunk.materials[base + 3]).to_rgba32()
				var emission := Color(chunk.materials[base + 4], chunk.materials[base + 5], chunk.materials[base + 6]).to_rgba32()
				var key := "%08x|%08x|%.2f|%.2f" % [color, emission, chunk.materials[base + 7], chunk.materials[base + 8]]
				cells[location * VoxelFrame.CHUNK_SIZE + Vector3i(local_x, local_y, local_z)] = key
	var counts := {}
	for cell: Vector3i in cells:
		var key: String = cells[cell]
		counts[key] = counts.get(key, 0) + 1
	for key: String in counts:
		print("MATERIAL %s count=%d" % [key, counts[key]])
	for key: String in counts:
		var remaining := {}
		for cell: Vector3i in cells:
			if cells[cell] == key:
				remaining[cell] = true
		var components: Array = []
		for cell: Vector3i in remaining.keys():
			if not remaining.has(cell):
				continue
			var component: Array[Vector3i] = []
			var stack: Array[Vector3i] = [cell]
			remaining.erase(cell)
			while not stack.is_empty():
				var current: Vector3i = stack.pop_back()
				component.append(current)
				for offset: Vector3i in FACE_OFFSETS:
					var neighbor := current + offset
					if remaining.has(neighbor):
						remaining.erase(neighbor)
						stack.append(neighbor)
			components.append(component)
		components.sort_custom(func(first: Array, second: Array) -> bool: return first.size() > second.size())
		print("MATERIAL %s components=%d" % [key, components.size()])
		for index in mini(8, components.size()):
			var component: Array = components[index]
			var box := AABB(Vector3(component[0]), Vector3.ZERO)
			for cell: Vector3i in component:
				box = box.expand(Vector3(cell))
			print("  component %d size=%d bounds=%s" % [index, component.size(), box])
		if components.size() > 1:
			var main: Array = components[0]
			var main_cells := {}
			for cell: Vector3i in main:
				main_cells[cell] = true
			for index in range(1, components.size()):
				var bit: Vector3i = components[index][0]
				print("  bit %s main_contacts:" % bit)
				for offset in _around():
					var neighbor := bit + offset
					if main_cells.has(neighbor):
						print("    main %s offset=%s" % [neighbor, offset])
					elif cells.has(neighbor):
						print("    solid %s offset=%s material=%s" % [neighbor, offset, cells[neighbor]])
	print("cells=%d" % cells.size())
	quit()


func _around() -> Array[Vector3i]:
	var offsets: Array[Vector3i] = []
	for z in range(-1, 2):
		for y in range(-1, 2):
			for x in range(-1, 2):
				if x == 0 and y == 0 and z == 0:
					continue
				offsets.append(Vector3i(x, y, z))
	return offsets
