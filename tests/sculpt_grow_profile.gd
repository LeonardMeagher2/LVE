extends "res://tests/test.gd"

# The original Grow profile.
#
# A long stroke keeps one fixed operation plane, so the footprint kernel is
# constant along the stroke. Every column at a fixed lateral offset from the path
# receives the same credited influence, and the heights form coherent nested
# bands. A footprint that re-projects onto the grown height under perspective
# walks sideways as the model rises, so the columns receive different dab counts
# and the bands turn into waves.
#
# The test predicts every column height from the recorded canonical dab list and
# the shipped kernel. The reference is the explicit fixed-plane accumulation: one
# disc of weights per dab, summed per logical column. A reset credit, a dropped
# dab, or a moved plane fails the prediction.
#
# The stroke runs in isometric perspective, which is the view where a
# re-projected center walks sideways. The floor is flat, so the fitted normal is
# exactly up and the reference needs no surface scan.

const ProbeScript := preload("./sculpt_grow_profile_probe.gd")
const SculptGeometryScript := preload("res://plugins/Sculpt/SculptGeometry.gd")

var _settings := preload("res://plugins/Sculpt/settings.tres")
var _tool
var _frame: VoxelFrame
var _viewport: SubViewport
var _plane_frame: SculptFrame
var _plane_drift := false


func _ready() -> void:
	test("a long perspective stroke keeps one credited kernel", _straight_profile, "straight_profile")
	test("a column above the old scan bound resolves with the same kernel", _beyond_bound, "beyond_bound")
	test("an empty-floor press builds the original footprint mound", _floor_mound, "floor_mound")


func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	_settings.tool = _settings.Tools.GROW
	_settings.grow_mode = _settings.GrowMode.ADD
	_settings.normal_source = _settings.NormalSource.SURFACE
	_settings.radius = 4
	_settings.strength = 1.0
	_settings.falloff = 0.5
	_viewport = editor_viewport()
	_viewport.get_parent().stretch = false
	_viewport.size = Vector2i(900, 600)
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
	await get_tree().process_frame


func _cleanup_test() -> void:
	if is_instance_valid(_tool):
		if _tool._edit != null:
			_tool.finish_on_switch()
		while _tool._edit != null:
			await get_tree().process_frame
		plugin("SculptPlugin").remove_editor_node(_tool)
		_tool.free()
	_tool = null


# --- Fixtures and input -------------------------------------------------------

# A flat floor wide enough for the stroke and the footprint disc.
func _floor() -> void:
	State.document = VoxelDocument.new()
	_frame = State.get_current_voxel_frame()
	var changes := {}
	var material := VoxelFrame.material(Color.WHITE)
	for x in range(-20, 48):
		for z in range(-20, 20):
			changes[Vector3i(x, 0, z)] = material
	_frame.set_cells(changes)
	sync_viewport()


# A flat floor with one 30 high column that the old bounded walk could not
# resolve from the plane.
func _floor_and_tower() -> void:
	State.document = VoxelDocument.new()
	_frame = State.get_current_voxel_frame()
	var changes := {}
	var material := VoxelFrame.material(Color.WHITE)
	for x in range(-20, 48):
		for z in range(-20, 20):
			changes[Vector3i(x, 0, z)] = material
	for y in range(1, 31):
		changes[Vector3i(20, y, 0)] = material
	_frame.set_cells(changes)
	sync_viewport()


func _view_perspective() -> void:
	camera_rig().set_view("isometric")
	camera_rig().is_orthogonal = false
	camera_rig().center_on(AABB(Vector3(-24, -10, -24), Vector3(80, 48, 48)))


func _screen(world: Vector3) -> Vector2:
	return camera_rig().unproject_position(world)


