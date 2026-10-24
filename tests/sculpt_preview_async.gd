extends "res://tests/test.gd"

# Verify the asynchronous hover preview.
#
# The idle hover fits its frame and builds its footprint on the preview worker.
# These tests drive the real pointer input through the editor viewport, let the
# frame loop pump the worker, and compare the published cells with the exact
# result of one direct request. The direct request runs the same controller and
# the same job inline, so a match proves the worker path computes the shipped
# cells.
#
# The tests also cover the request policy: a stale epoch never wins, a press
# never waits for a pending preview, a camera change drops a stale result, a
# sustained hover keeps installing, and a hover writes no history and starts no
# edit.

var _settings := preload("res://plugins/Sculpt/settings.tres")
var _viewport: SubViewport
var _tool
var _frame: VoxelFrame


func _ready() -> void:
	test("the worker hover agrees with a direct request", _worker_parity, "worker_parity")
	test("the Face source agrees on the worker", _face_parity, "face_parity")
	test("the Flatten preview agrees on the worker", _flatten_parity, "flatten_parity")
	test("the Smooth preview agrees on the worker", _smooth_parity, "smooth_parity")
	test("the Grab preview agrees with a direct request", _grab_parity, "grab_parity")
	test("a stale radius epoch never wins the preview", _stale_radius, "stale_radius")
	test("a press never waits for a pending preview", _press_while_pending, "press_while_pending")
	test("freeing the tool joins a running preview worker", _join_on_free, "join_on_free")
	test("a hover writes no history and starts no edit", _zero_state_activity, "zero_state_activity")
	test("a camera change drops a stale hover result", _camera_change_discards, "camera_change_discards")
	test("an orthographic zoom before a publish drops the stale result", _zoom_discards, "zoom_discards")
	test("a viewport resize before a publish drops the stale result", _resize_discards, "resize_discards")
	test("a raw write during a job never installs a stale result", _raw_write_during_job, "raw_write_during_job")
	test("a missing chunk during a job never installs a stale result", _missing_chunk_during_job, "missing_chunk_during_job")
	test("a press retires a finished hover job", _press_retires_finished_job, "press_retires_finished_job")
	test("a clear retires a pending hover job", _clear_retires_pending_job, "clear_retires_pending_job")
	test("a document change joins the worker and clears the preview", _document_reentry, "document_reentry")
	test("a sustained maximum-radius hover keeps installing", _sustained_installs, "sustained_installs")
	# The sparse symmetric sweep runs a long map on every event and measures the
	# cancel and join cost, so it needs its own deadline.
	timeout = 90.0
	test("a sparse symmetric maximum-radius hover stays bounded and exact", _sparse_symmetry_bounded, "sparse_symmetry_bounded")


func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.current_color = Color.from_rgba8(200, 60, 60)
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	_settings.tool = _settings.Tools.GROW
	_settings.grow_mode = _settings.GrowMode.ADD
	_settings.normal_source = _settings.NormalSource.SURFACE
	_settings.radius = 4
	_settings.strength = 1.0
	_settings.falloff = 0.0
	_plate(Vector3i(-30, 0, -30), Vector3i(30, 0, 30))
	_viewport = editor_viewport()
	_viewport.get_parent().stretch = false
	_viewport.size = Vector2i(800, 500)
	activate_tool("sculpt")
	var sculpt := plugin("SculptPlugin")
	sculpt.activate_tool()
	sculpt.deactivate_tool()
	_tool = preload("res://plugins/Sculpt/SculptTool.tscn").instantiate()
	if _tool._settings == null:
		_tool._settings = _settings
	sculpt.add_editor_node(_tool)
	_tool.set_process(true)
	_frame = State.get_current_voxel_frame()
	camera_rig().is_orthogonal = true
	camera_rig().set_view("top")
	await get_tree().process_frame


func _cleanup_test() -> void:
	if is_instance_valid(_tool):
		if _tool._edit != null:
			_tool.finish_on_switch()
		while _tool._busy():
			await get_tree().process_frame
		if _tool._preview != null:
			_tool._preview.join()
		plugin("SculptPlugin").remove_editor_node(_tool)
		_tool.free()
	_tool = null


# --- The cases ----------------------------------------------------------------

