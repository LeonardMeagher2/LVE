extends "res://tests/test.gd"

# Exercise the normal source option end to end.
#
# The tests drive the real pointer input through the viewport. A test-only probe
# counts the frames that came back fitted, so the Face source proves that no fit
# result reaches the tool on the hover path and on the pick path.

const ProbeScript := preload("./sculpt_normals_probe.gd")

var _settings := preload("res://plugins/Sculpt/settings.tres")
var _viewport: SubViewport
var _tool
var _frame: VoxelFrame
var _press := Vector2.ZERO
# The Surface footprint of the maximum radius case. Steps do not share locals,
# because a lambda captures a local by value.
var _surface_cells: Array = []


func _ready() -> void:
	test("Surface fits a non-cardinal normal and locks it for the stroke", _surface_gradient, "surface_gradient")
	test("Face uses the exact hovered face and returns no fitted frame", _face_exact, "face_exact")
	test("Face keeps the exact maximum radius footprint without a fit", _face_radius, "face_radius")
	test("Face keeps the exact signed face normal on every view axis", _face_signed_axes, "face_signed_axes")
	test("Face Smooth never fits and keeps its outward face normal", _smooth_face, "smooth_face")
	test("Grab hides the normal source and keeps the view plane drag", _grab_hidden, "grab_hidden")
	test("A source change closes the open stroke and the next stroke uses it", _source_change, "source_change")


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
	_settings.tool = _settings.Tools.GROW
	_settings.grow_mode = _settings.GrowMode.ADD
	_settings.normal_source = _settings.NormalSource.SURFACE
	_settings.radius = 3
	_settings.strength = 1.0
	_settings.falloff = 0.0
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
			await _wait_idle()
		plugin("SculptPlugin").remove_editor_node(_tool)
		_tool.free()
	_tool = null


# --- The cases ----------------------------------------------------------------

func _surface_gradient() -> void:
	step("Given a two-level step and the Surface source", func():
		_view("top")
		_stair()
		_settings.tool = _settings.Tools.GROW
		_settings.normal_source = _settings.NormalSource.SURFACE
		_settings.radius = 3
		_press = _pos(Vector3(0, 1, 0))
		_tool.reset_normals_probe()
	)
	step("When the user hovers over the step edge", func():
		_hover(_press)
		_tool._rebuild_preview()
	)
	await _settle_preview()
	step("Then the frame is fitted and its normal is not cardinal", func():
		expect(_tool._hover_frame != null, "the hover builds a frame")
		expect(_tool._hover_frame.fitted, "the Surface source fits the local surface")
		expect(absf(_tool._hover_frame.normal.y) < 0.995, "the fitted normal is not the flat face normal")
		expect(_tool.hover_fitted >= 1, "the hover built a fitted frame")
	)
	step("When the user presses", func():
		_button(true, _press)
	)
	step("Then the press keeps the same fitted surface normal", func():
		expect(_tool._stroke_frame != null and _tool._stroke_frame.fitted, "the press locks a fitted plane")
		expect(_tool._stroke_frame.normal.is_equal_approx(_tool._hover_frame.normal), "the pressed plane matches the hovered surface normal")
		expect(not _tool._preview_cells.is_empty(), "the preview outlines support voxels")
		_button(false, _press)
	)
	await _wait_idle()


func _face_exact() -> void:
	step("Given the two-level step and the Face source", func():
		_view("top")
		_stair()
		_settings.tool = _settings.Tools.GROW
		_settings.normal_source = _settings.NormalSource.FACE
		_settings.radius = 3
		_press = _pos(Vector3(0, 1, 0))
		_tool.reset_normals_probe()
	)
	step("When the user hovers", func():
		_hover(_press)
		_tool._rebuild_preview()
	)
	await _settle_preview()
	step("Then the frame is the exact hovered face and no fit runs", func():
		expect(_tool._hover_frame != null, "the hover builds a frame")
		expect(not _tool._hover_frame.fitted, "the Face source never fits")
		expect(_tool._hover_frame.normal.is_equal_approx(Vector3(_tool._last_pick.entry).normalized()), "the normal is the exact hovered entry face")
		expect(_tool._hover_frame.normal.is_equal_approx(Vector3.UP), "the top face normal is exact")
		expect(_tool.hover_fitted == 0, "no fitted hover frame reached the tool")
	)
	step("When the user presses", func():
		_button(true, _press)
	)
	step("Then the press keeps the same exact face and no fit runs", func():
		expect(_tool._stroke_frame != null and not _tool._stroke_frame.fitted, "the press keeps the face source")
		expect(_tool._stroke_frame.normal.is_equal_approx(_tool._hover_frame.normal), "the pressed face matches the hovered face")
		expect(_tool.fitted_frames == 0, "no fitted pick frame reached the tool")
		_button(false, _press)
	)
	await _wait_idle()


