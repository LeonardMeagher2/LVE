extends "res://tests/test.gd"

# A staged measurement of the spray pipeline at the maximum canonical sizes.
#
# The measurement reports what the latency benchmark cannot separate: the model
# size, the gathered and candidate cell counts, the painted count, the pure
# kernel cost, the frame snapshot cost, the input cost of one hover and one
# press, the sample-to-preview install lag, and the press-to-visible-model-draw
# lag. The fixture build and the renderer settle stay outside every timed value.
#
#   godot --headless --path . res://tests/benchmarks/spray_max64.tscn
#   godot --path . --screen 0 res://tests/benchmarks/spray_max64.tscn
#
# A spec names its canonical sizes explicitly: `spot` and `search` are widths in
# cells and `speed` is the sampled spot center count. An optional `mixed` value
# writes two alternating materials, and an optional `symmetry` value turns on
# that many symmetry axes about the model center.

const ProbeScript := preload("./spray_latency_tool.gd")
const PreviewProbeScript := preload("./spray_latency_preview.gd")
const SPRAY_SCENE := "res://plugins/paint/SprayTool.tscn"
const SEED := 20261024
const VIEWPORT_SIZE := Vector2i(800, 500)
const SPARSE_VOXELS := 48
## The warmup count and the measured count of one repeated value.
const WARMUPS := 1
const SAMPLES := 3

const VoxelBrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")
const SpraySampler := preload("res://plugins/paint/SpraySampler.gd")

const SPECS := [
	{"name": "dense128_max", "kind": "block", "size": 128, "spot": 64, "search": 64, "speed": 64},
	{"name": "dense64_mixed_sym", "kind": "block", "size": 64, "spot": 64, "search": 64, "speed": 64, "mixed": true, "symmetry": 1},
	{"name": "sparse256_max", "kind": "sparse", "size": 256, "spot": 64, "search": 64, "speed": 64},
]

var _settings := preload("res://plugins/paint/settings.tres")

var _tool
var _cursor
var _frame: VoxelFrame
var _renderer: VoxelRenderer
var _viewport: SubViewport
var _middle := Vector3i.ZERO
var _watch := {}
var _displayed := {}
var _installs := 0
var _measured := 0
var _snapshot_us := 0
var _kernel_us := 0
var _fixture_us := 0


func _ready() -> void:
	timeout = 240.0
	for spec in SPECS:
		test("the spray pipeline at the canonical maximum of %s" % spec["name"], func(): await _run(spec), spec["name"])