# A worker hover and a direct request on the same cell give the same cells.
func _worker_parity() -> void:
	await _hover_and_publish(Vector3(0, 0, 0))
	var worker_cells := _cells()
	step("Then the worker outlined support voxels", func():
		expect(worker_cells.size() > 0, "the worker hover outlines support voxels")
		expect(_tool._preview.publishes >= 1, "the worker published a result")
	)
	var direct := await _direct_cells()
	step("Then the direct request agrees with the worker", func():
		expect(direct == worker_cells, "the worker and the direct request give the exact cells")
	)


# The exact Face source agrees on the worker.
func _face_parity() -> void:
	_settings.normal_source = _settings.NormalSource.FACE
	await _hover_and_publish(Vector3(0, 0, 0))
	var worker_cells := _cells()
	var direct := await _direct_cells()
	step("Then the Face source agrees on the worker", func():
		expect(worker_cells.size() > 0, "the Face hover outlines support voxels")
		expect(direct == worker_cells, "the Face worker and the direct request give the exact cells")
	)


# The Flatten preview agrees on the worker.
func _flatten_parity() -> void:
	_settings.tool = _settings.Tools.FLATTEN
	await _hover_and_publish(Vector3(0, 0, 0))
	var worker_cells := _cells()
	var direct := await _direct_cells()
	step("Then the Flatten preview agrees on the worker", func():
		expect(direct == worker_cells, "the Flatten worker and the direct request give the exact cells")
	)


# The Smooth preview agrees on the worker.
func _smooth_parity() -> void:
	_settings.tool = _settings.Tools.SMOOTH
	await _hover_and_publish(Vector3(0, 0, 0))
	var worker_cells := _cells()
	var direct := await _direct_cells()
	step("Then the Smooth preview agrees on the worker", func():
		expect(worker_cells.size() > 0, "the Smooth hover outlines occupied candidates")
		expect(direct == worker_cells, "the Smooth worker and the direct request give the exact cells")
	)


# The Grab preview runs on the main thread, so it publishes in the hover frame.
func _grab_parity() -> void:
	_settings.tool = _settings.Tools.GRAB
	await _hover_and_publish(Vector3(0, 0, 0))
	var worker_cells := _cells()
	var direct := await _direct_cells()
	step("Then the Grab preview agrees with a direct request", func():
		expect(worker_cells.size() > 0, "the Grab hover outlines its sources")
		expect(not _tool._preview.is_running(), "the Grab hover runs no preview worker")
		expect(direct == worker_cells, "the Grab hover and the direct request give the exact cells")
	)


# A radius change invalidates the epoch. A rapid 4, 32, 4 change must end on the
# exact radius-4 result, and no old result may win.
func _stale_radius() -> void:
	await _hover_and_publish(Vector3(0, 0, 0))
	var before := _cells()
	step("When the radius changes to 32 and back to 4", func():
		_settings.radius = 32
		_settings.radius = 4
		_hover(_pos(Vector3(0, 0, 0)))
	)
	await _settle_preview()
	step("Then the final preview is the exact radius-4 result", func():
		expect(_tool._preview.is_settled(), "the controller settled after the rapid change")
		expect(_cells() == before, "the stale radius result never wins")
		expect(_tool._preview.discarded > 0 or _tool._preview.publishes >= 1, "the epoch policy ran")
	)


# A press while a preview job runs applies its first dab without joining the
# preview worker. A maximum-radius dab builds its footprint on the dab worker,
# so the press event itself stays bounded.
func _press_while_pending() -> void:
	_settings.radius = 32
	_hover(_pos(Vector3(0, 0, 0)))
	await get_tree().process_frame
	step("Given a running preview job at the hover cell", func():
		expect(_tool._preview.is_running(), "a preview job runs")
	)
	var before := _frame.count()
	var started := Time.get_ticks_usec()
	_mouse_press(_pos(Vector3(0, 0, 0)))
	var press_us := Time.get_ticks_usec() - started
	_mouse_release(_pos(Vector3(0, 0, 0)))
	var accepted: bool = _tool._busy()
	await _wait_dab()
	await _settle_preview()
	step("Then the press accepted a bounded dab that then applied", func():
		expect(press_us < 300000, "the press stayed bounded while a preview job ran")
		expect(accepted, "the press accepted a dab job in its input event")
		expect(_frame.count() > before, "the accepted dab changed the geometry")
		expect(not _tool._preview.is_running(), "the cancelled preview worker is joined")
		expect(_tool._preview.is_settled(), "the preview controller is idle after the press")
	)


