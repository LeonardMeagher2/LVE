extends "res://tests/test.gd"

var matte := VoxelFrame.material(Color.RED, Color(0.5, 0.25, 0.125), 0.0, 0.25)
var metal := VoxelFrame.material(Color.RED, Color(0.5, 0.25, 0.125), 1.0, 0.25)
var blue := VoxelFrame.material(Color.BLUE, Color(0.125, 0.5, 0.25), 0.25, 0.75)
var unsaved := VoxelFrame.material(Color.RED, Color(0.5, 0.25, 0.125), 1.0, 0.5)
var viewport: SubViewport
var brush: Node
var settings: Resource
var frame: VoxelFrame
var palette_before: Array


func _ready() -> void:
	timeout = 30.0
	test("drawing tools paint full materials and preserve copied voxel materials", _run)


func _run() -> void:
	step("Given a material brush with symmetry and a selection mask", func():
		viewport = editor_viewport()
		viewport.get_parent().stretch = false
		viewport.size = Vector2i(800, 500)
		brush = plugin("BrushPlugin")
		settings = brush._settings
		_reset(metal)
		State.symmetry_origin = Vector3.ZERO
		State.symmetry_axes = 5
		State.selection.add(Vector3i(2, 0, 3))
		State.selection.add(Vector3i(-2, 0, 3))
		State.selection_changed.emit()
		State.undo_redo.clear_history()
	)
	step("When the user draws one Pencil stroke", func():
		_click(Vector3(2, -0.5, 3))
	)
	await _settle()
	step("Then Pencil paints the full material within the selection", func():
		expect(frame.count() == 2, "the selection admits only two reflected voxels")
		expect(_same_material(Vector3i(2, 0, 3), metal), "the Pencil voxel has every selected material value")
		expect(_same_material(Vector3i(-2, 0, 3), metal), "the reflected voxel has every selected material value")
		expect(not frame.has(Vector3i(2, 0, -3)), "the excluded reflection stays empty")
		expect(State.selection.count() == 2, "the stroke preserves the selection mask")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo removes both material voxels")
		expect(not State.undo_redo.has_undo(), "the Pencil stroke creates one undo action")
		State.undo_redo.redo()
		expect(_same_material(Vector3i(2, 0, 3), metal), "redo restores the Pencil material")
		expect(_same_material(Vector3i(-2, 0, 3), metal), "redo restores the reflected material")
	)
	step("Given an occupied voxel with the same color and different metallic", func():
		_reset(metal)
		frame.set_cell(Vector3i.ZERO, matte)
		select_toolbar_item("Toolbar", "Paint")
		sync_viewport()
		State.undo_redo.clear_history()
	)
	step("When the user paints the occupied voxel", func():
		_click(Vector3(0, 0.5, 0))
	)
	await _settle()
	step("Then Paint replaces the material without adding a voxel", func():
		expect(frame.count() == 1, "Paint preserves the occupied voxel count")
		expect(_same_material(Vector3i.ZERO, metal), "Paint replaces metallic even when the color matches")
		State.undo_redo.undo()
		expect(_same_material(Vector3i.ZERO, matte), "undo restores the previous Paint material")
		expect(not State.undo_redo.has_undo(), "the Paint stroke creates one undo action")
		State.undo_redo.redo()
		expect(_same_material(Vector3i.ZERO, metal), "redo restores every Paint material value")
	)
	step("Given a Line brush crossing an existing voxel", func():
		_reset(metal)
		frame.set_cell(Vector3i.RIGHT, matte)
		select_toolbar_item("Toolbar", "Line")
		sync_viewport()
		State.undo_redo.clear_history()
	)
	step("When the user previews a line across the voxel", func():
		_click(Vector3(0, -0.5, 0))
		_motion(Vector3(3, -0.5, 0))
	)
	await _settle()
	step("Then the preview preserves the document and undo history", func():
		expect(frame.count() == 1 and _same_material(Vector3i.RIGHT, matte), "the preview leaves the existing material unchanged")
		expect(not State.undo_redo.has_undo(), "the line preview adds no undo action")
	)
	step("When the user commits the line", func():
		_click(Vector3(3, -0.5, 0))
	)
	await _settle()
	step("Then Line paints new and existing voxels with one material", func():
		expect(frame.count() == 4, "the line contains four voxels")
		for x in 4:
			expect(_same_material(Vector3i(x, 0, 0), metal), "each line voxel has the full selected material")
		State.undo_redo.undo()
		expect(frame.count() == 1 and _same_material(Vector3i.RIGHT, matte), "one undo restores the original line contents")
		expect(not State.undo_redo.has_undo(), "the line creates one undo action")
		State.undo_redo.redo()
		expect(_same_material(Vector3i.RIGHT, metal), "redo restores the replacement line material")
	)
	step("Given connected and separate voxels with the same color", func():
		_reset(metal)
		frame.set_cells({Vector3i.ZERO: matte, Vector3i.RIGHT: unsaved, Vector3i(4, 0, 0): matte, Vector3i(2, 0, 0): blue})
		activate_tool("fill")
		plugin("FillPlugin")._tool._settings.connected = true
		sync_viewport()
		State.undo_redo.clear_history()
	)
	step("When the user fills the connected region without changing its color", func():
		_click(Vector3(0, 0.5, 0))
	)
	await _settle()
	step("Then Fill replaces full materials and still matches regions by color", func():
		expect(frame.count() == 4, "Fill preserves the voxel count")
		expect(_same_material(Vector3i.ZERO, metal), "Fill replaces the seed metallic when its color matches")
		expect(_same_material(Vector3i.RIGHT, metal), "Fill includes a connected voxel with different material values")
		expect(_same_material(Vector3i(4, 0, 0), matte), "connected Fill preserves the separate region")
		expect(_same_material(Vector3i(2, 0, 0), blue), "Fill preserves a different color")
		State.undo_redo.undo()
		expect(_same_material(Vector3i.ZERO, matte), "undo restores the seed material")
		expect(_same_material(Vector3i.RIGHT, unsaved), "undo restores the neighbor material")
		expect(not State.undo_redo.has_undo(), "the connected fill creates one undo action")
		State.undo_redo.redo()
		expect(_same_material(Vector3i.RIGHT, metal), "redo restores the connected fill material")
	)
	step("When the user fills the separate region with connected disabled", func():
		plugin("FillPlugin")._tool._settings.connected = false
		State.undo_redo.clear_history()
		_click(Vector3(4, 0.5, 0))
	)
	await _settle()
	step("Then global Fill also applies a material-only change", func():
		expect(_same_material(Vector3i(4, 0, 0), metal), "global Fill replaces the separate voxel material")
		expect(_same_material(Vector3i(2, 0, 0), blue), "global Fill preserves the other color material")
		State.undo_redo.undo()
		expect(_same_material(Vector3i(4, 0, 0), matte), "one undo restores the separate voxel material")
		expect(not State.undo_redo.has_undo(), "the global fill creates one undo action")
	)
	step("Given two same-color swatches and two sample voxels", func():
		_reset(matte)
		State.set_palette([matte, metal])
		State.select_palette_entry(0)
		palette_before = State.get_palette()
		frame.set_cells({Vector3i.ZERO: metal, Vector3i(3, 0, 0): unsaved})
		activate_tool("eyedropper")
		sync_viewport()
	)
	step("When the user samples an exact material swatch", func():
		_click(Vector3(0, 0.5, 0))
	)
	step("Then Eyedropper selects the exact swatch without changing the palette", func():
		expect(State.current_material == metal, "Eyedropper samples all material parameters")
		expect(State.current_palette_index == 1, "the full material selects the second same-color swatch")
		expect(State.get_palette() == palette_before, "sampling an exact swatch preserves the palette")
	)
	step("When the user samples a material absent from the palette", func():
		_click(Vector3(3, 0.5, 0))
	)
	step("Then Eyedropper keeps an unsaved material without adding a swatch", func():
		expect(State.current_material == unsaved, "the unsaved sample retains every material value")
		expect(State.current_palette_index == -1, "the unsaved sample has no selected swatch")
		expect(State.get_palette() == palette_before, "sampling an unsaved material preserves the palette")
		expect(_same_material(Vector3i.ZERO, metal) and _same_material(Vector3i(3, 0, 0), unsaved), "sampling preserves both voxel materials")
	)
	step("Given a selected pair of voxels with different materials", func():
		_reset(matte)
		frame.set_cells({Vector3i(8, 0, 8): metal, Vector3i(8, 0, 9): blue})
		State.selection.from_box(Vector3i(8, 0, 8), Vector3i(8, 0, 9))
		State.selection_changed.emit()
	)
	step("When the user copies the selection as a voxel brush", func():
		brush._options.get_node("Shape/Selection").pressed.emit()
	)
	await _settle()
	step("Then copying preserves the source voxels and the selection", func():
		expect(frame.count() == 2, "copying the brush preserves both source voxels")
		expect(State.selection.count() == 2, "copying the brush preserves the source selection")
		expect(settings.shape == settings.BrushShape.SELECTION, "the copied voxel brush becomes active")
	)
	step("When the user stamps the copied brush with another current material", func():
		State.clear_selection()
		frame.clear()
		State.set_material(matte)
		sync_viewport()
		State.undo_redo.clear_history()
		_click(Vector3(0, -0.5, 0))
	)
	await _settle()
	step("Then the copied Pencil brush preserves each source material", func():
		expect(frame.count() == 2, "the copied stamp contains two voxels")
		expect(_same_material(Vector3i.ZERO, metal), "the first copied voxel retains its full material")
		expect(_same_material(Vector3i.BACK, blue), "the second copied voxel retains its full material")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo removes the copied stamp")
		expect(not State.undo_redo.has_undo(), "the copied stamp creates one undo action")
		State.undo_redo.redo()
		expect(_same_material(Vector3i.ZERO, metal) and _same_material(Vector3i.BACK, blue), "redo restores both copied materials")
	)
	step("When the user erases with the copied material brush", func():
		select_toolbar_item("Toolbar", "Eraser")
		State.undo_redo.clear_history()
		_click(Vector3(0, 0.5, 0))
	)
	await _settle()
	step("Then the eraser removes the copied voxels instead of repainting them", func():
		expect(frame.count() == 0, "the copied material brush erases both voxels")
		State.undo_redo.undo()
		expect(_same_material(Vector3i.ZERO, metal) and _same_material(Vector3i.BACK, blue), "undo restores both erased materials")
		expect(not State.undo_redo.has_undo(), "the copied eraser creates one undo action")
	)
	step("When the user draws a line with the copied material brush", func():
		frame.clear()
		select_toolbar_item("Toolbar", "Line")
		sync_viewport()
		State.undo_redo.clear_history()
		_click(Vector3(0, -0.5, 0))
		_click(Vector3(2, -0.5, 0))
	)
	await _settle()
	step("Then each copied Line stamp preserves both source materials", func():
		expect(frame.count() == 6, "the copied line contains two rows of three voxels")
		for x in 3:
			expect(_same_material(Vector3i(x, 0, 0), metal), "the first copied line row keeps its full material")
			expect(_same_material(Vector3i(x, 0, 1), blue), "the second copied line row keeps its full material")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo removes the copied material line")
		expect(not State.undo_redo.has_undo(), "the copied material line creates one undo action")
	)


