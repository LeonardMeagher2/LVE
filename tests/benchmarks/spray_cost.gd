extends "res://tests/test.gd"

# An opt-in cost benchmark for the spray kernel.
#
# The root suite autodiscovers `tests/*.tscn`, so this heavy A/B lives in the
# benchmarks folder instead. It compares the indexed sampler with the frozen
# reference on a 64-cube dense block, a 128-square plate, and a sparse plane.
# Every timed call includes the solid preview payload build.
#
#   godot --headless --path . res://tests/benchmarks/spray_cost.tscn

const SpraySampler := preload("res://plugins/paint/SpraySampler.gd")
const REFERENCE := preload("res://tests/spray_reference_size.gd")
const VoxelPreview := preload("res://Globals/Rendering/VoxelPreview.gd")

const SEED := 20261025
const WIDTHS := [1, 9, 17, 33, 64]
const AB_SAMPLES := 5
const AB_WARMUPS := 1

var frame: VoxelFrame
var _reference
var _reference_rng := RandomNumberGenerator.new()
var _sink := 0


func _ready() -> void:
	timeout = 120.0
	test("the indexed spray costs less than the frozen gather", _cost, "spray_cost")


func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	frame = State.get_current_voxel_frame()
	_reference = REFERENCE.new()
	await get_tree().process_frame


func _cleanup_test() -> void:
	_reference = null


func _cost() -> void:
	var rows := []
	step("Given dense, plate, and sparse fixtures at every width", func():
		for fixture in ["dense", "plate", "sparse"]:
			for width in WIDTHS:
				# A fresh frame per width gives fresh chunks, so the cold row
				# pays the row build while the process stays warm.
				var center := _rebuild_fixture(fixture)
				var cache := SpraySampler.ShapeCache.new()
				var live_report := {}
				var cold_live := _time_live(center, width, cache, live_report)
				_reference = REFERENCE.new()
				var cold_reference := _time_reference(center, width)
				print("MEASURE spray_cost %s/%d cold: live %d us, frozen %d us, gain %.2fx, index_builds=%d grid_reads=%d row_ops=%d" % [
					fixture, width, cold_live, cold_reference,
					float(cold_reference) / maxf(1.0, float(cold_live)),
					int(live_report.get("index_builds", 0)), int(live_report.get("index_grid_reads", 0)),
					int(live_report.get("row_ops", 0)),
				])
				for warmup in AB_WARMUPS:
					_time_live(center, width, cache)
					_time_reference(center, width)
				var live_times: Array[int] = []
				var reference_times: Array[int] = []
				for sample in AB_SAMPLES:
					if sample % 2 == 0:
						live_times.append(_time_live(center, width, cache))
						reference_times.append(_time_reference(center, width))
					else:
						reference_times.append(_time_reference(center, width))
						live_times.append(_time_live(center, width, cache))
				var live_median := _median(live_times)
				var reference_median := _median(reference_times)
				rows.append({"fixture": fixture, "width": width, "live": live_median, "reference": reference_median})
				print("MEASURE spray_cost %s/%d: live %d us, frozen %d us, gain %.2fx, samples %d/%d" % [
					fixture, width, live_median, reference_median,
					float(reference_median) / maxf(1.0, float(live_median)), live_times.size(), reference_times.size(),
				])
	)
	step("Then the indexed sample costs less at every constant-output width", func():
		# Widths 9, 17, 33, and 64 keep the dense and plate output at eight spots,
		# so those rows compare equal output. The sparse plane offers fewer spots
		# at a narrow width, but the frozen gather still walks the whole reach
		# volume, so the indexed path must cost less there too. Width 1 offers one
		# spot and is excluded. The eight spot chunks can spread across widths, so
		# no fixed gain factor is asserted.
		for row in rows:
			if int(row["width"]) >= 9:
				expect(int(row["live"]) < int(row["reference"]), "the indexed %s sample costs less at width %d" % [row["fixture"], int(row["width"])])
	)


func _rebuild_fixture(fixture: String) -> Vector3i:
	if fixture == "dense":
		_new_frame()
		_fill_box(Vector3i.ZERO, Vector3i.ONE * 63, VoxelFrame.material(Color.BLUE))
		frame.restore(frame.chunks)
		return Vector3i(32, 32, 32)
	if fixture == "plate":
		_new_frame()
		_fill_box(Vector3i.ZERO, Vector3i(127, 0, 127), VoxelFrame.material(Color.BLUE))
		frame.restore(frame.chunks)
		return Vector3i(64, 0, 64)
	_use_sparse()
	return Vector3i.ZERO


func _live_sample(center: Vector3i, width: int, cache, report := {}) -> Array[Vector3i]:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	return SpraySampler.sample(center, frame, VoxelFrame.EditContext.new(), 1, width, 8, rng, VoxelFrame.material(Color.WHITE), cache, null, report)


func _reference_sample(center: Vector3i, width: int) -> Array[Vector3i]:
	_reference_rng.seed = SEED
	return _reference.sample_size(center, frame, VoxelFrame.EditContext.new(), 1, width, 8, _reference_rng, VoxelFrame.material(Color.WHITE))


func _time_live(center: Vector3i, width: int, cache, report := {}) -> int:
	var started := Time.get_ticks_usec()
	var cells := _live_sample(center, width, cache, report)
	var payload := VoxelPreview.build_solid_payload(cells, Color.WHITE)
	_sink = payload.spots.size()
	return Time.get_ticks_usec() - started


func _time_reference(center: Vector3i, width: int) -> int:
	var started := Time.get_ticks_usec()
	var cells := _reference_sample(center, width)
	var payload := VoxelPreview.build_solid_payload(cells, Color.WHITE)
	_sink = payload.spots.size()
	return Time.get_ticks_usec() - started


func _new_frame() -> void:
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()


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


func _use_sparse() -> void:
	_new_frame()
	var cells := {}
	for index in 40:
		var cell := Vector3i(index * 3 - 60, 0, (index % 7) * 5 - 15)
		cells[cell] = VoxelFrame.material(Color.BLUE)
	cells[Vector3i.ZERO] = VoxelFrame.material(Color.BLUE)
	frame.set_cells(cells)
	State.document._bounds_dirty = true


func _median(values: Array[int]) -> int:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]
