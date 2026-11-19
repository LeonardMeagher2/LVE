extends "res://tests/test.gd"


const SurfaceMask := preload("res://Globals/State/Tools/SurfaceMask.gd")
const NEIGHBORS := [
	Vector3i.LEFT,
	Vector3i.RIGHT,
	Vector3i.UP,
	Vector3i.DOWN,
	Vector3i.FORWARD,
	Vector3i.BACK,
]

var _settings := preload("res://plugins/paint/PaintSettings.tres")
var viewport: SubViewport
var center := Vector2.ZERO
var target := VoxelPicking.NONE
var _tool: Node3D
var _shown := {}
var _gray := Color.from_rgba8(150, 150, 150)
var _red := Color.from_rgba8(200, 60, 60)


func _ready() -> void:
	timeout = 30.0
	test("the surface test reads a neighbor chunk", _mask, "surface_mask")
	test("the expansion keeps only exposed sources and destinations", _expand, "surface_expand")
	test("the paintbrush writes only exposed surface cells", _write, "surface_write")
	test("the paintbrush preview matches the write", _preview, "surface_preview")
	test("the paintbrush preview follows the cursor", _preview_move, "surface_preview_move")
	test("the paintbrush drops a buried symmetry mirror", _symmetry, "surface_symmetry")
	test("a paint press on a buried cell writes nothing", _buried_press, "surface_buried_press")
	test("a large paintbrush preview expands on the worker", _preview_worker, "surface_preview_worker")


func before_test() -> void:
	_settings.tool = PaintToolSettings.Tools.PAINTBRUSH
	_settings.diameter = 5
	_settings.shape = StampToolSettings.BrushShape.CUBE
	_settings.pixel_perfect = false
	State.stop()
	State.document = VoxelDocument.new()
	State.current_color = _red
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.slice_layers = 0
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	State.clear_selection()
	State.selection_changed.emit()
	State.undo_redo.clear_history()
	viewport = editor_viewport()
	viewport.get_parent().stretch = false
	viewport.size = Vector2i(800, 500)
	center = Vector2(400.0, 250.0)
	activate_tool("paint")
	select_toolbar_item("paint", "Paintbrush")
	_tool = active_tool_node("PaintPlugin")
	_fill_block(12)


func _fill_block(radius: int) -> void:
	var frame := State.get_current_voxel_frame()
	var cells := {}
	for z in range(-radius, radius + 1):
		for y in range(-radius, radius + 1):
			for x in range(-radius, radius + 1):
				cells[Vector3i(x, y, z)] = VoxelFrame.material(_gray)
	frame.set_cells(cells)
	sync_viewport()


func _asymmetric_block() -> void:
	var frame := State.get_current_voxel_frame()
	frame.clear()
	var cells := {}
	for z in range(-10, 11):
		for y in range(-10, 11):
			for x in range(-20, 11):
				cells[Vector3i(x, y, z)] = VoxelFrame.material(_gray)
	frame.set_cells(cells)
	State.document._bounds_dirty = true
	sync_viewport()


func _asymmetric_frame() -> VoxelFrame:
	var frame := VoxelFrame.new()
	var cells := {}
	for z in range(-10, 11):
		for y in range(-10, 11):
			for x in range(-20, 11):
				cells[Vector3i(x, y, z)] = VoxelFrame.material(_gray)
	frame.set_cells(cells)
	return frame


func _aim_center() -> void:
	var pick := aim(center)
	expect(pick.hit != VoxelPicking.NONE, "the center aim hits the block")
	target = pick.target


func _pattern() -> Dictionary:
	var pattern: Dictionary = _settings.pattern()
	expect(not pattern.is_empty(), "the paintbrush pattern is ready")
	return pattern


func _exposed(frame: VoxelFrame, cell: Vector3i) -> bool:
	for neighbor: Vector3i in NEIGHBORS:
		if not frame.has(cell + neighbor):
			return true
	return false


func _expected_world() -> Dictionary:
	var frame := State.get_current_voxel_frame()
	var cells := {}
	for offset: Vector3i in _pattern():
		var cell := target + offset
		if frame.has(cell) and _exposed(frame, cell):
			cells[cell] = true
	return cells


