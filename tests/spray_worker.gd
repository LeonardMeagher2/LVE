extends "res://tests/test.gd"

# Focused checks for the spray worker sample pipeline.
#
# The checks cover the parts that a synchronous sampler cannot show: a large
# batch computing on the worker pool, the install of its exact cells, the first
# click while a sample waits, the accepted stroke cells that a release, a switch,
# and a cancel must keep or drop, and the stale results that must never install.
#
# The checks drive the real viewport input path, so the picked cell and the
# painted cells go through the production event handling. The large sizes place
# the occupied reach estimate above the inline limit, so the worker path is the
# only path these tests exercise.

const SEED := 20261023
const BLOCK := 8
const SMALL_BLOCK := 6

const VoxelBrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")
const VoxelPreview := preload("res://Globals/Rendering/VoxelPreview.gd")

var _settings := preload("res://plugins/paint/settings.tres")

var viewport: SubViewport
var center := Vector2.ZERO
var tool: Node3D
var frame: VoxelFrame
var before: VoxelFrame
var preview: Array[Vector3i] = []
var cells: Array[Vector3i] = []
var _painted_before := 0
var _pre_press_painted := 0
var _block_cells := 0
var _payload


func _ready() -> void:
	timeout = 60.0
	test("a large hover samples on the worker and installs its exact batch", _worker_hover, "worker_hover")
	test("the first click while a sample waits paints its own captured batch", _worker_press, "worker_press")
	test("a release waits for the accepted worker sample of the stroke", _worker_deferred_release, "worker_release")
	test("Escape drops the queued worker work and a new press starts clean", _worker_cancel_repress, "worker_cancel")
	test("a tool switch commits the queued worker work as one action", _worker_switch, "worker_switch")
	test("a stale worker result never installs over the current batch", _worker_stale, "worker_stale")
	test("the worker builds a prepared preview payload the install path submits", _worker_prepared_payload, "worker_prepared")


# Each check starts from a fresh document, the default symmetry, and the default
# spray options. A previous check may have switched the active tool, so the spray
# can is selected again.
func _setup_test() -> void:
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
	_block_cells = frame.count()
	# A new document drops the preview surface of the previous fixture.
	tool._clear_cursor_preview()


func _painted_count() -> int:
	var count := 0
	for cell in frame.positions():
		if frame.get_color(cell) != Color.BLUE:
			count += 1
	return count


func _same_cell_set(first: Array[Vector3i], second: Array[Vector3i]) -> bool:
	if first.size() != second.size():
		return false
	var lookup := {}
	for cell in second:
		lookup[cell] = true
	for cell in first:
		if not lookup.has(cell):
			return false
	return true


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


func _hover_cell(cell: Vector3i) -> void:
	var pick := PickResult.new()
	pick.target = cell
	pick.hit = cell
	tool.update_visual(pick)


func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	get_tree().root.push_input(event)


# Waits until the samples, the write jobs, and the cursor settle. A worker sample
# installs from `_process`, so the check must let the frames run.
func _settle() -> void:
	for i in 600:
		if tool.is_sample_settled() and tool._job == null and tool._pending_centers.is_empty():
			await get_tree().process_frame
			return
		await get_tree().process_frame


# The large sizes of every worker check. The solid half-width block keeps the
# occupied reach estimate well above the inline limit.
func _use_large() -> void:
	_block(BLOCK)
	_settings.spot_diameter = 4
	_settings.spray_size = 17
	_settings.speed = 16
	tool.clear_shape_caches()
	tool._invalidate_batch()


func _worker_hover() -> void:
	step("Given a dense block and a size whose reach passes the inline limit", func():
		_block(BLOCK)
		_settings.spot_diameter = 1
		_settings.spray_size = 17
		_settings.speed = 8
		tool._invalidate_batch()
	)
	step("When the pointer hovers one voxel", func():
		_hover(center)
		expect(tool._hover_sample_job != null, "the large batch samples on the worker")
		expect(tool.preview_cells().is_empty(), "the worker sample does not block the input frame")
	)
	await _settle()
	step("Then the worker batch installs its exact cells", func():
		preview = tool.preview_cells()
		expect(preview.size() > 0, "the worker sample installed a batch")
		expect(tool._hover_sample_job == null, "the finished sample released its handle")
		for cell in preview:
			expect(frame.has(cell), "every installed cell is an existing voxel")
			expect(VoxelBrushSize.contains_sphere(17, cell - tool._batch_center), "every installed cell is inside the search sphere")
	)
	await _settle_cursor()
	step("When the user presses", func():
		var shown: Array[Vector3i] = []
		shown.assign(tool._installed_cells().keys() if not tool._installed_cells().is_empty() else preview)
		_press(center)
		expect(tool._edit != null, "the press opens the stroke")
		expect(_painted_count() > 0, "the press painted voxels")
		expect(_same_cell_set(tool.preview_cells(), preview), "the press kept the installed batch")
		for cell in preview:
			expect(frame.get_color(cell) == State.current_color, "every installed cell took the paint material")
		expect(shown.size() > 0, "the cursor offered a surface")
		_release(center)
		expect(State.undo_redo.get_history_count() == 1, "the click records one action")
	)