func _run(spec: Dictionary) -> void:
	await _prepare(spec)
	var spot: int = spec["spot"]
	var search: int = spec["search"]
	var speed: int = spec["speed"]
	step("Given the %s fixture at spot %d, search %d, speed %d" % [spec["name"], spot, search, speed], func():
		print("MEASURE spray_max %s fixture: cells=%d chunks=%d bounds=%s build_us=%d mixed=%s symmetry=%d" % [
			spec["name"], _frame.count(), _frame.chunks.size(), str(_frame.get_bounds()), _fixture_us,
			str(spec.get("mixed", false)), int(spec.get("symmetry", 0)),
		])
		expect(_frame.count() > 0, "the fixture holds voxels")
	)
	step("When the frame is snapshotted for a worker sample", func():
		var times: Array[int] = []
		for warmup in WARMUPS:
			_frame.copy_frame()
		for sample in SAMPLES:
			var started := Time.get_ticks_usec()
			var snapshot: VoxelFrame = _frame.copy_frame()
			times.append(Time.get_ticks_usec() - started)
			_measured = snapshot.chunks.size()
		_snapshot_us = _median(times)
		print("MEASURE spray_max %s copy_frame: median %d us, chunks=%d" % [spec["name"], _snapshot_us, _measured])
		expect(_snapshot_us >= 0, "the frame snapshot cost is reported")
	)
	step("When the pure kernel samples the maximum batch on the main thread", func():
		var report := {}
		var started := Time.get_ticks_usec()
		var cells := _kernel(spec, report)
		_kernel_us = Time.get_ticks_usec() - started
		print("MEASURE spray_max %s kernel: local=%d candidates=%d painted=%d speed=%d kernel_us=%d" % [
			spec["name"], int(report.get("local", 0)), int(report.get("candidates", 0)), cells.size(), speed, _kernel_us,
		])
		expect(cells.size() > 0, "the maximum batch paints cells")
	)
	# The hover event is deferred to the next frame, so the request cost is read
	# from the tool probe and the install lag from the test body. A wait inside a
	# step callable is not awaited by this harness.
	step("When the kernel phases are timed separately", func():
		var context := State.drawing_context()
		var reach := VoxelBrushSize.reach(search) + VoxelBrushSize.reach(spot)
		for warmup in WARMUPS:
			SpraySampler.local_cells(_middle, reach, _frame, context)
		var t0 := Time.get_ticks_usec()
		var local := SpraySampler.local_cells(_middle, reach, _frame, context)
		var t1 := Time.get_ticks_usec()
		var candidates := SpraySampler.candidate_cells(_middle, local, search)
		var t2 := Time.get_ticks_usec()
		var rng := RandomNumberGenerator.new()
		rng.seed = SEED
		var spots: Array[Vector3i] = []
		var count := mini(speed, candidates.size())
		for i in count:
			var pick := rng.randi_range(i, candidates.size() - 1)
			var swap := candidates[i]
			candidates[i] = candidates[pick]
			candidates[pick] = swap
			spots.append(candidates[i])
		var changes := SpraySampler.footprints(spots, local, spot, VoxelFrame.material(Color.WHITE), _tool._shape_cache)
		var t3 := Time.get_ticks_usec()
		var identity := VoxelFrame.EditContext.new()
		var plain := identity.expand(changes, _frame, true, null)
		var t4 := Time.get_ticks_usec()
		var expanded := context.expand(changes, _frame, true, null)
		var t5 := Time.get_ticks_usec()
		print("MEASURE spray_max %s phases: gather_us=%d gathered=%d candidates_us=%d candidates=%d footprint_us=%d painted=%d expand_identity_us=%d cells=%d expand_context_us=%d cells=%d axes=%d" % [
			spec["name"], t1 - t0, local.size(), t2 - t1, candidates.size(), t3 - t2, changes.size(),
			t4 - t3, plain.size(), t5 - t4, expanded.size(), int(spec.get("symmetry", 0)),
		])
		expect(local.size() > 0 and changes.size() > 0, "every kernel phase produced cells")
	)
	step("When the pointer hovers the middle voxel", func():
		_tool._invalidate_batch()
		_tool.reset_probe()
		_hover(_screen_of(_middle))
	)
	var hover_input_us := 0
	var lag_frames := 0
	var lag_started := Time.get_ticks_usec()
	while _tool._batch_cells.is_empty() and lag_frames < 1200:
		await get_tree().process_frame
		hover_input_us = maxi(hover_input_us, _tool.input_us)
		lag_frames += 1
	var lag_us := Time.get_ticks_usec() - lag_started
	step("Then the worker sample installs the preview after a bounded lag", func():
		print("MEASURE spray_max %s hover: input_us=%d worker_samples=%d estimate=%d install_frames=%d install_lag_us=%d painted=%d" % [
			spec["name"], hover_input_us, _tool.worker_samples,
			SpraySampler.occupied_estimate(_frame, _middle, VoxelBrushSize.reach(search) + VoxelBrushSize.reach(spot)),
			lag_frames, lag_us, _tool._batch_cells.size(),
		])
		expect(_tool._batch_cells.size() > 0, "the worker batch installs a preview")
		expect(hover_input_us < 50000, "the hover keeps the input frame short")
	)
	step("When the installed batch is shown to the cursor again", func():
		# The tool builds one dict for the cursor and the shared preview hashes it
		# and dedupes it. This measures both halves of one cursor request for a
		# maximum batch.
		_tool._preview_version = -1
		_cursor.reset_probe()
		var started := Time.get_ticks_usec()
		_tool._show_spots(_tool._batch_cells)
		var show_us := Time.get_ticks_usec() - started
		print("MEASURE spray_max %s preview_request: cells=%d tool_show_us=%d cursor_request_us=%d cursor_material_us=%d cursor_show_us=%d" % [
			spec["name"], _tool._batch_cells.size(), show_us, _cursor.request_us, _cursor.material_us, _cursor.show_us,
		])
		expect(_tool._batch_cells.size() > 0, "the cursor request holds the installed batch")
	)
	# The press and the visible draw are measured the same way.
	step("When the user presses the same voxel", func():
		_watch = _watch_around([_middle], VoxelBrushSize.reach(search) + VoxelBrushSize.reach(spot))
		_snapshot_displayed()
		_installs = 0
		_tool.reset_probe()
		_press(_screen_of(_middle))
	)
	var press_input_us := 0
	var draw_frames := 0
	var draw_started := Time.get_ticks_usec()
	while _installs == 0 and draw_frames < 1200:
		await get_tree().process_frame
		press_input_us = maxi(press_input_us, _tool.input_us)
		draw_frames += 1
		_sample_installs()
	var draw_us := Time.get_ticks_usec() - draw_started
	step("Then the press draws a visible model change", func():
		print("MEASURE spray_max %s press: input_us=%d painted=%d draw_frames=%d draw_us=%d model_installs=%d" % [
			spec["name"], press_input_us, _tool._batch_cells.size(), draw_frames, draw_us, _installs,
		])
		expect(_installs > 0, "the press draws a visible model change")
	)
	step("When the user releases", func():
		_release(_screen_of(_middle))
	)
	while _tool._job != null or not _tool._pending_centers.is_empty() or not _tool.is_sample_settled():
		await get_tree().process_frame
	step("Then the release closes the stroke", func():
		print("MEASURE spray_max %s release: history=%d edit=%s model_installs=%d" % [
			spec["name"], State.undo_redo.get_history_count(), str(_tool._edit != null), _installs,
		])
		expect(_tool._edit == null, "the release closes the stroke")
	)


