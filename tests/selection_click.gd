extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _cell := State.NONE
var _empty_cell := State.NONE


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("a click on a voxel or an empty cell selects that cell", _run)


func _run() -> void:
	step("Given the select tool and one voxel at the center", func():
		_vp = editor_viewport(_inst)
		State.set_tool(State.tools.select)
		var svp := _vp.get_viewport()
		var vsize: Vector2i = svp.size
		if vsize.x <= 0 or vsize.y <= 0:
			svp.size = Vector2i(800, 500)
			vsize = svp.size
		_center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
		_cell = aim(_vp, _center).target
		var f: VoxelFrame = State.document.frames[State.current_frame]
		f.cells[_cell] = State.document.ensure_color(Color8(150, 150, 150))
	)

	step("When the user clicks the voxel", func():
		_click(_center)
	)

	step("Then the clicked voxel is selected", func():
		expect(State.selection.cells.size() == 1, "selection holds one cell")
		expect(State.selection.contains(_cell), "the clicked cell is selected")
	)

	step("When the user clicks the voxel again", func():
		_click(_center)
	)

	step("Then the selection stays on that voxel", func():
		expect(State.selection.contains(_cell), "the clicked cell stays selected")
	)

	step("When the user clicks an empty cell", func():
		var empty := _empty_screen_pos()
		expect(empty != Vector2.INF, "an empty cell screen position exists")
		_empty_cell = aim(_vp, empty).target
		_click(empty)
	)

	step("Then that empty cell is selected", func():
		expect(State.selection.cells.size() == 1, "selection holds one cell")
		expect(State.selection.contains(_empty_cell), "the empty cell is selected")
	)


func _click(pos: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	_vp.get_viewport().push_input(press)
	press.pressed = false
	_vp.get_viewport().push_input(press)


func _empty_screen_pos() -> Vector2:
	var svp := _vp.get_viewport()
	for dy in range(int(svp.size.y) - 20, 0, -40):
		for dx in range(20, int(svp.size.x), 40):
			var res := aim(_vp, Vector2(dx, dy))
			if res.target != State.NONE and res.hit == State.NONE:
				return Vector2(dx, dy)
	return Vector2.INF
