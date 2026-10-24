extends "res://tests/test.gd"

# Focused checks for the spray sampler symmetry mirror and the read-only
# occupancy view.
#
# These checks build a small dense fixture and expand many material patterns, so
# they are split from the worker pipeline scene `spray_worker`. Each scene then
# stays under the shared runner deadline while the window is open.
#
#   godot --headless --path . res://tests/spray_worker_geometry.tscn

const SEED := 20261023
const BLOCK := 8
const SMALL_BLOCK := 6

const SpraySampler := preload("res://plugins/paint/SpraySampler.gd")

var _settings := preload("res://plugins/paint/settings.tres")

var viewport: SubViewport
var center := Vector2.ZERO
var tool: Node3D
var frame: VoxelFrame
var cells: Array[Vector3i] = []
var _spots: Array[Vector3i] = []
var _local: Array[Vector3i] = []
var _changes := {}


func _ready() -> void:
	timeout = 60.0
	test("an even spot under symmetry keeps every mirrored cell", _worker_mirror, "worker_mirror")
	test("the sampler occupancy view matches the edit context expansion exactly", _worker_expand_view, "worker_expand")


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
	frame = State.get_current_voxel_frame()
	viewport = editor_viewport()
	viewport.get_parent().stretch = false
	viewport.size = Vector2i(800, 500)
	center = Vector2(400.0, 250.0)
	camera_rig().is_orthogonal = true
	camera_rig().set_view("top")
	select_toolbar_item("paint", "Spray Can")
	tool = plugin("PaintPlugin")._spray_tool
	tool.seed_spray(SEED)
	await get_tree().process_frame
	tool.clear_shape_caches()
	tool._invalidate_batch()
	tool._hover_installed_epoch = 0


# A solid block around the origin, so the search sphere and the spot sphere are
# fully occupied and the reach estimate passes the inline limit.
func _block(half: int) -> void:
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	for x in range(-half, half + 1):
		for y in range(-half, half + 1):
			for z in range(-half, half + 1):
				frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.BLUE))
	camera_rig().center_on(frame.get_bounds())
	# A new document drops the preview surface of the previous fixture.
	tool._clear_cursor_preview()


# One expansion case. It compares the sampler occupancy view with the edit
# context expansion by cell count, by key order, and by material, so the read
# view is exact and not only a matching set.
func _expand_pair(label: String, changes: Dictionary, axes: int, origin_twice: Vector3i, selection: Dictionary) -> void:
	var context := VoxelFrame.EditContext.new()
	context.axes = axes
	context.origin_twice = origin_twice
	context.selection = selection
	var reference := context.expand(changes, frame, true, null)
	var occupancy := SpraySampler.Occupancy.new()
	occupancy.frame = frame
	var view := SpraySampler.expand_occupied(changes, occupancy, axes, origin_twice, selection)
	var same := reference.size() == view.size()
	if same:
		var expected_keys := reference.keys()
		var actual_keys := view.keys()
		for index in expected_keys.size():
			var cell: Vector3i = expected_keys[index]
			if actual_keys[index] != cell or view[actual_keys[index]] != reference[cell]:
				same = false
				break
	expect(same, "the occupancy view matches EditContext.expand exactly for %s (%d cells)" % [label, reference.size()])


