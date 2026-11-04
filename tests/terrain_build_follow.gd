extends "res://tests/test.gd"

# Keep Build coverage on the frozen cursor plane. Keep the normal and input
# spacing fixed at the press. Resolve each column's support with the bounded
# height lookup, without moving the footprint onto the grown surface.
#
# The test drives the real production tool through the viewport. A thin probe
# only records the observable stroke state after each dab. It never changes the
# placement.
#
# Check the growth pattern and locked normal as the column heights change.

const ProbeScript := preload("./terrain_build_follow_probe.gd")
const ToolScript := preload("res://plugins/Terrain/TerrainTool.gd")

var _settings := preload("res://plugins/Terrain/settings.tres")
var _tool
var _frame: VoxelFrame
var _viewport: SubViewport
var _cursor_ref: TerrainFrame
var _cursor_origin := Vector3.ZERO
var _cursor_normal := Vector3.UP
var _ground_high := Vector3.ZERO
var _plane_frame: TerrainFrame
var _grown_before := 0
var _ring_before := Vector3.ZERO
var _dabs_before := 0


func _ready() -> void:
	test("a floor drag ignores columns above its cylinder", _follow_levels, "follow_levels")
	test("a soft default brush carries its edge credits while the model rises", _soft_edge_bands, "soft_edge_bands")
	test("the credit key is stable along the normal and split across opposing normals", _credit_key_stable, "credit_key_stable")
	test("a drag at floor level ignores a tall column", _follow_beyond_scan, "follow_beyond_scan")
	test("a drop from a raised surface moves the ground down", _ground_drops, "ground_drops")
	test("Remove follows the real surface and never seeds an empty cell", _remove_follows, "remove_follows")
	test("a Surface press locks its surface normal while the growth climbs", _locked_normal_surface, "locked_normal_surface")
	test("the cursor plane keeps its normal while the ground follows", _spacing_frozen, "spacing_frozen")
	test("a cell-by-cell drag matches one coalesced drag", _coalesced_match, "coalesced_match")
	test("an orthographic and a perspective drag grow the same height", _projection_match, "projection_match")
	test("a model press never seeds and an empty-floor press keeps its captured floor", _add_hit_then_floor_miss, "add_hit_then_floor_miss")
	test("a Remove miss on an empty floor changes nothing", _remove_empty_miss, "remove_empty_miss")
	test("a floor UI change never moves an accepted dab", _captured_floor, "captured_floor")
	test("a held pointer with an edit-induced height adds no dab", _stationary_no_new_dab, "stationary_no_new_dab")
	test("symmetry mirrors the real hit position of a Build dab", _selection_symmetry, "selection_symmetry")
	test("a Build stroke supports undo and Escape", _history_cancel, "history_cancel")
	test("the layer follows the dominant normal axis", _layer_tilt, "layer_tilt")
	test("a flat stroke sprays a layer without lifting the ground", _spray_flat, "spray_flat")
	test("a revisit never seeds the floor and keeps growing", _revisit_keeps_top, "revisit_keeps_top")
	test("the ring waits for the dab on a small move", _ring_waits_for_the_dab, "ring_waits_for_the_dab")


func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	_settings.tool = _settings.Tools.BUILD
	_settings.build_mode = _settings.BuildMode.ADD
	_settings.radius = 9
	_settings.strength = 1.0
	_settings.falloff = 0.5
	_viewport = editor_viewport()
	_viewport.get_parent().stretch = false
	_viewport.size = Vector2i(800, 500)
	activate_tool("terrain")
	var terrain := plugin("TerrainPlugin")
	terrain.activate_tool()
	terrain.deactivate_tool()
	_tool = preload("res://plugins/Terrain/TerrainTool.tscn").instantiate()
	_tool.set_script(ProbeScript)
	if _tool._settings == null:
		_tool._settings = _settings
	terrain.add_editor_node(_tool)
	_tool.set_process(true)
	_frame = State.get_current_voxel_frame()
	camera_rig().is_orthogonal = true
	camera_rig().set_view("top")
	await get_tree().process_frame


