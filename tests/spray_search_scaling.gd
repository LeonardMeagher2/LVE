extends "res://tests/test.gd"

# The spray search scaling tests.
#
# The sampler must pick distinct occupied centers from the search sphere without
# gathering the whole reach volume. These tests prove the candidate order and the
# random draws match the frozen reference, count the work of the indexed path,
# and time the old and the new kernel in one process. The rendered benchmark is
# `tests/benchmarks/spray_search_scaling.gd`.
#
#   godot --path . res://tests/spray_search_scaling.tscn
#   godot --path . res://tests/spray_search_scaling.tscn -- spray_scale_work

const SpraySampler := preload("res://plugins/paint/SpraySampler.gd")
const SpraySamplingJob := preload("res://plugins/paint/SpraySamplingJob.gd")
const SprayIndex := preload("res://plugins/paint/SprayOccupancyIndex.gd")
const REFERENCE := preload("res://tests/spray_reference_size.gd")
const VoxelBrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")

const SEED := 20261025
const WIDTHS := [1, 9, 17, 33, 64]

var _settings := preload("res://plugins/paint/settings.tres")

var tool: Node3D
var frame: VoxelFrame
var _reference
var _reference_rng := RandomNumberGenerator.new()
var _live_state := 0
var _reference_state := 0
var _roi_subset_chunk: VoxelFrame.Chunk
var _alias_context: VoxelFrame.EditContext
var _cache_snapshot := {}
var _large_selection := {}
var _span_failures := 0
var _parity_compared := 0
var _parity_failures := 0
var _parity_order_failures := 0
var _parity_rng_failures := 0


# A job that stops after a fixed number of checkpoints. It proves that the new
# candidate, footprint, and expansion phases stop inside their own loops.
class CountingJob extends VoxelFrame.EditJob:
	var calls := 0
	var limit := 0

	func checkpoint(_completed: int) -> bool:
		calls += 1
		return calls <= limit


func _ready() -> void:
	timeout = 120.0
	test("the sphere span matches the shared brush sphere at every width", _span_parity, "spray_scale_span")
	test("the indexed sample matches the frozen reference at every width", _candidate_parity, "spray_scale_parity")
	test("the point selection reads chunk rows, not the candidate volume", _work_counts, "spray_scale_work")
	test("the occupancy rows survive material writes, copies, and restores", _cache_reuse, "spray_scale_cache")
	test("empty, selected, mirrored, even, and far cases keep the exact cells", _edge_cases, "spray_scale_edges")
	test("a cancelled sample stops before it selects or paints", _cancel, "spray_scale_cancel")
	test("the inline gate counts indexed row work, not occupied cells", _work_gate, "spray_scale_gate")
	test("a large frozen selection keeps a width one lookup small", _selection_index, "spray_scale_selection")
	test("the tool caches one frozen selection and misses a changed one", _tool_selection_cache, "spray_scale_selection_cache")
	test("a raw mutable selection is never served from a stale cache", _mutable_selection, "spray_scale_mutable")
	test("a raw mutable alias of the editor cells resamples every time", _mutable_alias, "spray_scale_mutable_alias")
	test("two frozen snapshots of the same cells compare once", _selection_pair_identity, "spray_scale_selection_pair")
	test("undo, redo, bulk repaint, and same-count moves keep the index exact", _index_mutations, "spray_scale_mutations")
	test("a shortage of three to five candidates caps the speed and keeps the draws", _shortage_rng, "spray_scale_shortage")
	test("the sparse scan and the dense union keep the same spot cells", _footprint_paths, "spray_scale_footprint_paths")
	test("cancellation stops inside the union, the scan, and the expansion", _cancel_phases, "spray_scale_cancel_phases")
	test("the inline and worker paths return the same cells and state", _inline_worker_parity, "spray_scale_inline_worker")
	test("the worker snapshot captures the base, mirror, and no distant chunk", _worker_roi, "spray_scale_worker_roi")


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
	frame = State.get_current_voxel_frame()
	_reference = REFERENCE.new()
	await get_tree().process_frame


func _cleanup_test() -> void:
	_reference = null


# --- Fixtures ---------------------------------------------------------------

# Starts a new document and returns its frame.
func _new_frame() -> void:
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()


# Fills one world box through the chunk storage. A chunk that the box covers
# whole uses one bulk grid fill, so a large fixture stays cheap.
func _fill_box(min_cell: Vector3i, max_cell: Vector3i, cell_material: PackedFloat32Array) -> void:
	var min_chunk := VoxelFrame.chunk_position(min_cell)
	var max_chunk := VoxelFrame.chunk_position(max_cell)
	for cz in range(min_chunk.z, max_chunk.z + 1):
		for cy in range(min_chunk.y, max_chunk.y + 1):
			for cx in range(min_chunk.x, max_chunk.x + 1):
				var location := Vector3i(cx, cy, cz)
				var chunk: VoxelFrame.Chunk = frame.chunks.get(location)
				if chunk == null:
					chunk = VoxelFrame.Chunk.new()
					chunk.location = location
					frame.chunks[location] = chunk
				var origin := location * VoxelFrame.CHUNK_SIZE
				var low := Vector3i(maxi(min_cell.x, origin.x), maxi(min_cell.y, origin.y), maxi(min_cell.z, origin.z)) - origin
				var high := Vector3i(mini(max_cell.x, origin.x + VoxelFrame.CHUNK_SIZE - 1), mini(max_cell.y, origin.y + VoxelFrame.CHUNK_SIZE - 1), mini(max_cell.z, origin.z + VoxelFrame.CHUNK_SIZE - 1)) - origin
				if low.x > high.x or low.y > high.y or low.z > high.z:
					continue
				var count := 0
				if low == Vector3i.ZERO and high == Vector3i.ONE * (VoxelFrame.CHUNK_SIZE - 1):
					chunk.grid.fill(1)
					count = VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE
				else:
					for lz in range(low.z, high.z + 1):
						for ly in range(low.y, high.y + 1):
							for lx in range(low.x, high.x + 1):
								chunk.grid[VoxelFrame.Chunk.cell_slot(Vector3i(lx, ly, lz))] = 1
								count += 1
				chunk.materials = cell_material.duplicate()
				chunk.shared_materials = true
				chunk.occupied_count = count
				chunk.voxel_revision = 1
				chunk.bounds_dirty = false
				chunk.occupied_bounds = AABB(Vector3(origin + low) - Vector3.ONE * 0.5, Vector3(high - low + Vector3i.ONE))