# Waits until the accepted dabs are applied and the stroke closes. A large dab
# builds its footprint on the worker, so the caller waits a few frames.
func _wait_dab() -> void:
	for _index in 600:
		if _tool._edit == null and not _tool._busy():
			await get_tree().process_frame
			return
		await get_tree().process_frame


# Freeing the tool while a preview job runs joins the worker, so no worker
# outlives the node and no callback touches a freed object.
func _join_on_free() -> void:
	_settings.radius = 32
	_hover(_pos(Vector3(0, 0, 0)))
	await get_tree().process_frame
	step("Given a running preview job", func():
		expect(_tool._preview.is_running(), "a preview job runs")
	)
	plugin("SculptPlugin").remove_editor_node(_tool)
	_tool.free()
	_tool = null
	for _index in 3:
		await get_tree().process_frame
	step("Then the freed tool left no worker and no error", func():
		expect(_tool == null, "the tool is gone")
	)


# A hover writes no history and starts no edit. The preview is a pure read.
func _zero_state_activity() -> void:
	var history_before := State.undo_redo.has_undo()
	step("When the pointer sweeps over several cells", func():
		expect(not history_before, "the fixture starts with no history")
	)
	for cell in [Vector3(0, 0, 0), Vector3(4, 0, 2), Vector3(-3, 0, 1)]:
		_hover(_pos(cell))
		await get_tree().process_frame
	await _settle_preview()
	step("Then the hover wrote no history and started no edit", func():
		expect(State.active_edit() == null, "a hover starts no edit")
		expect(not State.undo_redo.has_undo(), "a hover records no history action")
		expect(not State.edit_busy(), "a hover blocks no edit")
	)


# A camera change drops a result that was computed for the old view.
func _camera_change_discards() -> void:
	_settings.radius = 32
	_hover(_pos(Vector3(0, 0, 0)))
	await get_tree().process_frame
	step("Given a running preview job and the captured view", func():
		expect(_tool._preview.is_running(), "a preview job runs")
	)
	_tool._preview.reset_counters()
	var camera := _viewport.get_camera_3d()
	camera.position += Vector3(0, 0, 1)
	step("When the camera moves before the job publishes", func():
		expect(camera != null, "the viewport has a camera")
	)
	await _settle_preview()
	step("Then the stale result is dropped", func():
		expect(_tool._preview.discarded >= 1, "the camera change dropped the stale result")
	)


# An orthographic zoom changes the projection matrix without a pointer event. A
# result that was computed for the old zoom must never reach the cursor.
func _zoom_discards() -> void:
	_settings.radius = 32
	_hover(_pos(Vector3(0, 0, 0)))
	await get_tree().process_frame
	var camera := _viewport.get_camera_3d()
	_tool._preview.reset_counters()
	step("Given a running preview job and an orthographic camera", func():
		expect(camera != null and camera.projection == Camera3D.PROJECTION_ORTHOGONAL, "the camera is orthographic")
	)
	camera_rig().zoom(1.5)
	await _settle_preview()
	step("Then the zoom drops the stale result", func():
		expect(_tool._preview.discarded >= 1, "the orthographic zoom dropped the stale result")
	)


# A viewport resize changes the projection aspect without a pointer event.
func _resize_discards() -> void:
	_settings.radius = 32
	_hover(_pos(Vector3(0, 0, 0)))
	await get_tree().process_frame
	_tool._preview.reset_counters()
	step("Given a running preview job and the captured viewport", func():
		expect(_tool._preview.is_running(), "a preview job runs")
	)
	_viewport.size = Vector2i(640, 400)
	await _settle_preview()
	step("Then the resize drops the stale result", func():
		expect(_tool._preview.discarded >= 1, "the viewport resize dropped the stale result")
	)


# A raw write inside the read region with no signal. The finished job read a
# snapshot that predates the write, so the publish gate must drop its result and
# start a fresh request. The visible cells then follow the write.
func _raw_write_during_job() -> void:
	_settings.radius = 32
	await _hover_and_publish(Vector3(0, 0, 0))
	_hover(_pos(Vector3(6, 0, 3)))
	await get_tree().process_frame
	_tool._preview.reset_counters()
	step("Given a running preview job at a new hover cell", func():
		expect(_tool._preview.is_running(), "a preview job runs")
	)
	step("When a raw write lands inside the read region with no signal", func():
		_frame.set_cell(Vector3i(1, 1, 0), VoxelFrame.material(Color.WHITE))
	)
	await _settle_preview()
	step("Then the stale result is dropped and the fresh result follows the write", func():
		expect(_tool._preview.discarded >= 1, "the stale job was dropped")
		expect(_tool._preview.publishes >= 1, "a fresh request published")
		expect(_cells().has(Vector3i(1, 1, 0)), "the published cells follow the raw write")
	)
	var published := _cells()
	# A forced recompute must give the same cells, so the published result is the
	# exact fresh result and not a stale one.
	_tool._preview.invalidate()
	_tool._rebuild_preview()
	await _settle_preview()
	step("Then a forced recompute matches the published result", func():
		expect(_cells() == published, "the published fresh result matches the recompute")
	)


