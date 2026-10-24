extends "res://tests/test.gd"

# Keep Grow coverage on the frozen cursor plane. Keep the normal and input
# spacing fixed at the press. Resolve each column's support with the bounded
# height lookup, without moving the footprint onto the grown surface.
#
# The test drives the real production tool through the viewport. A thin probe
# only records the observable stroke state after each dab. It never changes the
# placement.
#
# Check the growth pattern and locked normal as the column heights change.

const ProbeScript := preload("./sculpt_grow_follow_probe.gd")
const ToolScript := preload("res://plugins/Sculpt/SculptTool.gd")

var _settings := preload("res://plugins/Sculpt/settings.tres")
var _tool
var _frame: VoxelFrame
var _viewport: SubViewport
var _cursor_ref: SculptFrame
var _cursor_origin := Vector3.ZERO
var _plane_frame: SculptFrame
var _grown_before := 0


func _ready() -> void:
	test("a floor drag grows on every column level beyond the old scan depth", _follow_levels, "follow_levels")
	test("a soft default brush carries its edge credits while the model rises", _soft_edge_bands, "soft_edge_bands")
	test("the credit key is stable along the normal and split across opposing normals", _credit_key_stable, "credit_key_stable")
	test("a drag onto a tower beyond the old scan depth grows and is not stalled", _follow_beyond_scan, "follow_beyond_scan")
	test("Remove follows the real surface and never seeds an empty cell", _remove_follows, "remove_follows")
	test("a Surface press locks its fitted normal while the growth climbs", _locked_normal_surface, "locked_normal_surface")
	test("a Face press locks its exact face normal while the growth climbs", _locked_normal_face, "locked_normal_face")
	test("the operation plane stays on the frozen cursor plane for the stroke", _spacing_frozen, "spacing_frozen")
	test("a cell-by-cell drag matches one coalesced drag", _coalesced_match, "coalesced_match")
	test("an orthographic and a perspective drag grow the same height", _projection_match, "projection_match")
	test("a model press never seeds and an empty-floor press keeps its captured floor", _add_hit_then_floor_miss, "add_hit_then_floor_miss")
	test("a Remove miss on an empty floor changes nothing", _remove_empty_miss, "remove_empty_miss")
	test("a floor UI change never moves an accepted dab", _captured_floor, "captured_floor")
	test("a held pointer with an edit-induced height adds no dab", _stationary_no_new_dab, "stationary_no_new_dab")
	test("symmetry mirrors the real hit position of a Grow dab", _selection_symmetry, "selection_symmetry")
	test("a Grow stroke supports undo and Escape", _history_cancel, "history_cancel")


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
		while _tool._edit != null:
			await get_tree().process_frame
		plugin("SculptPlugin").remove_editor_node(_tool)
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


# Runs one Grow stroke from a press at one world point through the given world
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
	var normals: Array = _tool.grow_normals
	if normals.size() < 2:
		return false
	var locked: Vector3 = normals[0]
	for normal in normals:
		if not (normal as Vector3).is_equal_approx(locked):
			return false
	return true


# Whether every dab center lies on the operation plane locked at the press. The
# footprint center is the canonical anchor projected onto that plane, so a dab
# that re-projects the center onto a grown height fails it.
func _centers_on_plane() -> bool:
	if _plane_frame == null or (_tool.grow_centers as Array).is_empty():
		return false
	for center in _tool.grow_centers:
		if absf(((center as Vector3) - _plane_frame.origin).dot(_plane_frame.normal)) > 1e-4:
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
	step("Then the brush grew on top of every column under the pointer", func():
		expect(_column_height(6, 0) >= 6, "the brush grew on top of the 5 high column")
		expect(_column_height(12, 0) >= 13, "the brush grew on top of the 12 high column")
		expect(_column_height(18, 0) >= 21, "the brush grew on top of the 20 high column beyond the old scan depth")
		expect(_max_y() >= 21, "a cell sits above the tallest column")
	)