func _worker_press() -> void:
	step("Given a dense block and a large spot", func():
		_use_large()
	)
	step("When the user presses before the hover sample installs", func():
		_hover(center)
		expect(tool._hover_sample_job != null, "the hover sample waits on the worker")
		_press(center)
		expect(tool._edit != null, "the press opens its stroke")
		expect(tool._pending_intents.size() + (1 if tool._sample_job != null else 0) > 0, "the large press queues one accepted batch instead of blocking the input")
	)
	await _settle()
	step("Then the queued press batch painted and the stroke is not stranded", func():
		expect(_painted_count() > 0, "the first click paints its own batch and never an empty one")
		preview = tool.preview_cells()
		expect(preview.size() > 0, "the press captured a batch")
		for cell in preview:
			expect(frame.has(cell), "every captured cell is an existing voxel")
			expect(frame.get_color(cell) == State.current_color, "every captured cell took the paint material")
		_release(center)
		expect(State.undo_redo.get_history_count() == 1, "the click records one action")
		expect(tool._edit == null, "the click closed its stroke")
	)


func _worker_deferred_release() -> void:
	step("Given a drag stroke with a queued worker sample", func():
		_use_large()
		before = frame.copy_frame()
	)
	step("When the user presses, drags to another voxel, and releases", func():
		_hover(center)
		_press(center)
		_pre_press_painted = _painted_count()
		_motion(_screen_pos_of(Vector3i(4, BLOCK, 0)))
		_release(_screen_pos_of(Vector3i(4, BLOCK, 0)))
	)
	await _settle()
	step("Then every accepted batch wrote before the stroke closed", func():
		expect(tool._edit == null, "the release closed the stroke")
		expect(State.undo_redo.get_history_count() == 1, "the drag records one action")
		expect(tool._pending_intents.is_empty(), "the queued brush cells drained")
		expect(_painted_count() > _pre_press_painted, "the accepted press and drag batches painted new voxels")
		expect(_painted_count() < _block_cells, "the spray changes existing voxels only")
	)


func _worker_cancel_repress() -> void:
	step("Given a drag stroke with a queued worker sample", func():
		_use_large()
		before = frame.copy_frame()
	)
	step("When the user presses, drags, and presses Escape", func():
		_hover(center)
		_press(center)
		_motion(_screen_pos_of(Vector3i(4, BLOCK, 0)))
		_key(KEY_ESCAPE)
	)
	await _settle()
	step("Then the spray rolls back and holds no queued work", func():
		expect(frame.storage_data() == before.storage_data(), "Escape restores the block exactly")
		expect(not State.undo_redo.has_undo(), "the cancelled spray records no history")
		expect(tool._edit == null, "the cancelled spray releases its edit")
		expect(tool._pending_intents.is_empty(), "the cancel drops the queued brush cells")
		expect(tool._sample_job == null, "the cancel joins the stroke sample")
	)
	step("When the user presses again", func():
		_press(center)
		expect(tool._edit != null, "a new press after a cancel opens a stroke")
	)
	await _settle()
	step("Then the new press painted its own batch", func():
		expect(_painted_count() > 0, "the new press paints its own batch")
		preview = tool.preview_cells()
		expect(preview.size() > 0, "the new press captured a batch")
		_release(center)
		expect(State.undo_redo.get_history_count() == 1, "the new click records one action")
	)


func _worker_switch() -> void:
	step("Given a drag stroke with a queued worker sample", func():
		_use_large()
		before = frame.copy_frame()
	)
	step("When the user presses, drags, and switches to the brush", func():
		_hover(center)
		_press(center)
		_painted_before = _painted_count()
		_motion(_screen_pos_of(Vector3i(4, BLOCK, 0)))
		activate_tool("Toolbar")
	)
	await _settle()
	step("Then the switch commits the queued work as one action", func():
		expect(tool._edit == null, "the switch releases the spray edit")
		expect(State.undo_redo.get_history_count() == 1, "the switched spray records one action")
		expect(tool._pending_intents.is_empty(), "the queue drained")
		expect(_painted_count() > _painted_before, "the queued worker batch still wrote")
		State.undo_redo.undo()
		expect(frame.storage_data() == before.storage_data(), "one undo restores the block after the switch")
	)