func _use_dense(half: int) -> void:
	_new_frame()
	_fill_box(Vector3i.ONE * -half, Vector3i.ONE * half, VoxelFrame.material(Color.BLUE))
	frame.restore(frame.chunks)


func _use_plate(half: int) -> void:
	_new_frame()
	_fill_box(Vector3i(-half, 0, -half), Vector3i(half, 0, half), VoxelFrame.material(Color.BLUE))
	frame.restore(frame.chunks)


func _use_sparse() -> void:
	_new_frame()
	var cells := {}
	for index in 40:
		var cell := Vector3i(index * 3 - 60, 0, (index % 7) * 5 - 15)
		cells[cell] = VoxelFrame.material(Color.BLUE)
	cells[Vector3i.ZERO] = VoxelFrame.material(Color.BLUE)
	frame.set_cells(cells)
	State.document._bounds_dirty = true


func _use_fixture(name: String) -> void:
	if name == "dense":
		_use_dense(12)
	elif name == "plate":
		_use_plate(32)
	else:
		_use_sparse()


# One voxel in the center of each chunk of a box. The hollow fixture exposes the
# per-chunk row and snapshot cost that a dense block hides.
func _use_hollow(chunks_x: int, chunks_y: int, chunks_z: int) -> void:
	_new_frame()
	var cells := {}
	for cx in chunks_x:
		for cy in chunks_y:
			for cz in chunks_z:
				cells[Vector3i(cx * VoxelFrame.CHUNK_SIZE + 8, cy * VoxelFrame.CHUNK_SIZE + 8, cz * VoxelFrame.CHUNK_SIZE + 8)] = VoxelFrame.material(Color.BLUE)
	frame.set_cells(cells)
	State.document._bounds_dirty = true


# Samples one cell through the production hover path without a ray.
func _hover_cell(cell: Vector3i) -> void:
	var pick := PickResult.new()
	pick.target = cell
	pick.hit = cell
	tool.update_visual(pick)


# Waits until the hover sample and its worker retire.
func _settle_tool() -> void:
	for i in 600:
		if tool.is_sample_settled():
			return
		await get_tree().process_frame


func _fixture_center(_name: String) -> Vector3i:
	return Vector3i.ZERO


# --- Sampling helpers -------------------------------------------------------

func _identity() -> VoxelFrame.EditContext:
	return VoxelFrame.EditContext.new()


func _selection_context(selection: Dictionary) -> VoxelFrame.EditContext:
	var context := VoxelFrame.EditContext.new()
	context.selection = selection
	return context


func _contexts() -> Array:
	var identity := VoxelFrame.EditContext.new()
	var mirror := VoxelFrame.EditContext.new()
	mirror.axes = 1
	mirror.origin_twice = Vector3i.ZERO
	var selection := VoxelFrame.EditContext.new()
	selection.selection = {Vector3i.ZERO: true, Vector3i(1, 0, 0): true, Vector3i(-1, 0, 0): true}
	return [["identity", identity], ["mirror", mirror], ["selection", selection]]


func _live_sample(center: Vector3i, context: VoxelFrame.EditContext, spot: int, search: int, speed: int, seed_value: int, report: Dictionary = {}) -> Array[Vector3i]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var cells := SpraySampler.sample(center, frame, context, spot, search, speed, rng, VoxelFrame.material(Color.WHITE), tool._shape_cache, null, report)
	_live_state = rng.state
	return cells


func _reference_sample(center: Vector3i, context: VoxelFrame.EditContext, spot: int, search: int, speed: int, seed_value: int) -> Array[Vector3i]:
	_reference_rng.seed = seed_value
	var cells: Array[Vector3i] = _reference.sample_size(center, frame, context, spot, search, speed, _reference_rng, VoxelFrame.material(Color.WHITE))
	_reference_state = _reference_rng.state
	return cells


func _same_set(first: Array[Vector3i], second: Array[Vector3i]) -> bool:
	if first.size() != second.size():
		return false
	for cell in first:
		if not second.has(cell):
			return false
	return true


# --- Tests ------------------------------------------------------------------

