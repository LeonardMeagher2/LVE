extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _cell := State.NONE


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("nudges with ui actions and deletes with the delete action", _run)


func _run() -> void:
	step("Given a selected voxel and the move tool", func():
		_vp = _inst.get_node("Content/Root/Body/CenterPane/ViewportContainer/Viewport/Editor")
		var svp := _vp.get_viewport()
		var container := svp.get_parent()
		container.stretch = false
		svp.size = Vector2i(800, 500)
		_center = Vector2(400.0, 250.0)
		_cell = aim(_vp, _center).target
		State.document.frames[0].cells[_cell] = State.document.ensure_color(State.current_color)
		State.selection.add(_cell)
		_vp.sync_to(0)
		State.set_tool(State.tools.move)
	)

	step("When the user presses ui_left", func():
		_press_action("ui_left")
	)

	step("Then the voxel moved left", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(not frame.cells.has(_cell), "original cell is cleared")
		expect(frame.cells.has(_cell + Vector3i(-1, 0, 0)), "voxel moved left")
	)

	step("When the user presses the delete action", func():
		_press_action("delete")
	)

	step("Then the selection is erased", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(not frame.cells.has(_cell + Vector3i(-1, 0, 0)), "moved voxel is erased")
		expect(frame.cells.is_empty(), "frame is empty")
	)


func _press_action(action: String) -> void:
	var key := InputEventKey.new()
	match action:
		"ui_left":
			key.keycode = KEY_LEFT
		"delete":
			key.physical_keycode = KEY_DELETE
	key.pressed = true
	_vp.get_viewport().push_input(key)
