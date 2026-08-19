extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("the eraser highlight is always visible", _run)


func _run() -> void:
	step("Given an eraser on an empty grid", func():
		_vp = _inst.get_node("Root/Body/CenterPane/ViewportContainer/Viewport/Editor")
		var svp := _vp.get_viewport()
		var container := svp.get_parent()
		container.stretch = false
		svp.size = Vector2i(800, 500)
		_center = Vector2(400.0, 250.0)
		State.set_tool(State.tools.eraser)
	)

	step("When the user hovers the empty grid", func():
		var motion := InputEventMouseMotion.new()
		motion.position = _center
		motion.button_mask = 0
		_vp.get_viewport().push_input(motion)
	)

	step("Then the highlight is visible at the cursor cell", func():
		var v: Node3D = _vp._tool.visual
		var req := _vp.pick_request(_center)
		var target := VoxelPicking.start_pick(req.origin, req.dir, req.cells).target
		expect(v.visible, "the highlight is visible")
		expect(v.position == Vector3(target), "the highlight is at the cursor cell")
	)
