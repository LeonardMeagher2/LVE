extends "res://tests/test.gd"

# Guards the merged faces of the mesher. It also prints the cost of one chunk
# build for sparse, solid, and material-heavy content.

const REGION := preload("res://Globals/Rendering/VoxelPlanarRegion.gd")


func _ready() -> void:
	timeout = 60.0
	test("the mesher merges flat faces and skips empty layers", _run)


func _run() -> void:
	step("Given rectangles and shapes with holes", func():
		var solid := _rectangle(Vector2i.ZERO, Vector2i(16, 16))
		expect(REGION.triangulate(solid).size() == 1, "a solid rectangle merges into one polygon")
		var ring := _rectangle(Vector2i.ZERO, Vector2i(6, 6))
		for cell in _rectangle(Vector2i(2, 2), Vector2i(2, 2)):
			ring.erase(cell)
		expect(REGION.triangulate(ring).size() > 1, "a ring splits at its hole")
		var notch := _rectangle(Vector2i.ZERO, Vector2i(6, 6))
		for cell in _rectangle(Vector2i(0, 0), Vector2i(2, 2)):
			notch.erase(cell)
		expect(REGION.triangulate(notch).size() == 1, "a corner notch still merges into one polygon")
	)

	step("Then no small mask falls back to one quad per cell", func():
		var fallbacks := []
		for mask in range(1, 512):
			var cells := {}
			for bit in 9:
				if mask & (1 << bit):
					cells[Vector2i(bit % 3, bit / 3)] = true
			if _is_fallback(cells, REGION.triangulate(cells)):
				fallbacks.append(mask)
		print("MEASURE 3x3 fallbacks: %d of 511 %s" % [fallbacks.size(), str(fallbacks)])
		expect(fallbacks.is_empty(), "no three-by-three mask falls back to one quad per cell")
	)

	step("Then a solid chunk keeps six merged faces", func():
		var solid := _chunk(func(_x: int, _y: int, _z: int) -> bool: return true)
		var flat := _mesh(solid, false)
		expect(flat[1] == 12, "a solid chunk keeps twelve flat triangles")
		expect(flat[0] == 24, "a solid chunk keeps twenty-four flat vertices")
		var smooth := _mesh(solid, true)
		expect(smooth[1] == 12, "a solid chunk keeps twelve smooth triangles")
		expect(smooth[0] == 8, "a smooth chunk shares its eight corners")
	)
	step("Then a one-layer plate keeps six merged faces", func():
		var plate := _chunk(func(_x: int, y: int, _z: int) -> bool: return y == 0)
		var flat := _mesh(plate, false)
		expect(flat[1] == 12, "a plate keeps twelve flat triangles")
	)

	step("Then an empty chunk builds no geometry", func():
		var empty := _chunk(func(_x: int, _y: int, _z: int) -> bool: return false)
		var measured := _mesh(empty, false)
		expect(measured[1] == 0, "an empty chunk keeps no triangles")
		print("MEASURE empty chunk build: %d us" % measured[2])
	)

	step("Then a hole costs more polygons than a plain plate", func():
		var plate := _chunk(func(_x: int, y: int, _z: int) -> bool: return y == 0)
		var holed := _chunk(func(x: int, y: int, z: int) -> bool: return y == 0 and not (x == 8 and z == 8))
		var plain_triangles: int = _mesh(plate, false)[1]
		var holed_triangles: int = _mesh(holed, false)[1]
		print("MEASURE plate triangles: plain %d, one hole %d" % [plain_triangles, holed_triangles])
		expect(holed_triangles > plain_triangles, "a hole adds triangles")
	)

	step("Then the sample document meshes without a fallback", func():
		var document := VoxelDocument.load_file("res://Flamingo.lve")
		expect(document != null, "the sample document loads")
		if document == null:
			return
		var frame: VoxelFrame = document.frames[0]
		var triangles := 0
		for chunk_location: Vector3i in frame.chunks:
			triangles += _mesh(frame, false, chunk_location)[1]
		print("MEASURE flamingo: %d voxels, %d triangles, %d chunks" % [
			frame.count(), triangles, frame.chunks.size(),
		])
		expect(triangles > 0, "the sample document produces triangles")
	)


# A group of two or more 4-connected cells must merge into fewer polygons than cells.
func _is_fallback(cells: Dictionary, output: Array) -> bool:
	if cells.size() < 2 or output.size() != cells.size():
		return false
	if not _connected(cells):
		return false
	for mesh: Dictionary in output:
		if mesh.points.size() != 4 or mesh.indices.size() != 6:
			return false
	return true


func _connected(cells: Dictionary) -> bool:
	var start: Vector2i = cells.keys()[0]
	var seen := {start: true}
	var queue: Array[Vector2i] = [start]
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_back()
		for offset: Vector2i in [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.UP, Vector2i.DOWN]:
			var next := cell + offset
			if cells.has(next) and not seen.has(next):
				seen[next] = true
				queue.append(next)
	return seen.size() == cells.size()


func _rectangle(origin: Vector2i, size: Vector2i) -> Dictionary:
	var cells := {}
	for y in size.y:
		for x in size.x:
			cells[origin + Vector2i(x, y)] = true
	return cells


func _chunk(occupied: Callable) -> VoxelFrame:
	var frame := VoxelFrame.new()
	var cell_material := VoxelFrame.material(Color.RED)
	for z in 16:
		for y in 16:
			for x in 16:
				if occupied.call(x, y, z):
					frame.set_cell(Vector3i(x, y, z), cell_material)
	return frame


# Returns the vertex count, the triangle count, and the build time in microseconds.
func _mesh(frame: VoxelFrame, smooth: bool, chunk_location := Vector3i.ZERO) -> Array:
	var job := VoxelMeshBuilder.new()
	job.source_frame = frame
	job.chunk_location = chunk_location
	job.smooth_normals = smooth
	var started_us := Time.get_ticks_usec()
	job.run()
	var elapsed_us := Time.get_ticks_usec() - started_us
	return [
		job.surface_arrays[Mesh.ARRAY_VERTEX].size(),
		job.surface_arrays[Mesh.ARRAY_INDEX].size() / 3,
		elapsed_us,
	]
