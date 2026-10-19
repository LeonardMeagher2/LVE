extends "res://tests/test.gd"

# Differential regression for the smooth corner normals. A direct textured build
# reads occupancy from its padded snapshot. This compares that path with the
# frame-based reference on the same groups, so both must emit identical vertices,
# normals, and indices. Fixtures cover chunk boundaries, edges, corners, negative
# locations, and a stored transparent voxel.

const BUILDER := preload("res://Globals/Rendering/VoxelMeshBuilder.gd")
const SURFACE := preload("res://Globals/Rendering/VoxelSurface.gd")
const ATLAS := preload("res://Globals/Rendering/VoxelAtlas.gd")

var fixtures: Array = []


func _ready() -> void:
	timeout = 60.0
	test("the padded snapshot corner normals match the frame reference", _run)


func _run() -> void:
	step("Given chunks that exercise boundaries, edges, corners, and negative locations", func():
		fixtures = [
			{"name": "a solid chunk at the origin", "frame": _solid(Vector3i.ZERO, 16), "chunk": Vector3i.ZERO},
			{"name": "a solid chunk at a negative location", "frame": _solid(Vector3i(-1, -1, -1), 16), "chunk": Vector3i(-1, -1, -1)},
			{"name": "two chunks across a color seam", "frame": _seam(), "chunk": Vector3i.ZERO},
			{"name": "a diagonal neighbor chunk", "frame": _diagonal(), "chunk": Vector3i.ZERO},
			{"name": "an opposite corner neighbor", "frame": _opposite_corner(), "chunk": Vector3i.ZERO},
			{"name": "a stored transparent voxel", "frame": _transparent(), "chunk": Vector3i.ZERO},
		]
		expect(fixtures.size() == 6, "six differential fixtures are prepared")
	)
	step("Then the snapshot path matches the frame path for every fixture", func():
		for fixture: Dictionary in fixtures:
			_expect_match(fixture)
	)
	step("Then the direct textured build matches the greedy frame build at the origin", func():
		_expect_end_to_end(fixtures[0])
	)


# The snapshot path and the frame path run on independent copies of the same
# groups, so the comparison isolates the normal source.
func _expect_match(fixture: Dictionary) -> void:
	var label: String = fixture["name"]
	var frame: VoxelFrame = fixture["frame"]
	var chunk: Vector3i = fixture["chunk"]
	var origin := Vector3(chunk * VoxelFrame.CHUNK_SIZE)
	var builder: VoxelMeshBuilder = BUILDER.new()
	var snapshot := BUILDER._snapshot(frame, chunk, true)
	var colors: PackedColorArray = snapshot[0]
	var occupancy: PackedInt32Array = snapshot[1]
	_expect_all_corners(frame, origin, occupancy, label)
	var materials: PackedFloat32Array = snapshot[2]
	var planes: PackedInt32Array = snapshot[3]
	var always := func(_progress: int) -> bool: return true
	var reference_bake: RefCounted = ATLAS.new()
	var snapshot_bake: RefCounted = ATLAS.new()
	var reference: Array = SURFACE._finish(builder._collect_groups(colors, occupancy, materials, planes), frame, origin, reference_bake, always, true)
	var snapshot_result: Array = SURFACE._finish(builder._collect_groups(colors, occupancy, materials, planes), frame, origin, snapshot_bake, always, true, occupancy)
	expect(reference[Mesh.ARRAY_VERTEX].size() > 0, "%s: the fixture produces geometry" % label)
	expect(_same_arrays(reference, snapshot_result), "%s: the snapshot normals match the frame normals" % label)


func _expect_all_corners(frame: VoxelFrame, origin: Vector3, occupancy: PackedInt32Array, label: String) -> void:
	var equal := true
	for z in 17:
		for y in 17:
			for x in 17:
				var corner := Vector3i(x, y, z)
				var reference: Vector3 = SURFACE._corner_normal(frame, Vector3(corner) - Vector3.ONE + origin)
				var actual: Vector3 = SURFACE._corner_normal_occupied(corner, occupancy)
				equal = equal and reference == actual
	expect(equal, "%s: all 4913 lattice corner normals match exactly" % label)


