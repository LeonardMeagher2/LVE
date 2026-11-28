extends "res://tests/test.gd"


const FILL_X := 32
const FILL_Y := 16
const FILL_Z := 16
const FILL_COUNT := FILL_X * FILL_Y * FILL_Z
const EMPTY_Z := 8
const SELECTED_COUNT := FILL_X * FILL_Y * (FILL_Z + EMPTY_Z)

var plugin_node: Node
var settings: StampToolSettings
var source_path := ""
var first_job: VoxelFrame.EditJob
var metal := VoxelFrame.material(Color.RED, Color(0.5, 0.25, 0.125), 1.0, 0.25)
var blue := VoxelFrame.material(Color.BLUE, Color(0.125, 0.5, 0.25), 0.25, 0.75)


func _ready() -> void:
	timeout = 30.0
	test("a large stamp selection copies every full material on the worker", _worker_publishes, "stamp_source_worker_publish")
	test("a document change cancels the stamp worker source and publishes nothing", _worker_cancel_context, "stamp_source_worker_cancel")
	test("a second stamp request keeps the running worker source", _worker_reentry, "stamp_source_worker_reentry")
	test("a large stamp file frame runs on the worker", _worker_file_frame, "stamp_source_worker_file")
	test("a selection toggles the stamp source button", _selection_availability, "stamp_source_worker_cells")


func before_test() -> void:
	State.stop()
	State.current_frame = 0
	State.active_tag = 0
	State.selection.clear()
	State.undo_redo.clear_history()
	State.document = VoxelDocument.new()
	while State.get_activity() != null:
		State.finish_operation(State.get_activity().id)
	plugin_node = plugin("StampPlugin")
	settings = plugin_node._settings
	settings.clear_stamp()
	first_job = null
	source_path = "user://stamp_source_worker_%s.lve" % Time.get_ticks_usec()
	await get_tree().process_frame


func after_test() -> void:
	for i in 300:
		if not State.edit_busy():
			break
		await get_tree().process_frame
	while State.get_activity() != null:
		State.finish_operation(State.get_activity().id)
	if FileAccess.file_exists(source_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(source_path))
	await get_tree().process_frame


func _worker_publishes() -> void:
	step("Given a selection larger than the inline limit with two full materials", func():
		_fill_source()
		expect(State.get_current_voxel_frame().count() == FILL_COUNT, "the source frame holds every block voxel")
		expect(State.selection.count() == SELECTED_COUNT, "the selection adds empty cells above the block")
	)
	step("When the user uses the selection as a stamp", func():
		plugin_node.use_current_selection()
		expect(plugin_node._source_job != null, "the large source runs on a worker")
		expect(State.edit_busy(), "the source preparation owns a foreground operation")
	)
	await _await_source()
	step("Then the worker publishes every full material and excludes the empty cells", func():
		expect(plugin_node._source_job == null, "the worker source clears its job")
		expect(not State.edit_busy(), "the worker source releases editing")
		expect(settings.shape == settings.BrushShape.STAMP, "the prepared pattern becomes the active shape")
		expect(settings.stamp_pattern.size() == FILL_COUNT, "the pattern holds only the occupied source voxels")
		expect(settings.stamp_material_pattern.size() == FILL_COUNT, "the pattern holds one material per occupied voxel")
		var materials: Array = settings.stamp_material_pattern.values()
		expect(materials.has(metal), "the pattern keeps the first full material")
		expect(materials.has(blue), "the pattern keeps the second full material")
	)


func _worker_cancel_context() -> void:
	step("Given a large selection source on the worker", func():
		_fill_source()
		plugin_node.use_current_selection()
		expect(plugin_node._source_job != null, "the large source runs on a worker")
		expect(settings.stamp_pattern.is_empty(), "the source pattern is not published yet")
	)
	step("When the document changes before the worker finishes", func():
		State.document = VoxelDocument.new()
	)
	await _await_source()
	step("Then the source cancels and publishes nothing", func():
		expect(plugin_node._source_job == null, "the cancelled source clears its job")
		expect(not State.edit_busy(), "the cancelled source releases editing")
		expect(settings.stamp_pattern.is_empty(), "the cancelled source publishes no pattern")
	)


func _worker_reentry() -> void:
	step("Given a large selection source on the worker", func():
		_fill_source()
		plugin_node.use_current_selection()
		first_job = plugin_node._source_job
		expect(first_job != null, "the first source runs on a worker")
	)
	step("When the user selects the same cells and requests the stamp again", func():
		State.selection.from_box(Vector3i.ZERO, Vector3i(FILL_X - 1, FILL_Y - 1, FILL_Z + EMPTY_Z - 1))
		State.selection_changed.emit()
		plugin_node.use_current_selection()
		expect(plugin_node._source_job == first_job, "the second request keeps the running source")
		expect(State.get_activity() != null, "the running source keeps its operation")
	)
	await _await_source()
	step("Then one worker publishes the pattern once", func():
		expect(plugin_node._source_job == null, "the single source clears its job")
		expect(not State.edit_busy(), "the single source releases editing")
		expect(settings.stamp_pattern.size() == FILL_COUNT, "the single source publishes the full pattern")
	)


func _worker_file_frame() -> void:
	step("Given a large file frame", func():
		var document := VoxelDocument.new()
		var cells := {}
		for x in FILL_X:
			for y in FILL_Y:
				for z in FILL_Z:
					cells[Vector3i(x, y, z)] = metal if (x + y + z) % 2 == 0 else blue
		document.active_layer().frames[0].set_cells(cells)
		expect(document.save_file(source_path) == OK, "the source document saves")
	)
	step("When the user opens the file and the first frame becomes the stamp", func():
		plugin_node.open_source_file(source_path)
		expect(plugin_node._source_job != null, "the large file frame runs on a worker")
	)
	await _await_source()
	step("Then the file frame publishes every full material", func():
		expect(settings.stamp_pattern.size() == FILL_COUNT, "the file frame pattern holds every voxel")
		expect(settings.stamp_material_pattern.size() == FILL_COUNT, "the file frame keeps one material per voxel")
		expect(not State.edit_busy(), "the file frame source releases editing")
	)


func _selection_availability() -> void:
	step("Given the stamp option bar and an empty selection", func():
		activate_tool("stamp")
		var options: Control = plugin_node._options
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, metal)
		State.selection_changed.emit()
		expect(options.get_node("UseSelection").disabled, "an empty selection disables the stamp source")
	)
	step("When one voxel is selected", func():
		State.selection.add(Vector3i.ZERO)
		State.selection_changed.emit()
		expect(not plugin_node._options.get_node("UseSelection").disabled, "a non-empty selection enables the stamp source")
	)
	step("When the selection is cleared", func():
		State.clear_selection()
		expect(plugin_node._options.get_node("UseSelection").disabled, "the cleared selection disables the stamp source")
	)


func _await_source() -> void:
	for i in 600:
		if plugin_node == null or plugin_node._source_job == null:
			break
		await get_tree().process_frame
	await get_tree().process_frame


func _fill_source() -> void:
	var frame := State.get_current_voxel_frame()
	var cells := {}
	for x in FILL_X:
		for y in FILL_Y:
			for z in FILL_Z:
				cells[Vector3i(x, y, z)] = metal if (x + y + z) % 2 == 0 else blue
	frame.set_cells(cells)
	State.selection.from_box(Vector3i.ZERO, Vector3i(FILL_X - 1, FILL_Y - 1, FILL_Z + EMPTY_Z - 1))
	State.selection_changed.emit()