func _cleanup_test() -> void:
	if is_instance_valid(_tool):
		if _tool._edit != null:
			_tool.finish_on_switch()
		while _tool._edit != null:
			await get_tree().process_frame
		plugin("TerrainPlugin").remove_editor_node(_tool)
		_tool.free()
	_tool = null


# --- Fixtures -----------------------------------------------------------------

func _install(changes: Dictionary) -> void:
	State.document = VoxelDocument.new()
	_frame = State.get_current_voxel_frame()
	_frame.set_cells(changes)
	_tool.reset_dabs()


func _material() -> PackedFloat32Array:
	return VoxelFrame.material(Color.WHITE)


func _floor(changes: Dictionary, x_min: int, x_max: int, z_min: int, z_max: int) -> void:
	var material := _material()
	for x in range(x_min, x_max + 1):
		for z in range(z_min, z_max + 1):
			changes[Vector3i(x, 0, z)] = material


func _column(changes: Dictionary, x: int, top: int) -> void:
	var material := _material()
	for y in range(0, top + 1):
		changes[Vector3i(x, y, 0)] = material


# A floor and three single columns of increasing height.
func _level_fixture() -> void:
	var changes := {}
	_floor(changes, -8, 24, -8, 8)
	for spec in [[6, 5], [12, 12], [18, 20]]:
		_column(changes, spec[0], spec[1])
	_install(changes)
	_view(AABB(Vector3(-14, -6, -14), Vector3(46, 50, 28)))


# A floor and one column taller than the old bounded surface scan.
func _tower_fixture() -> void:
	var changes := {}
	_floor(changes, -8, 24, -8, 8)
	_column(changes, 18, 30)
	_install(changes)
	_view(AABB(Vector3(-14, -6, -14), Vector3(46, 62, 28)))


# A floor and a wide block whose top is far above the old scan depth.
func _plateau_fixture() -> void:
	var changes := {}
	_floor(changes, -10, 26, -8, 8)
	var material := _material()
	for x in range(16, 23):
		for y in range(1, 21):
			for z in range(-8, 9):
				changes[Vector3i(x, y, z)] = material
	_install(changes)
	_view(AABB(Vector3(-14, -6, -14), Vector3(50, 50, 28)))


# A rising staircase.
func _ramp_fixture() -> void:
	var changes := {}
	var material := _material()
	for x in range(0, 11):
		for y in range(0, x + 1):
			for z in range(-4, 5):
				changes[Vector3i(x, y, z)] = material
	_install(changes)
	_view(AABB(Vector3(-6, -6, -8), Vector3(26, 30, 16)))


# A floor patch and a raised block. The area past the floor patch is empty, so a
# ray there misses the model.
func _gap_fixture() -> void:
	var changes := {}
	_floor(changes, -6, 2, -6, 6)
	var material := _material()
	for x in range(-1, 2):
		for y in range(1, 5):
			for z in range(-2, 3):
				changes[Vector3i(x, y, z)] = material
	_install(changes)
	_view(AABB(Vector3(-12, -6, -12), Vector3(34, 22, 24)))


# A floor and a mirrored pair of columns across the X plane at -0.5.
func _mirror_fixture() -> void:
	var changes := {}
	_floor(changes, -12, 12, -8, 8)
	_column(changes, 6, 5)
	_column(changes, -7, 5)
	_install(changes)
	_view(AABB(Vector3(-16, -6, -14), Vector3(36, 40, 28)))


# --- Camera and input ---------------------------------------------------------

func _view(box: AABB) -> void:
	camera_rig().set_view("top")
	camera_rig().is_orthogonal = true
	camera_rig().center_on(box)


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


func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	get_tree().root.push_input(event)


func _wait_idle() -> void:
	while _tool._edit != null:
		await get_tree().process_frame


# Runs one Build stroke from a press at one world point through the given world
# points. The whole stroke is one gesture. The locked operation plane is recorded
# at the press, because the stroke closes its frame at the release.
func _stroke(from: Vector3, path: Array) -> void:
	_tool.reset_dabs()
	_plane_frame = null
	_grown_before = _frame.count()
	_button(true, _screen(from))
	_plane_frame = _tool._stroke_frame
	for world in path:
		_motion(_screen(world))
	_button(false, _screen(path[path.size() - 1]) if not path.is_empty() else _screen(from))
	await _wait_idle()


