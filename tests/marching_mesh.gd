extends "res://tests/test.gd"


const MARCH := preload("res://Globals/Rendering/VoxelMarchingMeshBuilder.gd")

var _seed := 1
var _builder
var _renderer
var _bar
var _dialog
var _block_mesh: Mesh
var _closed_ok := true
var _non_empty_ok := true


func _ready() -> void:
	test("a single voxel makes a closed eight-triangle surface", _single_voxel, "march_single_voxel")
	test("a single voxel in a negative chunk keeps the same shape", _negative_voxel, "march_single_voxel_negative")
	test("two adjacent voxels merge into one closed surface", _adjacent_voxels, "march_adjacent_voxels")
	test("random layouts stay closed across chunk seams", _random_layouts, "march_watertight")
	test("a slice drops the cells outside its layers", _slice, "march_slice")
	test("a solid 2x2x2 block stays closed", _solid_block, "march_solid_block")
	test("a 16-cell slab spans the chunk", _slab, "march_slab")
	test("a hollow shell keeps its inner cavity", _hollow_shell, "march_hollow_shell")
	test("the low-poly style renders in the editor viewport", _viewport_style, "march_viewport_style")
	test("the settings modal stores one undoable style change", _style_undo, "march_style_undo")
	test("a diagonal pair draws one bridged surface in the viewport", _bridge_viewport, "march_bridge_viewport")


func _single_voxel() -> void:
	step("Given one voxel at the chunk origin", func():
		var frame := VoxelFrame.new()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color(0.8, 0.2, 0.1)))
		_builder = _march(frame, Vector3i.ZERO)
	)
	step("Then the surface is a closed octahedron inside the cell", func():
		var arrays: Array = _builder.surface_arrays
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		expect(indices.size() == 24, "the octahedron has eight triangles")
		expect(positions.size() == 24, "every triangle owns three vertices")
		expect(_closed(positions, indices), "every edge has an opposite partner, so the surface has no boundary")
		var box := _bounds(positions)
		expect(box.position.is_equal_approx(Vector3.ONE * -0.5), "the surface starts at the negative cell corner")
		expect(box.size.is_equal_approx(Vector3.ONE), "the surface fills one voxel")
		var outward := true
		for offset in range(0, indices.size(), 3):
			var centroid := (positions[indices[offset]] + positions[indices[offset + 1]] + positions[indices[offset + 2]]) / 3.0
			if normals[indices[offset]].dot(centroid) <= 0.0:
				outward = false
		expect(outward, "every normal points away from the voxel")
		var front_facing := true
		for offset in range(0, indices.size(), 3):
			var winding := (positions[indices[offset + 1]] - positions[indices[offset]]).cross(positions[indices[offset + 2]] - positions[indices[offset]])
			if winding.dot(normals[indices[offset]]) >= 0.0:
				front_facing = false
		expect(front_facing, "the winding is clockwise as Godot front faces require")
		var colored := true
		for color in colors:
			if not color.is_equal_approx(Color(0.8, 0.2, 0.1)):
				colored = false
		expect(colored, "every vertex carries the voxel color")
	)


func _negative_voxel() -> void:
	step("Given one voxel at the far corner of a negative chunk", func():
		var frame := VoxelFrame.new()
		frame.set_cell(Vector3i(-1, -1, -1), VoxelFrame.material(Color.WHITE))
		_builder = _march(frame, Vector3i(-1, -1, -1))
	)
	step("Then the surface sits around that cell", func():
		var positions: PackedVector3Array = _builder.surface_arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = _builder.surface_arrays[Mesh.ARRAY_INDEX]
		expect(indices.size() == 24, "the octahedron has eight triangles")
		expect(_closed(positions, indices), "the negative chunk surface is closed")
		var box := _bounds(positions)
		expect(box.position.is_equal_approx(Vector3.ONE * 14.5), "the surface starts at the cell's negative corner")
		expect(box.size.is_equal_approx(Vector3.ONE), "the surface fills one voxel")
	)


func _adjacent_voxels() -> void:
	step("Given two voxels that share a face", func():
		var frame := VoxelFrame.new()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.WHITE))
		frame.set_cell(Vector3i(1, 0, 0), VoxelFrame.material(Color.WHITE))
		_builder = _march(frame, Vector3i.ZERO)
	)
	step("Then the shared face is gone and the surface stays closed", func():
		var positions: PackedVector3Array = _builder.surface_arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = _builder.surface_arrays[Mesh.ARRAY_INDEX]
		expect(_closed(positions, indices), "the merged surface is closed")
		var shared_vertex := false
		for position in positions:
			if position.is_equal_approx(Vector3(0.5, 0.0, 0.0)):
				shared_vertex = true
		expect(not shared_vertex, "no vertex remains on the shared face")
		var box := _bounds(positions)
		expect(box.position.x <= -0.499 and box.end.x >= 1.499, "the surface spans both cells")
	)


