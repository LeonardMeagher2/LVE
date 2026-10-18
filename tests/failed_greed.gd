extends "res://tests/test.gd"

# Reports the merge quality of a reported document.
# The greedy mesh already merges each plane, so the cleanup can only add
# polygons. A chunk that gains many triangles marks a merge failure.
#
# The reported case is a 5 by 5 slab with a diagonal gap of three cells. Its
# outline pinches at two corners, so the region triangulator used to fall back
# to one quad per cell for both the top and the bottom face.

const CASE := "res://tests/fixtures/FailedGreed.lve"


func _ready() -> void:
	timeout = 60.0
	test("a document keeps its merged faces", _run)


func _run() -> void:
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
			var greedy := _mesh(frame, chunk_location, false)
			var merged := _mesh(frame, chunk_location, true)
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


# Returns the vertex count, the triangle count, and the build time in microseconds.
func _mesh(frame: VoxelFrame, chunk_location: Vector3i, cleanup: bool, smooth := false) -> Array:
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