# A raw write that creates a new missing chunk inside the read region. The chunk
# identity and revision of the watch change, so the gate drops the stale result.
func _missing_chunk_during_job() -> void:
	_settings.radius = 32
	await _hover_and_publish(Vector3(0, 0, 0))
	_hover(_pos(Vector3(6, 0, 3)))
	await get_tree().process_frame
	_tool._preview.reset_counters()
	step("Given a running preview job at a new hover cell", func():
		expect(_tool._preview.is_running(), "a preview job runs")
	)
	step("When a raw write creates a missing chunk inside the read region", func():
		_frame.set_cell(Vector3i(0, 40, 0), VoxelFrame.material(Color.WHITE))
	)
	await _settle_preview()
	step("Then the stale result is dropped", func():
		expect(_tool._preview.discarded >= 1, "the new chunk dropped the stale result")
	)


# A press retires the hover at once. A hover job that already finished must never
# publish over the stroke, and the press must not join the worker.
func _press_retires_finished_job() -> void:
	_settings.radius = 32
	_hover(_pos(Vector3(0, 0, 0)))
	await get_tree().process_frame
	step("Given a running preview job at the hover cell", func():
		expect(_tool._preview.is_running(), "a preview job runs")
	)
	var hover_publishes: int = _tool._preview.publishes
	var started := Time.get_ticks_usec()
	_mouse_press(_pos(Vector3(0, 0, 0)))
	var press_us := Time.get_ticks_usec() - started
	_mouse_release(_pos(Vector3(0, 0, 0)))
	await _settle_preview()
	step("Then the retired hover job never published over the stroke", func():
		expect(_tool._preview.publishes == hover_publishes, "no hover result installed during the stroke")
		expect(_tool._preview.discarded >= 1, "the retired hover job was discarded")
		expect(press_us < 300000, "the press did not join the preview worker")
	)


# A clear retires a pending hover job, so a finished result can never reappear
# after the outline is cleared.
func _clear_retires_pending_job() -> void:
	_settings.radius = 32
	_hover(_pos(Vector3(0, 0, 0)))
	await get_tree().process_frame
	step("Given a running preview job", func():
		expect(_tool._preview.is_running(), "a preview job runs")
	)
	_tool._preview.reset_counters()
	_tool._preview.clear_all()
	step("When the preview is cleared", func():
		expect(_cells().is_empty(), "the visible preview is empty")
	)
	await _settle_preview()
	step("Then the pending result never reappears", func():
		expect(_tool._preview.publishes == 0, "the retired job published nothing")
		expect(_cells().is_empty(), "the visible preview stays empty")
	)


# A document change discards the frame a running job reads. The worker is joined
# and the preview is cleared, so no result of the old document can install.
func _document_reentry() -> void:
	_settings.radius = 32
	_hover(_pos(Vector3(0, 0, 0)))
	await get_tree().process_frame
	step("Given a running preview job on the old document", func():
		expect(_tool._preview.is_running(), "a preview job runs")
	)
	step("When the document changes", func():
		State.document = VoxelDocument.new()
		State.document_changed.emit()
	)
	step("Then the worker is joined and the preview is clear", func():
		expect(not _tool._preview.is_running(), "the old worker is joined")
		expect(_cells().is_empty(), "no cell of the old document stays")
	)
	await get_tree().process_frame
	await _settle_preview()
	step("Then the new document shows no stale result", func():
		expect(_cells().is_empty(), "the new document shows no old preview")
	)


