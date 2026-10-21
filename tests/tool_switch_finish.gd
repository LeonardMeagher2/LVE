extends "res://tests/test.gd"

# A tool switch finishes the work a Pencil or Eraser stroke queued and commits it
# as one history action. A Box or Lasso switch applies the outline a held drag
# already drew, and a released calculation finishes after the detach. Escape and a
# frame or document change keep their rollback. The line preview and the streamed
# wand keep their own policy.

const BRUSH_DIAMETER := 20
const HELD_SIDE := 5
const WORKER_SIDE := 18
const SETTLE_FRAMES := 600

var _brush_settings := preload("res://plugins/brush/settings.tres")
var _selection_settings := preload("res://plugins/selection/settings.tres")

var viewport: SubViewport
var center := Vector2.ZERO
var frame: VoxelFrame
var brush: Node
var selection_plugin: Node
var reference: Array = []
var reference_selection: Dictionary = {}
var filled := 0
var block_cells: Array[Vector3i] = []
var block_rectangle := Rect2()
var _standalone_tool: Node = null
var _box: Node = null
var _lasso: Node = null
var _default_mode := BrushToolSettings.BrushMode.PENCIL
var _defaults_ready := false


func _ready() -> void:
	timeout = 20.0
	test("a Pencil worker stroke commits on a tool switch with one undo action", _brush_tool_switch, "brush_tool_switch")
	test("a one-voxel Pencil stamp lands in the input event", _brush_inline_stamp, "brush_inline_stamp")
	test("a brush mode change finishes the stroke with its captured mode", _brush_mode_switch, "brush_mode_switch")
	test("Escape rolls back a detached brush worker", _brush_escape, "brush_escape")
	test("a frame change cancels a detached brush worker", _brush_context_change, "brush_context_change")
	test("a reattach before the worker finishes joins and commits once", _brush_reattach, "brush_reattach")
	test("a held Box drag applies its outline on a switch", _box_held_switch, "box_held_switch")
	test("a held Lasso drag applies its outline on a switch", _lasso_held_switch, "lasso_held_switch")
	test("a released large Box projection finishes after a switch", _box_worker_switch, "box_worker_switch")
	test("Escape rolls back a detached Box projection", _box_escape, "box_escape")
	test("a pending Line preview is still discarded on a switch", _line_switch_discards, "line_switch_discards")
	test("freeing a brush with a running worker joins and releases it", _brush_predelete, "brush_predelete")
	test("an idle brush switch releases both subscriptions and reattaches once", _brush_inline_subscriptions, "brush_inline_subscriptions")
	test("an idle Box and Lasso switch releases the context subscription", _select_inline_subscriptions, "select_inline_subscriptions")
	test("a pending brush worker keeps its subscriptions across a switch", _brush_pending_subscriptions, "brush_pending_subscriptions")
	test("a brush worker that finishes detached releases its subscriptions", _brush_detached_finish_subscriptions, "brush_detached_finish_subscriptions")
	test("a pixel-perfect mode switch flushes the same queued centers", _brush_pixel_perfect_switch, "brush_pixel_perfect_switch")


func _setup_test() -> void:
	if not _defaults_ready:
		_default_mode = _brush_settings.mode
		_defaults_ready = true
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	_brush_settings.mode = _default_mode
	_brush_settings.pixel_perfect = false
	_brush_settings.shape = BrushToolSettings.BrushShape.CUBE
	_brush_settings.diameter = 1
	_selection_settings.mode = _selection_settings.SelectMode.REPLACE
	_selection_settings.include_empty = false
	_selection_settings.depth_test = true
	frame = State.get_current_voxel_frame()
	viewport = editor_viewport()
	viewport.get_parent().stretch = false
	viewport.size = Vector2i(800, 500)
	center = Vector2(400.0, 250.0)
	brush = plugin("BrushPlugin")._brush_tool
	selection_plugin = plugin("SelectionPlugin")
	activate_tool("Toolbar")
	camera_rig().is_orthogonal = true
	camera_rig().set_view("top")
	await get_tree().process_frame


# A wide cube brush with one center needs more than the inline limit, so the press
# starts a foreground worker.
func _wide_brush() -> void:
	_brush_settings.shape = BrushToolSettings.BrushShape.CUBE
	_brush_settings.diameter = BRUSH_DIAMETER
	activate_tool("Toolbar")
	select_toolbar_item("Toolbar", "Pencil")