func _soft_edge_bands() -> void:
	step("Given a flat plate and the default soft Grow brush", func():
		var changes := {}
		_floor(changes, -8, 8, -8, 8)
		_install(changes)
		_view(AABB(Vector3(-12, -6, -12), Vector3(28, 24, 28)))
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.normal_source = _settings.NormalSource.SURFACE
		_settings.radius = 4
		_settings.strength = 1.0
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
	step("Then the soft edge carried credits and formed nested bands", func():
		var base := 1
		var h0 := _column_height(0, 0)
		var h1 := _column_height(1, 0)
		var h2 := _column_height(2, 0)
		var h3 := _column_height(3, 0)
		var h4 := _column_height(4, 0)
		expect(h0 > base + 3, "the center rose with the stroke (height %d)" % h0)
		expect(h3 > base, "the soft edge carried its credits above the base (height %d)" % h3)
		expect(h0 >= h1 and h1 > h2 and h2 > h3 and h3 > h4, "the heights form a strict nested gradient (%s)" % str([h0, h1, h2, h3, h4]))
		expect(h0 > h3, "the center is not a needle at the edge height")
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
	step("When the user drags onto the tower", func():
		_tool.reset_dabs()
		_button(true, _screen(Vector3(-2, 0, 0)))
		_motion(_screen(Vector3(18, 30, 0)))
	)
	await get_tree().process_frame
	var first := _column_height(18, 0)
	step("Then the first visit grew above the column top", func():
		expect(first >= 32, "the tower grew past the old scan depth (height %d)" % first)
		expect(_frame.has(Vector3i(18, 31, 0)), "the growth sits above the column top")
	)
	step("When the user leaves the tower and returns without releasing", func():
		_motion(_screen(Vector3(8, 0, 0)))
		_motion(_screen(Vector3(18, 30, 0)))
	)
	await get_tree().process_frame
	step("Then the revisit grew the tower further instead of stalling", func():
		expect(_column_height(18, 0) > first, "the revisited tower grew further (%d > %d)" % [_column_height(18, 0), first])
		_button(false, _screen(Vector3(18, 30, 0)))
	)
	await _wait_idle()


func _remove_follows() -> void:
	step("Given a 30 high column and the Grow tool in Remove mode", func():
		_tower_fixture()
		_settings.grow_mode = _settings.GrowMode.REMOVE
	)
	await _stroke(Vector3(-2, 0, 0), [Vector3(18, 30, 0)])
	step("Then Remove followed the real surface and never seeded", func():
		expect(not _frame.has(Vector3i(18, 30, 0)), "Remove cleared the column top under the pointer")
		expect(_frame.count() > 0, "the untouched floor stays")
		var seeded := false
		for flag in _tool.grow_seeded:
			seeded = seeded or bool(flag)
		expect(not seeded, "a Remove dab never seeds an empty floor")
	)


func _locked_normal_surface() -> void:
	step("Given a rising staircase and the Surface normal source", func():
		_ramp_fixture()
		_settings.normal_source = _settings.NormalSource.SURFACE
	)
	await _stroke(Vector3(2, 2, 0), [Vector3(8, 8, 0)])
	step("Then the fitted normal stays locked while the growth climbs the ramp", func():
		expect((_tool.grow_normals as Array).size() > 1, "the drag resolved more than one dab")
		expect(absf(((_tool.grow_normals as Array)[0] as Vector3).x) > 0.2, "the Surface press fitted a tilted normal")
		expect(_normal_constant(), "every dab kept the captured fitted normal")
		expect(_centers_on_plane(), "every dab kept its center on the frozen plane")
		expect(_column_height(8, 0) > 9, "the growth climbed the ramp above the press height")
	)


func _locked_normal_face() -> void:
	step("Given a rising staircase and the Face normal source", func():
		_ramp_fixture()
		_settings.normal_source = _settings.NormalSource.FACE
	)
	await _stroke(Vector3(2, 2, 0), [Vector3(8, 8, 0)])
	step("Then the exact press face normal stays locked while the growth climbs", func():
		expect((_tool.grow_normals as Array).size() > 1, "the drag resolved more than one dab")
		expect(((_tool.grow_normals as Array)[0] as Vector3).is_equal_approx(Vector3.UP), "the Face press locked the top face normal")
		expect(_normal_constant(), "every dab kept the captured face normal")
		expect(_centers_on_plane(), "every dab kept its center on the frozen plane")
		expect(_column_height(8, 0) > 9, "the growth climbed the ramp above the press height")
	)


func _spacing_frozen() -> void:
	step("Given a floor and three columns", func():
		_level_fixture()
	)
	step("When the user presses and drags", func():
		_tool.reset_dabs()
		_button(true, _screen(Vector3(-2, 0, 0)))
		_cursor_ref = _tool._cursor_frame
		_cursor_origin = _cursor_ref.origin
		_motion(_screen(Vector3(18, 20, 0)))
	)
	await get_tree().process_frame
	step("Then the operation plane stays the frozen cursor plane", func():
		expect(_tool._cursor_frame == _cursor_ref, "the spacing frame stays the same object")
		expect(_tool._cursor_frame.origin == _cursor_origin, "the spacing frame origin is frozen")
		expect(_tool._stroke_frame == _tool._cursor_frame, "the operation plane is the frozen cursor plane")
		_button(false, _screen(Vector3(18, 20, 0)))
	)
	await _wait_idle()


func _coalesced_match() -> void:
	step("Given a floor and three columns", func():
		_level_fixture()
	)
	await _stroke(Vector3(-2, 0, 0), [Vector3(18, 20, 0)])
	var coalesced := _cell_materials()
	var coalesced_centers := (_tool.grow_centers as Array).duplicate()
	step("Given the same floor and columns", func():
		_level_fixture()
	)
	var steps: Array = []
	for x in range(-1, 19):
		steps.append(Vector3(float(x), 0.0, 0.0))
	await _stroke(Vector3(-2, 0, 0), steps)
	step("Then the two deliveries produced the same centers and the same voxels", func():
		expect(coalesced_centers.size() == (_tool.grow_centers as Array).size(), "the two deliveries applied the same dab count (%d vs %d)" % [coalesced_centers.size(), (_tool.grow_centers as Array).size()])
		expect(coalesced_centers == (_tool.grow_centers as Array), "the two deliveries resolved the same centers")
		expect(_cell_materials() == coalesced, "the two deliveries produced the same voxels and materials")
	)


func _projection_match() -> void:
	step("Given a floor and a wide 20 high block seen orthographically", func():
		_plateau_fixture()
	)
	await _stroke(Vector3(-2, 0, 0), [Vector3(18, 20, 0)])
	var ortho_top := _max_y()
	step("Given the same floor and block seen in perspective", func():
		_plateau_fixture()
		camera_rig().set_view("top")
		camera_rig().is_orthogonal = false
		camera_rig().center_on(AABB(Vector3(-14, -6, -14), Vector3(50, 50, 28)))
		expect(camera_rig().projection == Camera3D.PROJECTION_PERSPECTIVE, "the fixture uses a real perspective projection")
	)
	await get_tree().process_frame
	await _stroke(Vector3(-2, 0, 0), [Vector3(18, 20, 0)])
	step("Then both projections grew above the block top beyond the old scan depth", func():
		expect(ortho_top >= 21, "the orthographic brush grew above the block top")
		expect(_max_y() >= 21, "the perspective brush grew above the block top")
	)


func _add_hit_then_floor_miss() -> void:
	step("Given a floor patch and a raised block, and Add", func():
		_gap_fixture()
		_settings.grow_mode = _settings.GrowMode.ADD
	)
	await _stroke(Vector3(0, 4, 0), [Vector3(10, 0, 0)])
	step("Then the block hit grew and the model press seeded no floating canopy", func():
		expect(_frame.has(Vector3i(0, 5, 0)), "the press grew the block top")
		expect(_stroke_grew(), "the stroke grew the model")
		# The press hit the model, so the original policy never seeds. A later ray
		# that misses the model therefore adds nothing, rather than a canopy that
		# floats past the pressed footprint disc.
		expect(not _frame.has(Vector3i(10, 0, 0)), "the empty area past the patch stayed empty")
		expect(_max_x() <= 4, "no dab seeded a canopy past the pressed disc (max x %d)" % _max_x())
	)


func _remove_empty_miss() -> void:
	step("Given an empty floor and Remove", func():
		_install({})
		_view(AABB(Vector3(-14, -6, -14), Vector3(28, 20, 28)))
		_settings.grow_mode = _settings.GrowMode.REMOVE
	)
	await _stroke(Vector3(0, 0, 0), [Vector3(6, 0, 0)])
	step("Then a Remove miss applies nothing and records no history", func():
		expect(_frame.count() == 0, "a Remove miss changes no cell")
		expect(not State.undo_redo.has_undo(), "a Remove miss records no history")
		# The press missed the model, so the original policy captured the floor
		# seed. Remove never reads the seed, so it still places no cell.
		expect((_tool.grow_seeded as Array).size() > 0 and bool((_tool.grow_seeded as Array)[0]), "the empty-floor press captured its floor seed")
	)


func _captured_floor() -> void:
	step("Given an empty floor and an Add press", func():
		_install({})
		_view(AABB(Vector3(-14, -6, -14), Vector3(28, 20, 28)))
		_settings.grow_mode = _settings.GrowMode.ADD
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
	var before: int = (_tool.grow_centers as Array).size()
	step("When the pointer holds still while the model height changes", func():
		for _tick in 4:
			_tool.advance_stroke(1.0)
		_motion(_screen(Vector3(-2, 0, 0)))
	)
	await get_tree().process_frame
	step("Then the held pointer adds no dab", func():
		expect((_tool.grow_centers as Array).size() == before, "the held pointer invented no dab (%d)" % (_tool.grow_centers as Array).size())
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