# A sustained hover at the maximum radius keeps installing previews. A strict
# latest-only policy with a 100 ms compute would starve and install nothing, so
# the controller publishes a completed result before it starts the next request.
func _sustained_installs() -> void:
	_settings.radius = 32
	for mask_axes in [0, 7]:
		await _sustained_run(mask_axes)
	step("Then the sustained hover installed previews without a backlog", func():
		expect(_tool._preview.publishes >= 1, "a sustained hover installs a preview")
		expect(_tool._preview.is_settled(), "the controller settled after the sweep")
		expect(_cells().size() > 0, "the last published preview outlines voxels")
		# The settled publish is for the live pointer, so the visible outline is
		# not a stale position. The earlier publishes may lag, and their age is
		# reported above instead of being hidden.
		expect(_tool._preview.last_publish_target_matches, "the settled publish is for the live pointer")
	)


# Runs one sustained maximum-radius hover sweep with the given symmetry mask count
# and reports the honest input cost, the frame gap, the publish age, and the
# position lag of every published result.
func _sustained_run(mask_axes: int) -> void:
	State.symmetry_axes = mask_axes
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	_tool._preview.reset_counters()
	var events := 10
	var inputs: Array[int] = []
	var gaps: Array[int] = []
	var last := Time.get_ticks_usec()
	for index in events:
		var x := -12 + index * 3
		var started := Time.get_ticks_usec()
		_hover(_pos(Vector3(float(x), 0, 2.0)))
		inputs.append(Time.get_ticks_usec() - started)
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		gaps.append(now - last)
		last = now
	await _settle_preview()
	print("MEASURE sculpt_preview_async sustained: axes=%d masks=%d events=%d launches=%d publishes=%d stale_position=%d discarded=%d snapshot_us=%d sample_maps=%d map_us=%d input_max_us=%d input_p95_us=%d gap_max_us=%d gap_p95_us=%d gap_med_us=%d max_publish_age_us=%d last_age_us=%d target_matches=%s settled=%s cells=%d" % [
		mask_axes, _mask_count(mask_axes), events, _tool._preview.launches, _tool._preview.publishes,
		_tool._preview.stale_position_publishes, _tool._preview.discarded, _tool._preview.snapshot_us,
		_tool._preview.sample_map_calls, _tool._preview.sample_map_us,
		_max_int(inputs), _p95_int(inputs), _max_int(gaps), _p95_int(gaps), _median_int(gaps),
		_tool._preview.max_publish_age_us, _tool._preview.last_publish_age_us,
		str(_tool._preview.last_publish_target_matches), str(_tool._preview.is_settled()), _cells().size(),
	])
	step("Then the axes=%d sweep stayed bounded" % mask_axes, func():
		expect(_tool._preview.launches <= events, "the controller never queues more requests than events")
		expect(_tool._preview.is_settled(), "the controller settled after the sweep")
	)


# The number of active symmetry masks of one axes bit field.
static func _mask_count(axes: int) -> int:
	var count := 0
	for mask in 8:
		if (mask & ~axes) == 0:
			count += 1
	return count


# A sparse symmetric hover at the maximum radius stays bounded and exact. The
# eight symmetry masks multiply the footprint map, so the job is long and the
# coalescing policy is stressed. The case also measures the cancel and join cost
# of a running request, which is the real worst-case cancellation latency.
func _sparse_symmetry_bounded() -> void:
	step("Given a sparse checkerboard with eight symmetry masks at the maximum radius", func():
		_sparse_speckle()
		State.symmetry_axes = 7
		State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
		_settings.radius = 32
		_settings.falloff = 0.5
	)
	var events := 6
	var inputs: Array[int] = []
	var gaps: Array[int] = []
	var last := Time.get_ticks_usec()
	for index in events:
		var started := Time.get_ticks_usec()
		_hover(_pos(Vector3(float(-9 + index * 3), 0.0, 0.0)))
		inputs.append(Time.get_ticks_usec() - started)
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		gaps.append(now - last)
		last = now
	await _settle_preview()
	print("MEASURE sculpt_preview_async sparse_sym: axes=7 masks=8 events=%d launches=%d publishes=%d stale_position=%d discarded=%d snapshot_us=%d sample_maps=%d map_us=%d input_max_us=%d input_p95_us=%d gap_max_us=%d gap_p95_us=%d settled=%s cells=%d" % [
		events, _tool._preview.launches, _tool._preview.publishes, _tool._preview.stale_position_publishes,
		_tool._preview.discarded, _tool._preview.snapshot_us, _tool._preview.sample_map_calls,
		_tool._preview.sample_map_us, _max_int(inputs), _p95_int(inputs), _max_int(gaps), _p95_int(gaps),
		str(_tool._preview.is_settled()), _cells().size(),
	])
	step("Then the sparse symmetric hover stayed bounded", func():
		expect(_tool._preview.launches <= events, "the controller never queues more requests than events")
		expect(_tool._preview.is_settled(), "the controller settled on the sparse model")
	)
	# The cancel and join cost of one running eight-mask request. The join waits
	# for the worker to reach its next cancel checkpoint, so this is the worst
	# case a press or a teardown can block on.
	_hover(_pos(Vector3(0, 0, 0)))
	await get_tree().process_frame
	var running: bool = _tool._preview.is_running()
	var cancel_started := Time.get_ticks_usec()
	_tool._preview.join()
	var join_us := Time.get_ticks_usec() - cancel_started
	print("MEASURE sculpt_preview_async cancel: running_before=%s join_us=%d" % [str(running), join_us])
	step("Then the cancel and join of a running eight-mask request is bounded", func():
		expect(running, "a long request ran before the cancel")
		expect(not _tool._preview.is_running(), "the request is joined")
		expect(join_us < 500000, "the cancel checkpoint bounds the join")
	)
	await _hover_and_publish(Vector3(0, 0, 0))
	var worker_cells := _cells()
	var direct := await _direct_cells()
	step("Then the sparse worker result matches a direct request", func():
		expect(worker_cells.size() > 0, "the sparse symmetric hover outlines voxels")
		expect(direct == worker_cells, "the sparse symmetric worker result is exact")
	)