func _random_layouts() -> void:
	step("When eight pseudo-random layouts are meshed across eight chunks", func():
		_closed_ok = true
		_non_empty_ok = true
		for index in 8:
			var frame := _random_frame(index)
			var merged := _march_region(frame)
			var positions: PackedVector3Array = merged[0]
			var indices: PackedInt32Array = merged[1]
			if indices.is_empty():
				_non_empty_ok = false
			elif not _closed(positions, indices):
				_closed_ok = false
	)
	step("Then every layout is closed and non-empty", func():
		expect(_non_empty_ok, "the random layouts produce surfaces")
		expect(_closed_ok, "every random layout is closed across chunk seams")
	)


func _slice() -> void:
	step("Given two voxels in a line and a one-layer slice", func():
		var frame := VoxelFrame.new()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.WHITE))
		frame.set_cell(Vector3i(1, 0, 0), VoxelFrame.material(Color.WHITE))
		_builder = MARCH.new()
		_builder.source_frame = frame
		_builder.chunk_location = Vector3i.ZERO
		_builder.slice_axis = 0
		_builder.slice_index = 0
		_builder.slice_count = 1
		_builder.run()
	)
	step("Then only the sliced voxel keeps a surface", func():
		var positions: PackedVector3Array = _builder.surface_arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = _builder.surface_arrays[Mesh.ARRAY_INDEX]
		expect(indices.size() == 24, "the slice keeps one voxel and its eight triangles")
		expect(_closed(positions, indices), "the sliced surface has no boundary")
		var box := _bounds(positions)
		expect(box.end.x <= 0.5001, "nothing extends past the sliced voxel")
	)


func _viewport_style() -> void:
	step("Given one voxel and the block style", func():
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.frames_changed.emit()
		_renderer = editor_viewport().get_node("ViewportScene/VoxelRenderer")
	)
	await _settle()
	step("When the document switches to the low-poly style", func():
		_block_mesh = _renderer._chunk_instances[Vector3i.ZERO].mesh
		State.set_mesh_style(1, false)
	)
	await _settle()
	step("Then the chunk draws a marching-cubes surface", func():
		var mesh: Mesh = _renderer._chunk_instances[Vector3i.ZERO].mesh
		expect(mesh != null, "the low-poly chunk has a mesh")
		expect(mesh != _block_mesh, "the style change replaces the chunk mesh")
		if mesh != null:
			var arrays := mesh.surface_get_arrays(0)
			expect(arrays[Mesh.ARRAY_INDEX].size() == 24, "one voxel becomes an eight-triangle octahedron")
			expect(arrays[Mesh.ARRAY_COLOR] is PackedColorArray, "the low-poly mesh carries voxel colors")
		if DisplayServer.get_name() != "headless":
			RenderingServer.force_draw()
			get_tree().root.get_texture().get_image().save_png(_dir() + "/low_poly_voxel.png")
	)
	step("When the style returns to blocks", func():
		State.set_mesh_style(0, false)
	)
	await _settle()
	step("Then the block surface returns from the cache", func():
		expect(_renderer._chunk_instances[Vector3i.ZERO].mesh == _block_mesh, "the style is part of the surface key")
	)


func _solid_block() -> void:
	step("Given a solid 2x2x2 block", func():
		var frame := VoxelFrame.new()
		var cells := {}
		for z in 2:
			for y in 2:
				for x in 2:
					cells[Vector3i(x, y, z)] = VoxelFrame.material(Color.WHITE)
		frame.set_cells(cells)
		_builder = _march(frame, Vector3i.ZERO)
	)
	step("Then the surface is closed around the block", func():
		var positions: PackedVector3Array = _builder.surface_arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = _builder.surface_arrays[Mesh.ARRAY_INDEX]
		expect(_closed(positions, indices), "the block surface has no boundary")
		var box := _bounds(positions)
		expect(box.position.is_equal_approx(Vector3.ONE * -0.5), "the block surface starts at the outer corner")
		expect(box.size.is_equal_approx(Vector3.ONE * 2.0), "the block surface fills the two-cell extent")
	)


func _slab() -> void:
	step("Given sixteen voxels in a line", func():
		var frame := VoxelFrame.new()
		var cells := {}
		for x in VoxelFrame.CHUNK_SIZE:
			cells[Vector3i(x, 0, 0)] = VoxelFrame.material(Color.WHITE)
		frame.set_cells(cells)
		_builder = _march(frame, Vector3i.ZERO)
	)
	step("Then the surface spans the whole line and stays closed", func():
		var positions: PackedVector3Array = _builder.surface_arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = _builder.surface_arrays[Mesh.ARRAY_INDEX]
		expect(_closed(positions, indices), "the slab surface has no boundary")
		var box := _bounds(positions)
		expect(box.size.is_equal_approx(Vector3(16.0, 1.0, 1.0)), "the slab keeps its length and thickness")
	)


