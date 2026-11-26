extends "res://tests/test.gd"


const SPAN := 3
const CHUNK := VoxelFrame.CHUNK_SIZE
const WARMUPS := 1
const REPEATS := 2

var frame: VoxelFrame
var locations: Array[Vector3i] = []
var results: Array = []
var mutex := Mutex.new()
var parallel_atlas := true
var parallel_smooth := false


func _ready() -> void:
	timeout = 900.0
	test("the chunk surface arrays build in parallel with identical output", _cost, "mesh_parallel")


func _cost() -> void:
	step("Given a 27 chunk mixed fixture", func():
		frame = _fixture()
		for location: Vector3i in frame.chunks:
			locations.append(location)
		expect(locations.size() == SPAN * SPAN * SPAN, "the fixture holds 27 chunks")
	)
	var sequential := _measure(false)
	var parallel := _measure(true)
	step("Then both builds write the same arrays", func():
		expect(sequential["vertices"] == parallel["vertices"], "the vertex count matches")
		expect(sequential["indices"] == parallel["indices"], "the index count matches")
		expect(sequential["hash"] == parallel["hash"], "the vertex and index data match")
		expect(sequential["vertices"] > 0, "the fixture builds a surface")
	)


func _measure(use_threads: bool) -> Dictionary:
	var times: Array[int] = []
	var summary := {}
	for pass_index in WARMUPS + REPEATS:
		results.resize(locations.size())
		var started := Time.get_ticks_usec()
		if use_threads:
			var group := WorkerThreadPool.add_group_task(_task, locations.size(), -1, false, "bench surface")
			WorkerThreadPool.wait_for_group_task_completion(group)
		else:
			for index in locations.size():
				results[index] = _build(index)
		times.append(Time.get_ticks_usec() - started)
		summary = _sum(results)
	var measured := times.slice(WARMUPS)
	measured.sort()
	var median: int = measured[measured.size() / 2]
	print("MEASURE mesh_parallel %s: us=%d cores=%d vertices=%d indices=%d" % [
		"threads" if use_threads else "serial", median, OS.get_processor_count(),
		int(summary.get("vertices", 0)), int(summary.get("indices", 0)),
	])
	return summary


func _task(index: int) -> void:
	var value := _build(index)
	mutex.lock()
	results[index] = value
	mutex.unlock()


func _build(index: int) -> Dictionary:
	var builder := VoxelMeshBuilder.new()
	builder.source_frame = frame
	builder.chunk_location = locations[index]
	builder.smooth_normals = parallel_smooth
	builder.texture_materials = parallel_atlas
	builder.run()
	var arrays: Array = builder.surface_arrays
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var hash := positions.size() * 31 + indices.size()
	if positions.size() > 0:
		hash = hash * 31 + int(positions[0].x * 8.0) + int(positions[positions.size() - 1].z * 8.0)
	if indices.size() > 0:
		hash = hash * 31 + indices[0] + indices[indices.size() - 1]
	return {"vertices": positions.size(), "indices": indices.size(), "hash": hash}


func _sum(values: Array) -> Dictionary:
	var vertices := 0
	var indices := 0
	var hash := 0
	for value: Dictionary in values:
		vertices += int(value["vertices"])
		indices += int(value["indices"])
		hash += int(value["hash"])
	return {"vertices": vertices, "indices": indices, "hash": hash}


func _fixture() -> VoxelFrame:
	var value := VoxelFrame.new()
	var flat := VoxelFrame.material(Color.from_rgba8(90, 160, 220))
	var metal := VoxelFrame.material(Color.from_rgba8(220, 120, 70), Color(0.2, 0.1, 0.0), 0.8, 0.2)
	var rough := VoxelFrame.material(Color(0.1, 0.4, 0.9), Color.BLACK, 0.0, 1.0)
	var translucent := VoxelFrame.material(Color(1.0, 0.0, 0.0, 0.5))
	for cz in SPAN:
		for cy in SPAN:
			for cx in SPAN:
				var location := Vector3i(cx, cy, cz)
				var chunk := VoxelFrame.Chunk.new()
				chunk.location = location
				chunk.occupied_count = CHUNK * CHUNK * CHUNK
				chunk.shared_materials = true
				chunk.bounds_dirty = false
				chunk.occupied_bounds = AABB(Vector3(location * CHUNK) - Vector3.ONE * 0.5, Vector3.ONE * CHUNK)
				for lz in CHUNK:
					for ly in CHUNK:
						for lx in CHUNK:
							chunk.grid[VoxelFrame.Chunk.cell_slot(Vector3i(lx, ly, lz))] = 1 + ((lx + ly + lz) % 4)
				chunk.materials = rough.duplicate()
				chunk.materials.append_array(metal)
				chunk.materials.append_array(flat)
				chunk.materials.append_array(translucent)
				value.chunks[location] = chunk
	value.restore(value.chunks)
	return value
