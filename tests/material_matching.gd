extends "res://tests/test.gd"

var fill: Node
var wand: Node
var frame: VoxelFrame


func _ready() -> void:
	test("Fill and Wand match the full voxel material, not only the color", _run)


func _run() -> void:
	step("Given same-color voxels with different materials", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i(0, 0, 0), _metal_red())
		frame.set_cell(Vector3i(1, 0, 0), VoxelFrame.material(Color.RED))
		frame.set_cell(Vector3i(20, 0, 0), _metal_red())
		frame.set_cell(Vector3i(0, 2, 0), VoxelFrame.material(Color.RED, Color(0.5, 0.0, 0.0)))
		activate_tool("fill")
		fill = plugin("FillPlugin")._tool
		State.current_material = VoxelFrame.material(Color.GREEN)
		State.undo_redo.clear_history()
	)

	step("When the user fills the metal voxel with Connected on", func():
		fill._settings.connected = true
		_fill(Vector3i.ZERO)
	)
	await _settle_fill()
	step("Then the connected search stops at the same-color voxel with another material", func():
		expect(frame.matches(Vector3i.ZERO, VoxelFrame.material(Color.GREEN)), "the clicked voxel takes the fill material")
		expect(frame.matches(Vector3i(1, 0, 0), VoxelFrame.material(Color.RED)), "the plain red neighbor keeps its material")
		expect(frame.matches(Vector3i(20, 0, 0), _metal_red()), "the disconnected metal voxel keeps its material")
	)

	step("When the user turns Connected off and fills the same voxel", func():
		frame.set_cell(Vector3i.ZERO, _metal_red())
		fill._settings.connected = false
		_fill(Vector3i.ZERO)
	)
	await _settle_fill()
	step("Then every voxel with the same full material takes the fill material", func():
		expect(frame.matches(Vector3i.ZERO, VoxelFrame.material(Color.GREEN)), "the clicked voxel takes the fill material")
		expect(frame.matches(Vector3i(20, 0, 0), VoxelFrame.material(Color.GREEN)), "the distant voxel in another chunk takes the fill material")
		expect(frame.matches(Vector3i(1, 0, 0), VoxelFrame.material(Color.RED)), "the same-color voxel with another metallic keeps its material")
		expect(frame.matches(Vector3i(0, 2, 0), VoxelFrame.material(Color.RED, Color(0.5, 0.0, 0.0))), "the same-color voxel with emission keeps its material")
	)

	step("Given a frame with the same materials and the Wand tool", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i(0, 0, 0), _metal_red())
		frame.set_cell(Vector3i(1, 0, 0), VoxelFrame.material(Color.RED))
		frame.set_cell(Vector3i(20, 0, 0), _metal_red())
		activate_tool("selection")
		select_toolbar_item("selection", "Wand")
		wand = plugin("SelectionPlugin")._wand
	)
	step("When the user selects the metal voxel with Connected off", func():
		wand._settings.connected = false
		wand._settings.mode = wand._settings.SelectMode.REPLACE
		wand._commit(Vector3i.ZERO)
	)
	await _settle_wand()
	step("Then the selection holds only the voxels with the same full material", func():
		expect(State.selection.contains(Vector3i.ZERO), "the clicked voxel is selected")
		expect(State.selection.contains(Vector3i(20, 0, 0)), "the distant voxel with the same material is selected")
		expect(not State.selection.contains(Vector3i(1, 0, 0)), "the same-color voxel with another metallic stays unselected")
		expect(State.selection.count() == 2, "the selection holds only the two metal voxels")
	)

	step("Given mirrored voxels with different materials", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i(2, 0, 2), _metal_red())
		frame.set_cell(Vector3i(2, 0, 4), _metal_red())
		frame.set_cell(Vector3i(-2, 0, 2), VoxelFrame.material(Color.RED))
		frame.set_cell(Vector3i(-2, 0, 4), _metal_red())
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3.ZERO
		activate_tool("fill")
		fill._settings.connected = false
		State.current_material = VoxelFrame.material(Color.GREEN)
		State.undo_redo.clear_history()
	)
	step("When the user fills the metal voxels with the X plane enabled", func():
		_fill(Vector3i(2, 0, 2))
	)
	await _settle_fill()
	step("Then the mirror recolors a matching voxel and keeps a different material", func():
		expect(frame.matches(Vector3i(2, 0, 2), VoxelFrame.material(Color.GREEN)), "the source voxel takes the fill material")
		expect(frame.matches(Vector3i(2, 0, 4), VoxelFrame.material(Color.GREEN)), "the second source voxel takes the fill material")
		expect(frame.matches(Vector3i(-2, 0, 4), VoxelFrame.material(Color.GREEN)), "the mirrored voxel with the same material takes the fill material")
		expect(frame.matches(Vector3i(-2, 0, 2), VoxelFrame.material(Color.RED)), "the mirrored voxel with another material keeps its material")
		State.symmetry_axes = 0
		State.undo_redo.undo()
		expect(frame.matches(Vector3i(2, 0, 2), _metal_red()), "one undo restores every filled voxel")
	)


func _fill(seed_cell: Vector3i) -> void:
	fill._release_pending = true
	fill._queue_seed(seed_cell)


func _settle_fill() -> void:
	while not fill.is_settled() or not fill._search_jobs.is_empty() or State.edit_busy():
		await get_tree().process_frame


func _settle_wand() -> void:
	while wand._job != null or State.edit_busy():
		await get_tree().process_frame


func _metal_red() -> PackedFloat32Array:
	return VoxelFrame.material(Color.RED, VoxelFrame.DEFAULT_EMISSION, 0.8, 0.5)