func _brush_tool_switch() -> void:
	step("Given a wide Pencil brush", func():
		_wide_brush()
	)
	step("When the user presses once and releases", func():
		_click(center)
	)
	await _await_brush_idle()
	step("Then the stroke paints its footprint with one undo action", func():
		reference = frame.storage_data()
		expect(frame.count() > 0, "the reference stroke painted voxels")
		expect(State.undo_redo.has_undo(), "the reference stroke records one undo action")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo clears the reference stroke")
		State.undo_redo.clear_history()
	)
	step("When the user presses and switches tools while the worker runs", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_wide_brush()
		_press(center)
		expect(State.edit_busy(), "the press starts a foreground worker")
		activate_tool("selection")
	)
	await _await_brush_idle()
	step("Then the switched-away stroke commits the same footprint once", func():
		expect(frame.storage_data() == reference, "the switched stroke equals the reference")
		expect(State.undo_redo.has_undo(), "the switched stroke records one undo action")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo clears the whole switched stroke")
	)


func _brush_inline_stamp() -> void:
	step("Given a one-voxel Pencil brush", func():
		_brush_settings.shape = BrushToolSettings.BrushShape.CUBE
		_brush_settings.diameter = 1
		activate_tool("Toolbar")
		select_toolbar_item("Toolbar", "Pencil")
	)
	step("When the user presses", func():
		_press(center)
	)
	step("Then the first stamp lands in the input event", func():
		expect(frame.count() == 1, "the inline stamp is visible before the next frame")
		expect(not State.edit_busy(), "the inline stamp records no operation")
	)
	step("When the user releases", func():
		_release(center)
	)
	step("Then the stroke closes with one undo action", func():
		expect(State.undo_redo.has_undo(), "the inline stroke records one action")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo clears the inline stroke")
	)


func _brush_mode_switch() -> void:
	step("Given a wide Pencil brush", func():
		_wide_brush()
	)
	step("When the user presses once and releases", func():
		_click(center)
	)
	await _await_brush_idle()
	step("Then the reference stroke paints its footprint", func():
		reference = frame.storage_data()
		expect(frame.count() > 0, "the reference stroke painted voxels")
		State.undo_redo.undo()
		State.undo_redo.clear_history()
	)
	step("When the user presses and switches to the paintbrush while the worker runs", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_wide_brush()
		_press(center)
		expect(State.edit_busy(), "the press starts a foreground worker")
		select_toolbar_item("paint", "Paintbrush")
	)
	await _await_brush_idle()
	step("Then the stroke finishes with the Pencil mode it captured", func():
		expect(frame.storage_data() == reference, "the tool switch keeps the captured Pencil stroke")
		expect(State.undo_redo.has_undo(), "the finished stroke records one undo action")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo clears the stroke")
	)
	step("When the user erases and switches to Pencil while the worker runs", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		filled = _fill_frame(24)
		_brush_settings.shape = BrushToolSettings.BrushShape.CUBE
		_brush_settings.diameter = BRUSH_DIAMETER
		select_toolbar_item("Toolbar", "Eraser")
		_press(center)
		expect(State.edit_busy(), "the eraser press starts a foreground worker")
		select_toolbar_item("Toolbar", "Pencil")
	)
	await _await_brush_idle()
	step("Then the stroke removes voxels with the Eraser mode it captured", func():
		expect(frame.count() < filled, "the mode change keeps the captured Eraser stroke")
		expect(State.undo_redo.has_undo(), "the finished erase records one undo action")
		State.undo_redo.undo()
		expect(frame.count() == filled, "one undo restores the erased voxels")
	)


func _brush_escape() -> void:
	step("Given a wide Pencil brush with a running worker", func():
		_wide_brush()
		_press(center)
		expect(State.edit_busy(), "the press starts a foreground worker")
	)
	step("When the user switches tools and presses Escape", func():
		activate_tool("selection")
		_key(KEY_ESCAPE)
	)
	await _await_brush_idle()
	step("Then the detached stroke rolls back", func():
		expect(frame.count() == 0, "Escape removed the stroke voxels")
		expect(not State.undo_redo.has_undo(), "the cancelled stroke adds no history")
	)


