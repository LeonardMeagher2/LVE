extends "res://tests/test.gd"

# One process runs the paint and stroke tests. Each test keeps the steps and
# checks of its original scene. The user arguments after `--` name the tests to
# run, so an old scene name still selects its own test.

var _brush_settings := preload("res://plugins/brush/settings.tres")

var viewport: SubViewport
var center := Vector2.ZERO
var pressed := VoxelPicking.NONE
var painted := VoxelPicking.NONE
var mouse_end := VoxelPicking.NONE
var anchor := VoxelPicking.NONE
var front := VoxelPicking.NONE
var _p := PixelPerfectStroke.new()
var _drawn: Array[Vector3i] = []
var _default_color := Color.BLACK
var _default_mode := BrushToolSettings.BrushMode.PENCIL
var _default_pixel_perfect := false
var _defaults_ready := false


func _ready() -> void:
	test("can paint a stroke of voxels with a drag", _paint, "paint")
	test("can undo and redo a stroke", _undo_redo, "undo_redo")
	test("paints a connected stroke when the mouse jumps", _stroke_connect, "stroke_connect")
	test("draws a clean diagonal and skips transient cells", _pixel_perfect, "pixel_perfect")
	test("pixel perfect mode paints the cursor cell and stays connected", _pixel_perfect_tool, "pixel_perfect_tool")
	test("the brush adds voxels in front of the clicked face or recolors them in paint mode", _brush_modes, "brush_modes")


# Each test starts from a fresh document and the default brush. The brush mode
# and the pixel-perfect option live in the shared settings resource, so they are
# restored here. The brush color is restored to its startup value for the tests
# that do not set one.
func _setup_test() -> void:
	if not _defaults_ready:
		_default_color = State.current_color
		_default_mode = _brush_settings.mode
		_default_pixel_perfect = _brush_settings.pixel_perfect
		_defaults_ready = true
	State.stop()
	State.document = VoxelDocument.new()
	State.current_color = _default_color
	_brush_settings.mode = _default_mode
	_brush_settings.pixel_perfect = _default_pixel_perfect
	var pixel_perfect := plugin("BrushPlugin")._options.get_node("PixelPerfect") as Button
	if pixel_perfect != null and pixel_perfect.button_pressed != _default_pixel_perfect:
		pixel_perfect.button_pressed = _default_pixel_perfect


# Shared viewport setup. Every viewport case uses the same view and center.
func _view_setup() -> void:
	viewport = editor_viewport()
	viewport.get_parent().stretch = false
	viewport.size = Vector2i(800, 500)
	center = Vector2(400.0, 250.0)


# Shared input helpers. Every case drives the real viewport input path.
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


func _motion(pos: Vector2, relative: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	event.relative = relative
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.push_input(event)


func _click(pos: Vector2) -> void:
	_press(pos)
	_release(pos)


func _paint() -> void:
	step("Given a red brush on an empty grid", func():
		State.current_color = Color.from_rgba8(200, 60, 60)
		_view_setup()
	)

	step("When the user presses and drags the viewport", func():
		var req := pick_request(center)
		pressed = VoxelPicking.start_pick(req.origin, req.dir, req.frame, req.forward).target
		_press(center)
		var drag_pos := center + Vector2(0.0, 150.0)
		_motion(drag_pos, Vector2(0.0, 150.0))
		_release(drag_pos)
	)

	step("Then a stroke of voxels is painted", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.count() > 1, "the drag painted a stroke")
		expect(frame.has(pressed), "the pressed cell is painted")
	)

	step("When the user undoes the stroke", func():
		State.undo_redo.undo()
	)

	step("Then the stroke is removed", func():
		expect(State.document.frames[0].count() == 0, "the stroke is removed")
	)


func _undo_redo() -> void:
	step("Given an editor with a fresh document", func():
		_view_setup()
	)

	step("When the user paints a voxel at the cursor", func():
		var req := pick_request(center)
		painted = VoxelPicking.start_pick(req.origin, req.dir, req.frame, req.forward).target
		_click(center)
	)

	step("Then the stroke voxel is in the frame", func():
		expect(State.document.frames[0].has(painted), "stroke voxel present")
	)

	step("When the user undoes the stroke", func():
		State.undo_redo.undo()
	)

	step("Then the stroke voxel is removed", func():
		expect(not State.document.frames[0].has(painted), "stroke voxel removed after undo")
	)

	step("When the user redoes the stroke", func():
		State.undo_redo.redo()
	)

	step("Then the stroke voxel returns", func():
		expect(State.document.frames[0].has(painted), "stroke voxel present after redo")
	)


func _stroke_connect() -> void:
	step("Given a brush on an empty grid", func():
		State.current_color = Color.from_rgba8(200, 60, 60)
		_view_setup()
		activate_tool("Toolbar")
	)

	step("When the user clicks and jumps the mouse far in one motion", func():
		var start := aim(center)
		pressed = start.target
		_press(center)
		var drag_pos := center + Vector2(0.0, 60.0)
		_motion(drag_pos, Vector2(0.0, 60.0))
		_release(drag_pos)
		mouse_end = drag(drag_pos, start.plane).target
	)

	step("Then the cells between press and release are all painted", func():
		var frame: VoxelFrame = State.document.frames[0]
		var path := StrokeLine.cells(pressed, mouse_end)
		expect(frame.has(pressed), "the pressed cell is painted")
		expect(frame.has(mouse_end), "the cell under the mouse is painted")
		expect(path.size() >= 3, "the stroke spans several cells")
		for c in path:
			expect(frame.has(c), "every cell along the stroke is painted")
	)