# Samples the batch through the pure kernel with the explicit spec inputs.
func _kernel(spec: Dictionary, report: Dictionary) -> Array[Vector3i]:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	return SpraySampler.sample(_middle, _frame, State.drawing_context(), int(spec["spot"]), int(spec["search"]), int(spec["speed"]), rng, VoxelFrame.material(Color.WHITE), _tool._shape_cache, null, report)


func _prepare(spec: Dictionary) -> void:
	# The Main scene adds its editor and its plugins with a deferred call, so the
	# first frames still reconfigure the editor. Wait them out before the tool is
	# installed, or a startup rebuild would replace the measured tool.
	for i in 4:
		await get_tree().process_frame
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.current_color = Color.RED
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	State.is_playing = false
	_frame = State.get_current_voxel_frame()
	var fixture_started := Time.get_ticks_usec()
	_build_fixture(spec)
	_fixture_us = Time.get_ticks_usec() - fixture_started
	_settings.spot_diameter = spec["spot"]
	_settings.spray_size = spec["search"]
	_settings.speed = spec["speed"]
	_middle = _middle_cell(spec)
	if int(spec.get("symmetry", 0)) > 0:
		State.symmetry_axes = int(spec["symmetry"])
		State.symmetry_origin = _frame.get_bounds().get_center()
	_install_tool()
	_viewport.size = VIEWPORT_SIZE
	_viewport.get_parent().stretch = false
	sync_viewport()
	camera_rig().is_orthogonal = true
	camera_rig().center_on(_frame.get_bounds())
	camera_rig().set_view("top")
	await _settle_all()
	for i in 3:
		await get_tree().process_frame