func _span_parity() -> void:
	_span_failures = 0
	step("Given every canonical size and a far, negative center", func():
		var centers: Array[Vector3i] = [Vector3i.ZERO, Vector3i(-17, 3, 29), Vector3i(3000, 0, -3000)]
		for size in range(1, VoxelBrushSize.MAX_SIZE + 1):
			var reach := VoxelBrushSize.reach(size)
			for center in centers:
				var offsets: Array[int] = []
				if size <= 16:
					for value in range(-reach, reach + 1):
						offsets.append(value)
				else:
					for value in [-reach, -reach + 1, -1, 0, 1, reach - 1, reach]:
						if not offsets.has(value):
							offsets.append(value)
				for dy in offsets:
					for dz in offsets:
						var span: Vector2i = SprayIndex.sphere_x_span(center, size, center.y + dy, center.z + dz)
						for dx in range(-reach - 1, reach + 2):
							var world_x := center.x + dx
							var inside := world_x >= span.x and world_x <= span.y
							var expected := VoxelBrushSize.contains_sphere(size, Vector3i(dx, dy, dz))
							if inside != expected:
								_span_failures += 1
	)
	step("Then the integer span matches the shared sphere on every tested cell", func():
		expect(_span_failures == 0, "every sphere row span matches contains_sphere")
	)


func _candidate_parity() -> void:
	_parity_compared = 0
	_parity_failures = 0
	_parity_order_failures = 0
	_parity_rng_failures = 0
	step("Given dense, plate, and sparse fixtures", func():
		for fixture in ["dense", "plate", "sparse"]:
			_use_fixture(fixture)
			for width in WIDTHS:
				for entry in _contexts():
					var context: VoxelFrame.EditContext = entry[1]
					var live := _live_sample(_fixture_center(fixture), context, 1, width, 8, SEED)
					var reference := _reference_sample(_fixture_center(fixture), context, 1, width, 8, SEED)
					_parity_compared += 1
					if not _same_set(live, reference):
						_parity_failures += 1
					if live != reference:
						_parity_order_failures += 1
					if _live_state != _reference_state:
						_parity_rng_failures += 1
	)
	step("When an even width, a negative center, and a far center sample", func():
		_use_dense(12)
		var even_live := _live_sample(Vector3i(-3, 2, -5), _identity(), 4, 4, 6, SEED)
		var even_reference := _reference_sample(Vector3i(-3, 2, -5), _identity(), 4, 4, 6, SEED)
		_parity_compared += 1
		if not _same_set(even_live, even_reference):
			_parity_failures += 1
		if _live_state != _reference_state:
			_parity_rng_failures += 1
		_new_frame()
		var far := Vector3i(3000, 0, -3000)
		_fill_box(far - Vector3i.ONE * 6, far + Vector3i.ONE * 6, VoxelFrame.material(Color.BLUE))
		frame.restore(frame.chunks)
		var far_live := _live_sample(far, _identity(), 1, 9, 8, SEED)
		var far_reference := _reference_sample(far, _identity(), 1, 9, 8, SEED)
		_parity_compared += 1
		if not _same_set(far_live, far_reference):
			_parity_failures += 1
		if _live_state != _reference_state:
			_parity_rng_failures += 1
	)
	step("Then every sample keeps the reference cells and draws", func():
		expect(_parity_compared == 3 * WIDTHS.size() * 3 + 2, "every fixture, width, and context compared")
		expect(_parity_failures == 0, "every sample keeps the exact reference cell set")
		expect(_parity_order_failures == 0, "every point sample keeps the reference cell order")
		expect(_parity_rng_failures == 0, "every sample consumes the same random draws as the reference")
	)


func _work_counts() -> void:
	var report := {}
	step("Given a 64-cube block and a point spot with speed eight", func():
		_new_frame()
		_fill_box(Vector3i.ONE * -32, Vector3i.ONE * 31, VoxelFrame.material(Color.BLUE))
		frame.restore(frame.chunks)
		_settings.spot_diameter = 1
		_settings.spray_size = 64
		_settings.speed = 8
	)
	step("When the sampler picks eight centers from the wide search", func():
		var cells := _live_sample(Vector3i.ZERO, _identity(), 1, 64, 8, SEED, report)
		expect(cells.size() == 8, "the batch holds eight spot centers")
	)
	step("Then the work follows the chunk rows, not the candidate volume", func():
		expect(int(report.get("local", -1)) == 0, "the legacy local array stays empty")
		expect(int(report.get("candidates", 0)) > 500, "the exposed search shell holds many candidates")
		expect(int(report.get("candidates", 0)) < 100000, "the buried block core is not a candidate")
		expect(int(report.get("chunks", 0)) <= 64, "the exact size 64 box walks four chunks per axis")
		expect(int(report.get("rows", 0)) <= 64 * 256, "the count reads at most one row per chunk row")
		expect(int(report.get("rank_rows", 0)) <= 8 * 2 * 256, "the rank selection reads a bounded number of rows")
		expect(int(report.get("footprint_cells", 0)) == 8, "the point footprint holds the eight centers alone")
		expect(int(report.get("footprint_visits", 0)) == 8, "the point footprint visits eight occupied cells")
		expect(int(report.get("index_builds", 0)) > 0, "the cold sample builds the chunk rows")
		expect(int(report.get("index_grid_reads", 0)) >= int(report.get("index_builds", 0)) * 4096, "the build reports its real grid reads")
		expect(int(report.get("index_build_slots", 0)) == int(report.get("index_builds", 0)) * 256, "the build reports its real row masks")
		expect(int(report.get("row_ops", 0)) > 0, "the sample reports its indexed row work")
	)
	step("When the same sample runs again on the warm rows", func():
		var warm := {}
		_live_sample(Vector3i.ZERO, _identity(), 1, 64, 8, SEED, warm)
		expect(int(warm.get("index_builds", -1)) == 0, "the warm sample builds no chunk rows")
		expect(int(warm.get("index_grid_reads", -1)) == 0, "the warm sample reads no grid slot")
		expect(int(warm.get("rows", 0)) <= 64 * 256, "the warm count keeps the bounded row work")
		expect(int(warm.get("candidates", 0)) == int(report.get("candidates", 0)), "the warm count is the same")
	)


