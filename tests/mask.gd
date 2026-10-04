extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO
var inside := VoxelPicking.NONE
var outside := VoxelPicking.NONE


func _ready() -> void:
	test("tools edit only inside the selection", _run)


func _run() -> void:
	step("Given a selected box around the center and the brush in add mode", func():
		viewport = editor_viewport()
		var container := viewport.get_parent()
		container.stretch = false
		viewport.size = Vector2i(800, 500)
		center = Vector2(400.0, 250.0)
		var start := aim(center)
		inside = start.target
		outside = aim(center + Vector2(0.0, 60.0)).target
		State.selection.from_box(inside - Vector3i(1, 1, 1), inside + Vector3i(1, 1, 1))
		State.selection_changed.emit()
		activate_tool("Toolbar")
		select_toolbar_item("Toolbar", "Pencil")
		State.current_color = Color.from_rgba8(200, 60, 60)
	)

	step("When the user clicks inside and outside the selection", func():
		_click(center)
		_click(center + Vector2(0.0, 60.0))
	)

	step("Then only the inside click painted a voxel", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.has(inside), "inside cell is painted")
		expect(not frame.has(outside), "outside cell is not painted")
	)

	step("Given paint mode with voxels inside and outside the selection", func():
		State.document.frames[0].clear()
		State.document.set_cell(0, inside, Color.from_rgba8(150, 150, 150))
		State.document.set_cell(0, outside, Color.from_rgba8(150, 150, 150))
		select_toolbar_item("Toolbar", "Paint")
		State.current_color = Color.from_rgba8(200, 60, 60)
	)

	step("When the user clicks both voxels in paint mode", func():
		_click(center)
		_click(center + Vector2(0.0, 60.0))
	)

	step("Then only the inside voxel is recolored", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.get_color(inside) == Color.from_rgba8(200, 60, 60), "inside voxel is recolored")
		expect(frame.get_color(outside) == Color.from_rgba8(150, 150, 150), "outside voxel keeps its color")
	)

	step("Given an eraser on the same two voxels", func():
		activate_tool("eraser")
	)

	step("When the user clicks both voxels with the eraser", func():
		_click(center)
		_click(center + Vector2(0.0, 60.0))
	)

	step("Then only the inside voxel is erased", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(not frame.has(inside), "inside voxel is erased")
		expect(frame.has(outside), "outside voxel remains")
	)

	step("Given a gray blob crossing the selection boundary and the fill tool", func():
		State.document.frames[0].clear()
		State.selection.from_box(inside, inside + Vector3i(0, 0, 1))
		State.selection_changed.emit()
		State.document.set_cell(0, inside, Color.from_rgba8(150, 150, 150))
		State.document.set_cell(0, inside + Vector3i(0, 0, 1), Color.from_rgba8(150, 150, 150))
		State.document.set_cell(0, inside + Vector3i(0, 0, 2), Color.from_rgba8(150, 150, 150))
		activate_tool("fill")
		State.current_color = Color.from_rgba8(200, 60, 60)
	)

	step("When the user fills the selected voxel", func():
		_click(center)
	)

	step("Then the fill stops at the selection boundary", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.get_color(inside) == Color.from_rgba8(200, 60, 60), "seed voxel is recolored")
		expect(frame.get_color(inside + Vector3i(0, 0, 1)) == Color.from_rgba8(200, 60, 60), "selected neighbor is recolored")
		expect(frame.get_color(inside + Vector3i(0, 0, 2)) == Color.from_rgba8(150, 150, 150), "unselected voxel keeps its color")
	)

	step("When the user clears the selection and paints outside it", func():
		State.selection.clear()
		State.selection_changed.emit()
		State.document.frames[0].clear()
		activate_tool("Toolbar")
		select_toolbar_item("Toolbar", "Pencil")
		_click(center + Vector2(0.0, 60.0))
	)

	step("Then painting works again without a selection", func():
		expect(State.document.frames[0].has(outside), "outside cell is painted")
	)


func _click(pos: Vector2) -> void:
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = pos
	viewport.push_input(click)
	click.pressed = false
	viewport.push_input(click)
