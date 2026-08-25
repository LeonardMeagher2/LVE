extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _r1 := State.NONE
var _r2 := State.NONE
var _r3 := State.NONE
var _control := State.NONE


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("fill recolors every voxel of the same color when connected is off", _run)


func _run() -> void:
	step("Given the fill tool with a blue brush and three separate red voxels", func():
		_vp = editor_viewport(_inst)
		State.set_tool(State.tools.fill)
		State.set_color(Color.BLUE)
		var svp := _vp.get_viewport()
		var vsize: Vector2i = svp.size
		if vsize.x <= 0 or vsize.y <= 0:
			svp.size = Vector2i(800, 500)
			vsize = svp.size
		_center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
		_r1 = aim(_vp, _center).target
		_r2 = _r1 + Vector3i(8, 0, 0)
		_r3 = _r1 + Vector3i(16, 0, 0)
		_control = _r1 + Vector3i(0, 1, 0)
		var f: VoxelFrame = State.document.frames[State.current_frame]
		f.cells[_r1] = Color.RED
		f.cells[_r2] = Color.RED
		f.cells[_r3] = Color.RED
		f.cells[_control] = Color.GREEN
	)

	step("Then the option bar shows a connected icon toggle", func():
		var b := _connected_toggle()
		expect(b != null, "the connected toggle exists")
		if b == null:
			return
		expect(b.toggle_mode, "the connected control is a toggle button")
		expect(b.icon != null, "the connected toggle shows an icon")
		expect(b.button_pressed, "the connected toggle starts on")
	)

	step("When the user fills one red voxel with connected on", func():
		expect(State.get_tool_option(State.tools.fill, "connected") == true, "connected is on by default")
		_click(_screen_pos_of(_r2))
	)

	step("Then only that voxel changes color", func():
		var f: VoxelFrame = State.document.frames[State.current_frame]
		expect(f.cells[_r2] == Color.BLUE, "the clicked voxel takes the brush color")
		expect(f.cells[_r1] == Color.RED, "the distant red voxel keeps its color")
		expect(f.cells[_r3] == Color.RED, "the farthest red voxel keeps its color")
	)

	step("When the user turns connected off and fills another red voxel", func():
		State.set_tool_option("", "connected", false)
		_click(_screen_pos_of(_r1))
	)

	step("Then every red voxel takes the brush color", func():
		var f: VoxelFrame = State.document.frames[State.current_frame]
		expect(f.cells[_r1] == Color.BLUE, "the first red voxel takes the brush color")
		expect(f.cells[_r3] == Color.BLUE, "the last red voxel takes the brush color")
		expect(f.cells[_control] == Color.GREEN, "the green voxel keeps its color")
	)


func _connected_toggle() -> Button:
	var bar := _inst.get_node("%OptionBar")
	for w in bar.get_node("OptionsBox").get_children():
		for c in w.get_children():
			if c is Button and c.tooltip_text == "Connected":
				return c
	return null


func _click(pos: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	_vp.get_viewport().push_input(press)
	press.pressed = false
	_vp.get_viewport().push_input(press)


func _screen_pos_of(cell: Vector3i) -> Vector2:
	var svp := _vp.get_viewport()
	for dy in range(0, int(svp.size.y), 10):
		for dx in range(0, int(svp.size.x), 10):
			var pos := Vector2(dx, dy)
			if aim(_vp, pos).target == cell:
				return pos
	return Vector2.INF
