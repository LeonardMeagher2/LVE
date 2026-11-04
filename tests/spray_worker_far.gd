extends "res://tests/test.gd"

# Focused checks for the dense spray footprint union at far world coordinates.
#
# The union groups its spans by world row and sorts them with the native compare.
# A world coordinate must never be packed into a fixed-width field, so every
# translation below must stay exact. This scene is split from `spray_worker`,
# because the many large unions and the two full presses exceed the shared runner
# deadline when the window is open.
#
#   godot --path . res://tests/spray_worker_far.tscn

const SEED := 20261023
const BLOCK := 8

const VoxelBrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")

var _settings := preload("res://plugins/paint/settings.tres")

var viewport: SubViewport
var center := Vector2.ZERO
var tool: Node3D
var frame: VoxelFrame
var _spots: Array[Vector3i] = []
var _local: Array[Vector3i] = []
var _union := {}
var _far_center := Vector3i.ZERO
var _batch: Array[Vector3i] = []


func _ready() -> void:
	timeout = 60.0
	test("the dense footprint union is exact at every world coordinate", _worker_dense_far, "worker_far")


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


func _screen_pos_of(cell: Vector3i) -> Vector2:
	return camera_rig().unproject_position(Vector3(cell))


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


# Waits until the samples, the write jobs, and the cursor settle. A worker sample
# installs from `_process`, so the check must let the frames run.
func _settle() -> void:
	for i in 600:
		if tool.is_sample_settled() and tool._job == null and tool._pending_centers.is_empty():
			await get_tree().process_frame
			return
		await get_tree().process_frame


# The dense footprint union groups its spans by world row and sorts them with the
# native compare. A world coordinate must never be packed into a fixed-width
# field, so every translation below must stay exact. The existing tests cover
# centers near the origin only, which hides a window bug.
func _worker_dense_far() -> void:
	var half := 8
	var base: Array[Vector3i] = []
	for x in range(-half, half + 1):
		for y in range(-half, half + 1):
			for z in range(-half, half + 1):
				base.append(Vector3i(x, y, z))
	var spot_offsets: Array[Vector3i] = [Vector3i(-2, 0, -2), Vector3i(2, 2, -1), Vector3i(-1, -2, 3)]
	var translations: Array[Vector3i] = [
		Vector3i.ZERO, Vector3i(255, 0, -257), Vector3i(256, 256, 256), Vector3i(-256, -256, -256),
		Vector3i(10000, 0, 0), Vector3i(0, -10000, 0), Vector3i(0, 0, 10000),
		Vector3i(10000, -10000, 10000), Vector3i(-10000, 10000, -10000),
	]
	step("Given a 17-cube local voxel block and three spot centers", func():
		expect(base.size() == 4913, "the local block holds its cells")
	)
	for size in [2, 32, 64]:
		for offset in translations:
			step("When the dense footprint unions size %d translated by %s" % [size, str(offset)], func():
				var spots: Array[Vector3i] = []
				for spot in spot_offsets:
					spots.append(spot + offset)
				var local: Array[Vector3i] = []
				var pool := {}
				for cell in base:
					var far_cell := cell + offset
					local.append(far_cell)
					pool[far_cell] = true
				_union = tool._footprints(spots, local, size)
				var expected := {}
				for spot in spots:
					for sphere in VoxelBrushSize.sphere_offsets(size):
						var cell := spot + sphere
						if pool.has(cell):
							expected[cell] = true
				var got: Array[Vector3i] = []
				got.assign(_union.keys())
				var want: Array[Vector3i] = []
				want.assign(expected.keys())
				expect(got.size() == want.size() and _same_cell_set(got, want), "the dense union of size %d at %s holds the exact sphere union (%d of %d cells)" % [size, str(offset), got.size(), want.size()])
			)
	step("Given a solid block far from the origin", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_far_center = Vector3i(10000, -10000, 10000)
		for x in range(-half, half + 1):
			for y in range(-half, half + 1):
				for z in range(-half, half + 1):
					frame.set_cell(_far_center + Vector3i(x, y, z), VoxelFrame.material(Color.BLUE))
		camera_rig().center_on(frame.get_bounds())
		tool._clear_cursor_preview()
		_settings.spot_diameter = 64
		_settings.spray_size = 1
		_settings.speed = 1
		expect(frame.count() == 4913, "the far block holds every cell")
	)
	step("When the live tool samples one spot at the far cell", func():
		var rng := RandomNumberGenerator.new()
		rng.seed = SEED
		_batch = tool._sample(_far_center, frame, State.drawing_context(), rng, VoxelFrame.material(Color.WHITE))
		var pool := {}
		for cell in frame.positions():
			pool[cell] = true
		var expected := {}
		for sphere in VoxelBrushSize.sphere_offsets(64):
			var cell := _far_center + sphere
			if pool.has(cell):
				expected[cell] = true
		var want: Array[Vector3i] = []
		want.assign(expected.keys())
		expect(_batch.size() == want.size() and _same_cell_set(_batch, want), "the live far sample holds the exact spot union (%d of %d cells)" % [_batch.size(), want.size()])
		expect(_batch.size() == 4913, "the live far sample paints the whole far block")
	)
	# The application path: a real press through the viewport, with the camera
	# centered on the far model. Before the coordinate fix this painted nothing,
	# because the dense span union wrapped every world coordinate outside
	# -64..191 into another row.
	step("Given a dense block far from the origin, centered in the live viewport", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_far_center = Vector3i(10000, -10000, 10000)
		for x in range(-half, half + 1):
			for y in range(-half, half + 1):
				for z in range(-half, half + 1):
					frame.set_cell(_far_center + Vector3i(x, y, z), VoxelFrame.material(Color.BLUE))
		camera_rig().center_on(frame.get_bounds())
		tool._clear_cursor_preview()
		tool._invalidate_batch()
		_settings.spot_diameter = 64
		_settings.spray_size = 1
		_settings.speed = 1
		expect(frame.count() == 4913, "the far block holds every cell")
	)
	step("When the user presses the far voxel through the viewport", func():
		_press(_screen_pos_of(_far_center))
		expect(tool._edit != null, "the press opens a stroke at the far cell")
	)
	await _settle()
	step("Then the paint lands on the far block and not near the origin", func():
		var painted: Array[Vector3i] = []
		var stray := 0
		for cell in frame.positions():
			if frame.get_color(cell) == Color.BLUE:
				continue
			painted.append(cell)
			if absi(cell.x - _far_center.x) > 9 or absi(cell.y - _far_center.y) > 9 or absi(cell.z - _far_center.z) > 9:
				stray += 1
		expect(painted.size() == 4913, "the far press paints the whole far block (%d cells)" % painted.size())
		expect(stray == 0, "every painted cell sits in the far block and none near the origin")
		expect(_same_cell_set(painted, frame.positions()), "the paint covers exactly the far block")
		expect(VoxelFrame.chunk_position(_far_center) == Vector3i(625, -625, 625), "the far block sits in its own chunk coordinate")
		_release(_screen_pos_of(_far_center))
		expect(State.undo_redo.get_history_count() >= 1, "the far click records its action")
	)