func _brush_context_change() -> void:
	step("Given a wide Pencil brush with a running worker", func():
		_wide_brush()
		_press(center)
		expect(State.edit_busy(), "the press starts a foreground worker")
	)
	step("When the user switches tools and changes the frame", func():
		activate_tool("selection")
		State.add_frame()
	)
	await _await_brush_idle()
	step("Then neither frame receives the stale stroke", func():
		expect(frame.count() == 0, "the source frame keeps no stale voxels")
		expect(State.get_current_voxel_frame().count() == 0, "the new frame receives no stale voxels")
		expect(State.undo_redo.get_history_count() == 1, "only the frame change records history")
	)


func _brush_reattach() -> void:
	step("Given a wide Pencil brush with a running worker", func():
		_wide_brush()
		_press(center)
		expect(State.edit_busy(), "the press starts a foreground worker")
		expect(_brush_connections() == 1, "the brush holds one context connection")
	)
	step("When the user switches away and back before the worker finishes", func():
		activate_tool("selection")
		activate_tool("Toolbar")
	)
	await _await_brush_idle()
	step("Then the worker joins and the stroke commits exactly once", func():
		expect(frame.count() > 0, "the reattached stroke commits")
		expect(State.undo_redo.get_history_count() == 1, "the stroke records exactly one action")
		expect(_brush_connections() == 1, "the reattach adds no second connection")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo clears the stroke")
	)


func _box_held_switch() -> void:
	step("Given the Box tool and a small block", func():
		_select_setup("Box")
		block_cells = _place_block(HELD_SIDE)
		block_rectangle = _drag_rectangle_of(block_cells)
	)
	step("When the user releases the drag normally", func():
		_press(block_rectangle.position)
		_move_to(block_rectangle.end)
		_release(block_rectangle.end)
	)
	step("Then the release selects the block", func():
		reference_selection = State.selection.capture()
		expect(reference_selection.size() > 0, "the release selects voxels")
		State.undo_redo.undo()
		expect(State.selection.is_empty(), "one undo clears the release selection")
		State.undo_redo.clear_history()
	)
	step("When the user holds the drag and switches tools", func():
		_press(block_rectangle.position)
		_move_to(block_rectangle.end)
		activate_tool("Toolbar")
	)
	await _await_selection_idle()
	step("Then the held outline applies exactly like the release", func():
		expect(State.selection.capture() == reference_selection, "the switched outline matches the release")
		expect(State.undo_redo.has_undo(), "the switched selection records one undo action")
		State.undo_redo.undo()
		expect(State.selection.is_empty(), "one undo clears the switched selection")
	)


func _lasso_held_switch() -> void:
	step("Given the Lasso tool and a small block", func():
		_select_setup("Lasso")
		block_cells = _place_block(HELD_SIDE)
		block_rectangle = _drag_rectangle_of(block_cells)
	)
	step("When the user releases the lasso normally", func():
		_lasso_drag()
		_release(_lasso_last_point())
	)
	step("Then the release selects the block", func():
		reference_selection = State.selection.capture()
		expect(reference_selection.size() > 0, "the release selects voxels")
		State.undo_redo.undo()
		expect(State.selection.is_empty(), "one undo clears the release selection")
		State.undo_redo.clear_history()
	)
	step("When the user holds the lasso and switches tools", func():
		_lasso_drag()
		activate_tool("Toolbar")
	)
	await _await_selection_idle()
	step("Then the held outline applies exactly like the release", func():
		expect(State.selection.capture() == reference_selection, "the switched outline matches the release")
		expect(State.undo_redo.has_undo(), "the switched selection records one undo action")
		State.undo_redo.undo()
		expect(State.selection.is_empty(), "one undo clears the switched selection")
	)


func _box_worker_switch() -> void:
	step("Given the Box tool and a block larger than the inline limit", func():
		_select_setup("Box")
		block_cells = _place_block(WORKER_SIDE)
		block_rectangle = _drag_rectangle_of(block_cells)
		expect(block_cells.size() > 4096, "the block needs a worker")
	)
	step("When the user releases the drag normally", func():
		_press(block_rectangle.position)
		_move_to(block_rectangle.end)
		_release(block_rectangle.end)
	)
	await _await_selection_count(block_cells.size())
	step("Then the release selects the whole block", func():
		reference_selection = State.selection.capture()
		expect(reference_selection.size() == block_cells.size(), "the release selects every block voxel")
		State.undo_redo.undo()
		expect(State.selection.is_empty(), "one undo clears the release selection")
		State.undo_redo.clear_history()
	)
	step("When the user releases the drag and switches tools while the worker runs", func():
		_press(block_rectangle.position)
		_move_to(block_rectangle.end)
		_release(block_rectangle.end)
		expect(State.edit_busy(), "the release starts a foreground worker")
		activate_tool("Toolbar")
	)
	await _await_selection_count(block_cells.size())
	step("Then the switched-away projection selects the whole block once", func():
		expect(State.selection.capture() == reference_selection, "the switched projection equals the release")
		expect(State.undo_redo.has_undo(), "the switched projection records one undo action")
		State.undo_redo.undo()
		expect(State.selection.is_empty(), "one undo clears the switched projection")
	)


