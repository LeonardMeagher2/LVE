extends "res://tests/test.gd"

# The padded snapshot corner normals, and their in-process A/B, in one process.
#
# A direct textured build reads occupancy from its padded snapshot. The
# differential test compares that path with the frame-based reference on the same
# groups, so both must emit identical vertices, normals, and indices. Fixtures
# cover chunk boundaries, edges, corners, negative locations, and a stored
# transparent voxel. The A/B compares a frozen whole-surface build with the
# production one on independent group copies. Compare timings within one run.
# Only geometry parity is an assertion.
#
# Each test keeps the steps and checks of its original scene. The user arguments
# after `--` name the tests to run, so an old scene name still selects its own
# test.

const BUILDER := preload("res://Globals/Rendering/VoxelMeshBuilder.gd")
const SURFACE := preload("res://Globals/Rendering/VoxelSurface.gd")
const ATLAS := preload("res://Globals/Rendering/VoxelAtlas.gd")
const REPEATS := 5

var fixtures: Array = []


func _ready() -> void:
	timeout = 60.0
	test("the padded snapshot corner normals match the frame reference", _snapshot_normals, "snapshot_normals")
	test("snapshot normal performance and geometry parity", _bench_snapshot_normals, "_bench_snapshot_normals")


# Each test starts from fresh group state, so a test runs alone or in any order.
func _setup_test() -> void:
	fixtures = []


# --- snapshot_normals ---------------------------------------------------------

func _snapshot_normals() -> void:
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
	var pair: Array = _finish_pair(frame, origin, builder, colors, occupancy, materials, planes, always)
	var reference: Array = pair[0]
	var snapshot_result: Array = pair[1]
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


# The snapshot path and the frame path run on independent copies of the same
# groups, so the comparison isolates the normal source. Both paths share the
# padded snapshot inputs.
func _finish_pair(frame: VoxelFrame, origin: Vector3, builder: VoxelMeshBuilder, colors: PackedColorArray, occupancy: PackedInt32Array, materials: PackedFloat32Array, planes: PackedInt32Array, always: Callable) -> Array:
	var reference_bake: RefCounted = ATLAS.new()
	var snapshot_bake: RefCounted = ATLAS.new()
	var reference: Array = SURFACE._finish(builder._collect_groups(colors, occupancy, materials, planes), frame, origin, reference_bake, always, true)
	var snapshot_result: Array = SURFACE._finish(builder._collect_groups(colors, occupancy, materials, planes), frame, origin, snapshot_bake, always, true, occupancy)
	return [reference, snapshot_result]


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


# --- _bench_snapshot_normals --------------------------------------------------

func _bench_snapshot_normals() -> void:
	# One solid chunk with no neighbors, so every face is exposed and the build
	# produces geometry. The interior corners exercise the all-occupied read path.
	var frame := VoxelFrame.new()
	var material := VoxelFrame.material(Color.RED)
	var cells := {}
	for z in range(16, 32):
		for y in range(16, 32):
			for x in range(16, 32):
				cells[Vector3i(x, y, z)] = material
	frame.set_cells(cells)
	var chunk := Vector3i(1, 1, 1)
	var origin := Vector3(chunk * VoxelFrame.CHUNK_SIZE)
	var builder: VoxelMeshBuilder = BUILDER.new()
	var snapshot := BUILDER._snapshot(frame, chunk, true)
	var colors: PackedColorArray = snapshot[0]
	var occupancy: PackedInt32Array = snapshot[1]
	var materials: PackedFloat32Array = snapshot[2]
	var planes: PackedInt32Array = snapshot[3]
	var always := func(_progress: int) -> bool: return true

	_parity(frame, origin, builder, colors, occupancy, materials, planes, always)
	_corner_micro(frame, origin, occupancy)
	_full_build(frame, chunk, origin, builder, colors, occupancy, materials, planes)
	_material_rich()


func _parity(frame: VoxelFrame, origin: Vector3, builder: VoxelMeshBuilder, colors: PackedColorArray, occupancy: PackedInt32Array, materials: PackedFloat32Array, planes: PackedInt32Array, always: Callable) -> void:
	var pair: Array = _finish_pair(frame, origin, builder, colors, occupancy, materials, planes, always)
	var reference: Array = pair[0]
	var snapshot_result: Array = pair[1]
	var reference_positions: PackedVector3Array = reference[Mesh.ARRAY_VERTEX]
	var snapshot_positions: PackedVector3Array = snapshot_result[Mesh.ARRAY_VERTEX]
	var reference_normals: PackedVector3Array = reference[Mesh.ARRAY_NORMAL]
	var snapshot_normals: PackedVector3Array = snapshot_result[Mesh.ARRAY_NORMAL]
	var reference_indices: PackedInt32Array = reference[Mesh.ARRAY_INDEX]
	var snapshot_indices: PackedInt32Array = snapshot_result[Mesh.ARRAY_INDEX]
	print("parity: vertices %d vs %d, triangles %d vs %d" % [
		reference_positions.size(), snapshot_positions.size(),
		reference_indices.size() / 3, snapshot_indices.size() / 3,
	])
	print("parity: positions equal %s (max %f), normals equal %s (max %f), indices equal %s" % [
		reference_positions == snapshot_positions, _max_delta(reference_positions, snapshot_positions),
		reference_normals == snapshot_normals, _max_delta(reference_normals, snapshot_normals),
		reference_indices == snapshot_indices,
	])
	expect(reference_positions == snapshot_positions, "the two paths emit identical positions")
	expect(reference_normals == snapshot_normals, "the two paths emit identical normals")
	expect(reference_indices == snapshot_indices, "the two paths emit identical indices")


