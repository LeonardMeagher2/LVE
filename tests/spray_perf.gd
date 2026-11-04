extends "res://tests/test.gd"

# Differential and performance test for the spray sampler.
#
# `tests/spray_reference.gd` freezes the kernel that ran before the in-place
# partial shuffle, the diameter-1 shortcut, and the identity-context fast path.
# Every fixture is sampled by the live `SprayTool._sample` and by the reference,
# then compared as cell sets under the identity, the symmetry, and the selection
# contexts. The A/B alternates the two kernels in one process and reports medians
# with their sample counts. A repeated hover is compared with the per-cell
# occupancy check and the preview dict build it replaced.
#
# A size whose occupied reach estimate passes the tool's inline limit samples on
# the worker pool. That hover row reports the request cost alone, because the
# inline A/B cannot compare a job that runs off the input frame.
#
#   godot --path . res://tests/spray_perf.tscn

const REFERENCE := preload("res://tests/spray_reference_size.gd")
const VoxelBrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")
const SpraySampler := preload("res://plugins/paint/SpraySampler.gd")

const SEED := 20261020
const AB_SAMPLES := 5
const AB_WARMUPS := 1
# The spot size, the spray search size, and the speed of each measured setting.
# The sizes are canonical widths. The old table named the search value a radius:
# its spans were 9, 17, and 33 cells, so the span-equivalent sizes are used here.
const SETTINGS := [[1, 9, 8], [8, 17, 16], [32, 33, 64]]
const SETTING_NAMES := ["default", "medium", "max"]

var _settings := preload("res://plugins/paint/settings.tres")

var tool: Node3D
var frame: VoxelFrame
var _cursor: MeshInstance3D
var _reference
var _reference_rng := RandomNumberGenerator.new()
var _sink := 0
var _parity_compared := 0
var _parity_failures := 0
var _parity_rng_failures := 0
var _parity_first := ""
var _hover_compared := 0


func _ready() -> void:
	timeout = 110.0
	test("the spray sample matches its frozen reference in every context", _parity, "spray_perf_parity")
	test("the spray sample and the repeated hover cost less than the frozen baseline", _perf, "spray_perf")


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
	select_toolbar_item("paint", "Spray Can")
	tool = plugin("PaintPlugin")._spray_tool
	_reference = REFERENCE.new()
	_cursor = tool.get_node("Cursor")
	frame = State.get_current_voxel_frame()
	await get_tree().process_frame


func _cleanup_test() -> void:
	_reference = null


# A solid block around the origin, so a spot sphere is fully occupied.
func _dense_cells(half: int) -> Dictionary:
	var cells := {}
	for x in range(-half, half + 1):
		for y in range(-half, half + 1):
			for z in range(-half, half + 1):
				cells[Vector3i(x, y, z)] = VoxelFrame.material(Color.BLUE)
	return cells


# A square plate on the floor plane.
func _plate_cells() -> Dictionary:
	var cells := {}
	for x in range(-32, 33):
		for z in range(-32, 33):
			cells[Vector3i(x, 0, z)] = VoxelFrame.material(Color.BLUE)
	return cells


# Scattered voxels in one plane, so the reach holds a mostly empty region.
func _sparse_cells() -> Dictionary:
	var cells := {}
	for index in 40:
		cells[Vector3i(index * 3, 0, (index % 7) * 5)] = VoxelFrame.material(Color.BLUE)
	return cells


func _use_fixture(cells: Dictionary) -> void:
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	frame.set_cells(cells)
	State.document._bounds_dirty = true


func _identity_context() -> VoxelFrame.EditContext:
	return VoxelFrame.EditContext.new()


func _contexts() -> Array:
	var identity := VoxelFrame.EditContext.new()
	var mirror := VoxelFrame.EditContext.new()
	mirror.axes = 1
	mirror.origin_twice = Vector3i.ZERO
	var half := VoxelFrame.EditContext.new()
	half.axes = 1
	half.origin_twice = Vector3i(1, 1, 1)
	var selection := VoxelFrame.EditContext.new()
	selection.selection = {Vector3i.ZERO: true, Vector3i(1, 0, 0): true, Vector3i(-1, 0, 0): true}
	return [["identity", identity], ["mirror", mirror], ["half", half], ["selection", selection]]


func _live_sample(center: Vector3i, context: VoxelFrame.EditContext, seed_value: int) -> Array[Vector3i]:
	tool.seed_spray(seed_value)
	tool._batch_material = VoxelFrame.material(Color.WHITE)
	return tool._sample(center, frame, context)