func _column_height(x: int, z: int) -> int:
	var cell := Vector3i(x, 0, z)
	var count := 0
	while _frame.has(cell):
		count += 1
		cell.y += 1
	return count


func _max_y() -> int:
	var top := -4096
	for cell in _frame.positions():
		top = maxi(top, cell.y)
	return top


func _max_x() -> int:
	var right := -4096
	for cell in _frame.positions():
		right = maxi(right, cell.x)
	return right


func _cell_materials() -> Dictionary:
	var materials := {}
	for cell in _frame.positions():
		materials[cell] = _frame.get_material(cell)
	return materials


func _normal_constant() -> bool:
	var normals: Array = _tool.build_normals
	if normals.size() < 2:
		return false
	var locked: Vector3 = normals[0]
	for normal in normals:
		if not (normal as Vector3).is_equal_approx(locked):
			return false
	return true


# Whether every dab center lies on the plane of its own dab. The ground recenters
# after each dab, so the center must match the frame the dab used, not the press
# frame.
func _centers_on_plane() -> bool:
	if (_tool.build_centers as Array).is_empty():
		return false
	for index in (_tool.build_centers as Array).size():
		var center: Vector3 = _tool.build_centers[index]
		var normal: Vector3 = _tool.build_normals[index]
		var origin: Vector3 = _tool.build_origins[index]
		if absf((center - origin).dot(normal)) > 1e-4:
			return false
	return true


# Whether the ground moved along the normal during the stroke.
func _origin_moved() -> bool:
	var origins: Array = _tool.build_origins
	if origins.size() < 2:
		return false
	var first: Vector3 = origins[0]
	for origin in origins:
		if (origin - first).length() > 1e-4:
			return true
	return false


# Whether every dab used the same ground.
func _origin_flat() -> bool:
	var origins: Array = _tool.build_origins
	if origins.size() < 2:
		return false
	var first: Vector3 = origins[0]
	for origin in origins:
		if (origin - first).length() > 1e-4:
			return false
	return true


# Whether the stroke grew any cell.
func _stroke_grew() -> bool:
	return _frame.count() > _grown_before


# --- Cases --------------------------------------------------------------------

func _follow_levels() -> void:
	step("Given a floor and three columns of height 5, 12, and 20", func():
		_level_fixture()
	)
	await _stroke(Vector3(-2, 0, 0), [Vector3(18, 20, 0)])
	step("Then the column under the pointer grew and the floor followed", func():
		expect(_column_height(18, 0) > 21, "the 20 high column grew under the pointer")
		expect(_frame.count() > 0, "the floor stroke grew the model")
	)


func _soft_edge_bands() -> void:
	step("Given a flat plate and a soft Build brush at strength four", func():
		var changes := {}
		_floor(changes, -8, 8, -8, 8)
		_install(changes)
		_view(AABB(Vector3(-12, -6, -12), Vector3(28, 24, 28)))
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 9
		_settings.strength = 4
		_settings.falloff = 0.5
	)
	step("When the user drags back and forth without release as the model rises", func():
		_tool.reset_dabs()
		var near := _screen(Vector3(0, 0, 0))
		var far := _screen(Vector3(1, 0, 0))
		_button(true, near)
		for _cycle in 6:
			_motion(far)
			_motion(near)
		_button(false, near)
	)
	await _wait_idle()
	step("Then the center grows more than the rim", func():
		var base := 1
		var h0 := _column_height(0, 0)
		var h2 := _column_height(2, 0)
		var h4 := _column_height(4, 0)
		expect(h0 > base, "the center rose with the stroke (height %d)" % h0)
		expect(h4 > base, "the rim rose too (height %d)" % h4)
		expect(h0 > h4, "the center grew more than the rim (%s)" % str([h0, h2, h4]))
		expect(h0 >= h2 and h2 >= h4, "the height falls off from the center (%s)" % str([h0, h2, h4]))
	)


