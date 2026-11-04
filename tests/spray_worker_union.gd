extends "res://tests/test.gd"

# Focused checks for the spray sampler at the maximum sizes and the exact sphere
# union. Both build a large fixture and a wide union, so they are split from
# `spray_worker_geometry` to keep one scene inside the shared runner deadline
# while the window is open.
#
#   godot --path . res://tests/spray_worker_union.tscn

const SEED := 20261023
const BLOCK := 8

const VoxelBrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")

var _settings := preload("res://plugins/paint/settings.tres")

var viewport: SubViewport
var center := Vector2.ZERO
var tool: Node3D
var frame: VoxelFrame
var preview: Array[Vector3i] = []
var _block_cells := 0
var _spots: Array[Vector3i] = []
var _local: Array[Vector3i] = []
var _union := {}


func _ready() -> void:
	timeout = 60.0
	test("the maximum spot, search, and speed are not clamped", _worker_max_sizes, "worker_max")
	test("the widest even spot unions exactly at a negative center", _worker_exact_union, "worker_union")


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
	_block_cells = frame.count()
	# A new document drops the preview surface of the previous fixture.
	tool._clear_cursor_preview()


func _painted_count() -> int:
	var count := 0
	for cell in frame.positions():
		if frame.get_color(cell) != Color.BLUE:
			count += 1
	return count


func _same_cell_set(first: Array[Vector3i], second: Array[Vector3i]) -> bool:
	if first.size() != second.size():
		return false
	var lookup := {}
	for cell in second:
		lookup[cell] = true
	for cell in first:
		if not lookup.has(cell):
			return false
	return true


func _press(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = pos
	viewport.push_input(event)


func _release(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	event.position = pos
	viewport.push_input(event)


func _hover(pos: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	viewport.push_input(event)


# Waits until the samples, the write jobs, and the cursor settle. A worker sample
# installs from `_process`, so the check must let the frames run.
func _settle() -> void:
	for i in 600:
		if tool.is_sample_settled() and tool._job == null and tool._pending_centers.is_empty():
			await get_tree().process_frame
			return
		await get_tree().process_frame


func _worker_max_sizes() -> void:
	step("Given a dense block and the maximum spot, search, and speed", func():
		_block(BLOCK)
		_settings.spot_diameter = 64
		_settings.spray_size = 64
		_settings.speed = 64
		tool.clear_shape_caches()
		tool._invalidate_batch()
		expect(_settings.spot_diameter == 64, "the spot size is not clamped")
		expect(_settings.spray_size == 64, "the search size is not clamped")
		expect(_settings.speed == 64, "the speed count is not clamped")
	)
	step("When the pointer hovers one voxel", func():
		_hover(center)
		expect(tool._hover_sample_job != null, "the maximum batch samples on the worker")
	)
	await _settle()
	step("Then the maximum batch installs and every cell exists", func():
		preview = tool.preview_cells()
		expect(preview.size() > 1, "the maximum batch installed a wider set than one spot")
		var reach := VoxelBrushSize.reach(64) + VoxelBrushSize.reach(64)
		# One exact predicate over the whole batch, with a count diagnostic. A
		# thousand repeated checks would print a thousand lines and prove nothing
		# more than the aggregate does.
		var outside := 0
		for cell in preview:
			if not frame.has(cell) or Vector3(cell - tool._batch_center).length_squared() > float(reach * reach):
				outside += 1
		expect(outside == 0, "every installed cell is an existing voxel inside the union ball (%d of %d outside)" % [outside, preview.size()])
	)
	step("When the user presses", func():
		_press(center)
	)
	await _settle()
	step("Then the press paints exactly the installed maximum batch", func():
		expect(_painted_count() == preview.size(), "the press paints exactly the installed maximum batch")
		expect(frame.count() == _block_cells, "the spray adds no voxel")
		_release(center)
	)


func _worker_exact_union() -> void:
	step("Given a dense block and four spot centers below zero", func():
		_block(BLOCK)
		_spots = [Vector3i(-6, 0, -6), Vector3i(-6, 4, 2), Vector3i(2, -4, -6), Vector3i(-1, -1, -1)]
		_local = []
		for cell in frame.positions():
			_local.append(cell)
		tool._batch_material = VoxelFrame.material(Color.WHITE)
	)
	for size in [32, 64]:
		step("When the footprint unions the four spheres of the even size %d" % size, func():
			_union = tool._footprints(_spots, _local, size)
		)
		step("Then the union holds exactly the sphere cells of that size", func():
			var expected := {}
			for spot in _spots:
				for offset in VoxelBrushSize.sphere_offsets(size):
					var cell := spot + offset
					if frame.has(cell):
						expected[cell] = true
			var got: Array[Vector3i] = []
			got.assign(_union.keys())
			var want: Array[Vector3i] = []
			want.assign(expected.keys())
			expect(got.size() == want.size(), "the union of size %d holds every sphere cell" % size)
			expect(_same_cell_set(got, want), "the union of size %d matches the exact sphere union" % size)
		)