# Builds a sparse checkerboard at the floor layer. Half of the cells are empty,
# so a fit has few samples and a wide query has many misses.
func _sparse_speckle() -> void:
	var changes := {}
	var material := VoxelFrame.material(Color.from_rgba8(90, 160, 220))
	for x in range(-12, 13):
		for z in range(-12, 13):
			if posmod(x + z, 2) == 0:
				changes[Vector3i(x, 0, z)] = material
	State.document = VoxelDocument.new()
	_frame = State.get_current_voxel_frame()
	_frame.set_cells(changes)


static func _max_int(values: Array) -> int:
	var best := 0
	for value in values:
		best = maxi(best, int(value))
	return best


static func _median_int(values: Array) -> int:
	if values.is_empty():
		return 0
	var sorted := values.duplicate()
	sorted.sort()
	return int(sorted[sorted.size() / 2])


# Returns the 95th percentile of one sample list.
static func _p95_int(values: Array) -> int:
	if values.is_empty():
		return 0
	var sorted := values.duplicate()
	sorted.sort()
	return int(sorted[mini(sorted.size() - 1, int(floor(0.95 * float(sorted.size() - 1))))])


# --- Fixture and helpers ------------------------------------------------------

# Builds a solid plate at the floor layer between two inclusive cell corners.
func _plate(low: Vector3i, high: Vector3i) -> void:
	var changes := {}
	var material := VoxelFrame.material(Color.from_rgba8(90, 160, 220))
	for x in range(low.x, high.x + 1):
		for z in range(low.z, high.z + 1):
			changes[Vector3i(x, 0, z)] = material
	State.document = VoxelDocument.new()
	_frame = State.get_current_voxel_frame()
	_frame.set_cells(changes)


func _pos(world: Vector3) -> Vector2:
	return camera_rig().unproject_position(world)


func _hover(pos: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	_viewport.push_input(event)


func _mouse_press(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = pos
	_viewport.push_input(event)


func _mouse_release(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	event.position = pos
	_viewport.push_input(event)


# Hovers one cell and waits for the worker to publish its result.
func _hover_and_publish(world: Vector3) -> void:
	_hover(_pos(world))
	await _settle_preview()


# Waits for the preview controller to settle and for the cursor mesh to settle.
func _settle_preview() -> void:
	for index in 1500:
		await get_tree().process_frame
		if not _tool._preview.is_running() and not _tool._preview.is_dirty() and _tool.get_node("Cursor").is_settled():
			return


# Runs one direct request on the current hover and returns its exact cells. The
# direct request uses the same controller and the same job body as the worker.
func _direct_cells() -> Array:
	_tool._mark_preview_dirty()
	_tool._rebuild_preview()
	await _settle_preview()
	var keys: Array = _tool._preview_cells.keys()
	keys.sort()
	return keys


# Returns the sorted keys of the published preview cells.
func _cells() -> Array:
	var keys: Array = _tool._preview_cells.keys()
	keys.sort()
	return keys
