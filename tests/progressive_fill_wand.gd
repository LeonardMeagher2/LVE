extends "res://tests/test.gd"

# Progressive publication for the bucket fill and the wand.
#
# A large operation streams the cells it finds, and the main thread applies them in
# bounded batches. These tests prove that a partial result reaches the live frame,
# the live selection, and the installed renderer surface while the job still runs,
# that the final result matches the frozen reference exactly, that one stroke holds
# one undo action, and that a cancel restores the starting frame and selection.
#
#   godot --path . res://tests/progressive_fill_wand.tscn
#   godot --path . res://tests/progressive_fill_wand.tscn -- partial_fill

const REFERENCE := preload("res://tests/region_search_reference.gd")
# The fill fixture must be large enough that the streamed partial publication is
# still observable while the edit runs. A 32 by 16 by 16 block finishes its edit
# faster than the renderer installs its first partial surface once the write path
# is fast, so the fixture is 64 wide. The assertions are unchanged.
const FILL_SIDE_X := 64
const FILL_SIDE_Y := 16
const FILL_SIDE_Z := 16
const FILL_TOTAL := FILL_SIDE_X * FILL_SIDE_Y * FILL_SIDE_Z
# The wand fixture is large enough that the streamed selection lasts many frames,
# so a partial outline can actually install before the final one.
const WAND_SIDE := 40
const WAND_TOTAL := WAND_SIDE * WAND_SIDE * WAND_SIDE
# A wall-clock bound for one wait. The streaming fixtures finish in well under
# this, so a hit means a stalled producer and the next check reports it.
const WAIT_LIMIT_MS := 30000

var frame: VoxelFrame
var fill_tool: Node
var wand_tool: Node
var preview: MeshInstance3D
var _fill_settings := preload("res://plugins/paint/settings.tres")
var _first_visible_us := 0
var _started_us := 0
var _longest_frame_us := 0
var _partials := 0
var _peak_depth := 0
var _partial_outline := false
# A repaint keeps the same shape, so the installed vertex count cannot show it.
# This records that an installed chunk material held the original red and the fill
# blue in one sampled frame while the fill was unfinished.
var _partial_repaint := false
var _max_installed := 0
# Step lambdas capture locals by value, so the frames a later step needs are members.
var _before: VoxelFrame
var _expected: VoxelFrame
var _mask := {}


func _ready() -> void:
	timeout = 120.0
	test("a large fill shows a partial surface and a cancel restores the start", _partial_fill, "partial_fill")
	test("a large wand streams its selection, clears a replace, and one undo restores", _partial_wand, "partial_wand")
	test("the streamed results match the frozen reference", _streaming_parity, "streaming_parity")
	test("a tool switch lets both operations finish with one undo action", _tool_switch, "tool_switch")


# Each test starts from a fresh document, the default symmetry, and the default
# connected option, because those live in shared resources.
func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.clear_selection()
	State.undo_redo.clear_history()
	_fill_settings.connected = true
	_first_visible_us = 0
	_started_us = 0
	_longest_frame_us = 0
	_partials = 0
	_peak_depth = 0
	_partial_outline = false
	_partial_repaint = false
	await get_tree().process_frame


# Leave no worker or open stroke behind, so a test can run alone or in any order.
# A tool switch detaches a tool without destroying it, and its service loop is not
# tied to the tree, so the cancel runs for every valid tool.
func _cleanup_test() -> void:
	if is_instance_valid(fill_tool):
		fill_tool._interrupt_fill()
	if is_instance_valid(wand_tool):
		wand_tool._cancel_selection()
	State.clear_selection()
	State.undo_redo.clear_history()
	await _await_until(func(): return State.edit_busy())
	await get_tree().process_frame


func _block(x_side: int, y_side: int, z_side: int) -> Dictionary:
	var cells := {}
	var material := VoxelFrame.material(Color.RED)
	for x in x_side:
		for y in y_side:
			for z in z_side:
				cells[Vector3i(x, y, z)] = material
	return cells