func _reset(material: PackedFloat32Array) -> void:
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	State.symmetry_axes = 0
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	camera_rig().set_view("top")
	camera_rig().is_orthogonal = true
	camera_rig().center_on(AABB(Vector3(-10, -1, -10), Vector3(20, 2, 20)))
	select_toolbar_item("Toolbar", "Pencil")
	settings.shape = settings.BrushShape.CUBE
	settings.diameter = 1
	settings.pixel_perfect = false
	State.set_material(material)
	State.undo_redo.clear_history()


func _click(world: Vector3) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = camera_rig().unproject_position(world)
	event.pressed = true
	viewport.push_input(event)
	event.pressed = false
	viewport.push_input(event)


func _motion(world: Vector3) -> void:
	var event := InputEventMouseMotion.new()
	event.position = camera_rig().unproject_position(world)
	viewport.push_input(event)


func _settle() -> void:
	while State.edit_busy() or brush._brush_tool._stroke_open or brush._line_tool._job != null or brush._line_tool._preview_requested or brush._options._source_job != null or not plugin("FillPlugin")._tool.is_settled():
		await get_tree().process_frame
	await get_tree().process_frame


func _same_material(cell: Vector3i, expected: PackedFloat32Array) -> bool:
	if not frame.has(cell):
		return false
	var actual := VoxelFrame.material(frame.get_color(cell), frame.get_emission(cell), frame.get_metallic(cell), frame.get_roughness(cell))
	return actual == expected
