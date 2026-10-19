extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO
var a := VoxelPicking.NONE
var b := VoxelPicking.NONE
var c := VoxelPicking.NONE
var red := VoxelPicking.NONE


func _ready() -> void:
	test("wand selects every voxel of the same color when connected is off", _run)


func _run() -> void:
	step("Given the wand tool and three separate gray voxels plus one red voxel", func():
		viewport = editor_viewport()
		activate_tool("selection")
		select_toolbar_item("selection", "Wand")
		var vsize: Vector2i = viewport.size
		if vsize.x <= 0 or vsize.y <= 0:
			viewport.size = Vector2i(800, 500)
			vsize = viewport.size
		center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
		a = aim(center).target
		b = a + Vector3i(8, 0, 0)
		c = a + Vector3i(16, 0, 0)
		red = a + Vector3i(0, 1, 0)
		var gray := Color.from_rgba8(150, 150, 150)
		var f: VoxelFrame = State.document.frames[State.current_frame]
		f.set_cell(a, VoxelFrame.material(gray))
		f.set_cell(b, VoxelFrame.material(gray))
		f.set_cell(c, VoxelFrame.material(gray))
		f.set_cell(red, VoxelFrame.material(Color.RED))
		camera_rig().center_on(f.get_bounds())
	)

	step("When the user clicks one gray voxel with connected on", func():
		expect(_find_option_button("Connected").button_pressed == true, "connected is on by default")
		_click(_screen_pos_of(b))
	)

	step("Then only that voxel is selected", func():
		expect(State.selection.contains(b), "the clicked voxel is selected")
		expect(not State.selection.contains(a), "the distant gray voxel is not selected")
		expect(not State.selection.contains(red), "the red voxel is not selected")
	)

	step("Given no active selection", func():
		State.clear_selection()
	)

	step("When the user turns connected off and clicks another gray voxel", func():
		press_option("Connected")
		_click(_screen_pos_of(c))
	)

	step("Then every gray voxel is selected", func():
		expect(State.selection.contains(c), "the clicked voxel is selected")
		expect(State.selection.contains(a), "the first gray voxel is selected")
		expect(State.selection.contains(b), "the second gray voxel is selected")
		expect(State.selection.cells.size() == 3, "selection holds exactly the three gray voxels")
		expect(not State.selection.contains(red), "the red voxel is not selected")
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