# The real direct build against the greedy round trip the exporter uses.
func _expect_end_to_end(fixture: Dictionary) -> void:
	var frame: VoxelFrame = fixture["frame"]
	var chunk: Vector3i = fixture["chunk"]
	var origin := Vector3(chunk * VoxelFrame.CHUNK_SIZE)
	var direct: VoxelMeshBuilder = BUILDER.new()
	direct.source_frame = frame
	direct.chunk_location = chunk
	direct.smooth_normals = true
	direct.texture_materials = true
	direct.run()
	var greedy: VoxelMeshBuilder = BUILDER.new()
	greedy.source_frame = frame
	greedy.chunk_location = chunk
	greedy.smooth_normals = true
	greedy.texture_materials = false
	greedy.run()
	var world_positions: PackedVector3Array = greedy.surface_arrays[Mesh.ARRAY_VERTEX]
	for index in world_positions.size():
		world_positions[index] += origin
	var welded: Array = greedy.surface_arrays.duplicate()
	welded[Mesh.ARRAY_VERTEX] = world_positions
	var always := func(_progress: int) -> bool: return true
	var bake: RefCounted = ATLAS.new()
	var reference: Array = SURFACE._build(welded, frame, Vector3.ZERO, bake, always, true)
	var direct_positions: PackedVector3Array = direct.surface_arrays[Mesh.ARRAY_VERTEX]
	for index in direct_positions.size():
		direct_positions[index] += origin
	direct.surface_arrays[Mesh.ARRAY_VERTEX] = direct_positions
	expect(reference[Mesh.ARRAY_VERTEX].size() > 0, "the direct build produces geometry")
	expect(_same_geometry(reference, direct.surface_arrays), "the direct textured build matches the greedy frame build")


# The same groups feed both paths, so the full arrays must match, indices included.
func _same_arrays(a: Array, b: Array) -> bool:
	if not _same_geometry(a, b):
		return false
	var a_indices: PackedInt32Array = a[Mesh.ARRAY_INDEX]
	var b_indices: PackedInt32Array = b[Mesh.ARRAY_INDEX]
	return a_indices == b_indices


# Positions and normals in the same order, like the viewport and export check.
func _same_geometry(a: Array, b: Array) -> bool:
	var a_positions: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var b_positions: PackedVector3Array = b[Mesh.ARRAY_VERTEX]
	var a_normals: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
	var b_normals: PackedVector3Array = b[Mesh.ARRAY_NORMAL]
	if a_positions.size() != b_positions.size() or a_normals.size() != b_normals.size():
		return false
	for index in a_positions.size():
		if a_positions[index].distance_to(b_positions[index]) > 0.0001:
			return false
		if a_normals[index].distance_to(b_normals[index]) > 0.0001:
			return false
	return true


func _solid(chunk: Vector3i, count: int) -> VoxelFrame:
	var frame := VoxelFrame.new()
	var material := VoxelFrame.material(Color.RED)
	var origin := chunk * VoxelFrame.CHUNK_SIZE
	for z in count:
		for y in count:
			for x in count:
				frame.set_cell(origin + Vector3i(x, y, z), material)
	return frame


func _seam() -> VoxelFrame:
	var frame := VoxelFrame.new()
	var red := VoxelFrame.material(Color.RED)
	var blue := VoxelFrame.material(Color.BLUE)
	for z in 16:
		for y in 16:
			frame.set_cell(Vector3i(15, y, z), red)
			frame.set_cell(Vector3i(16, y, z), blue)
	return frame


func _diagonal() -> VoxelFrame:
	var frame := VoxelFrame.new()
	frame.set_cell(Vector3i(15, 15, 0), VoxelFrame.material(Color.RED))
	frame.set_cell(Vector3i(16, 16, 0), VoxelFrame.material(Color.BLUE))
	return frame


func _opposite_corner() -> VoxelFrame:
	var frame := VoxelFrame.new()
	frame.set_cell(Vector3i(15, 15, 15), VoxelFrame.material(Color.RED))
	frame.set_cell(Vector3i(16, 16, 16), VoxelFrame.material(Color.BLUE))
	return frame


# A stored transparent voxel. `VoxelFrame.has` is true for it, but its color is
# transparent, so only the frame rule and the occupancy map count it.
func _transparent() -> VoxelFrame:
	var frame := VoxelFrame.new()
	frame.set_cell(Vector3i(5, 5, 5), VoxelFrame.material(Color.RED))
	_inject(frame, Vector3i(6, 5, 5), VoxelFrame.material(Color.TRANSPARENT))
	return frame


func _inject(frame: VoxelFrame, cell: Vector3i, cell_material: PackedFloat32Array) -> void:
	var location := VoxelFrame.chunk_position(cell)
	var chunk: VoxelFrame.Chunk = frame.chunks.get(location)
	if chunk == null:
		chunk = VoxelFrame.Chunk.new()
		chunk.location = location
		frame.chunks[location] = chunk
	chunk.store(cell, cell_material)