func _cache_reuse() -> void:
	_cache_snapshot = {}
	var origin := Vector3i.ZERO
	step("Given a warm occupancy row index", func():
		_new_frame()
		_fill_box(Vector3i.ONE * -8, Vector3i.ONE * 7, VoxelFrame.material(Color.BLUE))
		frame.restore(frame.chunks)
		var first := {}
		_live_sample(origin, _identity(), 1, 9, 8, SEED, first)
		expect(int(first.get("index_builds", 0)) > 0, "the first sample builds the chunk rows")
		_cache_snapshot = frame.capture()
	)
	step("When a material-only write copies the chunk", func():
		frame.set_cell(origin, VoxelFrame.material(Color.GREEN))
	)
	step("Then the copied chunk reuses its rows", func():
		var report := {}
		_live_sample(origin, _identity(), 1, 9, 8, SEED, report)
		expect(int(report.get("index_builds", -1)) == 0, "a material-only write keeps the occupancy rows")
	)
	step("When an occupancy write erases a cell", func():
		frame.set_cell(origin, VoxelFrame.material(Color.TRANSPARENT))
	)
	step("Then only the changed chunk rebuilds its rows", func():
		var report := {}
		_live_sample(origin, _identity(), 1, 9, 8, SEED, report)
		expect(int(report.get("index_builds", 0)) == 1, "an occupancy write invalidates one chunk")
	)
	step("When the captured snapshot is restored", func():
		frame.restore(_cache_snapshot)
	)
	step("Then the restored chunks reuse their rows", func():
		var report := {}
		_live_sample(origin, _identity(), 1, 9, 8, SEED, report)
		expect(int(report.get("index_builds", -1)) == 0, "a restored snapshot keeps the occupancy rows")
	)


func _edge_cases() -> void:
	step("Given an empty frame", func():
		_new_frame()
		var report := {}
		var cells := _live_sample(Vector3i.ZERO, _identity(), 1, 64, 8, SEED, report)
		expect(cells.is_empty(), "an empty frame offers no candidate")
		expect(int(report.get("candidates", -1)) == 0, "an empty frame counts no candidate")
	)
	step("Given one selected voxel", func():
		_use_plate(8)
		State.clear_selection()
		State.selection.add(Vector3i.ZERO)
		State.selection_changed.emit()
		var context := State.drawing_context()
		var cells := _live_sample(Vector3i.ZERO, context, 1, 9, 8, SEED)
		expect(cells.size() == 1 and cells.has(Vector3i.ZERO), "the selection limits the candidates to its voxel")
	)
	step("Given a mirrored block and an even spot", func():
		_use_dense(8)
		var context := VoxelFrame.EditContext.new()
		context.axes = 1
		context.origin_twice = Vector3i.ZERO
		var live := _live_sample(Vector3i(0, 8, 0), context, 4, 4, 6, SEED)
		var reference := _reference_sample(Vector3i(0, 8, 0), context, 4, 4, 6, SEED)
		expect(_same_set(live, reference), "the even mirrored batch matches the reference")
		expect(_live_state == _reference_state, "the even mirrored batch consumes the same draws")
	)
	step("Given a spot sphere with a hole", func():
		_use_plate(8)
		frame.set_cell(Vector3i(1, 0, 0), VoxelFrame.material(Color.TRANSPARENT))
		var cells := _live_sample(Vector3i.ZERO, _identity(), 3, 1, 1, SEED)
		expect(not cells.has(Vector3i(1, 0, 0)), "the empty hole stays out of the footprint")
		expect(cells.has(Vector3i.ZERO), "the occupied center stays in the footprint")
	)
	step("Given a block below the origin", func():
		_new_frame()
		_fill_box(Vector3i.ONE * -20, Vector3i.ONE * -7, VoxelFrame.material(Color.BLUE))
		frame.restore(frame.chunks)
		var center := Vector3i(-13, -7, -13)
		var live := _live_sample(center, _identity(), 1, 9, 8, SEED)
		var reference := _reference_sample(center, _identity(), 1, 9, 8, SEED)
		expect(_same_set(live, reference), "the negative-chunk batch matches the reference")
		expect(_live_state == _reference_state, "the negative-chunk batch consumes the same draws")
	)


func _cancel() -> void:
	step("Given a wide dense search and a cancelled job", func():
		_new_frame()
		_fill_box(Vector3i.ONE * -32, Vector3i.ONE * 31, VoxelFrame.material(Color.BLUE))
		frame.restore(frame.chunks)
	)
	step("When the sampler runs with the cancelled job", func():
		var job := VoxelFrame.EditJob.new()
		job.cancel()
		var rng := RandomNumberGenerator.new()
		rng.seed = SEED
		var cells := SpraySampler.sample(Vector3i.ZERO, frame, _identity(), 1, 64, 8, rng, VoxelFrame.material(Color.WHITE), tool._shape_cache, job, {})
		expect(cells.is_empty(), "a cancelled sample returns no cells")
	)


