extends "res://tests/test.gd"


const MARCH := preload("res://Globals/Rendering/VoxelMarchingMeshBuilder.gd")

var _builder
var _positions := PackedVector3Array()
var _indices := PackedInt32Array()
var _fills := 0


func _ready() -> void:
	test("a same-material diagonal pair joins with a filled gap", _diagonal_pair, "bridge_diagonal_pair")
	test("a same-material corner pair joins through the block", _corner_pair, "bridge_corner_pair")
	test("different materials do not join", _different_materials, "bridge_different_materials")
	test("a third material blocks the gap", _third_material, "bridge_third_material")
	test("a concave corner stays open", _concave_corner, "bridge_concave_corner")
	test("a mixed-material concave corner stays open", _mixed_concave_corner, "bridge_mixed_concave")
	test("a gap across four chunks joins without a seam", _chunk_seam, "bridge_chunk_seam")


func _diagonal_pair() -> void:
	step("Given two same-material voxels that share an edge", func():
		var frame := VoxelFrame.new()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.WHITE))
		frame.set_cell(Vector3i(1, 1, 0), VoxelFrame.material(Color.WHITE))
		_builder = _march(frame, Vector3i.ZERO)
	)
	step("Then both gap cells fill", func():
		var positions: PackedVector3Array = _builder.surface_arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = _builder.surface_arrays[Mesh.ARRAY_INDEX]
		expect(_builder.bridge_cells == 2, "both gap cells fill")
		expect(_builder.rejected_third_material == 0, "no gap is rejected")
		expect(_closed(positions, indices), "the joined pair has no boundary")
		expect(_components(positions, indices) == 1, "the pair is one surface")
		expect(_has_gap_face(positions, indices), "the gap holds a filled face and not a pinch")
	)


func _corner_pair() -> void:
	step("Given two same-material voxels that share a corner", func():
		var frame := VoxelFrame.new()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.WHITE))
		frame.set_cell(Vector3i(1, 1, 1), VoxelFrame.material(Color.WHITE))
		_builder = _march(frame, Vector3i.ZERO)
	)
	step("Then the block between them fills", func():
		var positions: PackedVector3Array = _builder.surface_arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = _builder.surface_arrays[Mesh.ARRAY_INDEX]
		expect(_builder.bridge_cells == 6, "the six cells between the pair fill")
		expect(_closed(positions, indices), "the corner pair has no boundary")
		expect(_components(positions, indices) == 1, "the corner pair is one surface")
		expect(_bounds(positions).is_equal_approx(AABB(Vector3.ONE * -0.5, Vector3.ONE * 2.0)), "the pair fills the two-cell block")
		var touches_contact := false
		for position in positions:
			if position.is_equal_approx(Vector3.ONE * 0.5):
				touches_contact = true
		expect(not touches_contact, "the join does not pinch at one point")
	)


func _different_materials() -> void:
	step("Given two diagonal voxels of different materials", func():
		var frame := VoxelFrame.new()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.WHITE))
		frame.set_cell(Vector3i(1, 1, 0), VoxelFrame.material(Color.RED))
		_builder = _march(frame, Vector3i.ZERO)
	)
	step("Then the surfaces stay apart", func():
		var positions: PackedVector3Array = _builder.surface_arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = _builder.surface_arrays[Mesh.ARRAY_INDEX]
		expect(_builder.bridge_cells == 0, "no gap cell is filled")
		expect(indices.size() == 48, "the pair keeps sixteen triangles")
		expect(_closed(positions, indices), "both blobs have no boundary")
		expect(_components(positions, indices) == 2, "different materials do not join")
	)


func _third_material() -> void:
	step("Given a white diagonal pair with a red voxel beside one gap", func():
		var frame := VoxelFrame.new()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.WHITE))
		frame.set_cell(Vector3i(1, 1, 0), VoxelFrame.material(Color.WHITE))
		frame.set_cell(Vector3i(2, 0, 0), VoxelFrame.material(Color.RED))
		_builder = _march(frame, Vector3i.ZERO)
	)
	step("Then the tainted gap is skipped and the clean gap joins", func():
		var positions: PackedVector3Array = _builder.surface_arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = _builder.surface_arrays[Mesh.ARRAY_INDEX]
		expect(_builder.rejected_third_material == 1, "the gap beside the red voxel is skipped")
		expect(_builder.bridge_cells == 1, "the clean white gap fills")
		expect(_closed(positions, indices), "the pair has no boundary")
	)


func _concave_corner() -> void:
	step("Given three same-material voxels that form an L", func():
		var frame := VoxelFrame.new()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.WHITE))
		frame.set_cell(Vector3i(1, 0, 0), VoxelFrame.material(Color.WHITE))
		frame.set_cell(Vector3i(0, 1, 0), VoxelFrame.material(Color.WHITE))
		_builder = _march(frame, Vector3i.ZERO)
	)
	step("Then the notch stays open", func():
		var positions: PackedVector3Array = _builder.surface_arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = _builder.surface_arrays[Mesh.ARRAY_INDEX]
		expect(_builder.bridge_cells == 0, "no cell is added to the L")
		expect(_closed(positions, indices), "the L surface has no boundary")
		expect(not _fills_notch(positions), "the concave notch is not filled")
	)


