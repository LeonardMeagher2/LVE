extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO
var cell := VoxelPicking.NONE
var empty_cell := VoxelPicking.NONE


func _ready() -> void:
	test("a click on a voxel or an empty cell selects that cell", _run)


func _run() -> void:
	step("Given the select tool and one voxel at the center", func():
		viewport = editor_viewport()
		activate_tool("selection")
		select_toolbar_item("selection", "Box")
		var vsize: Vector2i = viewport.size
		if vsize.x <= 0 or vsize.y <= 0:
			viewport.size = Vector2i(800, 500)
			vsize = viewport.size
		center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
		cell = aim(center).target
		var f: VoxelFrame = State.document.frames[State.current_frame]
		f.set_cell(cell, VoxelFrame.material(Color.from_rgba8(150, 150, 150)))
	)

	step("When the user clicks the voxel", func():
		_click(center)
	)

	step("Then the clicked voxel is selected", func():
		expect(State.selection.cells.size() == 1, "selection holds one cell")
		expect(State.selection.contains(cell), "the clicked cell is selected")
	)

	step("When the user clicks the voxel again", func():
		_click(center)
	)

	step("Then the selection stays on that voxel", func():
		expect(State.selection.contains(cell), "the clicked cell stays selected")
	)

	step("When the user clicks an empty cell", func():
		var empty := _empty_screen_pos()
		expect(empty != Vector2.INF, "an empty cell screen position exists")
		empty_cell = aim(empty).target
		_click(empty)
	)

	step("Then that empty cell is selected", func():
		expect(State.selection.cells.size() == 1, "selection holds one cell")
		expect(State.selection.contains(empty_cell), "the empty cell is selected")
	)


func _click(pos: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	viewport.push_input(press)
	press.pressed = false
	viewport.push_input(press)


func _empty_screen_pos() -> Vector2:
	for dy in range(int(viewport.size.y) - 20, 0, -40):
		for dx in range(20, int(viewport.size.x), 40):
			var res := aim(Vector2(dx, dy))
			if res.target != VoxelPicking.NONE and res.hit == VoxelPicking.NONE:
				return Vector2(dx, dy)
	return Vector2.INF