func _box_escape() -> void:
	step("Given the Box tool and a block larger than the inline limit", func():
		_select_setup("Box")
		block_cells = _place_block(WORKER_SIDE)
		block_rectangle = _drag_rectangle_of(block_cells)
	)
	step("When the user releases the drag, switches tools, and presses Escape", func():
		_press(block_rectangle.position)
		_move_to(block_rectangle.end)
		_release(block_rectangle.end)
		expect(State.edit_busy(), "the release starts a foreground worker")
		activate_tool("Toolbar")
		_key(KEY_ESCAPE)
	)
	await _await_selection_idle()
	step("Then the detached projection rolls back", func():
		expect(State.selection.is_empty(), "Escape leaves the selection unchanged")
		expect(not State.undo_redo.has_undo(), "the cancelled projection adds no history")
	)


func _line_switch_discards() -> void:
	step("Given the Line tool with a pending preview", func():
		activate_tool("Toolbar")
		select_toolbar_item("Toolbar", "Line")
		_press(center)
		_release(center)
	)
	step("When the user switches back to Pencil", func():
		select_toolbar_item("Toolbar", "Pencil")
	)
	step("Then the line preview is discarded", func():
		expect(frame.count() == 0, "the discarded line leaves the frame empty")
		expect(not State.edit_busy(), "the switch releases editing")
		expect(not State.undo_redo.has_undo(), "the discarded line adds no history")
	)


func _brush_predelete() -> void:
	step("Given a standalone brush with a running worker", func():
		_brush_settings.shape = BrushToolSettings.BrushShape.CUBE
		_brush_settings.diameter = BRUSH_DIAMETER
		_standalone_tool = preload("res://plugins/brush/BrushTool.tscn").instantiate()
		viewport_scene().add_child(_standalone_tool)
		_press_on(_standalone_tool, center)
		expect(State.edit_busy(), "the standalone press starts a foreground worker")
	)
	step("When the tool is freed while the worker runs", func():
		_standalone_tool.free()
		_standalone_tool = null
	)
	step("Then the teardown joined the worker and released its operation", func():
		expect(not State.edit_busy(), "the freed tool released its operation")
		expect(State.active_edit() == null, "the freed tool released its edit")
		expect(frame.count() == 0, "the freed tool published no stroke")
		expect(not State.undo_redo.has_undo(), "the freed tool adds no history")
	)


func _brush_inline_subscriptions() -> void:
	step("Given a one-voxel Pencil brush and an inline stroke", func():
		_brush_settings.shape = BrushToolSettings.BrushShape.CUBE
		_brush_settings.diameter = 1
		activate_tool("Toolbar")
		select_toolbar_item("Toolbar", "Pencil")
		_click(center)
		expect(frame.count() == 1, "the inline stroke lands")
	)
	step("When the user switches tools while the brush is idle", func():
		activate_tool("selection")
	)
	step("Then the detached idle brush released both subscriptions", func():
		expect(_context_connections(brush, "_cancel_edit") == 0, "the idle detach released the context subscription")
		expect(_history_connections(brush, "_on_history_changed") == 0, "the idle detach released the history subscription")
	)
	step("When the user switches back to the brush", func():
		activate_tool("Toolbar")
	)
	step("Then the reattached brush holds exactly one of each", func():
		expect(_context_connections(brush, "_cancel_edit") == 1, "the reattach restores one context subscription")
		expect(_history_connections(brush, "_on_history_changed") == 1, "the reattach restores one history subscription")
	)