func _count_in(x_side: int, y_side: int, z_side: int, color: Color) -> int:
	var total := 0
	for x in x_side:
		for y in y_side:
			for z in z_side:
				if frame.get_color(Vector3i(x, y, z)) == color:
					total += 1
	return total


# Wait while `condition` holds, up to a wall-clock bound. Returns false when the
# bound is hit, so a stalled producer fails the next check instead of holding the
# harness watchdog.
func _await_until(condition: Callable, limit_ms := WAIT_LIMIT_MS) -> bool:
	var deadline := Time.get_ticks_msec() + limit_ms
	while condition.call():
		if Time.get_ticks_msec() >= deadline:
			return false
		await get_tree().process_frame
	return true


func _fill_fixture() -> void:
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	frame.set_cells(_block(FILL_SIDE_X, FILL_SIDE_Y, FILL_SIDE_Z))
	State.document._bounds_dirty = true
	State.undo_redo.clear_history()
	select_toolbar_item("paint", "Bucket Fill")
	fill_tool = plugin("PaintPlugin")._fill_tool
	State.current_material = VoxelFrame.material(Color.BLUE)


# The expected result, computed from an untouched copy with the frozen reference.
# The operation never sees this frame, so a missing or wrong cell cannot hide.
func _expected_fill(before: VoxelFrame, connected: bool, mask: Dictionary, symmetry := false) -> VoxelFrame:
	var expected := before.copy_frame()
	var target := expected.get_material(Vector3i.ZERO)
	var replacement := VoxelFrame.material(Color.BLUE)
	var changes := {}
	REFERENCE.find(changes, expected, Vector3i.ZERO, target, connected, replacement, mask)
	if symmetry:
		changes = State.drawing_context().expand(changes, expected, true, target)
	expected.set_cells(changes, null, replacement)
	return expected


# The vertices the viewport renderer has installed right now.
func _installed_vertices() -> int:
	var renderer := viewport_scene().get_node_or_null("VoxelRenderer")
	if renderer == null:
		return 0
	var total := 0
	for instance in renderer._chunk_instances.values():
		if instance.mesh and instance.mesh.get_surface_count() > 0:
			total += instance.mesh.surface_get_array_len(0)
	return total


# True when an installed chunk material's atlas holds this color. The atlas
# texture is the renderer's own installed data, so a request that was never
# installed cannot satisfy it. A repaint keeps the shape, so the atlas is the
# installed proof of the new color.
func _installed_holds(color: Color) -> bool:
	var renderer := viewport_scene().get_node_or_null("VoxelRenderer")
	if renderer == null:
		return false
	for instance in renderer._chunk_instances.values():
		var material := instance.material_override as StandardMaterial3D
		if material != null and material.albedo_texture != null and _texture_holds(material.albedo_texture, color):
			return true
	return false


func _texture_holds(texture: Texture2D, color: Color) -> bool:
	var expected := Vector3i(roundi(color.r * 255.0), roundi(color.g * 255.0), roundi(color.b * 255.0))
	var image := texture.get_image()
	if image == null or image.is_empty():
		return false
	for y in image.get_height():
		for x in image.get_width():
			var texel := image.get_pixel(x, y)
			if absi(roundi(texel.r * 255.0) - expected.x) <= 1 and absi(roundi(texel.g * 255.0) - expected.y) <= 1 and absi(roundi(texel.b * 255.0) - expected.z) <= 1:
				return true
	return false


