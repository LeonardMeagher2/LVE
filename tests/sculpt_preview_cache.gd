extends "res://tests/test.gd"

# Verify the hover preview cache. The cache reuses the exact preview cells when
# no geometry input changed, so a same-cell hover pays no fit and no surface
# scan. Every irrelevant input (color, strength, another frame, a distant raw
# write) must keep the cache. Every relevant input (a raw write inside the read
# region, a missing chunk inside it, a selection, a symmetry or a floor change)
# must drop it. The probe reports the surface scans, so one scan proves a miss.
#
# The test drives the real pointer input through the editor viewport. The counts
# come from the preview controller, which the probe also reports, so the numbers
# match the benchmark.

const ProbeScript := preload("./benchmarks/sculpt_preview_probe.gd")
const SculptGeometryScript := preload("res://plugins/Sculpt/SculptGeometry.gd")

var _settings := preload("res://plugins/Sculpt/settings.tres")
var _viewport: SubViewport
var _tool
var _frame: VoxelFrame
var _press := Vector2.ZERO


func _ready() -> void:
	test("a same-cell hover reuses the cached samples", _same_cell, "same_cell")
	test("a color or a strength change resamples nothing", _color_strength, "color_strength")
	test("a geometry change in another frame leaves the hover alone", _other_frame, "other_frame")
	test("a raw write outside the read region leaves the cache alone", _outside_region, "outside_region")
	test("a raw write inside the read region rebuilds the hover", _current_frame_raw, "current_frame_raw")
	test("a raw write in a missing chunk inside the region rebuilds", _missing_chunk, "missing_chunk")
	test("two selections of equal count resample different cells", _selection_content, "selection_content")
	test("a symmetry or a floor change rebuilds the hover", _symmetry_floor, "symmetry_floor")
	test("a floor hover follows the pointer across the plane", _floor_move, "floor_move")
	test("the shared disc cache is read-only and stable", _disk_freeze, "disk_freeze")


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
	_plate(Vector3i(-6, 0, -6), Vector3i(6, 0, 6))
	_viewport = editor_viewport()
	_viewport.get_parent().stretch = false
	_viewport.size = Vector2i(800, 500)
	activate_tool("sculpt")
	var sculpt := plugin("SculptPlugin")
	sculpt.activate_tool()
	sculpt.deactivate_tool()
	_tool = preload("res://plugins/Sculpt/SculptTool.tscn").instantiate()
	_tool.set_script(ProbeScript)
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
		plugin("SculptPlugin").remove_editor_node(_tool)
		_tool.free()
	_tool = null


# --- The cases ----------------------------------------------------------------

func _same_cell() -> void:
	await _hover_and_settle(Vector3.ZERO)
	var before := _cells()
	step("When the user hovers the same cell again", func():
		_tool.reset_probe()
		_tool._rebuild_preview()
	)
	await _settle_preview()
	step("Then the cached cells come back without a surface scan", func():
		expect(_tool.rebuild_calls == 1, "the preview rebuild ran once")
		expect(_scans() == 0, "a same-cell hover runs no sample map")
		expect(_cells() == before, "the cached cells match the exact cells")
	)


func _color_strength() -> void:
	await _hover_and_settle(Vector3.ZERO)
	var before := _cells()
	step("When the color and the strength change alone", func():
		State.current_color = Color.from_rgba8(20, 200, 90)
		State.color_changed.emit(State.current_color)
		_settings.strength = 7.0
		_tool.reset_probe()
		_tool._rebuild_preview()
	)
	await _settle_preview()
	step("Then the cached cells come back without a surface scan", func():
		expect(_scans() == 0, "a color or a strength change runs no sample map")
		expect(_cells() == before, "the cached cells match the exact cells")
	)


func _other_frame() -> void:
	await _hover_and_settle(Vector3.ZERO)
	var before := _cells()
	step("Given a settled hover and a second frame with a new voxel", func():
		var other := State.document.add_frame(0)
		var other_cell := Vector3i(0, 5, 0)
		other.set_cell(other_cell, VoxelFrame.material(Color.WHITE))
		var cells: Array[Vector3i] = [other_cell]
		State.cells_changed.emit(1, cells)
	)
	step("When the current frame rebuilds", func():
		_tool.reset_probe()
		_tool._rebuild_preview()
	)
	await _settle_preview()
	step("Then the other frame leaves the exact cells alone", func():
		expect(_scans() == 0, "a change in another frame runs no sample map")
		expect(_cells() == before, "the cached cells match the exact cells")
		State.document.remove_frame(1)
	)


func _outside_region() -> void:
	await _hover_and_settle(Vector3.ZERO)
	var before := _cells()
	step("When a raw write lands far outside the read region", func():
		_frame.set_cell(Vector3i(200, 0, 200), VoxelFrame.material(Color.WHITE))
		_tool.reset_probe()
		_tool._rebuild_preview()
	)
	await _settle_preview()
	step("Then the far write leaves the cache alone", func():
		expect(_scans() == 0, "a raw write outside the region runs no sample map")
		expect(_cells() == before, "the cached cells match the exact cells")
	)


