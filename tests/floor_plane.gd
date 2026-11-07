extends "res://tests/test.gd"

var viewport: SubViewport
var grid: MeshInstance3D
var before := 0


func _ready() -> void:
	test("the floor plane picks from any side, changes axis, and moves with the plane tool", _run)
	test("the slice option targets the floor layer and shows it alone", _slice_run, "slice_plane")
	test("a slice slab covers the layers around the floor", _slab_run, "slice_slab")


func _setup_test() -> void:
	State.slice_enabled = false
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	State.document = VoxelDocument.new()
	activate_tool("Toolbar")


func _slice_run() -> void:
	step("Given a slice at layer 2 and voxels in front of and behind it", func():
		viewport = editor_viewport()
		State.floor_axis = Vector3.Axis.AXIS_Y
		State.floor_index = 2
		State.document.set_cell(0, Vector3i(0, 5, 0), VoxelFrame.material(Color.RED))
		State.document.set_cell(0, Vector3i(0, 2, 0), VoxelFrame.material(Color.GREEN))
		State.document.set_cell(0, Vector3i(0, 20, 0), VoxelFrame.material(Color.BLUE))
	)
	step("When a ray from above meets the slice", func():
		var frame := State.get_current_voxel_frame()
		var pick := VoxelPicking.start_pick(Vector3(0.4, 20.0, 0.2), Vector3(0, -1, 0), frame, Vector3(0, 1, 0), true)
		expect(pick.target == Vector3i(0, 2, 0), "the slice pick targets the layer under the ray")
		expect(pick.hit == Vector3i(0, 2, 0), "an occupied slice cell is the hit")
		expect(pick.plane != null and pick.plane.axis == Vector3.Axis.AXIS_Y, "the pick plane faces the slice axis")
		expect(pick.plane.idx == 2, "the pick plane holds the layer index")
	)
	step("Then an empty slice cell is still the target and not the hit", func():
		var frame := State.get_current_voxel_frame()
		var pick := VoxelPicking.start_pick(Vector3(3.4, 20.0, 0.2), Vector3(0, -1, 0), frame, Vector3(0, 1, 0), true)
		expect(pick.target == Vector3i(3, 2, 0), "the brush can add on an empty slice cell")
		expect(pick.hit == VoxelPicking.NONE, "an empty slice cell has no voxel hit")
	)
	step("Then a slice drag stays on the layer", func():
		var plane := VoxelPicking.slice_plane()
		var pick := VoxelPicking.drag_pick(Vector3(9.4, 20.0, -3.6), Vector3(0, -1, 0), State.get_current_voxel_frame(), plane)
		expect(pick.target.y == 2, "a slice drag lands on the layer")
	)
	step("Then a negative layer index works the same way", func():
		State.floor_index = -1
		var pick := VoxelPicking.start_pick(Vector3(1.4, 20.0, 1.2), Vector3(0, -1, 0), State.get_current_voxel_frame(), Vector3(0, 1, 0), true)
		expect(pick.target.y == -1, "the slice pick handles a negative layer")
		State.floor_index = 2
	)
	step("When the user presses the slice option", func():
		activate_tool("plane")
	)
	await get_tree().process_frame
	step("Then the option bar sets the slice layers and keeps the floor index", func():
		var layers = plugin("PlanePlugin")._options.get_node("Layers")
		layers.value = 1
		expect(State.slice_layers == 1 and State.slice_enabled, "one layer turns the slice on")
		expect(State.floor_index == 2, "the layer count does not move the floor")
		layers.value = 0
		expect(State.slice_layers == 0 and not State.slice_enabled, "zero layers shows every layer")
		activate_tool("Toolbar")
	)
	step("Given the slice view on layer 2", func():
		State.slice_enabled = true
		sync_viewport()
	)
	var renderer: VoxelRenderer = viewport_scene().get_node("VoxelRenderer")
	while not renderer.is_settled():
		await get_tree().process_frame
	await get_tree().process_frame
	step("Then the view draws only the chunk row that holds the slice", func():
		expect(renderer.slice_axis == Vector3.Axis.AXIS_Y and renderer.slice_index == 2, "the viewport applies the slice")
		var slice_row := VoxelFrame.chunk_position(Vector3i(0, 2, 0)).y
		var only_slice_row := true
		for location: Vector3i in renderer._chunk_instances:
			if location.y != slice_row:
				only_slice_row = false
		expect(only_slice_row, "the view draws only the chunk row that holds the slice")
		expect(renderer._chunk_instances.size() == 1, "the other chunk rows are hidden")
	)
	step("When the user turns the slice off", func():
		State.slice_enabled = false
		sync_viewport()
	)
	while not renderer.is_settled():
		await get_tree().process_frame
	await get_tree().process_frame
	step("Then the full model returns", func():
		expect(renderer.slice_axis == -1, "the view drops the slice when the option is off")
		expect(renderer._chunk_instances.size() == 2, "both chunk rows are drawn again")
	)