# Watch a running fill frame by frame. Records the first partial frame, the first
# partial installed repaint, the longest frame gap, and the peak queue depth. The
# loop stops at a wall-clock bound, so a stalled fill reports instead of hanging.
func _watch_fill() -> void:
	_started_us = Time.get_ticks_usec()
	_first_visible_us = 0
	_longest_frame_us = 0
	_partials = 0
	_peak_depth = 0
	_max_installed = 0
	var deadline := Time.get_ticks_msec() + WAIT_LIMIT_MS
	var previous := Time.get_ticks_usec()
	while State.edit_busy() or not fill_tool.is_settled() or not fill_tool._search_jobs.is_empty():
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		_longest_frame_us = maxi(_longest_frame_us, now - previous)
		previous = now
		var running: bool = State.edit_busy() or not fill_tool.is_settled() or not fill_tool._search_jobs.is_empty()
		var blue := _count_in(FILL_SIDE_X, FILL_SIDE_Y, FILL_SIDE_Z, Color.BLUE)
		if blue > 0 and blue < FILL_TOTAL:
			_partials += 1
			if _first_visible_us == 0:
				_first_visible_us = now - _started_us
		_max_installed = maxi(_max_installed, _installed_vertices())
		if running and not _partial_repaint and _installed_holds(Color.BLUE) and _installed_holds(Color.RED):
			_partial_repaint = true
		for search_job in fill_tool._search_jobs:
			if search_job.batch_queue:
				_peak_depth = maxi(_peak_depth, search_job.batch_queue.depth())
		if Time.get_ticks_msec() >= deadline:
			break


func _partial_fill() -> void:
	step("Given a large red block and the fill tool", func():
		_fill_fixture()
		_before = frame.copy_frame()
		expect(frame.count() == FILL_TOTAL, "the block holds every cell")
	)
	step("When the user fills the block", func():
		fill_tool._release_pending = true
		fill_tool._queue_seed(Vector3i.ZERO)
	)
	await _watch_fill()
	step("Then a partial result and an installed repaint were visible before the end", func():
		expect(_partials > 0, "the live frame showed a partial fill while the job ran")
		expect(_partial_repaint, "an installed chunk material held the original red and the fill blue while the job ran")
		expect(_peak_depth <= 4, "the handoff queue stayed inside its bound")
		print("MEASURE progressive fill: cells=%d first_visible %d us, total %d us, longest_frame %d us, partial_frames %d, peak_depth %d, partial_repaint %s, partial_surface_vertices %d of %d" % [
			FILL_TOTAL, _first_visible_us, Time.get_ticks_usec() - _started_us, _longest_frame_us, _partials, _peak_depth, str(_partial_repaint), _max_installed, _installed_vertices(),
		])
	)
	step("Then the final fill equals the frozen expectation and holds one undo", func():
		expect(frame.storage_data() == _expected_fill(_before, true, {}).storage_data(), "the streamed frame equals the reference frame")
		expect(_count_in(FILL_SIDE_X, FILL_SIDE_Y, FILL_SIDE_Z, Color.BLUE) == FILL_TOTAL, "every block cell takes the fill color")
		expect(State.undo_redo.has_undo(), "the fill records one undo action")
		State.undo_redo.undo()
		expect(_count_in(FILL_SIDE_X, FILL_SIDE_Y, FILL_SIDE_Z, Color.RED) == FILL_TOTAL, "one undo restores every block cell")
		State.undo_redo.clear_history()
	)
	step("When the user fills again and cancels after a partial result", func():
		fill_tool._release_pending = true
		fill_tool._queue_seed(Vector3i.ZERO)
	)
	await _await_until(func(): return _count_in(FILL_SIDE_X, FILL_SIDE_Y, FILL_SIDE_Z, Color.BLUE) == 0 or not State.edit_busy())
	step("Then the cancel is accepted and the frame returns to its start", func():
		var activity := State.get_activity()
		expect(activity != null and State.cancel_operation(activity.id), "the cancel request is accepted")
	)
	await _watch_fill()
	step("Then the cancelled fill leaves no history and no busy state", func():
		expect(_count_in(FILL_SIDE_X, FILL_SIDE_Y, FILL_SIDE_Z, Color.RED) == FILL_TOTAL, "the cancelled fill restores every cell")
		expect(not State.edit_busy(), "the cancelled fill releases the edit state")
		expect(not State.undo_redo.has_undo(), "the cancelled fill records no history")
	)


