extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO
var anchor := VoxelPicking.NONE
var front := VoxelPicking.NONE


func _ready() -> void:
	test("the brush adds voxels in front of the clicked face or recolors them in paint mode", _run)


func _run() -> void:
	step("Given a gray voxel where the center ray lands and the brush in add mode", func():
		viewport = editor_viewport()
		var container := viewport.get_parent()
		container.stretch = false
		viewport.size = Vector2i(800, 500)
		center = Vector2(400.0, 250.0)
		activate_tool("Toolbar")
		select_toolbar_item("Toolbar", "Pencil")
		State.current_color = Color.from_rgba8(200, 60, 60)
		anchor = aim(center).target
		State.document.set_cell(0, anchor, VoxelFrame.material(Color.from_rgba8(150, 150, 150)))
		sync_viewport()
		front = aim(center).add_target
	)

	step("When the user clicks the center of the viewport", func():
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.position = center
		viewport.push_input(click)
		click.pressed = false
		viewport.push_input(click)
	)

	step("Then a voxel appears in front of the clicked face", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.has(front), "a voxel is added beside the clicked voxel")
	)

	step("When the user switches to paint mode and clicks the front voxel", func():
		select_toolbar_item("Toolbar", "Paint")
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.position = center
		viewport.push_input(click)
		click.pressed = false
		viewport.push_input(click)
	)

	step("Then the front voxel is recolored and no voxel is added", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.count() == 2, "paint mode adds no new voxels")
		expect(frame.get_color(front) == Color.from_rgba8(200, 60, 60), "the front voxel has the brush color")
	)

	step("When the user clears the grid and clicks the empty grid in paint mode", func():
		State.document.frames[0].clear()
		sync_viewport()
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.position = center
		viewport.push_input(click)
		click.pressed = false
		viewport.push_input(click)
	)

	step("Then paint mode leaves the empty grid unchanged", func():
		expect(State.document.frames[0].count() == 0, "no voxel is painted on empty cells")
	)
