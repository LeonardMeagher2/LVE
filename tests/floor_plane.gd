extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _grid: GridRenderer
var _before := 0


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("the floor plane picks from any side, changes axis, and moves with the plane tool", _run)


func _run() -> void:
	step("Given the default floor plane on the Y axis at layer 0", func():
		_vp = editor_viewport(_inst)
		_grid = _vp.get_node("%Grid")
		State.floor_axis = Vector3.Axis.AXIS_Y
		State.floor_index = 0
	)

	step("When the user aims down and up at the same grid point", func():
		var down := VoxelPicking.ground_pick(Vector3(3, 8, -2), Vector3(0, -1, 0), Vector3(0, -1, 0))
		expect(down.target == Vector3i(3, 0, -2), "the aim from above lands on the floor layer")
		var up := VoxelPicking.ground_pick(Vector3(3, -9, -2), Vector3(0, 1, 0), Vector3(0, 1, 0))
		expect(up.target == Vector3i(3, -1, -2), "the aim from below lands under the plane")
		expect(up.plane != null, "the aim from below builds a stroke plane")
	)

	step("When the tool picks empty space from below", func():
		var pick := VoxelPicking.start_pick(Vector3(1, -7, 4), Vector3(0.2, 1.0, -0.1), {}, Vector3(0, 1, 0))
		expect(pick.target.x == 1 or pick.target.x == 2, "the slanted pick keeps the in-plane column near the ray")
		expect(pick.target.y == -1, "the start pick from below rests under the plane")
		expect(pick.hit == State.NONE, "empty space has no voxel hit")
	)

	step("When the user turns the floor to the X and Z axes", func():
		State.floor_axis = Vector3.Axis.AXIS_X
		var pos := VoxelPicking.ground_pick(Vector3(6, 2, 5), Vector3(-1, 0, 0), Vector3(-1, 0, 0)).target
		expect(pos == Vector3i(0, 2, 5), "an X pick from the far side lands on the X floor layer")
		pos = VoxelPicking.ground_pick(Vector3(-6, 2, 5), Vector3(1, 0, 0), Vector3(1, 0, 0)).target
		expect(pos == Vector3i(-1, 2, 5), "an X pick from the near side lands under the X floor")
		State.floor_axis = Vector3.Axis.AXIS_Z
		pos = VoxelPicking.ground_pick(Vector3(1, 2, 8), Vector3(0, 0, -1), Vector3(0, 0, -1)).target
		expect(pos == Vector3i(1, 2, 0), "a Z pick from the far side lands on the Z floor layer")
		pos = VoxelPicking.ground_pick(Vector3(1, 2, -8), Vector3(0, 0, 1), Vector3(0, 0, 1)).target
		expect(pos == Vector3i(1, 2, -1), "a Z pick from the near side lands under the Z floor")
		State.floor_axis = Vector3.Axis.AXIS_Y
	)

	step("When the user raises the floor three layers", func():
		State.floor_index = 3
		var above := VoxelPicking.ground_pick(Vector3(0, 9, 0), Vector3(0, -1, 0), Vector3(0, -1, 0)).target
		expect(above.y == 3, "the raised floor takes the aim from above into layer 3")
		var below := VoxelPicking.ground_pick(Vector3(0, -5, 0), Vector3(0, 1, 0), Vector3(0, 1, 0)).target
		expect(below.y == 2, "the raised floor takes the aim from below into layer 2")
		expect(_grid.position.y == 2.5, "the grid lines sit under the raised layer")
		State.floor_index = 0
		expect(_grid.position.y == -0.5, "the grid returns under the base layer")
	)

	step("Given the plane tool is active", func():
		State.set_tool(State.tools.plane)
	)

	await get_tree().process_frame

	step("When the user drags the plane upward", func():
		_before = State.floor_index
		_drag_plane(-120.0)
		expect(State.floor_index > _before, "the upward drag lifts the plane")
		expect(_grid.position[State.floor_axis] == float(State.floor_index) - 0.5, "the grid follows the dragged plane")
	)

	step("When the user drags the plane downward", func():
		_before = State.floor_index
		_drag_plane(200.0)
		expect(State.floor_index < _before, "the downward drag lowers the plane")
		expect(_grid.position[State.floor_axis] == float(State.floor_index) - 0.5, "the grid follows the lowered plane")
	)

	step("When the user drags from empty space beside the plane", func():
		_before = State.floor_index
		_drag_plane(-100.0, 260.0)
		expect(State.floor_index > _before, "a drag that starts off the plane still moves it")
	)


	step("When the user presses the Z and X keys", func():
		_key(KEY_Z)
		expect(State.floor_axis == Vector3.Axis.AXIS_Z, "the Z key faces the plane along Z")
		_key(KEY_X)
		expect(State.floor_axis == Vector3.Axis.AXIS_X, "the X key faces the plane along X")
	)

	await get_tree().process_frame

	step("When the user presses an axis button in the option bar", func():
		var z_btn := _axis_button("Z")
		expect(z_btn != null, "the option bar shows axis buttons for the plane tool")
		if z_btn:
			z_btn.pressed.emit()
			expect(State.floor_axis == Vector3.Axis.AXIS_Z, "the Z button faces the plane along Z")
			var y_btn := _axis_button("Y")
			y_btn.pressed.emit()
			expect(State.floor_axis == Vector3.Axis.AXIS_Y, "the Y button faces the plane along Y")
	)

	step("When the editor returns to the default floor", func():
		State.floor_axis = Vector3.Axis.AXIS_Y
		State.floor_index = 0
		State.set_tool(State.tools.pencil)
		expect(State.floor_axis == Vector3.Axis.AXIS_Y, "the floor returns to the Y axis")
		expect(State.floor_index == 0, "the floor returns to layer 0")
	)


func _drag_plane(delta_y: float, offset_x := 0.0) -> void:
	var cam := _vp.get_viewport().get_camera_3d()
	var center := Vector3.ZERO
	center[State.floor_axis] = float(State.floor_index) - 0.5
	var pos := cam.unproject_position(center) + Vector2(offset_x, 0.0)
	_mouse_button(pos, true)
	for i in 3:
		_mouse_motion(pos + Vector2(0.0, delta_y * float(i + 1) / 3.0))
	_mouse_button(pos + Vector2(0.0, delta_y), false)


func _mouse_button(pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	_vp.get_viewport().push_input(ev)


func _mouse_motion(pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	_vp.get_viewport().push_input(ev)


func _key(code: Key) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.pressed = true
	_vp.get_viewport().push_input(ev)


func _axis_button(label: String) -> Button:
	for node in _inst.find_children("*", "Button", true, false):
		var b := node as Button
		if b and b.toggle_mode and b.text == label:
			return b
	return null