func _install_tool() -> void:
	var paint := plugin("PaintPlugin")
	select_toolbar_item("paint", "Spray Can")
	paint.deactivate_tool()
	_viewport = editor_viewport()
	_renderer = viewport_scene().get_node("VoxelRenderer")
	_tool = preload(SPRAY_SCENE).instantiate()
	_cursor = _tool.get_node("Cursor")
	var authored := _authored_exports(_tool)
	_tool.set_script(ProbeScript)
	_cursor.set_script(PreviewProbeScript)
	_restore_exports(authored)
	if _tool._settings == null:
		_tool._paint_settings = _settings
		_tool._settings = _settings
	paint.add_editor_node(_tool)
	_tool.seed_spray(SEED)
	_tool.clear_shape_caches()


func _cleanup_test() -> void:
	if is_instance_valid(_tool):
		if _tool._edit != null:
			_tool.finish_on_switch()
		while _tool._job != null or not _tool._pending_centers.is_empty() or not _tool.is_sample_settled():
			await get_tree().process_frame
		plugin("PaintPlugin").remove_editor_node(_tool)
		_tool.free()
	_tool = null
	_cursor = null
	_frame = null
	_watch = {}
	_displayed = {}


func _build_fixture(spec: Dictionary) -> void:
	var kind: String = spec["kind"]
	var size: int = spec["size"]
	var mixed: bool = spec.get("mixed", false)
	if kind == "block":
		_fill_box(Vector3i.ZERO, Vector3i.ONE * (size - 1), mixed)
	elif kind == "plate":
		_fill_box(Vector3i.ZERO, Vector3i(size - 1, 0, size - 1), mixed)
	else:
		for index in SPARSE_VOXELS:
			var cell := _sparse_cell(size, index)
			_fill_box(cell, cell, mixed)
	_frame.restore(_frame.chunks)


func _middle_cell(spec: Dictionary) -> Vector3i:
	var kind: String = spec["kind"]
	var size: int = spec["size"]
	if kind == "sparse":
		return _sparse_cell(size, SPARSE_VOXELS / 2)
	if kind == "block":
		return Vector3i(size / 2, size - 1, size / 2)
	return Vector3i(size / 2, 0, size / 2)


# Fills one world box. A chunk the box covers whole uses one bulk grid fill.
func _fill_box(min_cell: Vector3i, max_cell: Vector3i, mixed: bool) -> void:
	var material_a := VoxelFrame.material(Color.from_rgba8(90, 160, 220))
	var material_b := VoxelFrame.material(Color.from_rgba8(220, 120, 70))
	var chunks := _frame.chunks
	var min_chunk := VoxelFrame.chunk_position(min_cell)
	var max_chunk := VoxelFrame.chunk_position(max_cell)
	for cz in range(min_chunk.z, max_chunk.z + 1):
		for cy in range(min_chunk.y, max_chunk.y + 1):
			for cx in range(min_chunk.x, max_chunk.x + 1):
				var location := Vector3i(cx, cy, cz)
				var chunk: VoxelFrame.Chunk = chunks.get(location)
				if chunk == null:
					chunk = VoxelFrame.Chunk.new()
					chunk.location = location
					chunks[location] = chunk
				var origin := location * VoxelFrame.CHUNK_SIZE
				var lo := Vector3i(maxi(min_cell.x, origin.x), maxi(min_cell.y, origin.y), maxi(min_cell.z, origin.z)) - origin
				var hi := Vector3i(mini(max_cell.x, origin.x + 15), mini(max_cell.y, origin.y + 15), mini(max_cell.z, origin.z + 15)) - origin
				if lo.x > hi.x or lo.y > hi.y or lo.z > hi.z:
					continue
				var count := 0
				if not mixed:
					for lz in range(lo.z, hi.z + 1):
						for ly in range(lo.y, hi.y + 1):
							for lx in range(lo.x, hi.x + 1):
								chunk.grid[VoxelFrame.Chunk.cell_slot(Vector3i(lx, ly, lz))] = 1
								count += 1
					chunk.materials = material_a.duplicate()
					chunk.shared_materials = true
				else:
					# Two alternating materials. The ids and the table are real, so
					# the batch writes a non-uniform model.
					chunk.materials = material_a.duplicate()
					chunk.materials.append_array(material_b)
					for lz in range(lo.z, hi.z + 1):
						for ly in range(lo.y, hi.y + 1):
							for lx in range(lo.x, hi.x + 1):
								chunk.grid[VoxelFrame.Chunk.cell_slot(Vector3i(lx, ly, lz))] = 1 + ((lx + ly + lz) % 2)
								count += 1
					chunk.shared_materials = true
				chunk.occupied_count = count
				chunk.voxel_revision = 1
				chunk.bounds_dirty = false
				chunk.occupied_bounds = AABB(Vector3(origin + lo) - Vector3.ONE * 0.5, Vector3(hi - lo + Vector3i.ONE))


