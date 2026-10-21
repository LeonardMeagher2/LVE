extends "res://tests/test.gd"

# An optional benchmark for the single-chunk surface cycle. Run it directly. It
# is outside automatic suite discovery, because its acceptance is a throughput
# target that depends on the hardware and the machine load.
#
#   godot --path . --screen 1 res://tests/benchmarks/renderer_cycle.tscn
#
# The benchmark keeps one chunk dirty on every frame and records, through a phase
# probe, when each build's worker finished, when its result was cached, and when
# the view installed it. The strict criterion is the same one the spray drag uses:
# a visible surface installs at least every fourth changed motion.
#
# The functional contract that must hold on any machine lives in
# `tests/renderer_progress.tscn`.

const PHASE_PROBE := preload("res://tests/renderer_phase_probe.gd")
## The block edge of the single-chunk fixture.
const BLOCK := 16
## The number of frames that each change one cell of the chunk.
const EDITS := 24
## The frames that the benchmark observes after the last change.
const SETTLE_FRAMES := 40

var renderer: VoxelRenderer
var probe
var frame: VoxelFrame
var _watch := Vector3i.ZERO
var _edits := 0
var _installs_in_window := 0
var _report := {}


func _ready() -> void:
	timeout = 120.0
	test("one dirty chunk installs a surface at least every fourth change", _cycle, "cycle")


func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = 0
	State.current_color = Color.RED
	renderer = viewport_scene().get_node("VoxelRenderer")


func _cleanup_test() -> void:
	VoxelRenderer._surface_job_limit = 0
	if is_instance_valid(renderer):
		await _settle_within(renderer, 60)
	_report = {}


func _cycle() -> void:
	step("Given the editor view of one dense chunk with a phase probe", func():
		_fixture()
		_watch = Vector3i.ZERO
		probe = _attach_phase_probe(renderer)
		sync_viewport()
	)
	await _settle(renderer)
	step("Then the probed view is settled and displayed", func():
		expect(probe != null, "the phase probe is attached")
		expect(renderer.is_settled(), "the view starts settled")
		expect(renderer._chunk_instances.has(_watch), "the watched chunk is displayed")
		probe.reset_probe()
		_edits = 0
	)
	for index in EDITS:
		_edit_surface(index)
		_edits += 1
		await get_tree().process_frame
	var installs_in_window: Array = probe.install_frames.get(_watch, [])
	_installs_in_window = installs_in_window.size()
	for index in SETTLE_FRAMES:
		await get_tree().process_frame
	step("Then the cycle reports its phases and the install cadence", func():
		_report = _cycle_summary()
		print("MEASURE renderer_cycle: dirty_frames=%d installs_in_window=%d motion_per_install=%.2f installs_total=%d mean_install_interval=%d max_install_interval=%d" % [
			_report["edits"], _report["window_installs"], _report["window_motions_per_install"],
			_report["installs"], _report["mean_install_interval"], _report["max_install_interval"],
		])
		print("MEASURE renderer_cycle_calls: calls=%d starved=%d max_call_us=%d mean_call_us=%d max_ready=%d duplicate_keys=%d" % [
			_report["calls"], _report["starved"], _report["max_call_us"],
			_report["mean_call_us"], _report["max_ready"], _report["duplicates"],
		])
		print("MEASURE renderer_cycle_pool: trips=%d median_trip_frames=%d max_trip_frames=%d" % [
			_report["trips"], _report["median_trip"], _report["max_trip"],
		])
		print("MEASURE renderer_cycle_phases: %s" % _report["phases"])
		print("MEASURE renderer_cycle_trace: installs_at=%s" % _report["installs_at"])
		expect(int(_report["window_installs"]) > 0, "the view installs a surface while the chunk stays dirty")
		expect(float(_report["window_motions_per_install"]) <= 4.0, "a visible surface installs at least every fourth changed motion")
	)