func _wand_fixture() -> void:
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	frame.set_cells(_block(WAND_SIDE, WAND_SIDE, WAND_SIDE))
	State.document._bounds_dirty = true
	State.clear_selection()
	State.undo_redo.clear_history()
	activate_tool("selection")
	select_toolbar_item("selection", "Wand")
	# The selection plugin can be mid-load while another agent edits it. Leave the
	# tools null then, so the caller fails a check instead of reading a null tool.
	var selection_plugin := plugin("SelectionPlugin")
	wand_tool = selection_plugin._wand if selection_plugin != null else null
	preview = selection_plugin._selection if selection_plugin != null else null
	if wand_tool != null:
		wand_tool._settings.connected = true
		wand_tool._settings.mode = wand_tool._settings.SelectMode.REPLACE


func _partial_wand() -> void:
	step("Given a large block, a marked voxel, and the wand tool", func():
		_wand_fixture()
		expect(wand_tool != null and preview != null, "the selection plugin exposes the wand and the preview")
		# A previous selection that a replace must drop.
		State.selection.add(Vector3i(999, 999, 999))
	)
	if wand_tool == null:
		return
	step("When the user selects the block in replace mode", func():
		wand_tool._commit(Vector3i.ZERO)
		expect(State.selection.count() == 0, "a replace drops the previous selection before the search ends")
	)
	var samples: Array[int] = []
	var outline_lengths: Array[int] = []
	var revisions := 0
	var previous_revision: int = preview._request_revision
	var previous_us := Time.get_ticks_usec()
	_started_us = previous_us
	_first_visible_us = 0
	_longest_frame_us = 0
	_partial_outline = false
	var deadline := Time.get_ticks_msec() + WAIT_LIMIT_MS
	while wand_tool._job != null or State.edit_busy():
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		_longest_frame_us = maxi(_longest_frame_us, now - previous_us)
		previous_us = now
		var count := State.selection.count()
		if count > 0 and count < WAND_TOTAL:
			samples.append(count)
			if _first_visible_us == 0:
				_first_visible_us = now - _started_us
		if preview._request_revision != previous_revision:
			previous_revision = preview._request_revision
			revisions += 1
		if preview.mesh and preview.mesh.get_surface_count() > 0:
			outline_lengths.append(preview.mesh.surface_get_array_len(0))
		if Time.get_ticks_msec() >= deadline:
			break
	step("Then a partial selection and a partial outline arrived before the end", func():
		expect(samples.size() > 0, "the live selection showed a partial result")
		var ascending := true
		for index in range(1, samples.size()):
			if samples[index] < samples[index - 1]:
				ascending = false
		expect(ascending, "the partial selections only grew")
		expect(revisions >= 1, "the outline was requested again while the job ran")
		var final_length: int = preview.mesh.surface_get_array_len(0) if preview.mesh else 0
		for length in outline_lengths:
			if length > 0 and length < final_length:
				_partial_outline = true
		expect(_partial_outline, "a partial outline mesh was installed while the job ran")
		print("MEASURE progressive wand: cells=%d first_visible %d us, total %d us, longest_frame %d us, partial_samples %d, outline_revisions %d, partial_outline %s" % [
			WAND_TOTAL, _first_visible_us, Time.get_ticks_usec() - _started_us, _longest_frame_us, samples.size(), revisions, str(_partial_outline),
		])
	)
	step("Then the final selection is exact and holds one undo action", func():
		expect(State.selection.count() == WAND_TOTAL, "the selection holds the whole block")
		expect(not State.selection.contains(Vector3i(999, 999, 999)), "the replaced marker stays out")
		expect(State.undo_redo.has_undo(), "the wand records one undo action")
		State.undo_redo.undo()
		expect(State.selection.count() == 1 and State.selection.contains(Vector3i(999, 999, 999)), "one undo restores the previous selection")
		State.undo_redo.clear_history()
	)


