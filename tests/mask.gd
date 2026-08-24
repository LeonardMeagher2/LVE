extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _inside := State.NONE
var _outside := State.NONE
var _plane: StrokePlane


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("tools edit only inside the selection", _run)


func _run() -> void:
	step("Given a selected box around the center and the brush in add mode", func():
		_vp = editor_viewport(_inst)
		var svp := _vp.get_viewport()
		var container := svp.get_parent()
		container.stretch = false
		svp.size = Vector2i(800, 500)
		_center = Vector2(400.0, 250.0)
		var start := aim(_vp, _center)
		_plane = start.plane
		_inside = start.target
		_outside = drag(_vp, _center + Vector2(0.0, 60.0), _plane).target
		State.selection.from_box(_inside - Vector3i(2, 2, 2), _inside + Vector3i(2, 2, 2))
		State.selection_changed.emit()
		State.set_tool(State.tools.pencil)
		State.current_color = Color8(200, 60, 60)
	)

	step("When the user clicks inside and outside the selection", func():
		_click(_center)
		_click(_center + Vector2(0.0, 60.0))
	)

	step("Then only the inside click painted a voxel", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.cells.has(_inside), "inside cell is painted")
		expect(not frame.cells.has(_outside), "outside cell is not painted")
	)

	step("Given paint mode with voxels inside and outside the selection", func():
		State.document.frames[0].cells.clear()
		State.document.frames[0].cells[_inside] = State.document.add_color(Color8(150, 150, 150))
		State.document.frames[0].cells[_outside] = State.document.add_color(Color8(150, 150, 150))
		State.set_tool(State.tools.paint_brush)
		State.current_color = Color8(200, 60, 60)
	)

	step("When the user clicks both voxels in paint mode", func():
		_click(_center)
		_click(_center + Vector2(0.0, 60.0))
	)

	step("Then only the inside voxel is recolored", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(State.document.color_of(frame.cells[_inside]) == Color8(200, 60, 60), "inside voxel is recolored")
		expect(State.document.color_of(frame.cells[_outside]) == Color8(150, 150, 150), "outside voxel keeps its color")
	)

	step("Given an eraser on the same two voxels", func():
		State.set_tool(State.tools.eraser)
	)

	step("When the user clicks both voxels with the eraser", func():
		_click(_center)
		_click(_center + Vector2(0.0, 60.0))
	)

	step("Then only the inside voxel is erased", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(not frame.cells.has(_inside), "inside voxel is erased")
		expect(frame.cells.has(_outside), "outside voxel remains")
	)

	step("Given a gray blob crossing the selection boundary and the fill tool", func():
		State.document.frames[0].cells.clear()
		State.selection.from_box(_inside, _inside + Vector3i(0, 0, 1))
		State.selection_changed.emit()
		State.document.frames[0].cells[_inside] = State.document.add_color(Color8(150, 150, 150))
		State.document.frames[0].cells[_inside + Vector3i(0, 0, 1)] = State.document.add_color(Color8(150, 150, 150))
		State.document.frames[0].cells[_inside + Vector3i(0, 0, 2)] = State.document.add_color(Color8(150, 150, 150))
		State.set_tool(State.tools.fill)
		State.current_color = Color8(200, 60, 60)
	)

	step("When the user fills the selected voxel", func():
		_click(_center)
	)

	step("Then the fill stops at the selection boundary", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(State.document.color_of(frame.cells[_inside]) == Color8(200, 60, 60), "seed voxel is recolored")
		expect(State.document.color_of(frame.cells[_inside + Vector3i(0, 0, 1)]) == Color8(200, 60, 60), "selected neighbor is recolored")
		expect(State.document.color_of(frame.cells[_inside + Vector3i(0, 0, 2)]) == Color8(150, 150, 150), "unselected voxel keeps its color")
	)

	step("When the user clears the selection and paints outside it", func():
		State.selection.clear()
		State.selection_changed.emit()
		State.document.frames[0].cells.clear()
		State.set_tool(State.tools.pencil)
		_click(_center + Vector2(0.0, 60.0))
	)

	step("Then painting works again without a selection", func():
		expect(State.document.frames[0].cells.has(_outside), "outside cell is painted")
	)


func _click(pos: Vector2) -> void:
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = pos
	_vp.get_viewport().push_input(click)
	click.pressed = false
	_vp.get_viewport().push_input(click)