func _work_gate() -> void:
	step("Given a hollow fixture with one voxel per chunk", func():
		_use_hollow(4, 4, 4)
		tool._invalidate_batch()
		_settings.spot_diameter = 1
		_settings.spray_size = 64
		_settings.speed = 8
		var work := SpraySampler.work_estimate(frame, Vector3i(24, 24, 24), 64, 1, {}, 8, null)
		expect(work > 2048, "sixty-four nonempty chunks exceed the inline row budget")
	)
	step("When the pointer hovers one voxel", func():
		_hover_cell(Vector3i(24, 24, 24))
		expect(tool._hover_sample_job != null, "the hollow wide search samples on the worker")
		expect(tool.last_work_estimate > 2048, "the gate reports the hollow row work")
		expect(tool.preview_cells().is_empty(), "the worker sample does not block the input frame")
	)
	await _settle_tool()
	step("Then the worker batch installs with real build counts", func():
		expect(tool.preview_cells().size() > 0, "the hollow worker batch installs")
		expect(tool.last_index_builds > 0, "the worker sample built the chunk rows")
		expect(tool.last_index_grid_reads > 0, "the worker sample reports its grid reads")
		tool._invalidate_batch()
	)
	step("Given a plate and a narrow search", func():
		_use_plate(8)
		var work := SpraySampler.work_estimate(frame, Vector3i.ZERO, 9, 1, {}, 8, null)
		expect(work <= 2048, "four plate chunks fit the inline row budget")
	)


func _selection_index() -> void:
	_large_selection = {}
	step("Given a large frozen selection and a small occupied block", func():
		_use_dense(8)
		for x in range(-25, 25):
			for y in range(-25, 25):
				for z in range(-25, 25):
					_large_selection[Vector3i(x, y, z)] = true
		expect(_large_selection.size() > 100000, "the selection holds more than one hundred thousand cells")
	)
	step("When a width one sample uses the frozen masks", func():
		var index := SprayIndex.SelectionIndex.build(_large_selection)
		var report := {}
		var rng := RandomNumberGenerator.new()
		rng.seed = SEED
		var cells := SpraySampler.sample(Vector3i(0, 8, 0), frame, _selection_context(_large_selection), 1, 1, 8, rng, VoxelFrame.material(Color.WHITE), tool._shape_cache, null, report, index)
		expect(cells.size() == 1, "width one offers the face cell alone")
		expect(int(report.get("selection_checked", -1)) == 0, "the indexed selection does not walk the selection")
		expect(int(report.get("selection_builds", -1)) == 0, "the caller-provided masks are reused")
	)
	step("When the same selection samples at width nine", func():
		var index := SprayIndex.SelectionIndex.build(_large_selection)
		var report := {}
		var rng := RandomNumberGenerator.new()
		rng.seed = SEED
		var live := SpraySampler.sample(Vector3i(0, 8, 0), frame, _selection_context(_large_selection), 1, 9, 8, rng, VoxelFrame.material(Color.WHITE), tool._shape_cache, null, report, index)
		var live_state := rng.state
		var small := {}
		for cell in frame.positions():
			if VoxelBrushSize.contains_sphere(9, cell - Vector3i(0, 8, 0)) and _large_selection.has(cell):
				small[cell] = true
		var small_report := {}
		var small_rng := RandomNumberGenerator.new()
		small_rng.seed = SEED
		var reference := SpraySampler.sample(Vector3i(0, 8, 0), frame, _selection_context(small), 1, 9, 8, small_rng, VoxelFrame.material(Color.WHITE), tool._shape_cache, null, small_report)
		expect(live == reference, "the large mask sample keeps the small selection cells and order")
		expect(live_state == small_rng.state, "the large mask sample consumes the same draws")
		expect(int(report.get("selection_checked", -1)) == 0, "the width nine sample does not walk the large selection")
	)
	step("When the large mask build is cancelled", func():
		var job := CountingJob.new()
		job.limit = 1
		var built := SprayIndex.SelectionIndex.build(_large_selection, job)
		expect(built == null, "a cancelled mask build returns no index")
		expect(job.calls > 0, "the mask build checked the cancel flag")
	)
	step("When the sample builds the large masks itself", func():
		var report := {}
		var rng := RandomNumberGenerator.new()
		rng.seed = SEED
		var cells := SpraySampler.sample(Vector3i(0, 8, 0), frame, _selection_context(_large_selection), 1, 1, 8, rng, VoxelFrame.material(Color.WHITE), tool._shape_cache, null, report)
		expect(cells.size() == 1, "the mask sample still offers the face cell alone")
		expect(int(report.get("selection_work", 0)) == _large_selection.size(), "the mask build reports one row op per selected cell")
		expect(int(report.get("row_ops", 0)) >= _large_selection.size(), "the row work includes the mask build")
	)
	step("When a small selection uses the bucket", func():
		var small := {Vector3i(0, 8, 0): true, Vector3i(1, 8, 0): true}
		var report := {}
		var rng := RandomNumberGenerator.new()
		rng.seed = SEED
		var cells := SpraySampler.sample(Vector3i(0, 8, 0), frame, _selection_context(small), 1, 9, 8, rng, VoxelFrame.material(Color.WHITE), tool._shape_cache, null, report)
		expect(cells.size() == 2, "the bucket offers both selected cells")
		expect(int(report.get("selection_checked", 0)) == 2, "the bucket checks each selected cell")
		expect(int(report.get("selection_work", 0)) == 1, "the bucket reports half a row op per entry")
	)


