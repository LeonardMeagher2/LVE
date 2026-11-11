extends "res://tests/test.gd"

# Focused lifecycle checks for the spray worker pipeline.
#
# The checks cover the parts that a single sample cannot show: a cancel and an
# immediate repress, the settings of one queued brush cell, the press that owns
# its current cell while another hover waits, the cancel checkpoints of the dense
# footprint union, and the random-state contract between the inline and worker
# paths.
#
# The checks drive the real viewport input path, so the picked cell and the
# painted cells go through the production event handling. The large sizes place
# the occupied reach estimate above the inline limit, so the worker path is the
# only path these checks exercise.

const SEED := 20261023
const BLOCK := 10

const VoxelBrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")

# A job that stops after a fixed number of checkpoints. The sampler uses it to
# prove that the dense union checks the cancel flag while it builds rows and while
# it emits them.
class CountingJob extends VoxelFrame.EditJob:
	var limit := 1
	var calls := 0

	func checkpoint(_completed: int) -> bool:
		calls += 1
		return calls < limit

var _settings := preload("res://plugins/paint/settings.tres")

var viewport: SubViewport
var center := Vector2.ZERO
var tool: Node3D
var frame: VoxelFrame
var _first_job: VoxelFrame.EditJob
var _a_cells: Array[Vector3i] = []
var _spots: Array[Vector3i] = []
var _local: Array[Vector3i] = []
var _context: VoxelFrame.EditContext
var _material := PackedFloat32Array()
var _inline: Array[Vector3i] = []
var _inline_state := 0
var _rng_before := 0
var _accepted_job: VoxelFrame.EditJob


func _ready() -> void:
	timeout = 60.0
	test("Escape then an immediate repress waits for the retired runner", _lifecycle_cancel_repress, "lifecycle_cancel")
	test("a queued brush cell keeps the settings captured when it was accepted", _lifecycle_intent_settings, "lifecycle_intent")
	test("a queued large cell keeps its ROI after the live settings shrink", _lifecycle_decrease_intent, "lifecycle_intent_decrease")
	test("a press paints its own cell while another hover waits", _lifecycle_press_own_cell, "lifecycle_press")
	test("a cancelled dense union publishes no partial batch", _lifecycle_cancel_checkpoints, "lifecycle_checkpoints")
	test("the worker draws the same state as the inline path", _lifecycle_rng_parity, "lifecycle_rng")


# Each check starts from a fresh document, the default symmetry, and the default
# spray options. A previous check may have switched the active tool, so the spray
# can is selected again.
func before_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.current_color = Color.RED
	_settings.diameter = 1
	_settings.spot_diameter = 1
	_settings.spray_size = 9
	_settings.speed = 8
	frame = State.get_current_voxel_frame()
	viewport = editor_viewport()
	viewport.get_parent().stretch = false
	viewport.size = Vector2i(800, 500)
	center = Vector2(400.0, 250.0)
	camera_rig().is_orthogonal = true
	camera_rig().set_view("top")
	select_toolbar_item("paint", "Spray Can")
	tool = plugin("PaintPlugin")._spray_tool
	tool.seed_spray(SEED)
	await get_tree().process_frame
	tool.clear_shape_caches()
	tool._invalidate_batch()
	tool._hover_installed_epoch = 0


# A solid block around the origin, so the search sphere and the spot sphere are
# fully occupied and the reach estimate passes the inline limit.
func _block(half: int) -> void:
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	for x in range(-half, half + 1):
		for y in range(-half, half + 1):
			for z in range(-half, half + 1):
				frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.BLUE))
	camera_rig().center_on(frame.get_bounds())
	# A new document drops the preview surface of the previous fixture.
	tool._clear_cursor_preview()


# A wide slab whose top face sits on the chunk boundary at y=16. A width 17
# search at the top face crosses two occupied chunk rows, so the work estimate
# passes the inline limit, and the two press cells stay outside each other's
# reach.
func _press_slab() -> void:
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	var blue := VoxelFrame.material(Color.BLUE)
	for x in range(-17, 18):
		for y in range(-10, 17):
			for z in range(-8, 9):
				frame.set_cell(Vector3i(x, y, z), blue)
	camera_rig().center_on(frame.get_bounds())
	tool._clear_cursor_preview()


