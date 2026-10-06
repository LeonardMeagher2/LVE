extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO
var r1 := VoxelPicking.NONE
var r2 := VoxelPicking.NONE
var r3 := VoxelPicking.NONE
var control := VoxelPicking.NONE
var empty_floor := VoxelPicking.NONE


func _ready() -> void:
	test("fill recolors every voxel of the same color when connected is off", _run)


func _run() -> void:
	step("Given the fill tool with a blue brush and three separate red voxels", func():
		viewport = editor_viewport()
		viewport.get_parent().stretch = false
		viewport.size = Vector2i(800, 500)
		activate_tool("fill")
		State.set_color(Color.BLUE)
		var vsize: Vector2i = viewport.size
		if vsize.x <= 0 or vsize.y <= 0:
			viewport.size = Vector2i(800, 500)
			vsize = viewport.size
		center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
		r1 = aim(center).target
		r2 = r1 + Vector3i(8, 0, 0)
		r3 = r1 + Vector3i(16, 0, 0)
		control = r1 + Vector3i(0, 1, 0)
		var f: VoxelFrame = State.document.frames[State.current_frame]
		f.set_cell(r1, Color.RED)
		f.set_cell(r2, Color.RED)
		f.set_cell(r3, Color.RED)
		f.set_cell(control, Color.GREEN)
	)

	step("When the user hovers a voxel with Fill", func():
		var motion := InputEventMouseMotion.new()
		motion.position = _screen_pos_of(r2)
		viewport.push_input(motion)
	)
	step("Then Fill shows its wire cube on the voxel", func():
		var tool: Node3D = plugin("FillPlugin")._tool
		expect(tool.visible and tool.position == Vector3(r2), "the Fill cursor follows the hovered voxel")
		var cursor: MeshInstance3D = tool.get_node("Cursor")
		expect(cursor.mesh.surface_get_primitive_type(0) == Mesh.PRIMITIVE_LINES, "the Fill cursor uses wire lines")
		expect(cursor.mesh.surface_get_array_len(0) == 24, "the Fill cursor shows all twelve cube edges")
	)
	step("When the user moves the Fill cursor over an empty floor cell", func():
		empty_floor = r1 + Vector3i(0, 0, 4)
		var motion := InputEventMouseMotion.new()
		motion.position = camera_rig().unproject_position(Vector3(empty_floor) + Vector3(0, -0.5, 0))
		viewport.push_input(motion)
	)
	step("Then the wire cursor follows the empty floor cell like the picker", func():
		var tool: Node3D = plugin("FillPlugin")._tool
		expect(tool.visible and tool.position == Vector3(empty_floor), "the Fill cursor stays visible over the empty floor cell")
	)
	step("Then the option bar shows a connected icon toggle", func():
		var b := _find_option_button("Connected")
		expect(b != null, "the connected toggle exists")
		if b == null:
			return
		expect(b.toggle_mode, "the connected control is a toggle button")
		expect(b.icon != null, "the connected toggle shows an icon")
		expect(b.button_pressed, "the connected toggle starts on")
	)

	step("When the user fills one red voxel with connected on", func():
		expect(_find_option_button("Connected").button_pressed == true, "connected is on by default")
		_click(_screen_pos_of(r2))
	)

	step("Then only that voxel changes color", func():
		var f: VoxelFrame = State.document.frames[State.current_frame]
		expect(f.get_color(r2) == Color.BLUE, "the clicked voxel takes the brush color")
		expect(f.get_color(r1) == Color.RED, "the distant red voxel keeps its color")
		expect(f.get_color(r3) == Color.RED, "the farthest red voxel keeps its color")
	)

	step("When the user turns connected off and fills another red voxel", func():
		press_option("Connected")
		_click(_screen_pos_of(r1))
	)

	step("Then every red voxel takes the brush color", func():
		var f: VoxelFrame = State.document.frames[State.current_frame]
		expect(f.get_color(r1) == Color.BLUE, "the first red voxel takes the brush color")
		expect(f.get_color(r3) == Color.BLUE, "the last red voxel takes the brush color")
		expect(f.get_color(control) == Color.GREEN, "the green voxel keeps its color")
	)


func _click(pos: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	viewport.push_input(press)
	press.pressed = false
	viewport.push_input(press)


func _screen_pos_of(cell: Vector3i) -> Vector2:
	for dy in range(0, int(viewport.size.y), 10):
		for dx in range(0, int(viewport.size.x), 10):
			var pos := Vector2(dx, dy)
			if aim(pos).target == cell:
				return pos
	return Vector2.INF