func _button(pressed: bool, position: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.pressed = pressed
	event.position = position
	_viewport.push_input(event)


func _motion(position: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	event.position = position
	_viewport.push_input(event)


func _wait_idle() -> void:
	while _tool._edit != null:
		await get_tree().process_frame


# Runs one straight Grow stroke along +X from the world origin. It records the
# locked operation plane and whether the plane moved during the stroke, because
# the stroke closes its frame at the release.
func _run_straight_stroke(steps: int) -> void:
	_tool.reset_profile()
	_plane_drift = false
	_plane_frame = null
	_button(true, _screen(Vector3.ZERO))
	_plane_frame = _tool._stroke_frame
	for index in range(1, steps + 1):
		_motion(_screen(Vector3(float(index), 0.0, 0.0)))
		if _tool._stroke_frame != _plane_frame:
			_plane_drift = true
	_button(false, _screen(Vector3(float(steps), 0.0, 0.0)))
	await _wait_idle()


# The explicit fixed-plane accumulation. One dab contributes one disc of weights,
# keyed by the world column under each disc cell. The weight depends only on the
# distance from the dab anchor, so the tangent orientation of the frame cannot
# change it.
func _reference_credit(anchors: Array, falloff: float) -> Dictionary:
	var radius: int = _settings.radius
	var credit := {}
	for anchor: Vector3i in anchors:
		for u in range(-radius, radius + 1):
			for v in range(-radius, radius + 1):
				var distance_squared := u * u + v * v
				if distance_squared > radius * radius:
					continue
				var weight := SculptGeometryScript.weight_at(sqrt(float(distance_squared)), float(radius), falloff)
				if weight <= 0.0:
					continue
				var column := Vector2i(anchor.x + u, anchor.z + v)
				credit[column] = float(credit.get(column, 0.0)) + _settings.strength * weight
	return credit


# The whole steps the credited influence applies on top of the support height.
func _credited_steps(credit: Dictionary, column: Vector2i) -> int:
	return int(floor(float(credit.get(column, 0.0)) + 1e-6))


# The height of one column, counted up from the floor plane.
func _column_height(x: int, z: int) -> int:
	var cell := Vector3i(x, 0, z)
	var count := 0
	while _frame.has(cell):
		count += 1
		cell.y += 1
	return count


# The mismatched columns between the actual heights and the prediction.
func _prediction_mismatches(credit: Dictionary, base: int) -> int:
	var mismatched := 0
	for column in credit:
		if _column_height(column.x, column.y) != base + _credited_steps(credit, column):
			mismatched += 1
	return mismatched


# --- Cases --------------------------------------------------------------------

func _straight_profile() -> void:
	step("Given a flat floor seen in isometric perspective and the default brush", func():
		_floor()
		_view_perspective()
		expect(camera_rig().projection == Camera3D.PROJECTION_PERSPECTIVE, "the fixture uses a real perspective projection")
	)
	await _run_straight_stroke(20)
	var anchors: Array = _tool.dab_anchors.duplicate()
	var credit: Dictionary = _reference_credit(anchors, 0.5)
	var xs: Array = []
	for anchor: Vector3i in anchors:
		xs.append(anchor.x)
	var x_min: int = int(xs.min()) + 4
	var x_max: int = int(xs.max()) - 4
	var mid: int = (int(xs.min()) + int(xs.max())) / 2
	var waves := 0
	for z in range(-4, 5):
		var height := _column_height(x_min, z)
		for x in range(x_min, x_max + 1):
			if _column_height(x, z) != height:
				waves += 1
	var center := _column_height(mid, 0)
	var edge := _column_height(mid, 3)
	var mismatched := _prediction_mismatches(credit, 1)
	step("Then the press locked one fixed plane with an up normal", func():
		expect(anchors.size() > 10, "the stroke applied many dabs (%d)" % anchors.size())
		expect(_plane_frame != null and _plane_frame.normal.is_equal_approx(Vector3.UP), "the operation plane normal is up")
		expect(not _plane_drift, "the operation plane frame never moved during the stroke")
	)
	step("Then every column matches the fixed-kernel prediction", func():
		expect(mismatched == 0, "every column keeps its credited steps (%d mismatched)" % mismatched)
	)
	step("Then each lateral row away from the ends stays coherent", func():
		expect(waves == 0, "no lateral row shows a repeated trough (%d mismatches)" % waves)
		expect(center > edge, "the path center is taller than the soft edge (%d > %d)" % [center, edge])
		expect(edge > 1, "the soft edge carried a fractional credit above the floor")
	)


func _beyond_bound() -> void:
	step("Given a flat floor with a 30 high column beyond the old scan bound", func():
		_floor_and_tower()
		_view_perspective()
	)
	await _run_straight_stroke(24)
	var credit: Dictionary = _reference_credit(_tool.dab_anchors, 0.5)
	var tower_column := Vector2i(20, 0)
	var neighbor := Vector2i(19, 0)
	var predicted_tower := 31 + _credited_steps(credit, tower_column)
	var actual_tower := _column_height(tower_column.x, tower_column.y)
	var predicted_neighbor := 1 + _credited_steps(credit, neighbor)
	var actual_neighbor := _column_height(neighbor.x, neighbor.y)
	step("Then the column resolved its own support without moving the plane", func():
		expect(_plane_frame != null and _plane_frame.normal.is_equal_approx(Vector3.UP), "the operation plane normal is up")
		expect(not _plane_drift, "the operation plane frame never moved during the stroke")
		expect(actual_tower == predicted_tower, "the tall column grew by its credited steps (%d vs %d)" % [actual_tower, predicted_tower])
		expect(actual_tower > 31, "the column grew past the old scan depth (height %d)" % actual_tower)
	)
	step("Then a low neighbor column kept the same kernel and its own support", func():
		expect(actual_neighbor == predicted_neighbor, "the low neighbor kept its credited steps (%d vs %d)" % [actual_neighbor, predicted_neighbor])
		expect(actual_neighbor < actual_tower, "the low neighbor stayed far below the tall column")
	)


func _floor_mound() -> void:
	step("Given an empty floor, a hard edge, and one Add press", func():
		State.document = VoxelDocument.new()
		_frame = State.get_current_voxel_frame()
		_settings.falloff = 0.0
		_view_perspective()
		_tool.reset_profile()
		_button(true, _screen(Vector3.ZERO))
		_button(false, _screen(Vector3.ZERO))
	)
	await _wait_idle()
	var credit: Dictionary = _reference_credit(_tool.dab_anchors, 0.0)
	var seeded := 0
	var wrong := 0
	for column in credit:
		if _credited_steps(credit, column) < 1:
			continue
		seeded += 1
		if _column_height(column.x, column.y) != 1:
			wrong += 1
	step("Then the press seeded the whole footprint disc as one layer", func():
		expect(_tool.dab_anchors.size() == 1, "the still press applied exactly one dab")
		expect(seeded == 49, "the hard-edge disc holds forty-nine columns (%d)" % seeded)
		expect(wrong == 0, "every seeded column holds exactly one layer (%d wrong)" % wrong)
		expect(_frame.count() == seeded, "the mound holds only the seeded columns (%d vs %d)" % [_frame.count(), seeded])
	)
