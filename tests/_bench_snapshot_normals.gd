extends "res://tests/test.gd"

# In-process A/B for the smooth corner normals. The reference reads the frame.
# The snapshot path reads the padded material map. Run one process:
#
#   godot --headless --path . res://tests/_bench_snapshot_normals.tscn
#
# Compare timings within this run. Only geometry parity is an assertion.

const BUILDER := preload("res://Globals/Rendering/VoxelMeshBuilder.gd")
const SURFACE := preload("res://Globals/Rendering/VoxelSurface.gd")
const ATLAS := preload("res://Globals/Rendering/VoxelAtlas.gd")
const REPEATS := 5


func _ready() -> void:
	timeout = 60.0
	test("snapshot normal performance and geometry parity", _run)


func _run() -> void:
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
	var reference_bake: RefCounted = ATLAS.new()
	var snapshot_bake: RefCounted = ATLAS.new()
	var reference: Array = SURFACE._finish(builder._collect_groups(colors, occupancy, materials, planes), frame, origin, reference_bake, always, true)
	var snapshot_result: Array = SURFACE._finish(builder._collect_groups(colors, occupancy, materials, planes), frame, origin, snapshot_bake, always, true, occupancy)
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
