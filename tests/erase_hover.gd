extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO


func _ready() -> void:
	test("the eraser highlight is always visible", _run)


func _run() -> void:
	step("Given an eraser on an empty grid", func():
		viewport = editor_viewport()
		var container := viewport.get_parent()
		container.stretch = false
		viewport.size = Vector2i(800, 500)
		center = Vector2(400.0, 250.0)
		select_toolbar_item("Toolbar", "Eraser")
	)

	step("When the user hovers the empty grid", func():
		var motion := InputEventMouseMotion.new()
		motion.position = center
		motion.button_mask = 0
		viewport.push_input(motion)
	)

	step("Then the highlight is visible at the cursor cell", func():
		var v: Node3D = active_tool_node("BrushPlugin")
		var req := pick_request(center)
		var target := VoxelPicking.start_pick(req.origin, req.dir, req.frame, req.forward).target
		expect(v.visible, "the highlight is visible")
		expect(v.get_node("Cursor").mesh.surface_get_primitive_type(0) == Mesh.PRIMITIVE_LINES, "the eraser preview uses an outline mesh")
		expect(v.position == Vector3(target), "the highlight is at the cursor cell")
	)