func _mixed_concave_corner() -> void:
	step("Given an L whose arms have different materials", func():
		var frame := VoxelFrame.new()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.WHITE))
		frame.set_cell(Vector3i(1, 0, 0), VoxelFrame.material(Color.RED))
		frame.set_cell(Vector3i(0, 1, 0), VoxelFrame.material(Color.WHITE))
		_builder = _march(frame, Vector3i.ZERO)
	)
	step("Then the notch stays open", func():
		var positions: PackedVector3Array = _builder.surface_arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = _builder.surface_arrays[Mesh.ARRAY_INDEX]
		expect(_builder.bridge_cells == 0, "no cell is added to the mixed L")
		expect(_closed(positions, indices), "the mixed L surface has no boundary")
		expect(not _fills_notch(positions), "different materials do not fill the notch")
	)


func _chunk_seam() -> void:
	step("Given a diagonal pair that straddles four chunks", func():
		var frame := VoxelFrame.new()
		frame.set_cell(Vector3i(15, 15, 0), VoxelFrame.material(Color.WHITE))
		frame.set_cell(Vector3i(16, 16, 0), VoxelFrame.material(Color.WHITE))
		var positions := PackedVector3Array()
		var indices := PackedInt32Array()
		_fills = 0
		for location: Vector3i in [Vector3i.ZERO, Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(1, 1, 0)]:
			var builder = _march(frame, location)
			_fills += builder.bridge_cells
			var offset := Vector3(location * VoxelFrame.CHUNK_SIZE)
			var first := positions.size()
			for position: Vector3 in builder.surface_arrays[Mesh.ARRAY_VERTEX]:
				positions.append(position + offset)
			for vertex: int in builder.surface_arrays[Mesh.ARRAY_INDEX]:
				indices.append(first + vertex)
		_positions = positions
		_indices = indices
	)
	step("Then the pair joins without a seam or a duplicate", func():
		expect(_fills >= 2, "each gap cell is filled in every chunk that samples it")
		expect(_closed(_positions, _indices), "the seam has no boundary")
		expect(_components(_positions, _indices) == 1, "the seam keeps one surface")
	)


func _march(frame: VoxelFrame, location: Vector3i):
	var builder = MARCH.new()
	builder.source_frame = frame
	builder.chunk_location = location
	builder.run()
	return builder


func _bounds(positions: PackedVector3Array) -> AABB:
	var box := AABB(positions[0], Vector3.ZERO)
	for position in positions:
		box = box.expand(position)
	return box


func _has_gap_face(positions: PackedVector3Array, indices: PackedInt32Array) -> bool:
	for offset in range(0, indices.size(), 3):
		var centroid := (positions[indices[offset]] + positions[indices[offset + 1]] + positions[indices[offset + 2]]) / 3.0
		if centroid.x > 0.3 and centroid.x < 0.7 and centroid.y > 0.3 and centroid.y < 0.7 and absf(centroid.z) > 0.25:
			return true
	return false


func _fills_notch(positions: PackedVector3Array) -> bool:
	for position in positions:
		if position.x > 1.3 and position.y > 0.8 and position.y < 1.2:
			return true
	return false


func _closed(positions: PackedVector3Array, indices: PackedInt32Array) -> bool:
	var canonical := _weld(positions)
	var edges := {}
	for offset in range(0, indices.size(), 3):
		for corner in 3:
			var start := canonical[indices[offset + corner]]
			var end := canonical[indices[offset + (corner + 1) % 3]]
			var key := Vector2i(start, end)
			edges[key] = edges.get(key, 0) + 1
	for key: Vector2i in edges:
		if not edges.has(Vector2i(key.y, key.x)):
			return false
		if edges[key] != edges[Vector2i(key.y, key.x)]:
			return false
	return not edges.is_empty()


func _components(positions: PackedVector3Array, indices: PackedInt32Array) -> int:
	var canonical := _weld(positions)
	var vertex_triangles: Array = []
	vertex_triangles.resize(canonical.size())
	for index in canonical.size():
		vertex_triangles[index] = []
	var triangle_count := indices.size() / 3
	for triangle in triangle_count:
		for corner in 3:
			vertex_triangles[canonical[indices[triangle * 3 + corner]]].append(triangle)
	var visited := PackedByteArray()
	visited.resize(triangle_count)
	var components := 0
	for triangle in triangle_count:
		if visited[triangle] != 0:
			continue
		components += 1
		var stack: Array[int] = [triangle]
		visited[triangle] = 1
		while not stack.is_empty():
			var current: int = stack.pop_back()
			for corner in 3:
				for neighbor: int in vertex_triangles[canonical[indices[current * 3 + corner]]]:
					if visited[neighbor] == 0:
						visited[neighbor] = 1
						stack.append(neighbor)
	return components


func _weld(positions: PackedVector3Array) -> PackedInt32Array:
	var welded := {}
	var canonical := PackedInt32Array()
	canonical.resize(positions.size())
	for index in positions.size():
		var key := Vector3i(
			roundi(positions[index].x * 1024.0),
			roundi(positions[index].y * 1024.0),
			roundi(positions[index].z * 1024.0)
		)
		if not welded.has(key):
			welded[key] = welded.size()
		canonical[index] = welded[key]
	return canonical