# Replaces one view's script with the phase probe. The instances the replaced
# script made go first, or the fresh script would add a second visible set.
func _attach_phase_probe(view: VoxelRenderer):
	for child in view.get_children():
		if child is MeshInstance3D:
			child.free()
	view.set_script(PHASE_PROBE)
	view._chunk_instances = {}
	view._displayed_surface_keys = {}
	view._pending_surface_keys = {}
	view._inflight_surface_keys = {}
	view._retired_chunk_instances = []
	view._displayed_frame = null
	return view


func _cycle_summary() -> Dictionary:
	var installs: Array = probe.install_frames.get(_watch, [])
	var launches: Array = probe.launch_frames.get(_watch, [])
	var keys: Array = probe.launch_keys.get(_watch, [])
	var intervals: Array[int] = []
	for index in range(1, installs.size()):
		intervals.append(int(installs[index]) - int(installs[index - 1]))
	var duplicates := 0
	for key in probe.launched_keys:
		duplicates += int(probe.launched_keys[key]) - 1
	# One entry per launched build: the launch frame, the frame the result became
	# available in the shared cache, and the frame it installed.
	var phases := PackedStringArray()
	for index in mini(6, launches.size()):
		var available = probe.available_frames.get(keys[index], -1)
		var installed := -1
		if index < installs.size():
			installed = int(installs[index])
		phases.append("L%d>A%s>I%d" % [int(launches[index]), str(available), installed])
	var install_list := PackedStringArray()
	for value in installs:
		install_list.append(str(int(value)))
	return {
		"edits": _edits,
		"installs": installs.size(),
		"window_installs": _installs_in_window,
		"window_motions_per_install": float(_edits) / maxf(1.0, float(_installs_in_window)),
		"mean_install_interval": _mean_of(intervals),
		"max_install_interval": _max_of(intervals),
		"calls": probe.calls.size(),
		"starved": probe.starved_calls,
		"max_call_us": probe.max_call_us,
		"mean_call_us": probe.total_call_us / maxi(1, probe.calls.size()),
		"max_ready": probe.max_ready,
		"duplicates": duplicates,
		"trips": probe.pool_trips.size(),
		"median_trip": _median_of(probe.pool_trips),
		"max_trip": _max_of(probe.pool_trips),
		"phases": " ".join(phases),
		"installs_at": ",".join(install_list),
	}


# One dense chunk whose top face holds sixteen materials, so a surface change
# changes real geometry and a chunk build costs more than one frame.
func _fixture() -> void:
	State.document = VoxelDocument.new()
	State.undo_redo.clear_history()
	frame = State.get_current_voxel_frame()
	var cells := {}
	for z in BLOCK:
		for y in BLOCK:
			for x in BLOCK:
				var material := VoxelFrame.material(Color.RED)
				if y == BLOCK - 1:
					material = VoxelFrame.material(Color.from_hsv(float((x * BLOCK + z) % 16) / 16.0, 0.8, 0.9))
				cells[Vector3i(x, y, z)] = material
	frame.set_cells(cells)


# One top-face cell takes a new material, so the chunk stays dirty every frame.
func _edit_surface(index: int) -> void:
	var cell := Vector3i(index % BLOCK, BLOCK - 1, (index / BLOCK) % BLOCK)
	frame.set_cell(cell, VoxelFrame.material(Color.from_hsv(float(index % 12) / 12.0, 1.0, 0.5 + 0.03 * (index % 12))))
	State.document._bounds_dirty = true
	var affected: Array[Vector3i] = [cell]
	State.cells_changed.emit(State.current_frame, affected)


func _mean_of(values: Array[int]) -> int:
	if values.is_empty():
		return 0
	var total := 0
	for value in values:
		total += value
	return total / values.size()


func _median_of(values: Array[int]) -> int:
	if values.is_empty():
		return 0
	var sorted := values.duplicate()
	sorted.sort()
	return int(sorted[sorted.size() / 2])


func _max_of(values: Array[int]) -> int:
	var best := 0
	for value in values:
		best = maxi(best, value)
	return best


func _settle(target: VoxelRenderer) -> void:
	while not target.is_settled():
		await get_tree().process_frame


func _settle_within(target: VoxelRenderer, frames: int) -> bool:
	for index in frames:
		if target.is_settled():
			return true
		await get_tree().process_frame
	return target.is_settled()
