extends "res://tests/test.gd"

# A rendered search-scaling benchmark for the spray can.
#
# The spot stays at one cell and the speed stays at eight. Only the search width
# changes. The benchmark drives the real Main scene viewport with real mouse
# events and a real windowed renderer, so it shows the input cost and the visible
# preview install of the production path.
#
#   godot --path . --screen 0 res://tests/benchmarks/spray_search_scaling.tscn
#   godot --path . --screen 0 res://tests/benchmarks/spray_search_scaling.tscn -- dense64
#
# The headless A/B in `tests/spray_search_scaling.gd` proves the kernel cost and
# the frozen-reference parity. This benchmark proves the rendered path keeps the
# input frame short and the preview installs while the search grows.

const ProbeScript := preload("./spray_latency_tool.gd")
const PreviewProbeScript := preload("./spray_latency_preview.gd")
const SPRAY_SCENE := "res://plugins/paint/SprayTool.tscn"
const SEED := 20261025
const VIEWPORT_SIZE := Vector2i(800, 500)
const WIDTHS := [1, 9, 17, 33, 64]
const SAME_EVENTS := 8
const SWEEP_EVENTS := 16
const SPARSE_VOXELS := 48

const SPECS := [
	{"name": "dense64", "kind": "block", "size": 64},
	{"name": "plate128", "kind": "plate", "size": 128},
	{"name": "sparse256", "kind": "sparse", "size": 256},
	{"name": "hollow1024", "kind": "hollow", "size": 256},
]

var _settings := preload("res://plugins/paint/settings.tres")

var _tool
var _cursor
var _frame: VoxelFrame
var _viewport: SubViewport
var _fixture_us := 0
var _last_same := {}
var _last_sweep := {}


func _ready() -> void:
	timeout = 240.0
	for spec in SPECS:
		test("the spray search scales at %s" % spec["name"], func(): await _run(spec), spec["name"])