func _pixel_perfect() -> void:
	step("Given a stroke that starts at the origin", func():
		_p.reset()
		_p.feed(Vector3i(0, 0, 0))
	)

	step("When the user draws a wobbly diagonal", func():
		_drawn = _p.feed(Vector3i(1, 1, 0))
		_drawn += _p.feed(Vector3i(2, 2, 0))
		_drawn += _p.feed(Vector3i(2, 3, 0))
		_drawn += _p.feed(Vector3i(3, 3, 0))
		_drawn += _p.feed(Vector3i(4, 4, 0))
		_drawn += _p.feed(Vector3i(4, 5, 0))
		_drawn += _p.feed(Vector3i(5, 5, 0))
	)

	step("Then the drawn cells form a clean diagonal", func():
		expect(_drawn.has(Vector3i(1, 1, 0)), "the first diagonal cell is drawn")
		expect(_drawn.has(Vector3i(2, 2, 0)), "the second diagonal cell is drawn")
		expect(_drawn.has(Vector3i(3, 3, 0)), "the third diagonal cell is drawn")
		expect(_drawn.has(Vector3i(4, 4, 0)), "the fourth diagonal cell is drawn")
		expect(_drawn.size() == 4, "the transient wobble cells are skipped")
	)

	step("When the user releases", func():
		_drawn += _p.flush()
	)

	step("Then the final cursor cell is painted", func():
		expect(_drawn.has(Vector3i(5, 5, 0)), "the cursor cell is painted on release")
	)

	step("When the user backtracks and moves on", func():
		_drawn += _p.feed(Vector3i(6, 5, 0))
		_drawn += _p.feed(Vector3i(7, 5, 0))
		_drawn += _p.feed(Vector3i(6, 5, 0))
		_drawn += _p.feed(Vector3i(6, 6, 0))
		_drawn += _p.feed(Vector3i(7, 6, 0))
		_drawn += _p.flush()
	)

	step("Then the transient cell is skipped and the cursor is painted", func():
		expect(_drawn.has(Vector3i(6, 5, 0)), "the frontier cell is drawn")
		expect(_drawn.has(Vector3i(7, 6, 0)), "the cursor cell is painted")
		expect(not _drawn.has(Vector3i(6, 6, 0)), "the transient cell is skipped")
	)

	step("When the user jumps far while the stroke is buffering", func():
		_drawn += _p.feed(Vector3i(8, 6, 0))
		_drawn += _p.feed(Vector3i(12, 10, 0))
		_drawn += _p.flush()
	)

	step("Then every drawn cell connects to its neighbor", func():
		expect(_drawn.has(Vector3i(12, 10, 0)), "the stroke reaches the cursor")
		var connected := true
		for i in range(1, _drawn.size()):
			if not _adjacent(_drawn[i - 1], _drawn[i]):
				connected = false
		expect(connected, "no gaps in the stroke")
	)


func _adjacent(a: Vector3i, b: Vector3i) -> bool:
	return maxi(absi(a.x - b.x), maxi(absi(a.y - b.y), absi(a.z - b.z))) <= 1


func _pixel_perfect_tool() -> void:
	step("Given a brush with pixel perfect enabled", func():
		State.current_color = Color.from_rgba8(200, 60, 60)
		_view_setup()
		activate_tool("Toolbar")
		press_option("Pixel perfect strokes")
	)

	step("When the user draws a slow stroke", func():
		_press(center)
		var pos := center
		for i in 4:
			pos += Vector2(0.0, 14.0)
			_motion(pos, Vector2(0.0, 14.0))
		_release(pos)
		var req_end := pick_request(pos)
		mouse_end = VoxelPicking.start_pick(req_end.origin, req_end.dir, req_end.frame, req_end.forward).target
	)

	step("Then the stroke is connected and the cursor cell is painted", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.count() >= 2, "the stroke painted a line")
		expect(frame.has(mouse_end), "the cursor cell is painted")
	)


func _brush_modes() -> void:
	step("Given a gray voxel where the center ray lands and the brush in add mode", func():
		_view_setup()
		activate_tool("Toolbar")
		select_toolbar_item("Toolbar", "Pencil")
		State.current_color = Color.from_rgba8(200, 60, 60)
		anchor = aim(center).target
		State.document.set_cell(0, anchor, VoxelFrame.material(Color.from_rgba8(150, 150, 150)))
		sync_viewport()
		front = aim(center).add_target
	)

	step("When the user clicks the center of the viewport", func():
		_click(center)
	)

	step("Then a voxel appears in front of the clicked face", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.has(front), "a voxel is added beside the clicked voxel")
	)

	step("When the user switches to the paintbrush and clicks the front voxel", func():
		select_toolbar_item("paint", "Paintbrush")
		_click(center)
	)

	step("Then the front voxel is recolored and no voxel is added", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.count() == 2, "the paintbrush adds no new voxels")
		expect(frame.get_color(front) == Color.from_rgba8(200, 60, 60), "the front voxel has the brush color")
	)

	step("When the user clears the grid and clicks the empty grid with the paintbrush", func():
		State.document.frames[0].clear()
		sync_viewport()
		_click(center)
	)

	step("Then the paintbrush leaves the empty grid unchanged", func():
		expect(State.document.frames[0].count() == 0, "no voxel is painted on empty cells")
	)
