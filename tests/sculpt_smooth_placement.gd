extends "res://tests/test.gd"

# Smooth must follow the real surface under the cursor. The view plane fixes only
# the input spacing. Each canonical dab reconstructs its camera ray from the
# captured segment rays and resolves the real hit and entered face on the
# accepted frame at dab time, so no dab sits in the air, a miss applies nothing,
# and a vertical side keeps its own normal. The probe records every resolved hit.

const ProbeScript := preload("./sculpt_smooth_probe.gd")

var _settings := preload("res://plugins/Sculpt/settings.tres")
var _tool
var _frame: VoxelFrame
var _viewport: SubViewport


func _ready() -> void:
	test("a floor to pillar drag never centers a dab in the air", _floor_to_pillar, "floor_to_pillar")
	test("a cell-by-cell drag matches one coalesced drag", _coalesced_match, "coalesced_match")
	test("a drag over a gap applies nothing over the gap", _gap_miss, "gap_miss")
	test("a drag over empty space applies nothing and records no action", _empty_miss, "empty_miss")
	test("a vertical side keeps its own face and region", _vertical_side, "vertical_side")
	test("a perspective drag resolves the same hits stepped and coalesced", _perspective_match, "perspective_match")
	test("a true vertical side ray enters the side face", _true_vertical_side, "true_vertical_side")
	test("a camera change ends the captured gesture", _camera_change_ends, "camera_change_ends")


func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	_settings.tool = _settings.Tools.SMOOTH
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


func _floor_and_pillar() -> void:
	var changes := {}
	var material := _material()
	for x in range(-14, 15):
		for z in range(-14, 15):
			changes[Vector3i(x, 0, z)] = material
	for y in range(0, 21):
		changes[Vector3i(10, y, 0)] = material
	_install(changes)


# Two pillars with a gap, and no floor, so the middle rays miss the model.
func _two_pillars() -> void:
	var changes := {}
	var material := _material()
	for base in [Vector3i(0, 0, 0), Vector3i(12, 0, 0)]:
		for y in range(0, 5):
			for dx in range(0, 2):
				for dz in range(0, 2):
					changes[base + Vector3i(dx, y, dz)] = material
	_install(changes)


func _floor_and_wall() -> void:
	var changes := {}
	var material := _material()
	for x in range(-14, 15):
		for z in range(-14, 15):
			changes[Vector3i(x, 0, z)] = material
	for x in range(-8, 9):
		for y in range(0, 13):
			for dz in range(0, 2):
				changes[Vector3i(x, y, 10 + dz)] = material
	_install(changes)


# --- The strokes --------------------------------------------------------------

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


func _screen(world: Vector3) -> Vector2:
	return camera_rig().unproject_position(world)


# Runs one Smooth stroke from a press at one world point through the given world
# points. A step of one world cell is a cell-by-cell replay, a larger jump is a
# coalesced segment. Returns the recorded dab hits.
func _stroke(from: Vector3, path: Array) -> Array:
	_tool.reset_dabs()
	_button(true, _screen(from))
	for world in path:
		_motion(_screen(world))
	_button(false, _screen(path[path.size() - 1]) if not path.is_empty() else _screen(from))
	await _wait_idle()
	return _tool.dab_hits


func _air_count(hits: Array, low: int, high: int) -> int:
	var count := 0
	for hit in hits:
		var cell: Vector3i = hit
		if cell != VoxelPicking.NONE and cell.y > low and cell.y < high:
			count += 1
	return count


# --- Cases --------------------------------------------------------------------

func _floor_to_pillar() -> void:
	step("Given a floor and a 20 cell pillar", func():
		_floor_and_pillar()
	)
	var hits := await _stroke(Vector3(0, 0, 0), [Vector3(10, 0, 0)])
	step("Then the floor dabs stayed on the floor and the pillar dabs hit the top", func():
		var floor_hits := 0
		var pillar_hits := 0
		for hit in hits:
			var cell: Vector3i = hit
			if cell == VoxelPicking.NONE:
				continue
			if cell.y == 0:
				floor_hits += 1
			elif cell.y == 20:
				pillar_hits += 1
		expect(floor_hits > 0, "the ray before the pillar hit the floor")
		expect(pillar_hits > 0, "the ray on the pillar hit the top")
		expect(_air_count(hits, 0, 20) == 0, "no dab centered in the air between the floor and the pillar")
		expect(_frame.has(Vector3i(0, 0, 0)), "the floor under the stroke stays usable")
	)


func _coalesced_match() -> void:
	step("Given a floor and a 20 cell pillar", func():
		_floor_and_pillar()
	)
	var coalesced := await _stroke(Vector3(0, 0, 0), [Vector3(10, 0, 0)])
	step("Given the same floor and pillar", func():
		_floor_and_pillar()
	)
	var steps: Array = []
	for x in range(1, 11):
		steps.append(Vector3(float(x), 0, 0))
	var stepped := await _stroke(Vector3(0, 0, 0), steps)
	step("Then the two deliveries resolved the same hits", func():
		expect(coalesced.size() == stepped.size(), "the two deliveries applied the same dab count (%d vs %d)" % [coalesced.size(), stepped.size()])
		expect(coalesced == stepped, "the two deliveries resolved the same hit sequence")
	)


func _gap_miss() -> void:
	step("Given two pillars with a gap and no floor", func():
		_two_pillars()
	)
	var hits := await _stroke(Vector3(0, 0, 0), [Vector3(13, 0, 0)])
	step("Then the gap dabs missed and applied nothing", func():
		var misses := 0
		var applied := 0
		for hit in hits:
			if hit == VoxelPicking.NONE:
				misses += 1
			else:
				applied += 1
		expect(misses > 0, "the gap rays missed the model")
		expect(applied > 0, "the pillar rays applied")
		expect(State.undo_redo.has_undo(), "the applied pillar dabs record one action")
	)