func _painted_cells() -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	for cell in frame.positions():
		if frame.get_color(cell) != Color.BLUE:
			cells.append(cell)
	return cells


func _painted_count() -> int:
	return _painted_cells().size()


func _screen_pos_of(cell: Vector3i) -> Vector2:
	return camera_rig().unproject_position(Vector3(cell))


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


func _motion(pos: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.push_input(event)


func _hover(pos: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	viewport.push_input(event)


func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	get_tree().root.push_input(event)


# Waits until the samples, the runner, the write jobs, and the cursor settle. A
# worker sample installs from `_process`, so the check must let the frames run.
func _settle() -> void:
	for i in 600:
		if tool.is_sample_settled() and not tool._intent_running and tool._job == null and tool._pending_centers.is_empty():
			await get_tree().process_frame
			return
		await get_tree().process_frame


func _settle_cursor() -> void:
	var cursor := tool.get_node("Cursor")
	for i in 600:
		if cursor.is_settled():
			await get_tree().process_frame
			return
		await get_tree().process_frame


# The large sizes of the worker checks. The solid half-width block keeps the
# occupied reach estimate well above the inline limit at search 33.
func _use_large() -> void:
	_block(8)
	_settings.spot_diameter = 4
	_settings.spray_size = 33
	_settings.speed = 16
	tool.clear_shape_caches()
	tool._invalidate_batch()


func _lifecycle_cancel_repress() -> void:
	step("Given a drag stroke with a queued worker sample", func():
		_use_large()
		_hover(center)
		_press(center)
		_motion(_screen_pos_of(Vector3i(4, 8, 0)))
		expect(tool._intent_running or tool._sample_job != null, "the accepted sample is still live")
	)
	step("When Escape cancels and the user presses again in the same frame", func():
		_key(KEY_ESCAPE)
		expect(tool._edit == null, "Escape releases the edit")
		expect(tool._intent_running or tool._sample_job != null, "the cancelled runner still retires")
		_press(center)
		expect(tool._edit == null, "the new press waits for the retired runner")
		expect(tool._pending_intents.is_empty(), "the rejected press queues no stranded cell")
	)
	step("When the user releases the rejected press", func():
		_release(center)
		expect(tool._edit == null, "the release cannot reopen the rejected stroke")
		expect(not tool._stroke_active, "the rejected press leaves no active stroke")
	)
	await _settle()
	step("When the user presses after the runner retired", func():
		expect(not tool._intent_running and tool._sample_job == null, "the old runner retired")
		_press(center)
		expect(tool._edit != null, "the later press opens a fresh stroke")
	)
	await _settle()
	step("Then the fresh press paints its own batch", func():
		expect(_painted_count() > 0, "the fresh press painted voxels")
		_release(center)
		expect(State.undo_redo.get_history_count() == 1, "the fresh click records one action")
	)


func _lifecycle_intent_settings() -> void:
	step("Given a dense block and a queued worker sample with spot 1", func():
		_block(8)
		_settings.spot_diameter = 1
		_settings.spray_size = 33
		_settings.speed = 8
		tool.clear_shape_caches()
		tool._invalidate_batch()
		_hover(center)
		_press(center)
		expect(tool._sample_job != null, "the first accepted sample runs on the worker")
		_first_job = tool._sample_job
		expect(_first_job.spot_size == 1, "the first job captured spot 1")
		expect(_first_job.search_size == 33, "the first job captured search 33")
		expect(_first_job.speed == 8, "the first job captured speed 8")
	)
	step("When the settings change and the drag accepts another cell", func():
		_settings.spot_diameter = 4
		_settings.speed = 16
		_motion(_screen_pos_of(Vector3i(4, 8, 0)))
		expect(tool._pending_intents.size() == 1, "the drag queued one accepted cell")
		var queued: Variant = tool._pending_intents[0]
		expect(queued.spot_size == 4, "the queued cell captured spot 4")
		expect(queued.speed == 16, "the queued cell captured speed 16")
	)
	await _settle()
	step("Then the first sample keeps its captured settings and the stroke paints", func():
		expect(_first_job.spot_size == 1, "the first sample never took the later spot")
		expect(_first_job.speed == 8, "the first sample never took the later speed")
		expect(_painted_count() > 0, "both accepted cells painted")
		_release(_screen_pos_of(Vector3i(4, 8, 0)))
		expect(State.undo_redo.get_history_count() == 1, "the drag records one action")
	)


func _lifecycle_decrease_intent() -> void:
	step("Given a frozen selection with a far mirror and captured large sizes", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		var blue := VoxelFrame.material(Color.BLUE)
		frame.set_cell(Vector3i(16, 0, 0), blue)
		frame.set_cell(Vector3i(-17, 0, 0), blue)
		State.clear_selection()
		State.selection.add(Vector3i(16, 0, 0))
		State.selection.add(Vector3i(-17, 0, 0))
		State.selection_changed.emit()
		State.symmetry_axes = 1
		State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
		_settings.spot_diameter = 4
		_settings.spray_size = 33
		_settings.speed = 1
		tool.clear_shape_caches()
		tool._invalidate_batch()
		tool.clear_selection_cache()
		_context = State.drawing_context()
		_material = VoxelFrame.material(Color.WHITE)
		# A busy runner makes `_accept_intent` only queue the cell, so the live
		# settings can shrink before the job builds.
		tool._intent_running = true
		tool._accept_intent(Vector3i(8, 0, 0), frame, _context, _material, 5000)
		expect(tool._pending_intents.size() == 1, "the large cell waits in the intent queue")
		expect(tool._pending_intents[0].search_size == 33, "the intent captured search 33")
		expect(tool._pending_intents[0].spot_size == 4, "the intent captured spot 4")
	)
	step("When the live settings shrink before the queued job builds", func():
		_settings.spot_diameter = 1
		_settings.spray_size = 9
		_settings.speed = 1
		# The frozen reference uses the captured sizes while the live settings
		# are already small.
		tool.seed_spray(SEED)
		_inline = tool._sample(Vector3i(8, 0, 0), frame, _context, null, _material, 4, 33, 1)
		_inline_state = tool._rng.state
		tool.seed_spray(SEED)
		tool.clear_selection_cache()
		tool.open_stroke()
		expect(tool._edit != null, "the check opened a stroke transaction")
		tool._intent_running = false
	)
	await tool._run_intents()
	await _settle()
	step("Then the job used the captured ROI and drew the frozen intent", func():
		expect(tool.preview_cells() == _inline, "the queued job keeps the frozen inline cells")
		expect(_inline.has(Vector3i(16, 0, 0)) and _inline.has(Vector3i(-17, 0, 0)), "the frozen output holds the base and the far mirror")
		expect(tool._rng.state == _inline_state, "the queued job consumes the same draws")
		# The small live box covers neither the base chunk nor the mirror chunk.
		expect(tool.last_capture_chunks == 2, "the large ROI captured the base and the far mirror chunk")
		expect(tool._selection_index == null, "a two-cell selection needs no mask cache")
		if tool._edit != null:
			State.cancel_edit(tool._edit)
			tool._edit = null
	)


func _lifecycle_press_own_cell() -> void:
	var a := Vector3i(-9, 16, 0)
	var b := Vector3i(9, 16, 0)
	step("Given a wide slab and an installed batch at cell A", func():
		_press_slab()
		_settings.spot_diameter = 1
		_settings.spray_size = 17
		_settings.speed = 8
		tool.clear_shape_caches()
		tool._invalidate_batch()
		_hover(_screen_pos_of(a))
	)
	await _settle()
	await _settle_cursor()
	step("Then A is the installed batch", func():
		expect(tool._batch_center == a, "the installed batch belongs to A")
		_a_cells = tool.preview_cells()
		expect(_a_cells.size() > 0, "A holds cells")
	)
	step("When B hovers and the user presses B before it installs", func():
		_hover(_screen_pos_of(b))
		expect(tool._hover_sample_job != null, "B samples on the worker")
		expect(tool._batch_center == a, "B has not installed yet")
		_press(_screen_pos_of(b))
		expect(tool._edit != null, "the press opens its stroke")
		expect(tool._batch_center != a, "the press dropped the stale batch A")
	)
	await _settle()
	step("Then the press painted B and never A", func():
		expect(tool._batch_center == b, "the adopted batch belongs to B")
		var reach := VoxelBrushSize.reach(17) + VoxelBrushSize.reach(1)
		var limit := reach * reach
		var painted := _painted_cells()
		expect(painted.size() > 0, "the press painted voxels")
		var outside_b := 0
		var near_a := 0
		for cell in painted:
			if Vector3(cell - b).length_squared() > float(limit):
				outside_b += 1
			if Vector3(cell - a).length_squared() <= float(limit):
				near_a += 1
		expect(outside_b == 0, "every painted cell lies inside B's captured reach")
		expect(near_a == 0, "no painted cell belongs to A's reach")
		_release(_screen_pos_of(b))
		expect(State.undo_redo.get_history_count() == 1, "the click records one action")
	)


func _lifecycle_cancel_checkpoints() -> void:
	step("Given a dense block and four maximum spot centers", func():
		_block(8)
		_settings.spot_diameter = 64
		_settings.spray_size = 64
		_settings.speed = 64
		tool.clear_shape_caches()
		tool._batch_material = VoxelFrame.material(Color.WHITE)
		_local = []
		for cell in frame.positions():
			_local.append(cell)
		_spots = [Vector3i.ZERO, Vector3i(20, 0, 0), Vector3i(0, -20, 12), Vector3i(9, 9, 9)]
	)
	step("When the dense row build is cancelled", func():
		var job := CountingJob.new()
		job.limit = 2
		var result: Dictionary = tool._footprints(_spots, _local, 64, VoxelFrame.material(Color.WHITE), job)
		expect(result.is_empty(), "a cancelled row build returns no partial cells")
		expect(job.calls == 2, "the row build checked the cancel flag twice")
	)
	step("When the dense row emission is cancelled", func():
		var job := CountingJob.new()
		job.limit = 5
		var result: Dictionary = tool._footprints(_spots, _local, 64, VoxelFrame.material(Color.WHITE), job)
		expect(result.is_empty(), "a cancelled row emission returns no partial cells")
		expect(job.calls == 5, "the row union checked the cancel flag through emission")
	)
	step("When a sample job is cancelled before it runs", func():
		var job: VoxelFrame.EditJob = tool._build_sample_job(frame, Vector3i.ZERO, State.drawing_context(), VoxelFrame.material(Color.WHITE), 5000)
		job.cancel()
		job.run()
		expect(job.cells.is_empty(), "a cancelled sample publishes no cells")
		expect(job.preview_payload == null, "a cancelled sample publishes no preview payload")
	)


func _lifecycle_rng_parity() -> void:
	step("Given a small dense block and one seed", func():
		_block(3)
		_settings.spot_diameter = 1
		_settings.spray_size = 9
		_settings.speed = 8
		tool.clear_shape_caches()
		tool._invalidate_batch()
		tool.seed_spray(SEED)
		_context = State.drawing_context()
		_material = VoxelFrame.material(Color.WHITE)
		var inline_cells: Array[Vector3i] = tool._sample(Vector3i(0, 3, 0), frame, _context, null, _material)
		_inline = inline_cells
		_inline_state = tool._rng.state
	)
	step("When the worker samples from the same captured state", func():
		tool.seed_spray(SEED)
		var job: VoxelFrame.EditJob = tool._build_sample_job(frame, Vector3i(0, 3, 0), _context, _material, 5000)
		job.run()
		expect(job.cells == _inline, "the worker draws the exact inline cells")
		expect(job.result_state == _inline_state, "the worker ends on the exact inline state")
	)
	step("When an obsolete hover starts on the worker", func():
		_use_large()
		tool.seed_spray(SEED)
		_rng_before = tool._rng.state
		_hover(center)
		expect(tool._hover_sample_job != null, "the hover samples on the worker")
		tool._invalidate_batch()
	)
	await _settle()
	step("Then the cancelled hover advances no shared draw", func():
		expect(tool._rng.state == _rng_before, "the cancelled hover advances no shared draw")
	)
	step("When an accepted worker batch starts", func():
		_use_large()
		tool.seed_spray(SEED)
		_hover(center)
		_press(center)
		_accepted_job = tool._sample_job
		expect(_accepted_job != null, "the press accepted a worker sample")
	)
	await _settle()
	step("Then the adopted batch commits its end state", func():
		expect(tool._rng.state == _accepted_job.result_state, "the adopted batch commits its end state")
		expect(_painted_count() > 0, "the accepted batch painted")
		_release(center)
		expect(State.undo_redo.get_history_count() == 1, "the click records one action")
	)