# The streamed result must equal the frozen reference for every mode the callers
# use: connected, disconnected, a selection mask, symmetry, and mixed materials.
func _streaming_parity() -> void:
	step("Given a red block with same-color neighbors of different materials", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cells(_block(FILL_SIDE_X, FILL_SIDE_Y, FILL_SIDE_Z))
		# A same-color voxel with a different metallic, and one with emission. Both
		# touch the block, so the connected search meets them and must reject them.
		# The match uses all nine floats, so the fill leaves them unchanged.
		frame.set_cell(Vector3i(FILL_SIDE_X, 0, 0), VoxelFrame.material(Color.RED, VoxelFrame.DEFAULT_EMISSION, 0.8, 0.5))
		frame.set_cell(Vector3i(0, 0, FILL_SIDE_Z), VoxelFrame.material(Color.RED, Color(0.5, 0.0, 0.0)))
		State.document._bounds_dirty = true
		State.clear_selection()
		State.undo_redo.clear_history()
		select_toolbar_item("paint", "Bucket Fill")
		fill_tool = plugin("PaintPlugin")._fill_tool
		State.current_material = VoxelFrame.material(Color.BLUE)
		_before = frame.copy_frame()
	)
	for connected: bool in [true, false]:
		var label := "connected" if connected else "disconnected"
		step("When the user fills with %s on" % label, func():
			fill_tool._settings.connected = connected
			_expected = _expected_fill(_before, connected, {})
			fill_tool._release_pending = true
			fill_tool._queue_seed(Vector3i.ZERO)
		)
		await _await_until(func(): return State.edit_busy() or not fill_tool.is_settled() or not fill_tool._search_jobs.is_empty())
		step("Then the streamed %s fill matches the frozen reference" % label, func():
			expect(frame.storage_data() == _expected.storage_data(), "the streamed %s fill equals the reference" % label)
			expect(frame.matches(Vector3i(FILL_SIDE_X, 0, 0), VoxelFrame.material(Color.RED, VoxelFrame.DEFAULT_EMISSION, 0.8, 0.5)), "the other-metallic voxel keeps its material")
			expect(frame.matches(Vector3i(0, 0, FILL_SIDE_Z), VoxelFrame.material(Color.RED, Color(0.5, 0.0, 0.0))), "the emission voxel keeps its material")
			State.undo_redo.undo()
			State.undo_redo.clear_history()
		)
	step("When the user fills inside a selection mask", func():
		for x in range(0, FILL_SIDE_X / 2):
			for y in FILL_SIDE_Y:
				for z in FILL_SIDE_Z:
					State.selection.add(Vector3i(x, y, z))
		_mask = State.selection.capture()
		_expected = _expected_fill(_before, true, _mask)
		fill_tool._settings.connected = true
		fill_tool._release_pending = true
		fill_tool._queue_seed(Vector3i.ZERO)
	)
	await _await_until(func(): return State.edit_busy() or not fill_tool.is_settled() or not fill_tool._search_jobs.is_empty())
	step("Then the masked streamed fill matches the frozen reference", func():
		expect(frame.storage_data() == _expected.storage_data(), "the masked streamed fill equals the reference")
		expect(_count_in(FILL_SIDE_X, FILL_SIDE_Y, FILL_SIDE_Z, Color.BLUE) == FILL_TOTAL / 2, "the fill covers only the selected half")
		State.undo_redo.undo()
		State.undo_redo.clear_history()
		State.clear_selection()
	)
	step("When the user fills with the X symmetry plane on", func():
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3.ZERO
		frame.set_cell(Vector3i(-5, 0, 0), VoxelFrame.material(Color.RED))
		var mirrored_before := frame.copy_frame()
		_expected = _expected_fill(mirrored_before, true, {}, true)
		fill_tool._settings.connected = true
		fill_tool._release_pending = true
		fill_tool._queue_seed(Vector3i.ZERO)
	)
	await _await_until(func(): return State.edit_busy() or not fill_tool.is_settled() or not fill_tool._search_jobs.is_empty())
	step("Then the mirrored streamed fill matches the frozen reference", func():
		expect(frame.storage_data() == _expected.storage_data(), "the mirrored streamed fill equals the reference")
		expect(frame.get_color(Vector3i(-5, 0, 0)) == Color.BLUE, "the reflected voxel takes the fill material")
		State.undo_redo.undo()
		State.undo_redo.clear_history()
		State.symmetry_axes = 0
		State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	)