func _corner_micro(frame: VoxelFrame, origin: Vector3, occupancy: PackedInt32Array) -> void:
	var corners: Array[Vector3i] = []
	for z in range(1, 17):
		for y in range(1, 17):
			for x in range(1, 17):
				corners.append(Vector3i(x, y, z))
	print("corners %d" % corners.size())
	var warm := Vector3.ZERO
	for repeat in 3:
		var started_us := Time.get_ticks_usec()
		for corner: Vector3i in corners:
			warm += SURFACE._corner_normal(frame, Vector3(corner) - Vector3.ONE + origin)
		var frame_us := Time.get_ticks_usec() - started_us
		started_us = Time.get_ticks_usec()
		for corner: Vector3i in corners:
			warm += SURFACE._corner_normal_occupied(corner, occupancy)
		var snapshot_us := Time.get_ticks_usec() - started_us
		print("  corner run %d: frame %d us | snapshot %d us | %f" % [repeat, frame_us, snapshot_us, warm.length()])


# A full surface build per path. The groups and the atlas bake are the same, so
# the difference is the corner-normal source inside the emission.
func _full_build(frame: VoxelFrame, chunk: Vector3i, origin: Vector3, builder: VoxelMeshBuilder, colors: PackedColorArray, occupancy: PackedInt32Array, materials: PackedFloat32Array, planes: PackedInt32Array) -> void:
	var frame_us := 0
	var snapshot_us := 0
	var vertices := 0
	var started_us := 0
	for repeat in REPEATS:
		var frame_groups: Dictionary = builder._collect_groups(colors, occupancy, materials, planes)
		var frame_surface := SURFACE.new()
		started_us = Time.get_ticks_usec()
		frame_surface.run_groups(frame_groups, frame, origin, Callable(), true)
		frame_us += Time.get_ticks_usec() - started_us
		var snapshot_groups: Dictionary = builder._collect_groups(colors, occupancy, materials, planes)
		var snapshot_surface := SURFACE.new()
		started_us = Time.get_ticks_usec()
		snapshot_surface.run_groups(snapshot_groups, frame, origin, Callable(), true, occupancy)
		snapshot_us += Time.get_ticks_usec() - started_us
		vertices = frame_surface.arrays[Mesh.ARRAY_VERTEX].size()
	print("full run_groups: frame %d us | snapshot %d us | vertices %d" % [frame_us / REPEATS, snapshot_us / REPEATS, vertices])

	var direct: VoxelMeshBuilder = BUILDER.new()
	direct.source_frame = frame
	direct.chunk_location = chunk
	direct.smooth_normals = true
	direct.texture_materials = true
	started_us = Time.get_ticks_usec()
	direct.run()
	print("direct VoxelMeshBuilder.run: %d us | vertices %d" % [Time.get_ticks_usec() - started_us, direct.surface_arrays[Mesh.ARRAY_VERTEX].size()])


func _max_delta(a: PackedVector3Array, b: PackedVector3Array) -> float:
	var worst := 0.0
	for index in mini(a.size(), b.size()):
		worst = maxf(worst, a[index].distance_to(b[index]))
	return worst


# Repeat the surface comparison on the material-rich draw_latency fixture.
func _material_rich() -> void:
	var frame := VoxelFrame.new()
	var palette: Array[PackedFloat32Array] = []
	for index in 64:
		palette.append(VoxelFrame.material(Color.from_rgba8(index * 3, 255 - index * 3, index * 2), Color.BLACK, 0.2, 0.4))
	for z in 32:
		for y in 32:
			for x in 32:
				frame.set_cell(Vector3i(x, y, z), palette[(x + y + z) % 64])
	var chunk := Vector3i(1, 1, 1)
	var origin := Vector3(chunk * VoxelFrame.CHUNK_SIZE)
	var snapshot := BUILDER._snapshot(frame, chunk, true)
	var colors: PackedColorArray = snapshot[0]
	var occupancy: PackedInt32Array = snapshot[1]
	var materials: PackedFloat32Array = snapshot[2]
	var planes: PackedInt32Array = snapshot[3]
	var builder: VoxelMeshBuilder = BUILDER.new()
	var always := func(_progress: int) -> bool: return true
	print("material-rich 32-cube, 64 materials")
	_parity(frame, origin, builder, colors, occupancy, materials, planes, always)
	_full_build(frame, chunk, origin, builder, colors, occupancy, materials, planes)