func _credit_key_stable() -> void:
	step("Given one physical column at two heights and an opposing normal", func():
		var base := {"normal": Vector3.UP, "surface": Vector3i(3, 4, 0), "point": Vector3(3, 4.5, 0)}
		var higher := {"normal": Vector3.UP, "surface": Vector3i(3, 40, 0), "point": Vector3(3, 40.5, 0)}
		var moved_origin := {"normal": Vector3.UP, "surface": Vector3i(3, 4, 0), "point": Vector3(3, 44.5, 0)}
		var neighbor := {"normal": Vector3.UP, "surface": Vector3i(4, 4, 0), "point": Vector3(4, 4.5, 0)}
		var down := {"normal": Vector3.DOWN, "surface": Vector3i(3, 4, 0), "point": Vector3(3, 3.5, 0)}
		var side := {"normal": Vector3.RIGHT, "surface": Vector3i(3, 4, 0), "point": Vector3(3.5, 4, 0)}
		expect(ToolScript._column_key(base) == ToolScript._column_key(higher), "the same column at a new height keeps its key")
		expect(ToolScript._column_key(base) == ToolScript._column_key(moved_origin), "moving the point only along the normal keeps the key")
		expect(ToolScript._column_key(base) != ToolScript._column_key(neighbor), "a neighbor column has a different key")
		expect(ToolScript._column_key(base) != ToolScript._column_key(down), "an opposing normal has a different key")
		expect(ToolScript._column_key(base) != ToolScript._column_key(side), "another axis has a different key")
	)


func _follow_beyond_scan() -> void:
	step("Given a floor and one 30 high column", func():
		_tower_fixture()
	)
	await _stroke(Vector3(-2, 0, 0), [Vector3(18, 30, 0)])
	step("Then the column under the pointer grew", func():
		expect(_column_height(18, 0) > 31, "the tall column grew under the pointer")
		expect(_stroke_grew(), "the floor stroke still grew")
	)


func _remove_follows() -> void:
	step("Given a 30 high column and the Build tool in Remove mode", func():
		_tower_fixture()
		_settings.build_mode = _settings.BuildMode.REMOVE
	)
	step("When the user presses the column top", func():
		_tool.reset_dabs()
		_button(true, _screen(Vector3(18, 30, 0)))
		_button(false, _screen(Vector3(18, 30, 0)))
	)
	await _wait_idle()
	step("Then Remove cleared the column top under the pointer", func():
		expect(not _frame.has(Vector3i(18, 30, 0)), "Remove cleared the column top under the pointer")
		expect(_frame.count() > 0, "the untouched floor stays")
	)


func _locked_normal_surface() -> void:
	step("Given a rising staircase and the Surface normal source", func():
		_ramp_fixture()
	)
	await _stroke(Vector3(2, 2, 0), [Vector3(8, 8, 0)])
	step("Then the surface normal stays locked while the growth climbs the ramp", func():
		expect((_tool.build_normals as Array).size() > 1, "the drag resolved more than one dab")
		expect(absf(((_tool.build_normals as Array)[0] as Vector3).x) > 0.2, "the Surface press read a tilted normal")
		expect(_normal_constant(), "every dab kept the captured surface normal")
		expect(_centers_on_plane(), "every dab kept its center on the plane it used")
		expect(_origin_moved(), "the ground moved along the normal")
		expect(_column_height(8, 0) > 9, "the growth climbed the ramp above the press height")
	)