func _run(spec: Dictionary) -> void:
	await _prepare(spec)
	step("Given the %s fixture at spot one and speed eight" % spec["name"], func():
		expect(_frame.count() > 0, "the fixture holds voxels")
		print("MEASURE spray_search_scaling %s fixture: cells=%d chunks=%d bounds=%s build_us=%d" % [
			spec["name"], _frame.count(), _frame.chunks.size(), str(_frame.get_bounds()), _fixture_us,
		])
	)
	# Warm the shader, the material, and the preview pipeline once. This hover is
	# not measured, and every cold row below rebuilds the fixture, so the row
	# index is still cold.
	_tool._invalidate_batch()
	_hover(_screen_of(_middle_cell(spec)))
	await _settle_all()
	await get_tree().process_frame
	var rows := []
	for width in WIDTHS:
		await _reset_cold_fixture(spec)
		_settings.spot_diameter = 1
		_settings.spray_size = width
		_settings.speed = 8
		_tool._invalidate_batch()
		_tool.clear_shape_caches()
		_tool.seed_spray(SEED)
		_tool.reset_probe()
		_cursor.reset_probe()
		var cell := _middle_cell(spec)
		var started := Time.get_ticks_usec()
		_hover(_screen_of(cell))
		var input_us := Time.get_ticks_usec() - started
		var visible_frames := 0
		for index in 240:
			await get_tree().process_frame
			visible_frames += 1
			if not _tool._batch_cells.is_empty() and _tool.is_sample_settled() and _cursor.is_settled():
				break
		var visible_us := Time.get_ticks_usec() - started
		var cold := {
			"width": width, "input_us": input_us, "visible_us": visible_us,
			"visible_frames": visible_frames, "cells": _tool._batch_cells.size(),
			"worker_samples": _tool.worker_samples, "request_us": _cursor.request_us,
			"install_us": _cursor.install_max_us,
			"index_builds": _tool.last_index_builds,
			"index_grid_reads": _tool.last_index_grid_reads,
			"work_estimate": _tool.last_work_estimate,
			"row_ops": _tool.last_row_ops,
			"capture_chunks": _tool.last_capture_chunks,
			"preview_cells": _cursor.preview_cells,
			"preview_chunks": _cursor.job_chunk_count,
			"preview_build_us": _cursor.build_us,
			"preview_merge_us": _cursor.merge_us,
			"preview_bytes": _cursor.geometry_bytes,
		}
		_tool.reset_probe()
		_cursor.reset_probe()
		var same_inputs: Array[int] = []
		for index in SAME_EVENTS:
			var event_started := Time.get_ticks_usec()
			_hover(_screen_of(cell))
			same_inputs.append(Time.get_ticks_usec() - event_started)
			await get_tree().process_frame
		var same := {
			"input_us": _median(same_inputs), "samples": _tool.sample_calls,
			"requests": _cursor.request_calls, "installs": _cursor.installs,
			"index_builds": _tool.last_index_builds,
		}
		_tool.reset_probe()
		_cursor.reset_probe()
		var sweep_inputs: Array[int] = []
		var sweep_cells := _path_cells(spec, SWEEP_EVENTS)
		for sweep_cell in sweep_cells:
			var event_started := Time.get_ticks_usec()
			_hover(_screen_of(sweep_cell))
			sweep_inputs.append(Time.get_ticks_usec() - event_started)
			await get_tree().process_frame
		var sweep := {
			"input_us": _median(sweep_inputs), "input_max_us": _max(sweep_inputs),
			"worker_samples": _tool.worker_samples, "requests": _cursor.request_calls,
			"installs": _cursor.installs, "discards": _cursor.discards,
			"index_builds": _tool.last_index_builds,
			"work_estimate": _tool.last_work_estimate,
			"capture_chunks": _tool.last_capture_chunks,
		}
		rows.append(cold)
		_last_same = same
		_last_sweep = sweep
		print("MEASURE spray_search_scaling %s search=%d cold: input_us=%d visible_us=%d visible_frames=%d cells=%d worker_samples=%d work_estimate=%d row_ops=%d capture_chunks=%d index_builds=%d index_grid_reads=%d cursor_request_us=%d install_us=%d preview_cells=%d preview_chunks=%d preview_build_us=%d preview_merge_us=%d preview_bytes=%d" % [
			spec["name"], width, cold["input_us"], cold["visible_us"], cold["visible_frames"],
			cold["cells"], cold["worker_samples"], cold["work_estimate"], cold["row_ops"], cold["capture_chunks"], cold["index_builds"], cold["index_grid_reads"],
			cold["request_us"], cold["install_us"], cold["preview_cells"], cold["preview_chunks"],
			cold["preview_build_us"], cold["preview_merge_us"], cold["preview_bytes"],
		])
		print("MEASURE spray_search_scaling %s search=%d same: input_us=%d samples=%d requests=%d installs=%d index_builds=%d" % [
			spec["name"], width, same["input_us"], same["samples"], same["requests"], same["installs"], same["index_builds"],
		])
		print("MEASURE spray_search_scaling %s search=%d sweep: input_us=%d input_max_us=%d worker_samples=%d requests=%d installs=%d discards=%d work_estimate=%d capture_chunks=%d index_builds=%d" % [
			spec["name"], width, sweep["input_us"], sweep["input_max_us"], sweep["worker_samples"],
			sweep["requests"], sweep["installs"], sweep["discards"], sweep["work_estimate"], sweep["capture_chunks"], sweep["index_builds"],
		])
	# Repaint and occupancy phases on the widest search. The material change must
	# keep the chunk rows; the erase must invalidate the queried chunk. The erase
	# cell sits beside the picked pivot in the same chunk, so the pivot stays the
	# ray hit and the erased chunk stays inside the measured query.
	_settings.spray_size = 64
	_settings.spot_diameter = 1
	_settings.speed = 8
	var phase_cell := _middle_cell(spec)
	var erase_cell := phase_cell + Vector3i(1, 0, 0)
	var erase_chunk := VoxelFrame.chunk_position(erase_cell)
	_frame.set_cell(phase_cell, VoxelFrame.material(Color.GREEN))
	_tool._invalidate_batch()
	_tool.seed_spray(SEED)
	_tool.reset_probe()
	_cursor.reset_probe()
	var repaint_started := Time.get_ticks_usec()
	_hover(_screen_of(phase_cell))
	var repaint_input := Time.get_ticks_usec() - repaint_started
	await _settle_all()
	var repaint_row := {
		"input_us": repaint_input, "index_builds": _tool.last_index_builds,
		"cells": _tool._batch_cells.size(), "worker_samples": _tool.worker_samples,
		"preview_chunks": _cursor.job_chunk_count, "preview_build_us": _cursor.build_us,
	}
	print("MEASURE spray_search_scaling %s repaint: input_us=%d index_builds=%d cells=%d worker_samples=%d preview_chunks=%d preview_build_us=%d" % [
		spec["name"], repaint_row["input_us"], repaint_row["index_builds"], repaint_row["cells"],
		repaint_row["worker_samples"], repaint_row["preview_chunks"], repaint_row["preview_build_us"],
	])
	var warm_chunk: VoxelFrame.Chunk = _frame.chunks.get(erase_chunk)
	step("When the occupancy erase invalidates the queried chunk", func():
		expect(warm_chunk != null and warm_chunk.occupancy_index_current(), "the repaint hover warmed the erased chunk")
		_frame.set_cell(erase_cell, VoxelFrame.material(Color.TRANSPARENT))
		var erased_chunk: VoxelFrame.Chunk = _frame.chunks.get(erase_chunk)
		expect(erased_chunk != null and erased_chunk.occupied_count > 0, "the erase keeps the queried chunk")
		expect(not erased_chunk.occupancy_index_current(), "the erase invalidates the queried chunk rows")
	)
	_tool._invalidate_batch()
	_tool.seed_spray(SEED)
	_tool.reset_probe()
	_cursor.reset_probe()
	var occupancy_started := Time.get_ticks_usec()
	_hover(_screen_of(phase_cell))
	var occupancy_input := Time.get_ticks_usec() - occupancy_started
	await _settle_all()
	var occupancy_row := {
		"input_us": occupancy_input, "index_builds": _tool.last_index_builds,
		"cells": _tool._batch_cells.size(), "worker_samples": _tool.worker_samples,
	}
	print("MEASURE spray_search_scaling %s occupancy: input_us=%d index_builds=%d cells=%d worker_samples=%d" % [
		spec["name"], occupancy_row["input_us"], occupancy_row["index_builds"],
		occupancy_row["cells"], occupancy_row["worker_samples"],
	])
	step("Then the material repaint keeps the rows and the erase rebuilds them", func():
		expect(int(repaint_row["index_builds"]) == 0, "a material repaint keeps the occupancy rows")
		expect(int(occupancy_row["cells"]) > 0, "the erase keeps the queried pivot")
		expect(int(occupancy_row["index_builds"]) >= 1, "an occupancy erase rebuilds the changed chunk")
	)
	step("Then every width keeps the point batch and a short input frame", func():
		for row in rows:
			expect(int(row["cells"]) > 0, "the point batch holds a spot center at width %d" % int(row["width"]))
			expect(int(row["cells"]) <= 8, "the point batch never passes the speed at width %d" % int(row["width"]))
			expect(int(row["input_us"]) < 8000, "the input frame stays under eight milliseconds at width %d" % int(row["width"]))
	)
	step("Then the still hover samples nothing and requests nothing", func():
		expect(int(rows[rows.size() - 1]["width"]) == 64, "the last measured width is 64")
		# The same-hover row is the last width row. A held batch never resamples
		# and never resubmits a preview.
		expect(int(_last_same.get("samples", -1)) == 0 and int(_last_same.get("requests", -1)) == 0, "the still hover samples and requests nothing")
	)
	step("Then the widest search still installs a visible preview", func():
		var widest: Dictionary = rows[rows.size() - 1]
		expect(int(widest["width"]) == 64, "the widest row is the width 64 row")
		expect(int(widest["visible_us"]) < 100000, "the width 64 preview installs under one hundred milliseconds")
		if spec["name"] != "sparse256":
			expect(int(widest["worker_samples"]) > 0, "the width 64 batch samples on the worker")
		expect(int(_last_sweep.get("installs", 0)) > 0, "the width 64 sweep installs a visible preview")
	)
	step("Then a hollow model captures only its local chunks", func():
		if spec["name"] == "hollow1024":
			var widest: Dictionary = rows[rows.size() - 1]
			expect(int(widest["capture_chunks"]) < _frame.chunks.size(), "the width 64 subset capture skips most of the 1024 chunks")
	)