func _hollow_shell() -> void:
	step("Given a hollow three-cube shell", func():
		var frame := VoxelFrame.new()
		var cells := {}
		for z in range(-1, 2):
			for y in range(-1, 2):
				for x in range(-1, 2):
					if x == 0 and y == 0 and z == 0:
						continue
					cells[Vector3i(x, y, z)] = VoxelFrame.material(Color.WHITE)
		frame.set_cells(cells)
		_builder = _march_region(frame)
	)
	step("Then the shell and its cavity are both closed", func():
		var positions: PackedVector3Array = _builder[0]
		var indices: PackedInt32Array = _builder[1]
		expect(_closed(positions, indices), "the shell surface has no boundary")
		var reaches_centre := false
		for position in positions:
			if Vector3(position).length() <= 0.8:
				reaches_centre = true
		expect(reaches_centre, "the inner cavity has its own surface")
		var box := _bounds(positions)
		expect(box.size.is_equal_approx(Vector3.ONE * 3.0), "the shell keeps its three-cell extent")
	)


func _style_undo() -> void:
	step("Given the document settings modal and the block style", func():
		_bar = main.get_node("%MenuBar")
		_dialog = _bar.get_node("DocumentSettingsModal")
		_renderer = editor_viewport().get_node("ViewportScene/VoxelRenderer")
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.frames_changed.emit()
	)
	await _settle()
	step("When the user picks Low Poly and confirms", func():
		_bar.get_node("ModelSettingsBtn").pressed.emit()
		_dialog.get_node("Margin/Layout/StyleRow/Low").button_pressed = true
		_dialog.confirmed.emit()
		_dialog.hide()
	)
	await _settle()
	step("Then the document stores one undoable style change", func():
		expect(State.document.mesh_style == 1, "the document stores the low-poly style")
		expect(State.undo_redo.has_undo(), "the style change has an undo step")
	)
	step("When the user undoes the style change", func():
		State.undo_redo.undo()
	)
	await _settle()
	step("Then the blocks and the modal selection return", func():
		expect(State.document.mesh_style == 0, "undo restores the block style")
		_bar.get_node("ModelSettingsBtn").pressed.emit()
		expect(_dialog.get_node("Margin/Layout/StyleRow/Blocks").button_pressed, "the modal shows the block style")
		_dialog.hide()
	)


func _bridge_viewport() -> void:
	step("Given two diagonal voxels and the low-poly style", func():
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.get_current_voxel_frame().set_cell(Vector3i(1, 1, 0), VoxelFrame.material(Color.RED))
		State.frames_changed.emit()
		_renderer = editor_viewport().get_node("ViewportScene/VoxelRenderer")
		State.set_mesh_style(1, false)
	)
	await _settle()
	step("Then the chunk draws the bridged pair", func():
		var mesh: Mesh = _renderer._chunk_instances[Vector3i.ZERO].mesh
		expect(mesh != null, "the bridged chunk has a mesh")
		if mesh != null:
			var positions: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
			expect(_has_gap_face(positions, indices), "the viewport fills the gap")
		if DisplayServer.get_name() != "headless":
			RenderingServer.force_draw()
			get_tree().root.get_texture().get_image().save_png(_dir() + "/low_poly_bridge.png")
	)


func _settle() -> void:
	while not _renderer.is_settled():
		await get_tree().process_frame
	await get_tree().process_frame


func _random_frame(seed: int) -> VoxelFrame:
	_seed = seed * 7919 + 104729
	var frame := VoxelFrame.new()
	var cells := {}
	for z in range(-2, 3):
		for y in range(-2, 3):
			for x in range(-2, 3):
				_seed = (_seed * 1103515245 + 12345) & 0x7fffffff
				if _seed % 100 < 45:
					cells[Vector3i(x, y, z)] = VoxelFrame.material(Color.WHITE)
	if cells.is_empty():
		cells[Vector3i.ZERO] = VoxelFrame.material(Color.WHITE)
	frame.set_cells(cells)
	return frame


func _march(frame: VoxelFrame, location: Vector3i):
	var builder = MARCH.new()
	builder.source_frame = frame
	builder.chunk_location = location
	builder.run()
	return builder


func _march_region(frame: VoxelFrame) -> Array:
	var positions := PackedVector3Array()
	var indices := PackedInt32Array()
	for z in range(-1, 1):
		for y in range(-1, 1):
			for x in range(-1, 1):
				var location := Vector3i(x, y, z)
				var builder = _march(frame, location)
				var offset := Vector3(location * VoxelFrame.CHUNK_SIZE)
				var first := positions.size()
				for position: Vector3 in builder.surface_arrays[Mesh.ARRAY_VERTEX]:
					positions.append(position + offset)
				for vertex: int in builder.surface_arrays[Mesh.ARRAY_INDEX]:
					indices.append(first + vertex)
	return [positions, indices]


func _bounds(positions: PackedVector3Array) -> AABB:
	var box := AABB(positions[0], Vector3.ZERO)
	for position in positions:
		box = box.expand(position)
	return box


func _closed(positions: PackedVector3Array, indices: PackedInt32Array) -> bool:
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


func _has_gap_face(positions: PackedVector3Array, indices: PackedInt32Array) -> bool:
	for offset in range(0, indices.size(), 3):
		var centroid := (positions[indices[offset]] + positions[indices[offset + 1]] + positions[indices[offset + 2]]) / 3.0
		if centroid.x > 0.3 and centroid.x < 0.7 and centroid.y > 0.3 and centroid.y < 0.7 and absf(centroid.z) > 0.25:
			return true
	return false