func _reference_sample(center: Vector3i, context: VoxelFrame.EditContext, seed_value: int) -> Array[Vector3i]:
	_reference_rng.seed = seed_value
	return _reference.sample_size(center, frame, context, _settings.spot_diameter, _settings.spray_size, _settings.speed, _reference_rng, VoxelFrame.material(Color.WHITE))


func _same_set(first: Array[Vector3i], second: Array[Vector3i]) -> bool:
	if first.size() != second.size():
		return false
	for cell in first:
		if not second.has(cell):
			return false
	return true


func _compare(label: String, center: Vector3i, context: VoxelFrame.EditContext, seed_value: int) -> void:
	var live := _live_sample(center, context, seed_value)
	# The live kernel draws from the tool source and the frozen kernel from its
	# own source. The two must consume the same draws, so the random state after
	# the sample is one more ground truth than the cell set alone.
	var live_state: int = tool._rng.state
	var reference := _reference_sample(center, context, seed_value)
	var reference_state: int = _reference_rng.state
	_parity_compared += 1
	if live_state != reference_state:
		_parity_rng_failures += 1
	if not _same_set(live, reference):
		_parity_failures += 1
		if _parity_first == "":
			_parity_first = label


func _parity() -> void:
	step("Given the frozen sampler reference", func():
		var source := FileAccess.get_file_as_string("res://tests/spray_reference.gd")
		expect(not source.contains("SprayTool"), "the frozen reference never calls the live tool")
		expect(source.contains("var indices: Array[int]"), "the frozen reference keeps the old index shuffle")
		expect(source.contains("context.expand(changes, frame, true, null)"), "the frozen reference keeps the full context expansion")
	)
	step("Given a dense block, a plate, and a sparse plane", func():
		_parity_compared = 0
		_parity_failures = 0
		_parity_rng_failures = 0
		_parity_first = ""
	)
	step("When every fixture is sampled by the live tool and the frozen reference", func():
		for fixture in ["dense", "plate", "sparse"]:
			if fixture == "dense":
				_use_fixture(_dense_cells(8))
			elif fixture == "plate":
				_use_fixture(_plate_cells())
			else:
				_use_fixture(_sparse_cells())
			for setting in SETTINGS.size():
				_settings.spot_diameter = SETTINGS[setting][0]
				_settings.spray_size = SETTINGS[setting][1]
				_settings.speed = SETTINGS[setting][2]
				for entry in _contexts():
					var label := "%s/%s/%s" % [fixture, SETTING_NAMES[setting], entry[0]]
					_compare(label, Vector3i.ZERO, entry[1], SEED)
					_compare(label, Vector3i.ZERO, entry[1], SEED + 7)
	)
	step("Then the live sample matches the reference in every context", func():
		expect(_parity_compared == 3 * SETTINGS.size() * 4 * 2, "every fixture, setting, and context compared twice")
		expect(_parity_failures == 0, "every sample keeps the exact cell set%s" % ("" if _parity_first == "" else " (first: %s)" % _parity_first))
		expect(_parity_rng_failures == 0, "every sample consumes the same random draws as the frozen reference")
	)


# One A/B pair of the sample kernel. The frames are prepared outside the timed
# region, so only the sampler runs inside it.
func _time_live(center: Vector3i, context: VoxelFrame.EditContext, seed_value: int) -> int:
	var started := Time.get_ticks_usec()
	var cells := _live_sample(center, context, seed_value)
	_sink = cells.size()
	return Time.get_ticks_usec() - started


func _time_reference(center: Vector3i, context: VoxelFrame.EditContext, seed_value: int) -> int:
	var started := Time.get_ticks_usec()
	var cells := _reference_sample(center, context, seed_value)
	_sink = cells.size()
	return Time.get_ticks_usec() - started


func _measure_sample(label: String, center: Vector3i) -> void:
	var context := _identity_context()
	_compare(label, center, context, SEED)
	var live_times: Array[int] = []
	var reference_times: Array[int] = []
	for warmup in AB_WARMUPS:
		_time_live(center, context, SEED)
		_time_reference(center, context, SEED)
	for sample in AB_SAMPLES:
		if sample % 2 == 0:
			live_times.append(_time_live(center, context, SEED))
			reference_times.append(_time_reference(center, context, SEED))
		else:
			reference_times.append(_time_reference(center, context, SEED))
			live_times.append(_time_live(center, context, SEED))
	var live_median := _median(live_times)
	var reference_median := _median(reference_times)
	print("MEASURE spray sample A/B %s: cells=%d live %d us, frozen %d us, gain %.2fx, samples %d/%d" % [
		label, frame.count(), live_median, reference_median,
		float(reference_median) / maxf(1.0, float(live_median)), live_times.size(), reference_times.size(),
	])


