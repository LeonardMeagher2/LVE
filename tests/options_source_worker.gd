extends "res://tests/test.gd"

# The brush and paint option bars copy a frame or a selection into a voxel
# brush pattern. A source above the inline limit runs on the worker pool through
# the shared `State.run_edit_job` helper. These tests cover that worker path for
# both bars: the full-material publication, the context-change cancellation, and
# the reentry guard. They also cover the narrowed cell-change publication, which
# updates only the selection-source button.

const FILL_X := 32
const FILL_Y := 16
const FILL_Z := 16
const FILL_COUNT := FILL_X * FILL_Y * FILL_Z
const EMPTY_Z := 8
const SELECTED_COUNT := FILL_X * FILL_Y * (FILL_Z + EMPTY_Z)
const BRUSH_SCENE := preload("res://plugins/brush/Options.tscn")
const PAINT_SCENE := preload("res://plugins/paint/Options.tscn")

var options: Node
var settings: Resource
var selection_path := ""
var first_job: VoxelFrame.EditJob
var metal := VoxelFrame.material(Color.RED, Color(0.5, 0.25, 0.125), 1.0, 0.25)
var blue := VoxelFrame.material(Color.BLUE, Color(0.125, 0.5, 0.25), 0.25, 0.75)


func _ready() -> void:
	timeout = 30.0
	for bar in _bars():
		var bar_name: String = bar["name"]
		test("a large selection copies every full material on the %s worker" % bar_name, _worker_publishes.bind(bar), "options_source_worker_publish_" + bar_name)
		test("a document change cancels the %s worker source and publishes nothing" % bar_name, _worker_cancel_context.bind(bar), "options_source_worker_cancel_" + bar_name)
		test("a second press keeps the running %s worker source" % bar_name, _worker_reentry.bind(bar), "options_source_worker_reentry_" + bar_name)
		test("a cell change toggles the %s selection source button" % bar_name, _cell_change_toggles_availability.bind(bar), "options_source_worker_cells_" + bar_name)


# The two option bars. `selection` is the selection-source button path. The paint
# bar nests the brush controls, so its path differs.
func _bars() -> Array:
	return [
		{"name": "brush", "scene": BRUSH_SCENE, "selection": "Shape/Selection"},
		{"name": "paint", "scene": PAINT_SCENE, "selection": "Brush/Shape/Selection"},
	]


func _setup_test() -> void:
	State.stop()
	State.current_frame = 0
	State.active_tag = 0
	State.selection.clear()
	State.undo_redo.clear_history()
	State.document = VoxelDocument.new()
	while State.get_activity() != null:
		State.finish_operation(State.get_activity().id)
	options = null
	settings = null
	await get_tree().process_frame


func _cleanup_test() -> void:
	if is_instance_valid(options):
		options.free()
	options = null
	for i in 300:
		if not State.edit_busy():
			break
		await get_tree().process_frame
	while State.get_activity() != null:
		State.finish_operation(State.get_activity().id)
	if settings != null:
		_reset_settings()
	settings = null
	await get_tree().process_frame


func _worker_publishes(bar: Dictionary) -> void:
	_begin(bar)
	step("Given a %s selection larger than the inline limit with two full materials" % bar["name"], func():
		_fill_source()
		expect(State.get_current_voxel_frame().count() == FILL_COUNT, "the source frame holds every block voxel")
		expect(State.selection.count() == SELECTED_COUNT, "the selection adds empty cells above the block")
	)
	step("When the user copies the selection as a voxel brush", func():
		options._on_selection_pressed()
		expect(options._source_job != null, "the large source runs on a worker")
		expect(State.edit_busy(), "the source preparation owns a foreground operation")
	)
	await _await_source()
	step("Then the worker publishes every full material and excludes the empty cells", func():
		expect(options._source_job == null, "the worker source clears its job")
		expect(not State.edit_busy(), "the worker source releases editing")
		expect(settings.shape == settings.BrushShape.SELECTION, "the copied pattern becomes the active shape")
		expect(settings.selection_pattern.size() == FILL_COUNT, "the pattern holds only the occupied source voxels")
		expect(settings.selection_material_pattern.size() == FILL_COUNT, "the pattern holds one material per occupied voxel")
		var materials: Array = settings.selection_material_pattern.values()
		expect(materials.has(metal), "the pattern keeps the first full material")
		expect(materials.has(blue), "the pattern keeps the second full material")
	)