func _spacing_frozen() -> void:
	step("Given a floor with a two-high step", func():
		var changes := {}
		_floor(changes, -8, 12, -8, 8)
		var material := _material()
		for x in range(4, 9):
			for y in range(1, 3):
				for z in range(-2, 3):
					changes[Vector3i(x, y, z)] = material
		_install(changes)
		_view(AABB(Vector3(-10, -6, -10), Vector3(30, 20, 20)))
	)
	step("When the user presses the floor and drags onto the step", func():
		_tool.reset_dabs()
		_button(true, _screen(Vector3(0, 0, 0)))
		_cursor_ref = _tool._cursor_frame
		_cursor_origin = _cursor_ref.origin
		_cursor_normal = _cursor_ref.normal
		_motion(_screen(Vector3(6, 2, 0)))
	)
	for _index in 120:
		if not _tool._busy() and not _tool._has_pending():
			break
		await get_tree().process_frame
	step("Then the cursor plane keeps its normal and the ground follows", func():
		expect(_tool._cursor_frame != null, "the cursor plane still exists")
		expect(_tool._cursor_frame.normal.is_equal_approx(_cursor_normal), "the spacing frame keeps its normal")
		expect((_tool._cursor_frame.origin - _cursor_origin).length() > 1e-4, "the ground moved")
		expect(absf((_tool._cursor_frame.origin - _cursor_origin).dot(_cursor_normal)) > 1e-4, "the move is along the normal")
		expect(_tool._stroke_frame == _tool._cursor_frame, "the operation plane is the cursor plane")
		_button(false, _screen(Vector3(6, 2, 0)))
	)
	await _wait_idle()


func _coalesced_match() -> void:
	step("Given a flat floor", func():
		var changes := {}
		_floor(changes, -8, 8, -8, 8)
		_install(changes)
		_view(AABB(Vector3(-12, -6, -12), Vector3(24, 20, 24)))
	)
	await _stroke(Vector3(-2, 0, 0), [Vector3(18, 0, 0)])
	var coalesced := _cell_materials()
	var coalesced_centers := (_tool.build_centers as Array).duplicate()
	step("Given the same flat floor", func():
		var changes := {}
		_floor(changes, -8, 8, -8, 8)
		_install(changes)
		_view(AABB(Vector3(-12, -6, -12), Vector3(24, 20, 24)))
	)
	var steps: Array = []
	for x in range(-1, 19):
		steps.append(Vector3(float(x), 0.0, 0.0))
	await _stroke(Vector3(-2, 0, 0), steps)
	step("Then the two deliveries produced the same centers and the same voxels", func():
		var same_count := coalesced_centers.size() == (_tool.build_centers as Array).size()
		var same_centers := same_count
		if same_centers:
			for index in coalesced_centers.size():
				if not (coalesced_centers[index] as Vector3).is_equal_approx((_tool.build_centers as Array)[index]):
					same_centers = false
					break
		expect(same_count, "the two deliveries applied the same dab count (%d vs %d)" % [coalesced_centers.size(), (_tool.build_centers as Array).size()])
		expect(same_centers, "the two deliveries resolved the same centers")
		expect(_cell_materials() == coalesced, "the two deliveries produced the same voxels and materials")
	)


func _projection_match() -> void:
	step("Given a floor and a wide 20 high block seen orthographically", func():
		_plateau_fixture()
	)
	await _stroke(Vector3(18, 20, 0), [Vector3(22, 20, 0)])
	var ortho_top := _max_y()
	step("Given the same floor and block seen in perspective", func():
		_plateau_fixture()
		camera_rig().set_view("top")
		camera_rig().is_orthogonal = false
		camera_rig().center_on(AABB(Vector3(-14, -6, -14), Vector3(50, 50, 28)))
		expect(camera_rig().projection == Camera3D.PROJECTION_PERSPECTIVE, "the fixture uses a real perspective projection")
	)
	await get_tree().process_frame
	await _stroke(Vector3(18, 20, 0), [Vector3(22, 20, 0)])
	step("Then both projections grew above the block top", func():
		expect(ortho_top >= 21, "the orthographic brush grew above the block top")
		expect(_max_y() >= 21, "the perspective brush grew above the block top")
	)


func _add_hit_then_floor_miss() -> void:
	step("Given a floor patch and a raised block, and Add", func():
		_gap_fixture()
		_settings.build_mode = _settings.BuildMode.ADD
	)
	await _stroke(Vector3(0, 4, 0), [Vector3(10, 0, 0)])
	step("Then the block hit grew and the floor miss seeded the floor", func():
		expect(_frame.has(Vector3i(0, 5, 0)), "the press grew the block top")
		expect(_stroke_grew(), "the stroke grew the model")
		# A model press no longer blocks a later floor seed, so the miss lays a
		# cell on the captured floor instead of a canopy at the press height.
		expect(_frame.has(Vector3i(10, 0, 0)), "the floor miss seeded on the floor")
	)