# --- Fixture and setup -------------------------------------------------------

# Rebuilds the fixture for one cold width. A fresh frame gives fresh chunks, so
# the occupancy rows are cold, while the process, the shader, and the material
# stay warm.
func _reset_cold_fixture(spec: Dictionary) -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	_frame = State.get_current_voxel_frame()
	_build_fixture(spec)
	_tool._clear_cursor_preview()
	_tool._invalidate_batch()
	camera_rig().center_on(_frame.get_bounds())
	camera_rig().set_view("top")
	await _settle_all()


func _prepare(spec: Dictionary) -> void:
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
	_settings.spot_diameter = 1
	_settings.spray_size = 9
	_settings.speed = 8
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


func after_test() -> void:
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


func _build_fixture(spec: Dictionary) -> void:
	var kind: String = spec["kind"]
	var size: int = spec["size"]
	var cell_material := VoxelFrame.material(Color.from_rgba8(90, 160, 220))
	if kind == "block":
		_fill_box(Vector3i.ZERO, Vector3i.ONE * (size - 1), cell_material)
	elif kind == "plate":
		_fill_box(Vector3i.ZERO, Vector3i(size - 1, 0, size - 1), cell_material)
	elif kind == "hollow":
		var hollow := {}
		for cx in 16:
			for cy in 4:
				for cz in 16:
					hollow[Vector3i(cx * VoxelFrame.CHUNK_SIZE + 8, cy * VoxelFrame.CHUNK_SIZE + 8, cz * VoxelFrame.CHUNK_SIZE + 8)] = cell_material
		# One neighbor keeps the middle chunk alive when the occupancy phase
		# erases the middle cell, so the phase really rebuilds a row index.
		hollow[Vector3i(8 * VoxelFrame.CHUNK_SIZE + 9, 1 * VoxelFrame.CHUNK_SIZE + 8, 8 * VoxelFrame.CHUNK_SIZE + 8)] = cell_material
		_frame.set_cells(hollow)
	else:
		var cells := {}
		for index in SPARSE_VOXELS:
			cells[_sparse_cell(size, index)] = cell_material
		cells[_sparse_cell(size, SPARSE_VOXELS / 2) + Vector3i(1, 0, 0)] = cell_material
		_frame.set_cells(cells)
	_frame.restore(_frame.chunks)