func _worker_stale() -> void:
	step("Given a finished worker sample", func():
		_block(SMALL_BLOCK)
		_settings.spot_diameter = 1
		_settings.spray_size = 9
		_settings.speed = 8
		tool._invalidate_batch()
		tool._hover_installed_epoch = 0
		var job: VoxelFrame.EditJob = tool._build_sample_job(frame, Vector3i.ZERO, State.drawing_context(), VoxelFrame.material(Color.WHITE), 5000)
		job.request_epoch = 10
		job.run()
		tool._install_hover(job)
		preview = tool.preview_cells()
		expect(preview.size() > 0, "the finished sample installs its batch")
		expect(tool._batch_center == Vector3i.ZERO, "the installed batch belongs to its cell")
	)
	step("When an older result arrives", func():
		var older: VoxelFrame.EditJob = tool._build_sample_job(frame, Vector3i.ZERO, State.drawing_context(), VoxelFrame.material(Color.WHITE), 5000)
		older.request_epoch = 5
		older.run()
		tool._install_hover(older)
		expect(tool.preview_cells() == preview, "an older result never replaces the installed batch")
	)
	step("When the edit context changed since the sample", func():
		var stale: VoxelFrame.EditJob = tool._build_sample_job(frame, Vector3i.ZERO, State.drawing_context(), VoxelFrame.material(Color.WHITE), 5000)
		stale.axes = 1
		stale.request_epoch = 20
		stale.run()
		tool._install_hover(stale)
		expect(tool.preview_cells() == preview, "a result of another edit context is dropped")
	)
	step("When the frame lost a sampled cell", func():
		var stale: VoxelFrame.EditJob = tool._build_sample_job(frame, Vector3i.ZERO, State.drawing_context(), VoxelFrame.material(Color.WHITE), 5000)
		stale.request_epoch = 30
		stale.run()
		var victim: Vector3i = stale.cells[0]
		frame.set_cell(victim, VoxelFrame.material(Color.TRANSPARENT))
		tool._install_hover(stale)
		expect(tool.preview_cells().is_empty(), "a batch that holds a removed cell is dropped")
	)
	step("When the live frame was replaced", func():
		var job: VoxelFrame.EditJob = tool._build_sample_job(frame, Vector3i.ZERO, State.drawing_context(), VoxelFrame.material(Color.WHITE), 5000)
		job.request_epoch = 40
		job.run()
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		tool._install_hover(job)
		expect(tool.preview_cells().is_empty(), "a result of another frame is dropped")
	)


# The worker builds the prepared preview payload off the main thread, and the
# install path submits it without rebuilding the color dictionary. The cursor
# then installs the payload dictionary itself, so a click validates the visible
# surface by identity.
func _worker_prepared_payload() -> void:
	step("Given a dense block and a large sample job", func():
		_use_large()
		tool._invalidate_batch()
		tool._hover_installed_epoch = 0
		var job: VoxelFrame.EditJob = tool._build_sample_job(frame, Vector3i.ZERO, State.drawing_context(), VoxelFrame.material(Color.WHITE), 5000)
		job.run()
		_payload = job.preview_payload
		expect(_payload != null, "the worker built a prepared payload")
		expect(_payload.cell_count == job.cells.size(), "the payload holds every sampled cell")
		expect(_payload.spots.is_read_only(), "the payload dictionary is read-only")
		expect(_payload.cell_hash == VoxelPreview._cell_hash(_payload.spots, false), "the payload carries the exact cell hash")
		expect(_same_cell_set(job.cells, _payload_cells(_payload)), "the payload keys are the sampled cells")
	)
	step("When the finished sample installs through the prepared path", func():
		# Clear the mesh cache, so the install really builds and the install records
		# the payload dictionary itself.
		VoxelPreview._mesh_cache.clear()
		var job: VoxelFrame.EditJob = tool._build_sample_job(frame, Vector3i.ZERO, State.drawing_context(), VoxelFrame.material(Color.WHITE), 5000)
		job.request_epoch = 1
		job.run()
		_payload = job.preview_payload
		tool._install_hover(job)
		expect(tool._batch_payload == _payload, "the install adopted the prepared payload")
		expect(is_same(tool._shown_spots, _payload.spots), "the show path hands the payload dictionary without a rebuild")
	)
	await _settle()
	await _settle_cursor()
	step("Then the cursor installed the exact prepared cells", func():
		expect(tool.preview_cells().size() == _payload.cell_count, "the cursor installed the same cell count")
		expect(is_same(tool._installed_cells(), _payload.spots), "the cursor installed the payload dictionary itself")
	)


# Waits for the cursor's preview worker, so the install is observed.
func _settle_cursor() -> void:
	var cursor := tool.get_node("Cursor")
	for i in 600:
		if cursor.is_settled():
			await get_tree().process_frame
			return
		await get_tree().process_frame


func _payload_cells(payload) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	result.assign(payload.spots.keys())
	return result