func _tool_selection_cache() -> void:
	step("Given a large editor selection and a narrow spray", func():
		_use_dense(8)
		State.selection.from_box(Vector3i(-25, -25, -25), Vector3i(24, 24, 24))
		State.selection_changed.emit()
		tool.clear_selection_cache()
		_settings.spot_diameter = 1
		_settings.spray_size = 1
		_settings.speed = 8
		tool._invalidate_batch()
	)
	step("When the first width one hover builds the masks on the worker", func():
		_hover_cell(Vector3i(0, 8, 0))
		expect(tool._hover_sample_job != null, "an uncached large selection samples on the worker")
	)
	await _settle_tool()
	step("Then the worker batch installs and the masks are cached", func():
		expect(tool.preview_cells().size() == 1, "the width one batch holds the face cell")
		expect(tool._selection_index != null, "the worker result caches the frozen masks")
		expect(tool.last_row_ops > 0, "the selection mask build reports its row work")
		tool._invalidate_batch()
	)
	step("When the same width one hover runs again", func():
		_hover_cell(Vector3i(0, 8, 0))
		expect(tool._hover_sample_job == null, "the cached masks keep the second lookup inline")
		expect(tool.last_selection_builds == 0, "the second lookup reuses the selection masks")
		expect(tool.last_index_builds == 0, "the second lookup reuses the chunk rows")
	)
	step("When the editor selection changes", func():
		State.selection.add(Vector3i(100, 0, 0))
		State.selection_changed.emit()
		tool._invalidate_batch()
		_hover_cell(Vector3i(0, 8, 0))
		expect(tool._hover_sample_job != null, "a changed selection identity misses the cache")
		tool._invalidate_batch()
	)


func _mutable_selection() -> void:
	step("Given a raw mutable selection and a small plate", func():
		_use_plate(8)
		tool.clear_selection_cache()
		var selection := {Vector3i.ZERO: true}
		var context := _selection_context(selection)
		var first: Array[Vector3i] = tool._sample(Vector3i.ZERO, frame, context)
		expect(first.size() == 1 and first.has(Vector3i.ZERO), "the raw selection offers its cell")
		selection[Vector3i(1, 0, 0)] = true
		var second: Array[Vector3i] = tool._sample(Vector3i.ZERO, frame, context)
		expect(second.size() == 2 and second.has(Vector3i(1, 0, 0)), "the mutated raw selection offers the new cell")
		expect(tool.last_row_ops > 0, "the selection bucket reports its row work")
		expect(tool._selection_index == null, "the tool never caches a raw mutable selection")
		selection.erase(Vector3i.ZERO)
		var third: Array[Vector3i] = tool._sample(Vector3i.ZERO, frame, context)
		expect(third.size() == 1 and third.has(Vector3i(1, 0, 0)), "the removed raw cell leaves the sample")
	)


func _mutable_alias() -> void:
	step("Given a raw mutable context that aliases the editor cells", func():
		_use_plate(8)
		State.selection.from_box(Vector3i.ZERO, Vector3i.ZERO)
		var raw := State.selection.all_cells()
		tool.clear_selection_cache()
		_alias_context = _selection_context(raw)
		expect(not raw.is_read_only(), "the editor cells are still mutable")
		expect(tool._cached_selection_index(raw) == null, "a mutable editor alias never caches masks")
	)
	step("When the alias changes between two samples", func():
		var first: Array[Vector3i] = tool._sample(Vector3i.ZERO, frame, _alias_context)
		expect(first.size() == 1 and first.has(Vector3i.ZERO), "the first sample reads the aliased cell")
		_alias_context.selection[Vector3i(1, 0, 0)] = true
		var second: Array[Vector3i] = tool._sample(Vector3i.ZERO, frame, _alias_context)
		expect(second.size() == 2 and second.has(Vector3i(1, 0, 0)), "the aliased mutation reaches the next sample")
		expect(tool._selection_index == null, "the mutable alias is never cached")
	)


func _selection_pair_identity() -> void:
	step("Given one large frozen editor snapshot", func():
		_use_dense(8)
		State.selection.from_box(Vector3i(-25, -25, -25), Vector3i(24, 24, 24))
		var live := State.selection.all_cells()
		live.make_read_only()
		tool.clear_selection_cache()
		expect(live.size() > 100000, "the snapshot holds more than one hundred thousand cells")
		expect(tool._same_selection(live, live), "the same frozen snapshot matches by identity")
		expect(tool._selection_equal_a.is_empty(), "an identity match records no content pair")
		var copy := live.duplicate()
		copy.make_read_only()
		expect(not is_same(live, copy), "the copy is a different dictionary")
		expect(tool._same_selection(live, copy), "two frozen snapshots of the same cells match")
		expect(is_same(tool._selection_equal_a, live) and is_same(tool._selection_equal_b, copy), "the equal pair is recorded once")
		expect(tool._same_selection(copy, live), "the recorded pair matches in either order")
		var changed := {Vector3i.ZERO: true}
		changed.make_read_only()
		expect(not tool._same_selection(live, changed), "a different frozen selection does not match")
	)