func _worker_cancel_context(bar: Dictionary) -> void:
	_begin(bar)
	step("Given a %s large selection source on the worker" % bar["name"], func():
		_fill_source()
		options._on_selection_pressed()
		expect(options._source_job != null, "the large source runs on a worker")
		expect(settings.shape == settings.BrushShape.CUBE, "the source shape is not published yet")
	)
	step("When the document changes before the worker finishes", func():
		State.document = VoxelDocument.new()
	)
	await _await_source()
	step("Then the source cancels and publishes nothing", func():
		expect(options._source_job == null, "the cancelled source clears its job")
		expect(not State.edit_busy(), "the cancelled source releases editing")
		expect(settings.shape == settings.BrushShape.CUBE, "the cancelled source keeps the previous shape")
		expect(settings.selection_pattern.is_empty(), "the cancelled source publishes no pattern")
	)


func _worker_reentry(bar: Dictionary) -> void:
	_begin(bar)
	step("Given a %s large selection source on the worker" % bar["name"], func():
		_fill_source()
		options._on_selection_pressed()
		first_job = options._source_job
		expect(first_job != null, "the first source runs on a worker")
	)
	step("When the user presses the selection shape again", func():
		options._on_selection_pressed()
		expect(options._source_job == first_job, "the second press keeps the running source")
		expect(State.get_activity() != null, "the running source keeps its operation")
	)
	await _await_source()
	step("Then one worker publishes the pattern once", func():
		expect(options._source_job == null, "the single source clears its job")
		expect(not State.edit_busy(), "the single source releases editing")
		expect(settings.selection_pattern.size() == FILL_COUNT, "the single source publishes the full pattern")
	)


# The narrowed cell-change publication updates only the selection-source button.
# The test emits the model signals directly and never calls `_sync`.
func _cell_change_toggles_availability(bar: Dictionary) -> void:
	_begin(bar)
	step("Given an empty frame and the %s option bar" % bar["name"], func():
		_emit_cells_changed()
		expect(_selection_button().disabled, "an empty frame disables the selection source")
	)
	step("When one cell appears and the model reports the change", func():
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, metal)
		_emit_cells_changed()
		expect(not _selection_button().disabled, "a populated frame enables the selection source")
	)
	step("When the last cell is removed and the model reports it", func():
		State.get_current_voxel_frame().clear()
		_emit_chunks_changed()
		expect(_selection_button().disabled, "an empty frame disables the selection source again")
	)


func _begin(bar: Dictionary) -> void:
	selection_path = str(bar["selection"])
	options = bar["scene"].instantiate()
	settings = options._settings
	first_job = null
	_reset_settings()
	main.add_child(options)


func _reset_settings() -> void:
	settings.shape = settings.BrushShape.CUBE
	settings.selection_pattern = {}
	settings.selection_material_pattern = {}
	settings.selection_offsets = []


func _selection_button() -> Button:
	return options.get_node(selection_path) as Button


func _emit_cells_changed() -> void:
	var affected: Array[Vector3i] = []
	State.cells_changed.emit(State.current_frame, affected)


func _emit_chunks_changed() -> void:
	var affected: Array[Vector3i] = []
	State.chunks_changed.emit(State.current_frame, affected)


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


func _await_source() -> void:
	for i in 600:
		if options == null or options._source_job == null:
			break
		await get_tree().process_frame
	await get_tree().process_frame