# The read view must reproduce the edit context expansion for the identity, the
# symmetry, the selection filter, negative chunks, missing chunks, and the whole
# even pattern.
func _worker_expand_view() -> void:
	step("Given a dense block with a distinct material per cell", func():
		_block(SMALL_BLOCK)
		_changes = {}
		var index := 0
		for cell in frame.positions():
			_changes[cell] = VoxelFrame.material(Color(0.1 + 0.01 * float(index % 40), 0.4, 0.7))
			index += 1
		expect(_changes.size() > 0, "the dense batch holds cells")
	)
	step("When the read view expands it under the identity and the symmetry", func():
		_expand_pair("identity", _changes, 0, Vector3i.ZERO, {})
		_expand_pair("x mirror", _changes, 1, Vector3i.ZERO, {})
		_expand_pair("xy half-cell mirror", _changes, 3, Vector3i(1, 1, 1), {})
		_expand_pair("all axes with a selection point", _changes, 7, Vector3i.ZERO, {Vector3i.ZERO: true, Vector3i(1, 0, 0): true})
	)
	step("Given a block below the origin in negative chunks", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_changes = {}
		for x in range(-20, -7):
			for y in range(-2, 3):
				for z in range(-20, -7):
					var cell := Vector3i(x, y, z)
					frame.set_cell(cell, VoxelFrame.material(Color.BLUE))
					_changes[cell] = VoxelFrame.material(Color(0.2, 0.6, 0.9))
		expect(_changes.size() > 0, "the negative batch holds cells")
	)
	step("When the read view mirrors it about the block center", func():
		_expand_pair("negative chunks x mirror", _changes, 1, Vector3i(-28, 0, -28), {})
		_expand_pair("negative chunks all axes", _changes, 7, Vector3i(-28, 0, -28), {})
	)
	step("Given a sparse region of three separate chunks", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_changes = {}
		for cell in [Vector3i(2, 0, 2), Vector3i(-3, 1, 0), Vector3i(0, 0, -40)]:
			frame.set_cell(cell, VoxelFrame.material(Color.BLUE))
			_changes[cell] = VoxelFrame.material(Color(0.7, 0.3, 0.2))
		expect(frame.chunks.size() == 3, "the sparse region holds three chunks")
	)
	step("When the read view mirrors the sparse cells through empty chunks", func():
		_expand_pair("sparse missing chunks", _changes, 1, Vector3i.ZERO, {})
		_expand_pair("sparse all axes", _changes, 7, Vector3i.ZERO, {})
		_expand_pair("sparse selection point", _changes, 1, Vector3i.ZERO, {Vector3i(-3, 1, 0): true})
	)
	step("Given the even spot pattern of a negative center", func():
		_block(BLOCK)
		_settings.spot_diameter = 32
		_settings.spray_size = 33
		_settings.speed = 4
		tool._batch_material = VoxelFrame.material(Color.WHITE)
		_local = []
		for cell in frame.positions():
			_local.append(cell)
		_spots = [Vector3i(-6, 0, -6), Vector3i(-6, 4, 2), Vector3i(2, -4, -6), Vector3i(-1, -1, -1)]
	)
	step("When the read view expands the whole even pattern", func():
		var pattern: Dictionary = tool._footprints(_spots, _local, 32)
		expect(pattern.size() > 0, "the even pattern holds cells")
		_expand_pair("even pattern x mirror", pattern, 1, Vector3i.ZERO, {})
		_expand_pair("even pattern all axes", pattern, 7, Vector3i(1, 1, 1), {})
	)


func _worker_mirror() -> void:
	step("Given a symmetric dense block and an X symmetry", func():
		_block(SMALL_BLOCK)
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3.ZERO
		_settings.spot_diameter = 4
		_settings.spray_size = 17
		_settings.speed = 16
		tool._batch_material = VoxelFrame.material(Color.WHITE)
	)
	step("When the sampler samples the centered cell", func():
		cells = tool._sample(Vector3i.ZERO, frame, State.drawing_context())
	)
	step("Then every sampled cell keeps its whole-cell mirror", func():
		expect(cells.size() > 0, "the symmetry sample holds cells")
		var lookup := {}
		for cell in cells:
			lookup[cell] = true
		for cell in cells:
			expect(lookup.has(Vector3i(-cell.x, cell.y, cell.z)), "every sampled cell keeps its mirrored destination")
	)
	step("When the symmetry origin sits on a half cell", func():
		State.symmetry_origin = Vector3(0.5, 0.5, 0.5)
		cells = tool._sample(Vector3i.ZERO, frame, State.drawing_context())
	)
	step("Then every cell whose half-cell mirror exists is mirrored too", func():
		expect(cells.size() > 0, "the half-cell symmetry sample holds cells")
		var lookup := {}
		for cell in cells:
			lookup[cell] = true
		for cell in cells:
			var mirror := Vector3i(1 - cell.x, cell.y, cell.z)
			if frame.has(mirror):
				expect(lookup.has(mirror), "every mirrored destination inside the frame joins the batch")
	)