func _index_mutations() -> void:
	step("Given a warm chunk index and a material-only edit", func():
		_use_dense(8)
		var first := {}
		_live_sample(Vector3i.ZERO, _identity(), 1, 9, 8, SEED, first)
		expect(int(first.get("index_builds", 0)) > 0, "the first sample builds the chunk rows")
		var tx := State.begin_edit()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.GREEN))
		State.finish_edit(tx)
		var report := {}
		_live_sample(Vector3i.ZERO, _identity(), 1, 9, 8, SEED, report)
		expect(int(report.get("index_builds", -1)) == 0, "a material-only edit keeps the rows")
	)
	step("When the edit is undone and redone", func():
		State.undo()
		var undone := {}
		_live_sample(Vector3i.ZERO, _identity(), 1, 9, 8, SEED, undone)
		expect(int(undone.get("index_builds", -1)) == 0, "undo restores the indexed snapshot")
		State.redo()
		var redone := {}
		_live_sample(Vector3i.ZERO, _identity(), 1, 9, 8, SEED, redone)
		expect(int(redone.get("index_builds", -1)) == 0, "redo keeps the indexed snapshot")
	)
	step("Given a full chunk and a bulk uniform repaint", func():
		_new_frame()
		_fill_box(Vector3i.ZERO, Vector3i.ONE * (VoxelFrame.CHUNK_SIZE - 1), VoxelFrame.material(Color.BLUE))
		frame.restore(frame.chunks)
		var first := {}
		_live_sample(Vector3i(8, 8, 8), _identity(), 1, 9, 8, SEED, first)
		expect(int(first.get("index_builds", 0)) > 0, "the full chunk builds its rows")
		var changes := {}
		for x in VoxelFrame.CHUNK_SIZE:
			for y in VoxelFrame.CHUNK_SIZE:
				for z in VoxelFrame.CHUNK_SIZE:
					changes[Vector3i(x, y, z)] = VoxelFrame.material(Color.GREEN)
		frame.set_cells(changes, null, VoxelFrame.material(Color.GREEN))
		var report := {}
		_live_sample(Vector3i(8, 8, 8), _identity(), 1, 9, 8, SEED, report)
		expect(int(report.get("index_builds", -1)) == 0, "a bulk uniform repaint keeps the rows")
	)
	step("Given a same-count add and erase batch", func():
		_new_frame()
		frame.set_cells({Vector3i.ZERO: VoxelFrame.material(Color.BLUE), Vector3i(2, 0, 0): VoxelFrame.material(Color.BLUE)})
		var first := {}
		_live_sample(Vector3i.ZERO, _identity(), 1, 9, 8, SEED, first)
		expect(int(first.get("index_builds", 0)) > 0, "the move fixture builds its rows")
		frame.set_cells({Vector3i(1, 0, 0): VoxelFrame.material(Color.BLUE), Vector3i(2, 0, 0): VoxelFrame.material(Color.TRANSPARENT)})
		var report := {}
		var cells := _live_sample(Vector3i.ZERO, _identity(), 1, 9, 8, SEED, report)
		expect(int(report.get("index_builds", 0)) == 1, "a same-count move invalidates the changed chunk")
		expect(cells.has(Vector3i(1, 0, 0)), "the added cell joins the sample")
		expect(not cells.has(Vector3i(2, 0, 0)), "the erased cell leaves the sample")
	)


func _shortage_rng() -> void:
	for count in [3, 4, 5]:
		step("Given %d occupied candidates and speed eight" % count, func():
			_new_frame()
			var cells := {}
			for index in count:
				cells[Vector3i(index, 0, 0)] = VoxelFrame.material(Color.BLUE)
			frame.set_cells(cells)
			_settings.spot_diameter = 1
			_settings.spray_size = 9
			_settings.speed = 8
		)
		step("Then the live and reference samples cap at the pool", func():
			var live := _live_sample(Vector3i.ZERO, _identity(), 1, 9, 8, SEED)
			var live_state := _live_state
			var reference := _reference_sample(Vector3i.ZERO, _identity(), 1, 9, 8, SEED)
			expect(live.size() == count, "the sample holds every available candidate")
			expect(live == reference, "the shortage sample keeps the reference order")
			expect(live_state == _reference_state, "the shortage sample consumes the same draws")
		)


func _footprint_paths() -> void:
	step("Given a sparse spot and a dense halo outside its sphere", func():
		_new_frame()
		frame.set_cells({
			Vector3i.ZERO: VoxelFrame.material(Color.BLUE),
			Vector3i(1, 0, 0): VoxelFrame.material(Color.BLUE),
			Vector3i(0, 1, 0): VoxelFrame.material(Color.BLUE),
			Vector3i(30, 30, 30): VoxelFrame.material(Color.BLUE),
			Vector3i(-30, 30, 30): VoxelFrame.material(Color.BLUE),
			Vector3i(30, -30, 30): VoxelFrame.material(Color.BLUE),
		})
	)
	step("When the scan and the union build the same spot", func():
		var spots: Array[Vector3i] = [Vector3i.ZERO]
		var scan_frame := VoxelFrame.new()
		scan_frame.set_cells({
			Vector3i.ZERO: VoxelFrame.material(Color.BLUE),
			Vector3i(1, 0, 0): VoxelFrame.material(Color.BLUE),
			Vector3i(0, 1, 0): VoxelFrame.material(Color.BLUE),
		})
		var scan := SpraySampler.footprints_selected(spots, scan_frame, _identity(), 64, VoxelFrame.material(Color.WHITE), tool._shape_cache)
		var union := SpraySampler.footprints_selected(spots, frame, _identity(), 64, VoxelFrame.material(Color.WHITE), tool._shape_cache)
		expect(scan.size() == 3, "the scan holds the three occupied sphere cells")
		expect(union.size() == 3, "the union ignores the halo outside the sphere")
		expect(_same_set(_keys(scan), _keys(union)), "the scan and the union hold the same cells")
	)