func _empty_miss() -> void:
	step("Given an empty frame", func():
		_install({})
	)
	var hits := await _stroke(Vector3(0, 0, 0), [Vector3(6, 0, 0), Vector3(12, 0, 0)])
	step("Then every Smooth dab missed and no edit or history exists", func():
		for hit in hits:
			expect(hit == VoxelPicking.NONE, "a Smooth dab over empty space resolves no hit")
		expect(_frame.count() == 0, "a Smooth miss changes no voxel")
		expect(not State.undo_redo.has_undo(), "a Smooth miss records no history")
	)


func _vertical_side() -> void:
	step("Given a floor and a tall wall seen from the top", func():
		_floor_and_wall()
	)
	step("When the user presses on the floor and drags onto the wall", func():
		_tool.reset_dabs()
		_button(true, _screen(Vector3(0, 0, 6)))
		_motion(_screen(Vector3(0, 0, 10)))
	)
	await get_tree().process_frame
	step("Then the wall dabs hit the wall top and the region follows the wall", func():
		var hits: Array = _tool.dab_hits
		var wall_hits := 0
		for hit in hits:
			var cell: Vector3i = hit
			if cell != VoxelPicking.NONE and cell.y >= 10:
				wall_hits += 1
		expect(wall_hits > 0, "the ray onto the wall resolved the wall top")
		var depth := _field_depth_range()
		expect(depth.y >= 8.0, "the effect region climbed onto the wall (got %s)" % str(depth))
		_button(false, _screen(Vector3(0, 0, 10)))
	)
	await _wait_idle()


func _perspective_match() -> void:
	var cam := camera_rig()
	step("Given a distant perspective camera over the floor and pillar", func():
		_floor_and_pillar()
		cam.set_view("top")
		cam.is_orthogonal = false
		cam.global_position += cam.basis.z * 400.0
		expect(cam.projection == Camera3D.PROJECTION_PERSPECTIVE, "the fixture uses a real perspective projection")
	)
	await get_tree().process_frame
	step("Given ray angles that straddle the old cross threshold", func():
		var d0 := cam.project_ray_normal(_screen(Vector3(0, 0, 0)))
		var d1 := cam.project_ray_normal(_screen(Vector3(1, 0, 0)))
		var d10 := cam.project_ray_normal(_screen(Vector3(10, 0, 0)))
		expect(d0.cross(d1).length() < 0.02, "the one cell segment is below the old cross threshold")
		expect(d0.cross(d10).length() > 0.02, "the ten cell segment is above the old cross threshold")
	)
	var coalesced := await _stroke(Vector3(0, 0, 0), [Vector3(10, 0, 0)])
	step("Given the same distant perspective camera", func():
		_floor_and_pillar()
		cam.set_view("top")
		cam.is_orthogonal = false
		cam.global_position += cam.basis.z * 400.0
	)
	await get_tree().process_frame
	var steps: Array = []
	for x in range(1, 11):
		steps.append(Vector3(float(x), 0, 0))
	var stepped := await _stroke(Vector3(0, 0, 0), steps)
	step("Then both deliveries resolved the same perspective hits", func():
		expect(coalesced.size() > 0, "the perspective drag resolved dabs")
		expect(coalesced == stepped, "the two perspective deliveries resolved the same hits")
	)


func _true_vertical_side() -> void:
	step("Given a wall and the front view", func():
		_floor_and_wall()
		camera_rig().set_view("front")
		camera_rig().is_orthogonal = true
	)
	await get_tree().process_frame
	step("When the user presses on the floor and drags up onto the wall face", func():
		_tool.reset_dabs()
		_button(true, _screen(Vector3(0, 0, 0)))
		_motion(_screen(Vector3(0, 6, 0)))
	)
	await get_tree().process_frame
	step("Then a dab entered the vertical side face", func():
		var side_entries := 0
		for entry in _tool.dab_entries:
			var face: Vector3i = entry
			if face.z != 0:
				side_entries += 1
		expect(_tool.dab_hits.size() > 0, "the drag resolved dabs")
		expect(side_entries > 0, "a dab entered the vertical wall face, not the top")
		_button(false, _screen(Vector3(0, 6, 0)))
	)
	await _wait_idle()


func _camera_change_ends() -> void:
	step("Given a floor and the top view", func():
		_floor_and_pillar()
		camera_rig().set_view("top")
		camera_rig().is_orthogonal = true
	)
	await get_tree().process_frame
	step("When the camera moves during the open stroke", func():
		_button(true, _screen(Vector3(0, 0, 0)))
		_motion(_screen(Vector3(4, 0, 0)))
		expect(_tool._edit != null, "the stroke is open before the camera change")
		camera_rig().global_position += Vector3(0, 0, 6)
		_motion(_screen(Vector3(8, 0, 0)))
	)
	await _wait_idle()
	step("Then the gesture ended on the camera change", func():
		expect(_tool._edit == null, "the gesture ends on a camera change")
		_button(false, _screen(Vector3(8, 0, 0)))
	)


func _field_depth_range() -> Vector2:
	var low := 1 << 30
	var high := -(1 << 30)
	for field in _tool._smooth_fields:
		for cell: Vector3i in field["cells"]:
			low = mini(low, cell.y)
			high = maxi(high, cell.y)
	if high < low:
		return Vector2(0, 0)
	return Vector2(float(low), float(high))