func _actual_red() -> Dictionary:
	var frame := State.get_current_voxel_frame()
	var cells := {}
	for cell: Vector3i in frame.positions():
		if frame.get_color(cell) == _red:
			cells[cell] = true
	return cells


func _same_set(first: Dictionary, second: Dictionary) -> bool:
	if first.size() != second.size():
		return false
	for cell in first:
		if not second.has(cell):
			return false
	return true


func _cell_set(cells: Array) -> Dictionary:
	var result := {}
	for cell: Vector3i in cells:
		result[cell] = true
	return result


func _press(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = pos
	viewport.push_input(event)


func _release(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	event.position = pos
	viewport.push_input(event)


func _click(pos: Vector2) -> void:
	_press(pos)
	_release(pos)


func _hover(pos: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	viewport.push_input(event)


func _wait_cursor() -> void:
	var cursor: MeshInstance3D = _tool.get_node("Cursor")
	var deadline := Time.get_ticks_msec() + 10000
	while (_tool._hover_job != null or not _tool.is_surface_preview_settled() or not cursor.is_settled()) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	expect(_tool._hover_job == null, "the pattern job finished")
	expect(_tool.is_surface_preview_settled(), "the preview expansion finished")
	expect(cursor.is_settled(), "the cursor mesh finished")


func _wait_stroke() -> void:
	var deadline := Time.get_ticks_msec() + 10000
	while (State.edit_busy() or _tool._edit != null or _tool._job != null) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	expect(not State.edit_busy(), "the stroke finished")


func _mask() -> void:
	var frame := VoxelFrame.new()
	step("Given a solid block that spans a chunk border", func():
		var cells := {}
		for z in range(17):
			for y in range(17):
				for x in range(17):
					cells[Vector3i(x, y, z)] = VoxelFrame.material(_gray)
		frame.set_cells(cells)
		expect(frame.has(Vector3i(15, 15, 15)), "the fixture holds the border cell")
		expect(frame.has(Vector3i(16, 15, 15)), "the fixture holds the neighbor chunk cell")
	)
	step("Then the surface test reads the neighbor chunk", func():
		expect(not SurfaceMask.is_exposed(frame, Vector3i(15, 15, 15)), "an occupied neighbor hides the cell")
		frame.set_cell(Vector3i(16, 15, 15), VoxelFrame.material(Color.TRANSPARENT))
		expect(SurfaceMask.is_exposed(frame, Vector3i(15, 15, 15)), "the empty neighbor exposes the cell")
	)
	step("Then a missing cell is not exposed", func():
		expect(not SurfaceMask.is_exposed(frame, Vector3i(-100, -100, -100)), "a missing cell is not exposed")
	)


func _expand() -> void:
	var frame := _asymmetric_frame()
	var material := VoxelFrame.material(_red)
	var context := VoxelFrame.EditContext.new()
	context.axes = 1
	context.origin_twice = Vector3i.ZERO
	step("Given an exposed source and a buried X mirror", func():
		expect(_exposed(frame, Vector3i(10, 0, 0)), "the source is exposed")
		expect(not _exposed(frame, Vector3i(-10, 0, 0)), "the mirror is buried")
	)
	step("Then the expansion keeps the exposed source", func():
		var expanded := context.expand({Vector3i(10, 0, 0): material}, frame, true, null, null, true)
		expect(expanded.has(Vector3i(10, 0, 0)), "the exposed source is kept")
		expect(not expanded.has(Vector3i(-10, 0, 0)), "the buried mirror is dropped")
		expect(expanded.size() == 1, "only the exposed source remains")
	)
	step("Then a buried source creates no exposed mirror", func():
		expect(not _exposed(frame, Vector3i(-10, 0, 0)), "the source is buried")
		expect(_exposed(frame, Vector3i(10, 0, 0)), "the mirror is exposed")
		var expanded := context.expand({Vector3i(-10, 0, 0): material}, frame, true, null, null, true)
		expect(expanded.is_empty(), "a buried source creates no mirror")
	)
	step("Then the selection still filters a destination", func():
		var pair := VoxelFrame.new()
		pair.set_cells({Vector3i(10, 0, 0): material, Vector3i(-10, 0, 0): material})
		context.selection = {Vector3i(10, 0, 0): true}
		var expanded := context.expand({Vector3i(10, 0, 0): material}, pair, true, null, null, true)
		expect(expanded.has(Vector3i(10, 0, 0)), "the selected source is kept")
		expect(not expanded.has(Vector3i(-10, 0, 0)), "the unselected mirror is dropped")
	)


func _write() -> void:
	step("Given a solid gray block and a diameter-5 paintbrush", func():
		_aim_center()
		expect(_pattern().size() == 125, "the pattern holds one hundred and twenty-five cells")
	)
	step("When the user clicks the center", func():
		_click(center)
	)
	await _wait_stroke()
	step("Then only exposed cells in the footprint are red", func():
		var expected := _expected_world()
		var actual := _actual_red()
		expect(not expected.is_empty(), "the footprint holds exposed cells")
		expect(expected.size() < _pattern().size(), "the footprint also holds hidden cells")
		expect(_same_set(actual, expected), "the stroke writes only the exposed footprint cells")
		expect(State.get_current_voxel_frame().count() == 25 ** 3, "the paintbrush adds no voxel")
	)
	step("When the user undoes the stroke", func():
		State.undo_redo.undo()
	)
	step("Then the block is gray again", func():
		expect(_actual_red().is_empty(), "the undo restores every cell")
	)


func _preview() -> void:
	step("Given a solid gray block and a diameter-5 paintbrush", func():
		_aim_center()
		_hover(center)
	)
	await _wait_cursor()
	step("Then the cursor shows the exposed footprint cells", func():
		_shown = _tool.get_node("Cursor").installed_cells()
		expect(_same_set(_shown, _expected_world()), "the preview shows every exposed footprint cell")
		var cursor: MeshInstance3D = _tool.get_node("Cursor")
		expect(cursor.mesh is ArrayMesh, "the surface preview uses per-cell geometry")
	)
	step("When the user clicks the previewed cells", func():
		_click(center)
	)
	await _wait_stroke()
	step("Then the write matches the preview exactly", func():
		expect(_same_set(_actual_red(), _shown), "the stroke writes the previewed cells")
	)
	step("When the user selects one cell and hovers again", func():
		State.undo_redo.undo()
		State.selection.add(target)
		State.selection_changed.emit()
		_hover(center)
	)
	await _wait_cursor()
	step("Then the preview narrows to the selected writable cell", func():
		_shown = _tool.get_node("Cursor").installed_cells()
		expect(_same_set(_shown, _cell_set([target])), "the preview shows only the selected exposed cell")
	)
	step("When the user clicks the narrowed preview", func():
		_click(center)
	)
	await _wait_stroke()
	step("Then the write matches the narrowed preview", func():
		expect(_same_set(_actual_red(), _shown), "the stroke writes only the selected previewed cell")
	)


func _preview_move() -> void:
	step("Given a visible paintbrush cursor at the block center", func():
		_aim_center()
		_hover(center)
	)
	await _wait_cursor()
	step("Then the center preview shows the top-face footprint", func():
		_shown = _tool.get_node("Cursor").installed_cells()
		expect(_same_set(_shown, _expected_world()), "the center preview matches the surface")
	)
	step("When the cursor moves to the block edge", func():
		var old_size := _shown.size()
		target = Vector3i(12, 12, 0)
		_tool.driver_show_cursor(target, target)
		expect(old_size == 25, "the center footprint holds the whole top face")
	)
	await _wait_cursor()
	step("Then the preview shows the clipped surface footprint", func():
		var shown: Dictionary = _tool.get_node("Cursor").installed_cells()
		expect(_same_set(shown, _expected_world()), "the moved preview shows the new exposed cells")
		expect(not _same_set(shown, _shown), "the edge preview differs from the center preview")
	)


func _symmetry() -> void:
	step("Given an asymmetric block and X symmetry at the origin", func():
		_asymmetric_block()
		_settings.diameter = 1
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3.ZERO
	)
	step("When the cursor hovers the exposed source", func():
		_tool.driver_show_cursor(Vector3i(10, 0, 0), Vector3i(10, 0, 0))
	)
	await _wait_cursor()
	step("Then the preview drops the buried mirror", func():
		_shown = _tool.get_node("Cursor").installed_cells()
		expect(_same_set(_shown, _cell_set([Vector3i(10, 0, 0)])), "the preview keeps only the exposed source")
	)
	step("When the user paints the exposed source", func():
		_tool.driver_begin_stroke(Vector3i(10, 0, 0), Vector3i(10, 0, 0))
		_tool.driver_end_stroke()
	)
	await _wait_stroke()
	step("Then the buried mirror keeps its material", func():
		expect(_same_set(_actual_red(), _shown), "the write matches the preview")
		expect(State.get_current_voxel_frame().get_color(Vector3i(-10, 0, 0)) == _gray, "the buried mirror stays gray")
	)
	step("When the cursor hovers the buried source", func():
		State.undo_redo.undo()
		_tool.driver_show_cursor(Vector3i(-10, 0, 0), Vector3i(-10, 0, 0))
	)
	await _wait_cursor()
	step("Then the buried source shows no preview", func():
		expect(_tool.get_node("Cursor").installed_cells().is_empty(), "a buried source has no preview cell")
	)
	step("When the user paints the buried source", func():
		_tool.driver_begin_stroke(Vector3i(-10, 0, 0), Vector3i(-10, 0, 0))
		_tool.driver_end_stroke()
	)
	await _wait_stroke()
	step("Then no cell is painted", func():
		expect(_actual_red().is_empty(), "the buried source writes nothing")
		expect(State.get_current_voxel_frame().get_color(Vector3i(10, 0, 0)) == _gray, "the exposed mirror stays gray")
	)


func _buried_press() -> void:
	step("Given a buried cell and a diameter-1 paintbrush", func():
		_settings.diameter = 1
		expect(State.get_current_voxel_frame().has(Vector3i.ZERO), "the fixture holds the center")
		expect(not _exposed(State.get_current_voxel_frame(), Vector3i.ZERO), "the center is buried")
	)
	step("When a paint stroke starts on the buried cell", func():
		_tool.driver_begin_stroke(Vector3i.ZERO, Vector3i.ZERO)
		_tool.driver_end_stroke()
	)
	await _wait_stroke()
	step("Then the buried cell keeps its material", func():
		expect(State.get_current_voxel_frame().get_color(Vector3i.ZERO) == _gray, "the buried cell keeps its color")
		expect(_actual_red().is_empty(), "the stroke paints no cell")
	)


func _preview_worker() -> void:
	step("Given a diameter-20 paintbrush", func():
		_settings.diameter = 20
		_aim_center()
		_hover(center)
	)
	await _wait_cursor()
	step("Then the large preview expands on the worker", func():
		expect(_tool.last_preview_inline == false, "the large preview left the inline path")
		_shown = _tool.get_node("Cursor").installed_cells()
		expect(_same_set(_shown, _expected_world()), "the worker preview matches the surface")
	)
	step("When the cursor moves while the worker is busy", func():
		var old_world := _shown
		target = Vector3i(0, 12, 2)
		_tool.driver_show_cursor(target, target)
		expect(_same_set(_tool.get_node("Cursor").installed_cells(), old_world), "the old preview stays visible while the worker runs")
	)
	await _wait_cursor()
	step("Then the worker preview replaces the old set", func():
		_shown = _tool.get_node("Cursor").installed_cells()
		expect(_same_set(_shown, _expected_world()), "the moved worker preview matches the surface")
	)
	step("When the user paints the moved worker preview", func():
		_tool.driver_begin_stroke(target, target)
		_tool.driver_end_stroke()
	)
	await _wait_stroke()
	step("Then the worker write matches the preview", func():
		expect(_same_set(_actual_red(), _shown), "the stroke writes the previewed cells")
		expect(State.get_current_voxel_frame().count() == 25 ** 3, "the paintbrush adds no voxel")
	)