# A tool switch must not cancel either operation, and the detached tool keeps its
# captured settings.
func _tool_switch() -> void:
	step("Given a running fill and a switch to another tool", func():
		_fill_fixture()
		_before = frame.copy_frame()
		fill_tool._release_pending = true
		fill_tool._queue_seed(Vector3i.ZERO)
	)
	await _await_until(func(): return _count_in(FILL_SIDE_X, FILL_SIDE_Y, FILL_SIDE_Z, Color.BLUE) == 0)
	step("Then the switched-away fill keeps running and completes", func():
		activate_tool("selection")
		expect(State.edit_busy(), "the tool switch did not cancel the fill")
		expect(fill_tool._search_jobs.size() == 1, "the detached fill keeps one job")
	)
	await _watch_fill()
	step("Then the detached fill matches the reference with one undo action", func():
		expect(frame.storage_data() == _expected_fill(_before, true, {}).storage_data(), "the detached fill equals the reference")
		expect(not State.edit_busy(), "the detached fill releases the edit state")
		expect(State.undo_redo.has_undo(), "the detached fill records one undo action")
		State.undo_redo.undo()
		State.undo_redo.clear_history()
	)
	step("When the user fills, switches tools, and cancels with Esc", func():
		select_toolbar_item("paint", "Bucket Fill")
		fill_tool._release_pending = true
		fill_tool._queue_seed(Vector3i.ZERO)
	)
	await _await_until(func(): return _count_in(FILL_SIDE_X, FILL_SIDE_Y, FILL_SIDE_Z, Color.BLUE) == 0)
	step("Then Esc reaches the detached tool and restores the frame", func():
		activate_tool("selection")
		var key := InputEventKey.new()
		key.keycode = KEY_ESCAPE
		key.pressed = true
		get_tree().root.push_input(key)
		expect(not State.edit_busy(), "Esc cancelled the detached fill")
	)
	await _watch_fill()
	step("Then the cancelled detached fill leaves no history", func():
		expect(_count_in(FILL_SIDE_X, FILL_SIDE_Y, FILL_SIDE_Z, Color.RED) == FILL_TOTAL, "Esc restored every cell")
		expect(not State.undo_redo.has_undo(), "the cancelled fill records no history")
	)
	step("When a wand selection runs and the user switches tools", func():
		_wand_fixture()
		expect(wand_tool != null, "the selection plugin exposes the wand")
		if wand_tool == null:
			return
		wand_tool._commit(Vector3i.ZERO)
	)
	if wand_tool == null:
		return
	await _await_until(func(): return State.selection.count() == 0)
	step("Then the switched-away wand keeps running and completes", func():
		activate_tool("paint")
		expect(wand_tool._job != null, "the tool switch did not cancel the wand")
	)
	await _await_until(func(): return wand_tool._job != null or State.edit_busy())
	step("Then the detached wand selection is exact with one undo action", func():
		expect(State.selection.count() == WAND_TOTAL, "the detached wand selected the whole block")
		expect(State.undo_redo.has_undo(), "the detached wand records one undo action")
		State.undo_redo.undo()
		expect(State.selection.is_empty(), "one undo clears the detached wand selection")
		State.undo_redo.clear_history()
	)