func _keys(changes: Dictionary) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	cells.assign(changes.keys())
	return cells


func _cancel_phases() -> void:
	step("Given a dense spot union and a cancelled job", func():
		_use_dense(8)
		var job := CountingJob.new()
		job.limit = 2
		var spots: Array[Vector3i] = [Vector3i.ZERO, Vector3i(4, 0, 0), Vector3i(0, 4, 0), Vector3i(0, 0, 4)]
		var result := SpraySampler.footprints_selected(spots, frame, _identity(), 64, VoxelFrame.material(Color.WHITE), tool._shape_cache, job, {})
		expect(result.is_empty(), "a cancelled union returns no partial cells")
		expect(job.calls >= 3, "the union checked the cancel flag while it built rows")
	)
	step("Given a sparse spot scan and a cancelled job", func():
		_new_frame()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.BLUE))
		var job := CountingJob.new()
		job.limit = 0
		var spots: Array[Vector3i] = [Vector3i.ZERO]
		var result := SpraySampler.footprints_selected(spots, frame, _identity(), 64, VoxelFrame.material(Color.WHITE), tool._shape_cache, job, {})
		expect(result.is_empty(), "a cancelled scan returns no partial cells")
		expect(job.calls > 0, "the scan checked the cancel flag per chunk")
	)
	step("Given a large expansion and a cancelled job", func():
		_use_dense(8)
		var occupancy := SpraySampler.Occupancy.new()
		occupancy.frame = frame
		var changes := {}
		for index in 5000:
			changes[Vector3i(index, 0, 0)] = VoxelFrame.material(Color.WHITE)
		var job := CountingJob.new()
		job.limit = 0
		var result := SpraySampler.expand_occupied(changes, occupancy, 1, Vector3i.ZERO, {}, job)
		expect(result.is_empty(), "a cancelled expansion returns no partial cells")
		expect(job.calls > 0, "the expansion checked the cancel flag")
	)


func _worker_roi() -> void:
	step("Given a mirrored voxel and a distant voxel", func():
		_new_frame()
		frame.set_cells({
			Vector3i(2, 0, 0): VoxelFrame.material(Color.BLUE),
			Vector3i(-1, 0, 0): VoxelFrame.material(Color.BLUE),
			Vector3i(100, 0, 0): VoxelFrame.material(Color.BLUE),
		})
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3(0.5, 0.5, 0.5)
		_settings.spot_diameter = 1
		_settings.spray_size = 1
		_settings.speed = 1
	)
	step("When the worker job captures its local region", func():
		var context := State.drawing_context()
		var job: SpraySamplingJob = tool._build_sample_job(frame, Vector3i(2, 0, 0), context, VoxelFrame.material(Color.WHITE), 5000)
		job.run()
		expect(job.source_frame == frame, "the job keeps the live source identity")
		expect(job.capture_chunk_count == 2, "the subset captures the base and mirror chunks")
		expect(job.frame.chunks.size() == 2, "the subset holds only the local chunks")
		expect(job.frame.chunks.has(Vector3i.ZERO), "the base chunk is present")
		expect(job.frame.chunks.has(Vector3i(-1, 0, 0)), "the half-origin mirrored chunk is present")
		expect(not job.frame.chunks.has(Vector3i(6, 0, 0)), "the distant chunk is absent")
		expect(job.cells.has(Vector3i(2, 0, 0)) and job.cells.has(Vector3i(-1, 0, 0)), "the batch holds the base and half-origin mirror cells")
		expect(tool.last_capture_chunks == 2, "the tool reports the subset capture count")
		_roi_subset_chunk = job.frame.chunks[Vector3i.ZERO]
	)
	step("Then a later source write leaves the subset frozen", func():
		frame.set_cell(Vector3i(2, 0, 0), VoxelFrame.material(Color.GREEN))
		expect(frame.get_color(Vector3i(2, 0, 0)) == Color.GREEN, "the source took the new color")
		expect(frame.chunks.get(Vector3i.ZERO) != _roi_subset_chunk, "the live write copied the chunk")
		expect(_roi_subset_chunk.get_color(Vector3i(2, 0, 0)) == Color.BLUE, "the subset chunk stays frozen")
	)


func _inline_worker_parity() -> void:
	step("Given a plate with a small spray", func():
		_use_plate(8)
		_settings.spot_diameter = 1
		_settings.spray_size = 9
		_settings.speed = 8
		tool.seed_spray(SEED)
		var inline_cells: Array[Vector3i] = tool._sample(Vector3i.ZERO, frame, _identity())
		var inline_state: int = tool._rng.state
		var material := VoxelFrame.material(Color.WHITE)
		tool.seed_spray(SEED)
		var job: SpraySamplingJob = tool._build_sample_job(frame, Vector3i.ZERO, _identity(), material, 5000)
		job.run()
		expect(job.cells == inline_cells, "the worker draws the exact inline cells")
		expect(job.result_state == inline_state, "the worker ends on the exact inline state")
	)
