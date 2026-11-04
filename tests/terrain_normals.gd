extends "res://tests/test.gd"

# Exercise the normal source option end to end.
#
# The tests drive the real pointer input through the viewport. A test-only probe
# counts the frames that follow the surface. The hover poses the cheap face or
# floor frame, so it never calls the pick frame function. A press calls it once,
# so the Face source proves that no surface frame reaches the tool on the press.

const ProbeScript := preload("./terrain_normals_probe.gd")

var _settings := preload("res://plugins/Terrain/settings.tres")
var _viewport: SubViewport
var _tool
var _frame: VoxelFrame
var _press := Vector2.ZERO


func _ready() -> void:
	test("Surface reads a non-cardinal normal and locks it for the stroke", _surface_gradient, "surface_gradient")
	test("Grab keeps the view plane drag", _grab_hidden, "grab_hidden")


func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.current_color = Color.from_rgba8(200, 60, 60)
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	_settings.tool = _settings.Tools.BUILD
	_settings.build_mode = _settings.BuildMode.ADD
	_settings.radius = 7
	_settings.strength = 1.0
	_settings.falloff = 0.0
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
			await _wait_idle()
		plugin("TerrainPlugin").remove_editor_node(_tool)
		_tool.free()
	_tool = null


# --- The cases ----------------------------------------------------------------

func _surface_gradient() -> void:
	step("Given a two-level step and the Surface source", func():
		_view("top")
		_stair()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 7
		_press = _pos(Vector3(0, 1, 0))
		_tool.reset_normals_probe()
	)
	step("When the user hovers over the step edge", func():
		_hover(_press)
	)
	step("Then the hover poses the cheap face frame and reads no surface", func():
		expect(_tool.surface_calls == 0, "the hover reads no pick surface")
		expect(_tool.surface_frames == 0, "the hover read no surface")
	)
	step("When the user presses", func():
		_button(true, _press)
	)
	step("Then the press locks a surface frame frame", func():
		expect(_tool._stroke_frame != null, "the press opens a stroke frame")
		expect(_tool._stroke_frame.follows_surface, "the Surface source reads the local surface")
		expect(_tool.surface_frames >= 1, "the press returned a surface frame")
		expect(absf(_tool._stroke_frame.normal.y) < 0.995, "the surface normal is not the flat face normal")
		_button(false, _press)
	)
	await _wait_idle()


func _grab_hidden() -> void:
	step("Given the Grab tool", func():
		_view("top")
		_solid_block()
		_settings.tool = _settings.Tools.GRAB
		_settings.radius = 5
		_press = _pos(Vector3(0, 3, 0))
	)
	step("When the user hovers and presses with Grab", func():
		_hover(_press)
		_button(true, _press)
	)
	step("Then Grab captures its drag sources on the view plane", func():
		expect(_tool._edit != null, "the Grab press opens the edit")
		expect(_tool._stroke_frame != null and not _tool._stroke_frame.follows_surface, "the Grab press stores the cheap face frame")
		expect(_tool._plane != null and _tool._plane.normal.is_equal_approx(_tool._forward().normalized()), "the drag plane is the view plane")
		expect(_tool._grab_anchor != VoxelPicking.NONE and not _tool._grab_sources.is_empty(), "the Grab tool captures its drag sources")
		_button(false, _press)
	)
	await _wait_idle()


func _view(view: String) -> void:
	State.floor_axis = _floor_axis(view)
	camera_rig().set_view(view)
	camera_rig().is_orthogonal = true


func _floor_axis(view: String) -> int:
	if view in ["top", "bottom"]:
		return Vector3.Axis.AXIS_Y
	if view in ["front", "back"]:
		return Vector3.Axis.AXIS_Z
	return Vector3.Axis.AXIS_X


func _axis_of(view: String) -> int:
	return _floor_axis(view)


func _pos(world: Vector3) -> Vector2:
	return camera_rig().unproject_position(world)


func _button(pressed: bool, pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.pressed = pressed
	event.position = pos
	_viewport.push_input(event)


func _hover(pos: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	_viewport.push_input(event)


func _wait_idle() -> void:
	while _tool._edit != null:
		await get_tree().process_frame


# A two-level step. The surface normal across the step is not cardinal.
func _stair() -> void:
	var changes := {}
	for x in range(-4, 1):
		for z in range(-3, 4):
			changes[Vector3i(x, 0, z)] = VoxelFrame.material(Color.WHITE)
	for x in range(1, 5):
		for z in range(-3, 4):
			changes[Vector3i(x, 0, z)] = VoxelFrame.material(Color.WHITE)
			changes[Vector3i(x, 1, z)] = VoxelFrame.material(Color.WHITE)
	_frame.set_cells(changes)
	sync_viewport()


# A wide flat plate, so a maximum radius disc stays on the model.
func _flat_plate() -> void:
	var changes := {}
	for x in range(-34, 35):
		for z in range(-34, 35):
			changes[Vector3i(x, 0, z)] = VoxelFrame.material(Color.WHITE)
	_frame.set_cells(changes)
	sync_viewport()


func _solid_block() -> void:
	State.document = VoxelDocument.new()
	_frame = State.get_current_voxel_frame()
	var changes := {}
	for x in range(-3, 4):
		for y in range(-3, 4):
			for z in range(-3, 4):
				changes[Vector3i(x, y, z)] = VoxelFrame.material(Color.WHITE)
	_frame.set_cells(changes)
	sync_viewport()


func _spike() -> void:
	State.document = VoxelDocument.new()
	_frame = State.get_current_voxel_frame()
	var changes := {}
	for x in range(-4, 5):
		for z in range(-4, 5):
			changes[Vector3i(x, 0, z)] = VoxelFrame.material(Color.from_rgba8(90, 160, 220))
	for y in range(1, 7):
		changes[Vector3i(0, y, 0)] = VoxelFrame.material(Color.from_rgba8(90, 160, 220))
	_frame.set_cells(changes)
	sync_viewport()


# The cell on the near face of the solid block for one view.
func _near_cell(view: String) -> Vector3i:
	match view:
		"top":
			return Vector3i(0, 3, 0)
		"bottom":
			return Vector3i(0, -3, 0)
		"front":
			return Vector3i(0, 0, 3)
		"back":
			return Vector3i(0, 0, -3)
		"left":
			return Vector3i(-3, 0, 0)
	return Vector3i(3, 0, 0)