func _current_frame_raw() -> void:
	await _hover_and_settle(Vector3.ZERO)
	var before := _cells()
	step("When a raw write lands inside the read region", func():
		_frame.set_cell(Vector3i(0, 1, 0), VoxelFrame.material(Color.WHITE))
		_tool.reset_probe()
		_tool._rebuild_preview()
	)
	await _settle_preview()
	step("Then the next preview reads the raw write", func():
		expect(_scans() == 1, "a raw write inside the region runs one sample map")
		expect(_cells() != before, "the raw write moves the exact cells")
	)


func _missing_chunk() -> void:
	step("Given a quarter plate so the read region holds a missing chunk", func():
		_plate(Vector3i(0, 0, 0), Vector3i(6, 0, 6))
		sync_viewport()
	)
	await _hover_and_settle(Vector3i(1, 0, 1))
	var watch_before: PackedInt64Array = _tool._hover_map_watch
	step("When a raw write lands in a missing chunk inside the region", func():
		_frame.set_cell(Vector3i(-1, 0, -1), VoxelFrame.material(Color.WHITE))
		_tool.reset_probe()
		_tool._rebuild_preview()
	)
	await _settle_preview()
	step("Then the new chunk enters the map watch and rebuilds the hover", func():
		expect(_scans() == 1, "a raw write in a missing chunk runs one sample map")
		expect(_tool._hover_map_watch != watch_before, "the new chunk enters the map watch")
	)


func _selection_content() -> void:
	await _hover_and_settle(Vector3.ZERO)
	step("When two selections of one size hold different cells", func():
		State.selection.from_box(Vector3i(-2, -1, -2), Vector3i(2, 1, 2))
		State.selection_changed.emit()
		_tool.reset_probe()
		_tool._rebuild_preview()
	)
	await _settle_preview()
	var first := _cells()
	var first_count: int = _scans()
	step("Then the shifted selection resamples different cells", func():
		State.selection.from_box(Vector3i(-1, -1, -2), Vector3i(3, 1, 2))
		State.selection_changed.emit()
		_tool.reset_probe()
		_tool._rebuild_preview()
	)
	await _settle_preview()
	step("Then the two equal-count selections filter differently", func():
		expect(first_count == 1, "the first selection runs one sample map")
		expect(_scans() == 1, "the shifted selection runs one sample map")
		expect(State.selection.count() == 5 * 3 * 5, "the two selections hold the same count")
		expect(_cells() != first, "the two selections filter different exact cells")
	)


func _disk_freeze() -> void:
	step("Then the shared disc cache is read-only and stable", func():
		var first: Array = SculptGeometryScript.disk_offsets(4)
		var second: Array = SculptGeometryScript.disk_offsets(4)
		expect(first.is_read_only(), "the cached disc array is read-only")
		expect(first.size() > 0, "the disc holds entries")
		expect((first[0] as Dictionary).is_read_only(), "each disc entry is read-only")
		expect(first == second, "the same radius returns the same cached disc")
		var large: Array = SculptGeometryScript.disk_offsets(32)
		expect(large.is_read_only() and large.size() > first.size(), "the large radius caches its own disc")
	)


func _floor_move() -> void:
	step("Given an empty floor", func():
		State.document = VoxelDocument.new()
		_frame = State.get_current_voxel_frame()
	)
	await _hover_and_settle(Vector3.ZERO)
	var first := _cells()
	await _hover_and_settle(Vector3(4, 0, 0))
	step("Then the moved floor hover reseeds at the new cell", func():
		expect(_cells().size() > 0, "the floor hover shows a seed cell")
		expect(_cells() != first, "the moved floor hover follows the pointer")
	)


func _symmetry_floor() -> void:
	await _hover_and_settle(Vector3.ZERO)
	step("When the symmetry changes", func():
		State.symmetry_axes = 1
		_tool.reset_probe()
		_tool._rebuild_preview()
	)
	await _settle_preview()
	step("Then the symmetry rebuilds the hover", func():
		expect(_scans() == 1, "a symmetry change runs one sample map")
	)
	step("When the floor changes", func():
		State.floor_axis = Vector3.Axis.AXIS_Z
		_tool.reset_probe()
		_tool._rebuild_preview()
	)
	await _settle_preview()
	step("Then the floor rebuilds the hover", func():
		expect(_scans() == 1, "a floor change runs one sample map")
	)


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


func _hover_and_settle(world: Vector3) -> void:
	_press = _pos(world)
	_hover(_press)
	await _settle_preview()
	_tool.reset_probe()


func _settle_preview() -> void:
	for index in 240:
		await get_tree().process_frame
		if not _tool._preview_dirty and not _tool._preview.is_running() and _tool.get_node("Cursor").is_settled():
			return


# Returns the surface scans that the preview controller counted on its worker.
# The probe reports the same count for the published hover. The live counter also
# catches a scan whose result was dropped.
func _scans() -> int:
	return _tool._preview.sample_map_calls


# Returns the sorted keys of the published preview cells, so two sets compare
# element by element.
func _cells() -> Array:
	var keys: Array = _tool._preview_cells.keys()
	keys.sort()
	return keys
