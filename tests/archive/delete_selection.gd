extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _cell := State.NONE


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("pressing delete erases the voxels inside the selection", _run)


func _run() -> void:
	step("Given a painted voxel and a selection with the pencil tool", func():
		_vp = editor_viewport(_inst)
		State.set_tool(State.tools.pencil)
		var svp := _vp.get_viewport()
		var container := svp.get_parent()
		container.stretch = false
		svp.size = Vector2i(800, 500)
		_center = Vector2(400.0, 250.0)
		_cell = aim(_vp, _center).target
		State.document.set_cell(State.current_frame, _cell, State.current_color)
		State.selection.add(_cell)
	)

	step("When the user presses delete", func():
		var key := InputEventKey.new()
		key.physical_keycode = KEY_DELETE
		key.pressed = true
		get_tree().root.push_input(key)
	)

	step("Then the selected voxels are gone but the selection stays", func():
		expect(not State.document.has_cell(State.current_frame, _cell), "the selected cell is erased")
		expect(State.selection.contains(_cell), "the selection remains after delete")
	)

	step("When the user undoes", func():
		State.undo_redo.undo()
	)

	step("Then the voxels come back", func():
		expect(State.document.has_cell(State.current_frame, _cell), "the erased cell returns after undo")
	)