func _face_radius() -> void:
	step("Given a wide flat plate at the maximum radius with the Surface source", func():
		_view("top")
		_flat_plate()
		_settings.tool = _settings.Tools.GROW
		_settings.normal_source = _settings.NormalSource.SURFACE
		_settings.radius = 32
		_press = _pos(Vector3.ZERO)
		_hover(_press)
	)
	await _settle_preview()
	step("Then the Surface source outlines the wide footprint with a fitted cardinal normal", func():
		_surface_cells = _tool._preview_cells.keys()
		_surface_cells.sort()
		expect(_surface_cells.size() > 0, "the wide footprint is not empty")
		expect(_tool._hover_frame.fitted and _tool._hover_frame.normal.is_equal_approx(Vector3.UP), "the flat plate fits its cardinal normal")
	)
	step("When the source becomes Face and the radius falls to four", func():
		_settings.normal_source = _settings.NormalSource.FACE
		_settings.radius = 4
	)
	await _settle_preview()
	step("Then the four radius face hover fitted nothing", func():
		_tool.reset_normals_probe()
		expect(_tool.hover_fitted == 0, "the face hover fitted no frame")
	)
	step("When the radius returns to the maximum", func():
		_settings.radius = 32
	)
	await _settle_preview()
	step("Then the Face footprint is exact and no fit ran", func():
		var face_cells: Array = _tool._preview_cells.keys()
		face_cells.sort()
		expect(face_cells.size() == _surface_cells.size(), "the Face footprint holds the same cell count (%d vs %d)" % [face_cells.size(), _surface_cells.size()])
		expect(face_cells == _surface_cells, "the Face footprint matches the Surface footprint element by element (first %s)" % _first_cell_difference(face_cells, _surface_cells))
		expect(face_cells.has(Vector3i(32, 0, 0)) and face_cells.has(Vector3i(-32, 0, 0)) and face_cells.has(Vector3i(0, 0, 32)) and face_cells.has(Vector3i(0, 0, -32)), "the footprint spans the whole maximum radius disc")
		expect(not _tool._hover_frame.fitted, "the radius change built no fitted frame")
		expect(_tool.hover_fitted == 0, "the radius change fitted no hover frame")
		expect(_tool.fitted_frames == 0, "the radius change fitted no pick frame")
	)


func _face_signed_axes() -> void:
	for view in ["top", "bottom", "front", "back", "left", "right"]:
		var near := Vector3i.ZERO
		step("Given a solid block seen from the %s with the Face source" % view, func():
			_solid_block()
			_view(view)
			_settings.tool = _settings.Tools.GROW
			_settings.normal_source = _settings.NormalSource.FACE
			_settings.radius = 2
			near = _near_cell(view)
			_press = _pos(Vector3(near))
			_tool.reset_normals_probe()
			_hover(_press)
			_button(true, _press)
		)
		step("Then the plane normal is the exact signed face normal", func():
			expect(_tool._last_pick.hit != VoxelPicking.NONE, "the ray hits the block")
			var entry: Vector3i = _tool._last_pick.entry
			expect(entry != Vector3i.ZERO, "the pick records the entered face")
			expect(_tool._stroke_frame != null, "the press opens a stroke frame")
			expect(_tool._stroke_frame.normal.is_equal_approx(Vector3(entry).normalized()), "the plane uses the entered face normal")
			expect(_tool._stroke_frame.normal != Vector3.ZERO, "the normal is never empty")
			expect(_tool._stroke_frame.normal[int(_axis_of(view))] != 0.0, "the normal follows the viewed axis")
			expect(_tool.fitted_frames == 0 and _tool.hover_fitted == 0, "no fit ran on this axis")
			_button(false, _press)
		)
		await _wait_idle()


