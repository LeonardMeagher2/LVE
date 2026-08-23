extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _anchor := State.NONE
var _front := State.NONE


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("the brush adds voxels in front of the clicked face or recolors them in paint mode", _run)


func _run() -> void:
	step("Given a gray voxel where the center ray lands and the brush in add mode", func():
		_vp = editor_viewport(_inst)
		var svp := _vp.get_viewport()
		var container := svp.get_parent()
		container.stretch = false
		svp.size = Vector2i(800, 500)
		_center = Vector2(400.0, 250.0)
		State.set_tool(State.tools.brush)
		State.current_color = Color8(200, 60, 60)
		_anchor = aim(_vp, _center).target
		State.document.frames[0].cells[_anchor] = State.document.ensure_color(Color8(150, 150, 150))
		_vp.sync_to(0)
		_front = aim(_vp, _center).add_target
	)

	step("When the user clicks the center of the viewport", func():
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.position = _center
		_vp.get_viewport().push_input(click)
		click.pressed = false
		_vp.get_viewport().push_input(click)
	)

	step("Then a voxel appears in front of the clicked face", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.cells.has(_front), "a voxel is added beside the clicked voxel")
	)

	step("When the user switches to paint mode and clicks the front voxel", func():
		State.set_tool(State.tools.brush_paint)
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.position = _center
		_vp.get_viewport().push_input(click)
		click.pressed = false
		_vp.get_viewport().push_input(click)
	)

	step("Then the front voxel is recolored and no voxel is added", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.cells.size() == 2, "paint mode adds no new voxels")
		expect(State.document.color_of(frame.cells[_front]) == Color8(200, 60, 60), "the front voxel has the brush color")
	)

	step("When the user clears the grid and clicks the empty grid in paint mode", func():
		State.document.frames[0].cells.clear()
		_vp.sync_to(0)
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.position = _center
		_vp.get_viewport().push_input(click)
		click.pressed = false
		_vp.get_viewport().push_input(click)
	)

	step("Then paint mode leaves the empty grid unchanged", func():
		expect(State.document.frames[0].cells.is_empty(), "no voxel is painted on empty cells")
	)