func _select_inline_subscriptions() -> void:
	step("Given the Box tool with an inline click", func():
		_select_setup("Box")
		_click(center)
		_box = selection_plugin._current_tool
	)
	step("When the user switches tools while the Box is idle", func():
		activate_tool("Toolbar")
		expect(_context_connections(_box, "_cancel_screen_job") == 0, "the idle detach released the Box context subscription")
	)
	step("When the user switches back to the Box", func():
		activate_tool("selection")
		expect(_context_connections(_box, "_cancel_screen_job") == 1, "the reattach restores one Box context subscription")
	)
	step("Given the Lasso tool with an inline click", func():
		select_toolbar_item("selection", "Lasso")
		_lasso = selection_plugin._current_tool
		_click(center)
	)
	step("When the user switches tools while the Lasso is idle", func():
		activate_tool("Toolbar")
		expect(_context_connections(_lasso, "_cancel_screen_job") == 0, "the idle detach released the Lasso context subscription")
	)
	step("When the user switches back to the Lasso", func():
		activate_tool("selection")
		expect(_context_connections(_lasso, "_cancel_screen_job") == 1, "the reattach restores one Lasso context subscription")
	)


func _brush_pending_subscriptions() -> void:
	step("Given a wide Pencil brush with a running worker", func():
		_wide_brush()
		_press(center)
		expect(State.edit_busy(), "the press starts a foreground worker")
	)
	step("When the user switches away and back before the worker finishes", func():
		activate_tool("selection")
		expect(_context_connections(brush, "_cancel_edit") == 1, "the pending worker keeps the context subscription")
		expect(_history_connections(brush, "_on_history_changed") == 1, "the pending worker keeps the history subscription")
		activate_tool("Toolbar")
		expect(_context_connections(brush, "_cancel_edit") == 1, "the reattach adds no second context subscription")
		expect(_history_connections(brush, "_on_history_changed") == 1, "the reattach adds no second history subscription")
	)
	await _await_brush_idle()
	step("Then the attached tool keeps exactly one of each", func():
		expect(_context_connections(brush, "_cancel_edit") == 1, "the attached tool keeps one context subscription")
		expect(_history_connections(brush, "_on_history_changed") == 1, "the attached tool keeps one history subscription")
	)


func _brush_detached_finish_subscriptions() -> void:
	step("Given a wide Pencil brush with a running worker", func():
		_wide_brush()
		_press(center)
		expect(State.edit_busy(), "the press starts a foreground worker")
	)
	step("When the user switches away and the worker finishes detached", func():
		activate_tool("selection")
		expect(_context_connections(brush, "_cancel_edit") == 1, "the pending worker keeps the context subscription")
	)
	await _await_brush_idle()
	step("Then the finished detached tool released both subscriptions", func():
		expect(_context_connections(brush, "_cancel_edit") == 0, "the detached idle tool released the context subscription")
		expect(_history_connections(brush, "_on_history_changed") == 0, "the detached idle tool released the history subscription")
	)
	step("When the user switches back to the brush", func():
		activate_tool("Toolbar")
	)
	step("Then the reattached brush holds exactly one of each", func():
		expect(_context_connections(brush, "_cancel_edit") == 1, "the reattach restores one context subscription")
		expect(_history_connections(brush, "_on_history_changed") == 1, "the reattach restores one history subscription")
	)


func _brush_pixel_perfect_switch() -> void:
	step("Given a wide pixel-perfect Pencil brush", func():
		_brush_settings.shape = BrushToolSettings.BrushShape.CUBE
		_brush_settings.diameter = BRUSH_DIAMETER
		_brush_settings.pixel_perfect = true
		activate_tool("Toolbar")
		select_toolbar_item("Toolbar", "Pencil")
	)
	step("When the user draws a slow stroke and releases", func():
		_pixel_perfect_stroke()
		_release(_pixel_perfect_end())
	)
	await _await_brush_idle()
	step("Then the release flushes the queued centers with one undo action", func():
		reference = frame.storage_data()
		expect(frame.count() > 0, "the reference stroke painted voxels")
		expect(State.undo_redo.has_undo(), "the reference stroke records one undo action")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo clears the reference stroke")
		State.undo_redo.clear_history()
	)
	step("When the user draws the same stroke and switches tool while the worker runs", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_pixel_perfect_stroke()
		expect(State.edit_busy(), "the stroke runs a worker")
		select_toolbar_item("paint", "Paintbrush")
	)
	await _await_brush_idle()
	step("Then the switch flushes the same queued centers once", func():
		expect(frame.storage_data() == reference, "the switched stroke equals the release")
		expect(State.undo_redo.has_undo(), "the switched stroke records one undo action")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo clears the switched stroke")
	)


