extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("a click selects one cell or cancels an existing selection", _run)


func _run() -> void:
	step("Given the select tool on an empty grid", func():
		_vp = editor_viewport(_inst)
		State.set_tool(State.tools.select)
		var svp := _vp.get_viewport()
		var vsize: Vector2i = svp.size
		if vsize.x <= 0 or vsize.y <= 0:
			svp.size = Vector2i(800, 500)
			vsize = svp.size
		_center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
	)

	step("When the user clicks without dragging", func():
		_click()
	)

	step("Then a one-cell selection exists", func():
		expect(not State.selection.is_empty(), "selection is not empty")
		var req := _vp.pick_request(_center)
		var cell := VoxelPicking.start_pick(req.origin, req.dir, req.cells, req.forward).target
		expect(State.selection.cells.size() == 1, "selection holds one cell")
		expect(State.selection.contains(cell), "the clicked cell is selected")
	)

	step("When the user clicks again without dragging", func():
		_click()
	)

	step("Then the selection is canceled", func():
		expect(State.selection.is_empty(), "selection is empty")
	)

	step("When the user clicks yet again", func():
		_click()
	)

	step("Then a one-cell selection exists again", func():
		expect(State.selection.cells.size() == 1, "selection holds one cell")
	)


func _click() -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = _center
	_vp.get_viewport().push_input(press)
	press.pressed = false
	_vp.get_viewport().push_input(press)