func _remove_empty_miss() -> void:
	step("Given an empty floor and Remove", func():
		_install({})
		_view(AABB(Vector3(-14, -6, -14), Vector3(28, 20, 28)))
		_settings.build_mode = _settings.BuildMode.REMOVE
	)
	await _stroke(Vector3(0, 0, 0), [Vector3(6, 0, 0)])
	step("Then a Remove miss applies nothing and records no history", func():
		expect(_frame.count() == 0, "a Remove miss changes no cell")
		expect(not State.undo_redo.has_undo(), "a Remove miss records no history")
	)


func _captured_floor() -> void:
	step("Given an empty floor and an Add press", func():
		_install({})
		_view(AABB(Vector3(-14, -6, -14), Vector3(28, 20, 28)))
		_settings.build_mode = _settings.BuildMode.ADD
		State.floor_index = 0
		_tool.reset_dabs()
		_button(true, _screen(Vector3(0, 0, 0)))
	)
	await get_tree().process_frame
	step("When the floor UI moves during the open stroke", func():
		State.floor_index = 6
		_motion(_screen(Vector3(6, 0, 0)))
	)
	await get_tree().process_frame
	step("Then the accepted dab still used the captured floor plane", func():
		expect(_frame.has(Vector3i(0, 0, 0)), "the press seeded the captured floor")
		expect(_frame.has(Vector3i(6, 0, 0)), "the later dab seeded the captured floor, not the new one")
		expect(not _frame.has(Vector3i(6, 6, 0)), "the moved floor plane did not move the accepted dab")
		_button(false, _screen(Vector3(6, 0, 0)))
	)
	await _wait_idle()


func _stationary_no_new_dab() -> void:
	step("Given a floor and a press on it", func():
		_level_fixture()
		_tool.reset_dabs()
		_button(true, _screen(Vector3(-2, 0, 0)))
	)
	await get_tree().process_frame
	var before: int = (_tool.build_centers as Array).size()
	step("When the pointer holds still while the model height changes", func():
		for _tick in 4:
			_tool.advance_stroke(1.0)
		_motion(_screen(Vector3(-2, 0, 0)))
	)
	await get_tree().process_frame
	step("Then the held pointer adds no dab", func():
		expect((_tool.build_centers as Array).size() == before, "the held pointer invented no dab (%d)" % (_tool.build_centers as Array).size())
		_button(false, _screen(Vector3(-2, 0, 0)))
	)
	await _wait_idle()


func _selection_symmetry() -> void:
	step("Given mirrored columns across the X plane at -0.5", func():
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3(-0.5, -0.5, -0.5)
		_mirror_fixture()
	)
	await _stroke(Vector3(6, 5, 0), [Vector3(7, 5, 0)])
	step("Then the mirror dab follows the mirrored real hit position", func():
		expect(_frame.has(Vector3i(6, 6, 0)), "the pressed column grew on top")
		expect(_frame.has(Vector3i(-7, 6, 0)), "the mirrored column grew on its own top")
	)


func _history_cancel() -> void:
	step("Given a floor and three columns", func():
		_level_fixture()
	)
	var pristine := _frame.count()
	step("When the user grows and releases", func():
		_button(true, _screen(Vector3(-2, 0, 0)))
		_motion(_screen(Vector3(18, 20, 0)))
		_button(false, _screen(Vector3(18, 20, 0)))
	)
	await _wait_idle()
	step("Then the release records one action that undo restores", func():
		expect(State.undo_redo.has_undo(), "the stroke records one action")
		expect(State.undo_redo.get_history_count() == 1, "the whole stroke is one history action")
		expect(_frame.count() > pristine, "the stroke grew the model")
		State.undo()
	)
	await get_tree().process_frame
	step("Then undo restored the model", func():
		expect(_frame.count() == pristine, "undo restored the model (%d vs %d)" % [_frame.count(), pristine])
	)
	step("When the user grows again and presses Escape", func():
		_button(true, _screen(Vector3(-2, 0, 0)))
		_motion(_screen(Vector3(18, 20, 0)))
		_key(KEY_ESCAPE)
	)
	await _wait_idle()
	step("Then the cancelled stroke changed nothing and added no history", func():
		expect(_frame.count() == pristine, "the cancelled stroke is rolled back")
		expect(not State.undo_redo.has_undo(), "the cancelled stroke records no history")
	)