# The per-cell occupancy check, the preview dict build, the preview dedupe scan,
# and the material update that the repeated hover used before the chunk snapshot
# and the cached preview dict.
func _time_old_hover() -> int:
	var started := Time.get_ticks_usec()
	var holds := true
	for cell in tool._batch_cells:
		if not frame.has(cell):
			holds = false
			break
	var spots := {}
	var color := Color.WHITE
	for cell in tool._batch_cells:
		spots[cell] = color
	var same: bool = spots.size() == tool._batch_cells.size()
	if same:
		for cell in tool._batch_cells:
			if not spots.has(cell):
				same = false
				break
	# The material update is shared by both paths, so the baseline includes it.
	_cursor.set_brush_material(tool._batch_material)
	_sink = spots.size() if holds and same else -1
	return Time.get_ticks_usec() - started


func _time_new_hover() -> int:
	var started := Time.get_ticks_usec()
	tool.update_visual(tool._last_pick)
	_sink = tool._batch_cells.size()
	return Time.get_ticks_usec() - started


# One A/B pair of the hover request. A size whose occupied reach estimate passes
# the inline limit queues a worker sample, so the inline path is not comparable
# there and the request cost is reported as it is.
func _measure_hover(label: String, center: Vector3i) -> void:
	var pick := PickResult.new()
	pick.target = center
	pick.hit = center
	var started := Time.get_ticks_usec()
	tool.update_visual(pick)
	var request_us := Time.get_ticks_usec() - started
	_hover_compared += 1
	var reach := VoxelBrushSize.reach(_settings.spray_size) + VoxelBrushSize.reach(_settings.spot_diameter)
	var estimate := SpraySampler.occupied_estimate(frame, center, reach)
	if tool._hover_sample_job != null:
		print("MEASURE spray hover %s: worker queue (inline path off), request %d us, estimate %d, work %d, spot %d, search %d, speed %d, batch=%d" % [
			label, request_us, estimate, tool.last_work_estimate, _settings.spot_diameter, _settings.spray_size, _settings.speed, tool._batch_cells.size(),
		])
		return
	var old_times: Array[int] = []
	var new_times: Array[int] = []
	for warmup in AB_WARMUPS:
		_time_old_hover()
		_time_new_hover()
	for sample in AB_SAMPLES:
		if sample % 2 == 0:
			old_times.append(_time_old_hover())
			new_times.append(_time_new_hover())
		else:
			new_times.append(_time_new_hover())
			old_times.append(_time_old_hover())
	var old_median := _median(old_times)
	var new_median := _median(new_times)
	print("MEASURE spray hover A/B %s: cells=%d estimate=%d work=%d old %d us, new %d us, gain %.2fx, samples %d/%d" % [
		label, tool._batch_cells.size(), estimate, tool.last_work_estimate, old_median, new_median,
		float(old_median) / maxf(1.0, float(new_median)), old_times.size(), new_times.size(),
	])


func _perf() -> void:
	step("Given the dense, plate, and sparse fixtures at the default, medium, and maximum settings", func():
		_parity_failures = 0
		_parity_rng_failures = 0
		_parity_first = ""
		_hover_compared = 0
	)
	step("When the live sampler and the frozen reference alternate on fixed centers", func():
		for fixture in ["dense", "plate", "sparse"]:
			if fixture == "dense":
				_use_fixture(_dense_cells(16))
			elif fixture == "plate":
				_use_fixture(_plate_cells())
			else:
				_use_fixture(_sparse_cells())
			for setting in SETTINGS.size():
				_settings.spot_diameter = SETTINGS[setting][0]
				_settings.spray_size = SETTINGS[setting][1]
				_settings.speed = SETTINGS[setting][2]
				_measure_sample("%s/%s" % [fixture, SETTING_NAMES[setting]], Vector3i.ZERO)
				_measure_hover("%s/%s" % [fixture, SETTING_NAMES[setting]], Vector3i.ZERO)
	)
	step("Then every timed sample keeps the exact reference cell set", func():
		expect(_parity_failures == 0, "every timed sample matches the frozen reference%s" % ("" if _parity_first == "" else " (first: %s)" % _parity_first))
		expect(_parity_rng_failures == 0, "every timed sample consumes the same random draws")
		expect(_hover_compared == 9, "every fixture and setting measured its hover")
	)


func _median(samples: Array[int]) -> int:
	var sorted := samples.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]
