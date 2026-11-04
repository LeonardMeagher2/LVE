extends "res://tests/test.gd"

const EYEDROPPER := preload("res://plugins/Eyedropper/EyedropperTool.tscn")
const CELL := Vector3i(2, 0, 0)
const WRITER_CELL := Vector3i(5, 0, 0)
const REENTER_CELL := Vector3i(6, 0, 0)

var sampled := VoxelFrame.material(Color.RED, Color(0.5, 0.25, 0.125), 1.0, 0.25)
var before := VoxelFrame.material(Color.BLUE, Color(0.125, 0.5, 0.25), 0.25, 0.75)
var frame: VoxelFrame
var tool: VoxelTool
var writer: VoxelTool
var reenter_writer: VoxelTool
var changed_cells: Array[Vector3i] = []
var cells_emits := 0
var chunks_emits := 0


# A local writer that changes one cell and reports the change. It does not
# override the base pick, so the test covers the base notification.
class WriterTool extends VoxelTool:
	func apply(target: Vector3i, _hit: Vector3i) -> bool:
		var edited_frame := State.get_current_voxel_frame()
		if edited_frame == null or target == VoxelPicking.NONE:
			return false
		edited_frame.set_cell(target, VoxelFrame.material(Color.GREEN))
		return true


func _ready() -> void:
	timeout = 30.0
	test("the eyedropper changes state but publishes no cell change", _eyedropper_is_state_only, "eyedropper_state_only")
	test("the base pick publishes the cells of a writer that returns true", _writer_publishes_cells, "writer_publishes_cells")
	test("a reentrant material callback keeps an unrelated writer notification", _reentrant_callback_keeps_writer, "reentrant_callback_keeps_writer")


func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.symmetry_axes = 0
	frame = State.get_current_voxel_frame()
	State.undo_redo.clear_history()
	changed_cells.clear()
	cells_emits = 0
	chunks_emits = 0
	State.cells_changed.connect(_on_cells_changed)
	State.chunks_changed.connect(_on_chunks_changed)


func _cleanup_test() -> void:
	if State.cells_changed.is_connected(_on_cells_changed):
		State.cells_changed.disconnect(_on_cells_changed)
	if State.chunks_changed.is_connected(_on_chunks_changed):
		State.chunks_changed.disconnect(_on_chunks_changed)
	if State.material_changed.is_connected(_on_sample_material_changed):
		State.material_changed.disconnect(_on_sample_material_changed)
	for node in [tool, writer, reenter_writer]:
		if is_instance_valid(node):
			node.free()
	tool = null
	writer = null
	reenter_writer = null


func _eyedropper_is_state_only() -> void:
	step("Given a metal voxel and a different current material", func():
		frame.set_cell(CELL, sampled)
		State.set_palette([before, sampled])
		State.select_palette_entry(0)
		State.undo_redo.clear_history()
		tool = EYEDROPPER.instantiate() as VoxelTool
		add_child(tool)
		State.is_playing = true
	)
	step("When the eyedropper samples the voxel", func():
		_clear_notifications()
		expect(tool.open_stroke() != null, "the eyedropper opens its own edit")
		tool._apply_pick(CELL, CELL)
		tool.close_stroke()
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then it copies the material and publishes no cell change", func():
		expect(State.current_material == sampled, "the eyedropper copies the full material")
		expect(State.current_palette_index == 1, "the sampled material selects its palette entry")
		expect(frame.count() == 1 and _same_material(CELL, sampled), "the sampled voxel keeps its material")
		expect(cells_emits == 0, "the eyedropper emits no cells_changed")
		expect(chunks_emits == 0, "the eyedropper emits no chunks_changed")
		expect(State.is_playing, "sampling does not stop playback")
		expect(State.undo_redo.get_history_count() == 1, "the eyedropper records only the Set Material action")
		expect(State.active_edit() == null, "the empty eyedropper edit closes")
	)
	step("Then one undo restores the previous material", func():
		State.undo_redo.undo()
		expect(State.current_material == before, "undo restores the material before the sample")
		expect(State.current_palette_index == 0, "undo restores the palette selection")
		expect(frame.count() == 1 and _same_material(CELL, sampled), "undo keeps the sampled voxel")
	)


func _writer_publishes_cells() -> void:
	step("Given a tool that writes one cell and reports true", func():
		writer = WriterTool.new()
		add_child(writer)
	)
	step("When the base pick applies it", func():
		_clear_notifications()
		writer._apply_pick(WRITER_CELL, WRITER_CELL)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the base pick publishes the changed cell", func():
		expect(_same_material(WRITER_CELL, VoxelFrame.material(Color.GREEN)), "the writer changes its cell")
		expect(cells_emits == 1, "the base pick emits cells_changed once")
		expect(changed_cells.size() == 1 and changed_cells[0] == WRITER_CELL, "the notification holds the writer cell")
		expect(chunks_emits == 0, "the base pick emits no chunks_changed")
	)


func _reentrant_callback_keeps_writer() -> void:
	step("Given a writer that applies during the eyedropper material signal", func():
		frame.set_cell(CELL, sampled)
		State.set_material(before)
		State.undo_redo.clear_history()
		tool = EYEDROPPER.instantiate() as VoxelTool
		add_child(tool)
		reenter_writer = WriterTool.new()
		add_child(reenter_writer)
		State.material_changed.connect(_on_sample_material_changed, CONNECT_ONE_SHOT)
	)
	step("When the eyedropper samples while the callback writes", func():
		_clear_notifications()
		tool._apply_pick(CELL, CELL)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then only the writer cell is published", func():
		expect(State.current_material == sampled, "the eyedropper copies the sampled material")
		expect(frame.count() == 2 and _same_material(CELL, sampled), "the sampled voxel keeps its material")
		expect(_same_material(REENTER_CELL, VoxelFrame.material(Color.GREEN)), "the reentrant writer changes its own cell")
		expect(cells_emits == 1, "one writer notification is published")
		expect(changed_cells.size() == 1 and changed_cells[0] == REENTER_CELL, "the notification holds only the writer cell")
		expect(chunks_emits == 0, "the eyedropper adds no chunks_changed")
	)


func _clear_notifications() -> void:
	cells_emits = 0
	chunks_emits = 0
	changed_cells.clear()


func _on_sample_material_changed() -> void:
	if is_instance_valid(reenter_writer):
		reenter_writer._apply_pick(REENTER_CELL, REENTER_CELL)


func _on_cells_changed(_frame: int, affected: Array[Vector3i]) -> void:
	cells_emits += 1
	changed_cells.append_array(affected)


func _on_chunks_changed(_frame: int, _affected: Array[Vector3i]) -> void:
	chunks_emits += 1


func _same_material(cell: Vector3i, expected: PackedFloat32Array) -> bool:
	if not frame.has(cell):
		return false
	var actual := VoxelFrame.material(frame.get_color(cell), frame.get_emission(cell), frame.get_metallic(cell), frame.get_roughness(cell))
	return actual == expected