func _fill_box(min_cell: Vector3i, max_cell: Vector3i, cell_material: PackedFloat32Array) -> void:
	var min_chunk := VoxelFrame.chunk_position(min_cell)
	var max_chunk := VoxelFrame.chunk_position(max_cell)
	for cz in range(min_chunk.z, max_chunk.z + 1):
		for cy in range(min_chunk.y, max_chunk.y + 1):
			for cx in range(min_chunk.x, max_chunk.x + 1):
				var location := Vector3i(cx, cy, cz)
				var chunk: VoxelFrame.Chunk = _frame.chunks.get(location)
				if chunk == null:
					chunk = VoxelFrame.Chunk.new()
					chunk.location = location
					_frame.chunks[location] = chunk
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


func _sparse_cell(size: int, index: int) -> Vector3i:
	var x := -size + (index * 2 * size) / SPARSE_VOXELS
	var z := -size + ((index * 13) % SPARSE_VOXELS) * (2 * size) / SPARSE_VOXELS
	return Vector3i(x, 0, z)


func _middle_cell(spec: Dictionary) -> Vector3i:
	var kind: String = spec["kind"]
	var size: int = spec["size"]
	if kind == "block":
		return Vector3i(size / 2, size - 1, size / 2)
	if kind == "plate":
		return Vector3i(size / 2, 0, size / 2)
	if kind == "hollow":
		return Vector3i(8 * VoxelFrame.CHUNK_SIZE + 8, 1 * VoxelFrame.CHUNK_SIZE + 8, 8 * VoxelFrame.CHUNK_SIZE + 8)
	return _sparse_cell(size, SPARSE_VOXELS / 2)


func _path_cells(spec: Dictionary, count: int) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	var kind: String = spec["kind"]
	var size: int = spec["size"]
	if kind == "sparse":
		for index in mini(count, SPARSE_VOXELS):
			cells.append(_sparse_cell(size, index))
		return cells
	if kind == "hollow":
		for index in count:
			var cx := 6 + (index % 4)
			var cz := 6 + ((index / 4) % 4)
			cells.append(Vector3i(cx * VoxelFrame.CHUNK_SIZE + 8, 1 * VoxelFrame.CHUNK_SIZE + 8, cz * VoxelFrame.CHUNK_SIZE + 8))
		return cells
	var y := size - 1 if kind == "block" else 0
	var start := size / 2 - count / 2
	for index in count:
		cells.append(Vector3i(start + index, y, size / 2 + (index % 3) - 1))
	return cells


# --- Input and settling ------------------------------------------------------

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


func _median(values: Array[int]) -> int:
	if values.is_empty():
		return 0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


func _max(values: Array[int]) -> int:
	var best := 0
	for value in values:
		best = maxi(best, value)
	return best