func _sparse_cell(size: int, index: int) -> Vector3i:
	var x := -size + (index * 2 * size) / SPARSE_VOXELS
	var z := -size + ((index * 13) % SPARSE_VOXELS) * (2 * size) / SPARSE_VOXELS
	return Vector3i(x, 0, z)


func _watch_around(cells: Array[Vector3i], reach: int) -> Dictionary:
	var watch := {}
	var offsets: Array[Vector3i] = [Vector3i.ZERO]
	offsets.append_array(VoxelFrame.DIRECTIONS)
	for cell in cells:
		for offset in offsets:
			watch[VoxelFrame.chunk_position(cell + offset * reach)] = true
	return watch


func _snapshot_displayed() -> void:
	_displayed = {}
	for location in _watch:
		var instance: MeshInstance3D = _renderer._chunk_instances.get(location)
		var id := 0
		if instance != null and instance.mesh != null:
			id = instance.mesh.get_instance_id()
		_displayed[location] = id


func _sample_installs() -> void:
	for location in _watch:
		var instance: MeshInstance3D = _renderer._chunk_instances.get(location)
		var id := 0
		if instance != null and instance.mesh != null:
			id = instance.mesh.get_instance_id()
		if _displayed.get(location, 0) != id:
			_displayed[location] = id
			if id != 0:
				_installs += 1


func _press(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = pos
	_viewport.push_input(event)


func _release(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	event.position = pos
	_viewport.push_input(event)


func _hover(pos: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	_viewport.push_input(event)


func _screen_of(cell: Vector3i) -> Vector2:
	return camera_rig().unproject_position(Vector3(cell))


func _settle_all() -> void:
	while _tool._job != null or not _tool._pending_centers.is_empty() or not _tool.is_sample_settled() or not _cursor.is_settled():
		await get_tree().process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw


func _authored_exports(root: Node) -> Dictionary:
	var saved := {}
	for node in _subtree(root):
		var values := {}
		for property in node.get_property_list():
			var usage: int = property["usage"]
			if usage & PROPERTY_USAGE_SCRIPT_VARIABLE and usage & PROPERTY_USAGE_EDITOR:
				values[property["name"]] = node.get(property["name"])
		saved[node] = values
	return saved


func _restore_exports(saved: Dictionary) -> void:
	for node in saved:
		if not is_instance_valid(node):
			continue
		var values: Dictionary = saved[node]
		for name in values:
			node.set(name, values[name])


func _subtree(root: Node) -> Array[Node]:
	var nodes: Array[Node] = [root]
	for child in root.get_children():
		nodes.append_array(_subtree(child))
	return nodes


func _median(values: Array[int]) -> int:
	if values.is_empty():
		return 0
	var sorted := values.duplicate()
	sorted.sort()
	return int(sorted[sorted.size() / 2])