# --- helpers ---------------------------------------------------------------
func _select_setup(tool_name: String) -> void:
	activate_tool("selection")
	select_toolbar_item("selection", tool_name)
	_selection_settings.depth_test = false
	frame.clear()
	State.clear_selection()
	State.selection_changed.emit()
	State.undo_redo.clear_history()


func _place_block(side: int) -> Array[Vector3i]:
	var material := VoxelFrame.material(Color.from_rgba8(150, 150, 150))
	var cells: Array[Vector3i] = []
	var half := side / 2
	for x in range(-half, half):
		for y in range(-half, half):
			for z in range(-half, half):
				var cell := Vector3i(x, y, z)
				frame.set_cell(cell, material)
				cells.append(cell)
	camera_rig().center_on(frame.get_bounds())
	return cells


# A solid block for the eraser cases. The camera centers on it, so a press at the
# viewport center lands on its top face.
func _fill_frame(side: int) -> int:
	frame.clear()
	var material := VoxelFrame.material(Color.from_rgba8(150, 150, 150))
	var half := side / 2
	for x in range(-half, half):
		for y in range(-half, half):
			for z in range(-half, half):
				frame.set_cell(Vector3i(x, y, z), material)
	camera_rig().center_on(frame.get_bounds())
	return frame.count()


func _drag_rectangle_of(cells: Array) -> Rect2:
	var camera := camera_rig()
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for cell in cells:
		var point := camera.unproject_position(Vector3(cell))
		low.x = minf(low.x, point.x)
		low.y = minf(low.y, point.y)
		high.x = maxf(high.x, point.x)
		high.y = maxf(high.y, point.y)
	var margin := Vector2(12.0, 12.0)
	return Rect2(low - margin, (high - low) + margin * 2.0)


# The lasso drag keeps the same path for the reference and the switch case, so the
# last sampled point is the one the switch applies.
func _lasso_drag() -> void:
	_press(block_rectangle.position)
	_move_to(Vector2(block_rectangle.end.x, block_rectangle.position.y))
	_move_to(block_rectangle.end)
	_move_to(_lasso_last_point())


func _lasso_last_point() -> Vector2:
	return Vector2(block_rectangle.position.x, block_rectangle.end.y)


func _press(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = pos
	viewport.push_input(event)


func _move_to(pos: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
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


func _press_on(tool: Node, pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = pos
	tool.handle_input(event, pos)


func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	get_tree().root.push_input(event)


func _await_brush_idle() -> void:
	for i in SETTLE_FRAMES:
		if not State.edit_busy() and brush._edit == null and brush._job == null:
			await get_tree().process_frame
			return
		await get_tree().process_frame
	expect(false, "the brush worker finished")


func _await_selection_idle() -> void:
	for i in SETTLE_FRAMES:
		if not State.edit_busy() and not _screen_job_pending():
			await get_tree().process_frame
			return
		await get_tree().process_frame
	expect(false, "the selection calculation finished")


func _await_selection_count(count: int) -> void:
	for i in SETTLE_FRAMES:
		if State.selection.count() == count and not State.edit_busy():
			await get_tree().process_frame
			return
		await get_tree().process_frame
	expect(false, "the selection reached its expected size")


func _screen_job_pending() -> bool:
	var tool: Node = selection_plugin._current_tool
	return tool != null and tool._screen_job != null


func _brush_connections() -> int:
	return _context_connections(brush, "_cancel_edit")


# Count the exact callable on the tool, never every connection of the signal.
func _context_connections(tool: Node, method: String) -> int:
	if tool == null:
		return -1
	var count := 0
	for connection in State.edit_context_changing.get_connections():
		var callable: Callable = connection["callable"]
		if callable.get_object() == tool and callable.get_method() == method:
			count += 1
	return count


func _history_connections(tool: Node, method: String) -> int:
	if tool == null:
		return -1
	var count := 0
	for connection in State.history_changed.get_connections():
		var callable: Callable = connection["callable"]
		if callable.get_object() == tool and callable.get_method() == method:
			count += 1
	return count


# The same slow path for the release and the switch, so the pixel-perfect filter
# queues the same centers.
func _pixel_perfect_stroke() -> void:
	_press(center)
	for i in 4:
		_move_to(center + Vector2(0.0, 14.0 * (i + 1)))


func _pixel_perfect_end() -> Vector2:
	return center + Vector2(0.0, 56.0)
