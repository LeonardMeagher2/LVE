extends "res://tests/test.gd"


const FIXTURE := preload("res://tests/helpers/marching_fixture.gd")
const EXPECTED_CELLS_HASH := 5752160045764862365
const EXPECTED_GEOMETRY_HASH := 1437062865021484261
const EXPECTED_CHUNKS := 64
const EXPECTED_NONEMPTY := 8
const EXPECTED_VERTICES := 3194
const EXPECTED_TRIANGLES := 2606

var _frame: VoxelFrame
var _locations: Array[Vector3i] = []
var _hash := 0
var _vertices := 0
var _triangles := 0
var _nonempty := 0
var _elapsed_us := 0


func _ready() -> void:
	timeout = 60.0
	test("the marching mesher keeps one geometry snapshot", _snapshot, "march_snapshot")


func _snapshot() -> void:
	step("Given a radius five sphere with four materials", func():
		var cells := FIXTURE.sphere_materials(5, 4)
		_frame = VoxelFrame.new()
		_frame.set_cells(cells)
		_locations = FIXTURE.requested_locations(_frame)
		expect(FIXTURE.cells_hash(cells) == EXPECTED_CELLS_HASH, "the fixture cells match the snapshot")
	)
	step("When every requested chunk builds", func():
		var started := Time.get_ticks_usec()
		_hash = 5381
		for location: Vector3i in _locations:
			var builder := VoxelMarchingMeshBuilder.new()
			builder.source_frame = _frame
			builder.chunk_location = location
			builder.run()
			var arrays: Array = builder.surface_arrays
			if not arrays[Mesh.ARRAY_VERTEX].is_empty():
				_nonempty += 1
				_vertices += arrays[Mesh.ARRAY_VERTEX].size()
				_triangles += arrays[Mesh.ARRAY_INDEX].size() / 3
			_hash = FIXTURE.geometry_hash(arrays, location, _hash)
		_elapsed_us = Time.get_ticks_usec() - started
	)
	step("Then the mesh geometry matches the snapshot", func():
		print("MEASURE march_snapshot: chunks=%d nonempty=%d vertices=%d triangles=%d us=%d hash=%d" % [
			_locations.size(), _nonempty, _vertices, _triangles, _elapsed_us, _hash,
		])
		expect(_locations.size() == EXPECTED_CHUNKS, "the fixture requests its sixty-four chunks")
		expect(_nonempty == EXPECTED_NONEMPTY, "the sphere fills eight chunks")
		expect(_vertices == EXPECTED_VERTICES, "the mesh keeps its vertex count")
		expect(_triangles == EXPECTED_TRIANGLES, "the mesh keeps its triangle count")
		expect(_hash == EXPECTED_GEOMETRY_HASH, "the mesh keeps every position, normal, colour, and index")
	)
