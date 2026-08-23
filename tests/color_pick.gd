extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("the pencil paints with the color picked in the toolbar", _run)


func _run() -> void:
	step("Given a pencil and an empty grid", func():
		_vp = editor_viewport(_inst)
		var svp := _vp.get_viewport()
		var container := svp.get_parent()
		container.stretch = false
		svp.size = Vector2i(800, 500)
		_center = Vector2(400.0, 250.0)
		State.set_tool(State.tools.pencil)
	)

	step("When the user picks a color in the toolbar", func():
		var picker := _inst.get_node("%PalettePanel").get_node("%ColorPicker") as ColorPicker
		picker.color = Color8(200, 60, 60)
		picker.color_changed.emit(picker.color)
	)

	step("Then the brush paints with the picked color", func():
		var req := _vp.pick_request(_center)
		var target := VoxelPicking.start_pick(req.origin, req.dir, req.cells, req.forward).target
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.position = _center
		_vp.get_viewport().push_input(click)
		click.pressed = false
		_vp.get_viewport().push_input(click)
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.cells.has(target), "the clicked cell is painted")
		expect(State.document.color_of(frame.cells[target]) == Color8(200, 60, 60), "the painted cell has the picked color")
	)