func _run() -> void:
	step("Given the default floor plane on the Y axis at layer 0", func():
		viewport = editor_viewport()
		grid = viewport.get_node("ViewportScene/Grid")
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
		var pick := VoxelPicking.start_pick(Vector3(1, -7, 4), Vector3(0.2, 1.0, -0.1), VoxelFrame.new(), Vector3(0, 1, 0))
		expect(pick.target.x == 1 or pick.target.x == 2, "the slanted pick keeps the in-plane column near the ray")
		expect(pick.target.y == -1, "the start pick from below rests under the plane")
		expect(pick.hit == VoxelPicking.NONE, "empty space has no voxel hit")
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
		expect(grid.position.y == 2.5, "the grid lines sit under the raised layer")
		State.floor_index = 0
		expect(grid.position.y == -0.5, "the grid returns under the base layer")
	)

	step("Given the plane tool is active", func():
		activate_tool("plane")
	)

	await get_tree().process_frame

	step("When the user drags the plane upward", func():
		before = State.floor_index
		_drag_plane(-120.0)
		expect(State.floor_index > before, "the upward drag lifts the plane")
		expect(grid.position[State.floor_axis] == float(State.floor_index) - 0.5, "the grid follows the dragged plane")
	)

	step("When the user drags the plane downward", func():
		before = State.floor_index
		_drag_plane(200.0)
		expect(State.floor_index < before, "the downward drag lowers the plane")
		expect(grid.position[State.floor_axis] == float(State.floor_index) - 0.5, "the grid follows the lowered plane")
	)

	step("When the user drags from empty space beside the plane", func():
		before = State.floor_index
		_drag_plane(-100.0, 260.0)
		expect(State.floor_index > before, "a drag that starts off the plane still moves it")
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
			z_btn.button_pressed = true
			expect(State.floor_axis == Vector3.Axis.AXIS_Z, "the Z button faces the plane along Z")
			var y_btn := _axis_button("Y")
			y_btn.button_pressed = true
			expect(State.floor_axis == Vector3.Axis.AXIS_Y, "the Y button faces the plane along Y")
	)

	step("When the user leaves Plane, changes the axis, and returns", func():
		activate_tool("Toolbar")
		State.floor_axis = Vector3.Axis.AXIS_X
		activate_tool("plane")
	)
	step("Then the Plane cursor uses the current axis on re-entry", func():
		var cursor: Node3D = plugin("PlanePlugin")._tool.get_node("Cursor")
		expect(cursor.basis.is_equal_approx(Basis(Vector3.FORWARD, -PI / 2)), "the returned Plane cursor faces the X axis")
	)
	step("When the user changes the axis after returning to Plane", func():
		State.floor_axis = Vector3.Axis.AXIS_Z
	)
	step("Then the Plane cursor keeps following axis changes", func():
		var cursor: Node3D = plugin("PlanePlugin")._tool.get_node("Cursor")
		expect(cursor.basis.is_equal_approx(Basis(Vector3.RIGHT, PI / 2)), "the returned Plane cursor follows the Z axis")
		activate_tool("Toolbar")
		State.floor_axis = Vector3.Axis.AXIS_Y
		activate_tool("plane")
		expect(cursor.basis.is_equal_approx(Basis.IDENTITY), "another tool switch restores the Y cursor rotation")
	)
	step("When the editor returns to the default floor", func():
		State.floor_axis = Vector3.Axis.AXIS_Y
		State.floor_index = 0
		activate_tool("Toolbar")
		expect(State.floor_axis == Vector3.Axis.AXIS_Y, "the floor returns to the Y axis")
		expect(State.floor_index == 0, "the floor returns to layer 0")
	)


func _drag_plane(delta_y: float, offset_x := 0.0) -> void:
	var cam := camera_rig()
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
	viewport.push_input(ev)


func _mouse_motion(pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.push_input(ev)


func _key(code: Key) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.pressed = true
	viewport.push_input(ev)


func _axis_button(label: String) -> Button:
	for node in main.find_children("*", "Button", true, false):
		var b := node as Button
		if b and b.toggle_mode and b.text == label:
			return b
	return null

func _slab_run() -> void:
	step("Given cells above and below a floor layer and a three-layer slab", func():
		State.floor_axis = Vector3.Axis.AXIS_Y
		State.floor_index = 2
		var frame := State.get_current_voxel_frame()
		for y in [1, 2, 3, 4]:
			frame.set_cell(Vector3i(0, y, 0), VoxelFrame.material(Color.RED))
		State.document._bounds_dirty = true
		State.slice_layers = 3
		expect(State.slice_first() == 1 and State.slice_last() == 3, "the slab is the floor layer plus one each side")
	)
	step("Then the ray picks the top cell inside the slab", func():
		var pick := VoxelPicking.start_pick(Vector3(0.5, 20.0, 0.5), Vector3(0, -1, 0), State.get_current_voxel_frame(), Vector3(0, 1, 0), true)
		expect(pick.target == Vector3i(0, 3, 0), "the top cell of the slab is the target")
		expect(pick.hit == Vector3i(0, 3, 0), "a cell above the slab does not block")
	)
	step("Then the write gate keeps the slab range", func():
		var context := State.drawing_context()
		expect(context.allows(Vector3i(0, 1, 0)), "the layer below the floor is writable")
		expect(context.allows(Vector3i(0, 2, 0)), "the floor layer is writable")
		expect(context.allows(Vector3i(0, 3, 0)), "the layer above the floor is writable")
		expect(not context.allows(Vector3i(0, 4, 0)), "a layer above the slab is refused")
		expect(not context.allows(Vector3i(0, 0, 0)), "a layer below the slab is refused")
	)
	step("When the slab holds one layer", func():
		State.slice_layers = 1
		expect(State.slice_first() == 2 and State.slice_last() == 2, "one layer keeps the floor layer")
		var pick := VoxelPicking.start_pick(Vector3(0.5, 20.0, 0.5), Vector3(0, -1, 0), State.get_current_voxel_frame(), Vector3(0, 1, 0), true)
		expect(pick.target == Vector3i(0, 2, 0), "the floor layer is the target")
		expect(not State.drawing_context().allows(Vector3i(0, 3, 0)), "the layer above the one-layer slice is refused")
	)
