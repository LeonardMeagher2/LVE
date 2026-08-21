extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _far_pick := State.NONE


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("the canvas is unbounded", _run)


func _run() -> void:
	step("Given an empty editor", func():
		_vp = _inst.get_node("Content/Root/Body/CenterPane/ViewportContainer/Viewport/Editor")
	)

	step("When the user paints a cell beyond the original 16x16 extent", func():
		State.document.paint(0, Vector3i(20, 0, 20), State.current_color)
		State.cells_changed.emit()
	)

	step("Then the cell persists and the bounds expand", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.cells.has(Vector3i(20, 0, 20)), "the far cell is stored")
		var b := State.document.bounds()
		expect(b.has_volume(), "the bounds cover the content")
		expect(int(b.end.x) - 1 == 20, "the bounds reach the painted column")
	)

	step("When the user box-selects a region with negative coordinates", func():
		State.selection.from_box(Vector3i(-2, 0, -3), Vector3i(1, 2, 1))
	)

	step("Then the selection keeps the out-of-bounds cells", func():
		expect(State.selection.contains(Vector3i(-2, 0, -3)), "the selection has the negative corner")
		expect(State.selection.contains(Vector3i(1, 2, 1)), "the selection has the positive corner")
	)

	step("When the user aims at the floor past the original grid", func():
		_far_pick = VoxelPicking.ground_pick(Vector3(30, 10, 30), Vector3(0, -1, 0)).target
	)

	step("Then the pick lands on the far floor cell", func():
		expect(_far_pick == Vector3i(30, 0, 30), "the pick reaches beyond the old grid")
	)