func _smooth_face() -> void:
	step("Given a spike with Smooth and the Face source", func():
		_spike()
		_view("top")
		_settings.tool = _settings.Tools.SMOOTH
		_settings.normal_source = _settings.NormalSource.FACE
		_settings.radius = 3
		_settings.strength = 8.0
		_press = _pos(Vector3(0, 0, 0))
		_tool.reset_normals_probe()
	)
	step("When the user presses the spike", func():
		_button(true, _press)
		expect(_tool._edit != null, "the press opens the edit")
		expect(_tool._stroke_frame != null and not _tool._stroke_frame.fitted, "the Smooth press keeps the face source")
	)
	step("Then a Smooth refit keeps the locked face normal and fits nothing", func():
		var before: Vector3 = _tool._stroke_frame.normal
		_frame.set_cell(Vector3i(1, 1, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_tool._rebuild_smooth()
		expect(_tool._stroke_frame.normal.is_equal_approx(before), "the refit keeps the locked face normal")
		expect(not _tool._stroke_frame.fitted, "the refit fits nothing")
		expect(_tool.fitted_frames == 0, "no fitted pick frame reached the tool")
		expect(_tool.hover_fitted == 0, "no fitted hover frame reached the tool")
		_button(false, _press)
	)
	await _wait_idle()
	step("Then the Smooth stroke records one history action", func():
		expect(State.undo_redo.has_undo(), "the Smooth stroke records history")
	)


func _grab_hidden() -> void:
	step("Given the Grab tool", func():
		_view("top")
		_solid_block()
		_settings.tool = _settings.Tools.GRAB
		_settings.normal_source = _settings.NormalSource.SURFACE
		_settings.radius = 2
		_press = _pos(Vector3(0, 3, 0))
	)
	step("Then the normal source control is hidden and offers both sources", func():
		var control: Button = plugin("SculptPlugin")._options.get_node("Normal")
		expect(not control.visible, "the Grab tool hides the normal source")
		expect(control.toggle_mode, "the normal source control is a toggle button")
		expect(control.icon != null, "the normal source control shows an icon")
		expect(control.text == "", "the normal source control has no text")
	)
	step("When the user hovers and presses with Grab", func():
		_hover(_press)
		_button(true, _press)
	)
	step("Then Grab captures its drag sources on the view plane and locks no stroke plane", func():
		expect(_tool._edit != null, "the Grab press opens the edit")
		expect(_tool._stroke_frame == null, "the Grab tool locks no stroke plane")
		expect(_tool._grab_anchor != VoxelPicking.NONE and not _tool._grab_sources.is_empty(), "the Grab tool captures its drag sources")
		_button(false, _press)
	)
	await _wait_idle()
	step("Then another tool shows the normal source again", func():
		_settings.tool = _settings.Tools.GROW
		expect(plugin("SculptPlugin")._options.get_node("Normal").visible, "the Grow tool shows the normal source")
	)


func _source_change() -> void:
	step("Given an open Grow stroke with the Surface source", func():
		_view("top")
		_stair()
		_settings.tool = _settings.Tools.GROW
		_settings.normal_source = _settings.NormalSource.SURFACE
		_settings.radius = 3
		_press = _pos(Vector3(0, 1, 0))
		_button(true, _press)
		expect(_tool._edit != null, "the press opens the edit")
		expect(_tool._stroke_normal_source == _settings.NormalSource.SURFACE, "the stroke captured the Surface source")
	)
	step("When the user changes the normal source while the stroke is open", func():
		_settings.normal_source = _settings.NormalSource.FACE
	)
	await _wait_idle()
	step("Then the open stroke ends and the next stroke uses the new source", func():
		expect(_tool._edit == null, "the source change closes the open stroke")
		expect(State.undo_redo.has_undo(), "the closed stroke is one history action")
		_button(true, _press)
		expect(_tool._edit != null, "the new press opens an edit")
		expect(_tool._stroke_normal_source == _settings.NormalSource.FACE, "the new stroke captured the Face source")
		expect(_tool._stroke_frame != null and not _tool._stroke_frame.fitted, "the new stroke uses the exact face")
		_button(false, _press)
	)
	await _wait_idle()


# --- Fixtures and helpers -----------------------------------------------------

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


func _settle_preview() -> void:
	for index in 240:
		await get_tree().process_frame
		if not _tool._preview_dirty and _tool.get_node("Cursor").is_settled():
			return


# The first cell that differs between two sorted cell lists, for a report.
func _first_cell_difference(first: Array, second: Array) -> String:
	for index in mini(first.size(), second.size()):
		if first[index] != second[index]:
			return "index %d: %s vs %s" % [index, str(first[index]), str(second[index])]
	if first.size() != second.size():
		return "count %d vs %d" % [first.size(), second.size()]
	return "-"


# A two-level step. The fitted normal across the step is not cardinal.
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