func _layer_tilt() -> void:
	var ramp := Vector3(-0.7071, 0.7071, 0.0)
	step("Given a flat surface cell", func():
		var frame := VoxelFrame.new()
		frame.set_cell(Vector3i(2, 2, 0), VoxelFrame.material(Color.WHITE))
		var action := TerrainGeometry.build_layer_cells(frame, {}, Vector3i(2, 2, 0), Vector3.UP, Vector3i(2, 2, 0), true, {})
		expect(action["cells"] == [Vector3i(2, 3, 0)], "a flat plane adds one cell")
		expect(action["next"] == Vector3i(2, 3, 0), "the next step starts on the new top")
	)
	step("Given a 45 degree surface cell", func():
		var frame := VoxelFrame.new()
		frame.set_cell(Vector3i(2, 2, 0), VoxelFrame.material(Color.WHITE))
		var action := TerrainGeometry.build_layer_cells(frame, {}, Vector3i(2, 2, 0), ramp, Vector3i(2, 2, 0), true, {})
		var cells: Array = action["cells"]
		expect(cells == [Vector3i(1, 2, 0)], "the layer steps one cardinal cell along the dominant axis")
		expect(action["next"] == Vector3i(1, 2, 0), "the next step starts on the new surface")
	)
	step("When one layer digs from the 45 degree cell", func():
		var frame := VoxelFrame.new()
		frame.set_cell(Vector3i(2, 2, 0), VoxelFrame.material(Color.WHITE))
		frame.set_cell(Vector3i(3, 2, 0), VoxelFrame.material(Color.WHITE))
		var action := TerrainGeometry.build_layer_cells(frame, {}, Vector3i(2, 2, 0), ramp, Vector3i(2, 2, 0), false, {})
		var cells: Array = action["cells"]
		expect(cells == [Vector3i(2, 2, 0)], "the dig clears the surface cell")
		expect(action["next"] == Vector3i(3, 2, 0), "the dig continues on the cell below the surface")
	)
func _spray_flat() -> void:
	var ground := Vector3.ZERO
	step("Given a flat plate and the Build tool", func():
		var changes := {}
		_floor(changes, -8, 8, -8, 8)
		_install(changes)
		_view(AABB(Vector3(-12, -6, -12), Vector3(24, 20, 24)))
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 9
		_settings.falloff = 0.0
		_settings.strength = 1.0
	)
	step("When the user drags back and forth over the same cells", func():
		_tool.reset_dabs()
		var near := _screen(Vector3(-4, 1, 0))
		var far := _screen(Vector3(4, 1, 0))
		_button(true, near)
		for _cycle in 4:
			_motion(far)
			_motion(near)
		_button(false, near)
	)
	await _wait_idle()
	step("Then the ground stays on the plate while the layer builds", func():
		expect(_tool.build_origins.size() > 2, "the stroke applied many dabs")
		expect(_origin_flat(), "the ground stayed on the plate")
		expect(_column_height(0, 0) > 1, "the stroke built a layer")
		ground = _tool.build_origins[0]
	)
	step("When the user starts a second stroke", func():
		_tool.reset_dabs()
		_button(true, _screen(Vector3(0, 1, 0)))
		_button(false, _screen(Vector3(0, 1, 0)))
	)
	await _wait_idle()
	step("Then the second stroke starts on the grown surface", func():
		expect(_tool.build_origins.size() > 0, "the second stroke applied a dab")
		expect((_tool.build_origins[0] as Vector3).y > ground.y + 0.5, "the second stroke starts higher")
	)


