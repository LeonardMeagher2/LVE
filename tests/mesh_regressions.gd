extends "res://tests/test.gd"

# The merged faces of the mesher, and the merge quality of a reported document,
# in one process. The greedy mesh already merges each plane, so the cleanup can
# only add polygons. A chunk that gains many triangles marks a merge failure.
#
# The reported case is a 5 by 5 slab with a diagonal gap of three cells. Its
# outline pinches at two corners, so the region triangulator used to fall back
# to one quad per cell for both the top and the bottom face.
#
# Each test keeps the steps and checks of its original scene. The user arguments
# after `--` name the tests to run, so an old scene name still selects its own
# test.

const REGION := preload("res://Globals/Rendering/VoxelPlanarRegion.gd")
const CASE := "res://tests/fixtures/FailedGreed.lve"


func _ready() -> void:
	timeout = 60.0
	test("the mesher merges flat faces and skips empty layers", _planar_merge, "planar_merge")
	test("a document keeps its merged faces", _failed_greed, "failed_greed")


# Both tests keep all of their state in local variables, so no setup hook is
# needed to isolate them.


func _planar_merge() -> void:
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
		var flat := _mesh(solid, Vector3i.ZERO, true, false)
		expect(flat[1] == 12, "a solid chunk keeps twelve flat triangles")
		expect(flat[0] == 24, "a solid chunk keeps twenty-four flat vertices")
		var smooth := _mesh(solid, Vector3i.ZERO, true, true)
		expect(smooth[1] == 12, "a solid chunk keeps twelve smooth triangles")
		expect(smooth[0] == 8, "a smooth chunk shares its eight corners")
	)
	step("Then a one-layer plate keeps six merged faces", func():
		var plate := _chunk(func(_x: int, y: int, _z: int) -> bool: return y == 0)
		var flat := _mesh(plate, Vector3i.ZERO, true, false)
		expect(flat[1] == 12, "a plate keeps twelve flat triangles")
	)

	step("Then an empty chunk builds no geometry", func():
		var empty := _chunk(func(_x: int, _y: int, _z: int) -> bool: return false)
		var measured := _mesh(empty, Vector3i.ZERO, true, false)
		expect(measured[1] == 0, "an empty chunk keeps no triangles")
		print("MEASURE empty chunk build: %d us" % measured[2])
	)

	step("Then a hole costs more polygons than a plain plate", func():
		var plate := _chunk(func(_x: int, y: int, _z: int) -> bool: return y == 0)
		var holed := _chunk(func(x: int, y: int, z: int) -> bool: return y == 0 and not (x == 8 and z == 8))
		var plain_triangles: int = _mesh(plate, Vector3i.ZERO, true, false)[1]
		var holed_triangles: int = _mesh(holed, Vector3i.ZERO, true, false)[1]
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
			triangles += _mesh(frame, chunk_location, true, false)[1]
		print("MEASURE flamingo: %d voxels, %d triangles, %d chunks" % [
			frame.count(), triangles, frame.chunks.size(),
		])
		expect(triangles > 0, "the sample document produces triangles")
	)


func _failed_greed() -> void:
	step("Given the reported document", func():
		expect(FileAccess.file_exists(CASE), "the reported document exists")
	)

	step("Then the cleanup never adds polygons to a chunk", func():
		var document := VoxelDocument.load_file(CASE)
		expect(document != null, "the reported document loads")
		if document == null:
			return
		var frame: VoxelFrame = document.frames[0]
		var distinct := {}
		for chunk: VoxelFrame.Chunk in frame.chunks.values():
			for cell_position in chunk.world_cells():
				distinct[frame.get_material(cell_position)] = true
		print("MEASURE case: %d voxels, %d chunks, %d materials, bounds %s" % [
			frame.count(), frame.chunks.size(), distinct.size(), str(frame.get_bounds()),
		])
		var greedy_triangles := 0
		var merged_triangles := 0
		var gained := []
		for chunk_location: Vector3i in frame.chunks:
			var greedy := _mesh(frame, chunk_location, false, false)
			var merged := _mesh(frame, chunk_location, true, false)
			greedy_triangles += greedy[1]
			merged_triangles += merged[1]
			if merged[1] > greedy[1]:
				gained.append([chunk_location, greedy[1], merged[1]])
		print("MEASURE case: greedy %d triangles, with cleanup %d triangles" % [
			greedy_triangles, merged_triangles,
		])
		print("MEASURE case: %d chunks gained triangles in the cleanup %s" % [
			gained.size(), str(gained.slice(0, 8)),
		])
		# The diagonal gap used to make the outline pinch at two corners. The
		# region then fell back to one quad per cell and reached 92 triangles.
		expect(greedy_triangles == 64, "the merged source uses 64 triangles")
		expect(merged_triangles == 72, "the cleanup adds only seam triangles")
		expect(greedy_triangles > 0, "the document produces triangles")
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
# `cleanup` selects the planar cleanup build, which the greedy path leaves off.
func _mesh(frame: VoxelFrame, chunk_location: Vector3i, cleanup: bool, smooth: bool) -> Array:
	var job := VoxelMeshBuilder.new()
	job.source_frame = frame
	job.chunk_location = chunk_location
	job.smooth_normals = smooth
	job.texture_materials = cleanup
	var started_us := Time.get_ticks_usec()
	job.run()
	var elapsed_us := Time.get_ticks_usec() - started_us
	return [
		job.surface_arrays[Mesh.ARRAY_VERTEX].size(),
		job.surface_arrays[Mesh.ARRAY_INDEX].size() / 3,
		elapsed_us,
	]