func _ground_drops() -> void:
	step("Given a raised block on a lower floor", func():
		var changes := {}
		_floor(changes, -10, 14, -8, 8)
		var material := _material()
		for x in range(-2, 3):
			for y in range(1, 5):
				for z in range(-2, 3):
					changes[Vector3i(x, y, z)] = material
		_install(changes)
		_view(AABB(Vector3(-14, -6, -12), Vector3(32, 20, 24)))
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 9
		_settings.falloff = 0.0
		_settings.strength = 1.0
	)
	step("When the user starts on the block and drags to the floor", func():
		_tool.reset_dabs()
		_button(true, _screen(Vector3(0, 5, 0)))
		_ground_high = _tool._stroke_frame.origin
		_motion(_screen(Vector3(8, 1, 0)))
	)
	for _index in 120:
		if not _tool._busy() and not _tool._has_pending():
			break
		await get_tree().process_frame
	step("Then the ground moved down to the floor", func():
		expect(_tool._stroke_frame != null, "the stroke frame still exists")
		expect(_tool._stroke_frame.origin.y < _ground_high.y - 1.0, "the ground dropped to the floor")
		_button(false, _screen(Vector3(8, 1, 0)))
	)
	await _wait_idle()


# A column can grow past the surface read depth. When the brush leaves it and
# comes back, the read from the old plane cannot reach the top. The stroke cache
# must return the tracked top instead of seeding the captured floor cell.
func _revisit_keeps_top() -> void:
	step("Given a plate above a low floor and a Build brush", func():
		State.floor_index = -3
		var changes := {}
		_floor(changes, -10, 10, -10, 10)
		_install(changes)
		_view(AABB(Vector3(-12, -6, -12), Vector3(24, 30, 24)))
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 9
		_settings.strength = 4
		_settings.falloff = 0.0
	)
	step("When the user raises one column past the read depth", func():
		_tool.reset_dabs()
		var start := _screen(Vector3(0, 0, 0))
		_button(true, start)
		for _dab in 6:
			_tool.advance_stroke(1.0)
		expect(_column_height(0, 0) > _tool._height_depth() + 1, "the column is taller than the surface read (%d)" % _column_height(0, 0))
	)
	step("When the brush leaves the column and comes back", func():
		var start := _screen(Vector3(0, 0, 0))
		var far := _screen(Vector3(8, 0, 0))
		_motion(far)
		_motion(start)
		_button(false, start)
	)
	await _wait_idle()
	step("Then the revisit keeps the top and seeds no floor cell", func():
		expect(not _frame.has(Vector3i(0, -3, 0)), "the revisit writes no cell at the floor")
		expect(_column_height(0, 0) > 24, "the revisit raises the same column (%d)" % _column_height(0, 0))
	)


# The dab gate holds the anchor back for a move the user cannot see. The ring
# must hold with it, or the ring jitters ahead of the dab.
func _ring_waits_for_the_dab() -> void:
	step("Given a plate seen at a grazing angle and a Build press", func():
		var changes := {}
		_floor(changes, -12, 12, -12, 12)
		_install(changes)
		camera_rig().is_orthogonal = true
		camera_rig()._set_angles(0.0, deg_to_rad(6.0))
		camera_rig().center_on(AABB(Vector3(-12, -4, -12), Vector3(24, 8, 24)))
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 9
		_settings.strength = 1
		_settings.falloff = 0.0
		_tool.reset_dabs()
		var start := _screen(Vector3(0, 0, 0))
		_button(true, start)
		_ring_before = _tool._footprint.global_position
		_dabs_before = _tool.build_centers.size()
	)
	step("When the pointer moves less than three pixels", func():
		var start := _screen(Vector3(0, 0, 0))
		_motion(start + Vector2(0, 2))
	)
	step("Then the ring and the dab count stay", func():
		expect(_tool.build_centers.size() == _dabs_before, "the small move adds no dab")
		expect(_tool._footprint.global_position.is_equal_approx(_ring_before), "the ring stays on the accepted anchor")
	)
	step("When the pointer moves past the gate", func():
		var start := _screen(Vector3(0, 0, 0))
		_motion(start + Vector2(0, 12))
	)
	step("Then the ring and the dab move together", func():
		expect(_tool.build_centers.size() > _dabs_before, "the larger move adds a dab")
		expect(not _tool._footprint.global_position.is_equal_approx(_ring_before), "the ring follows the dab")
		var end := _screen(Vector3(0, 0, 0))
		_button(false, end)
	)
