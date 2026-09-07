extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO
var pick_target := VoxelPicking.NONE


func _ready() -> void:
	test("can paint with the mouse at the cursor using the brush color", _run)


func _run() -> void:
	step("Given an editor with a red brush and a voxel viewport", func():
		State.current_color = Color.from_rgba8(200, 60, 60)
		viewport = editor_viewport()
		var vsize: Vector2i = viewport.size
		if vsize.x <= 0 or vsize.y <= 0:
			viewport.size = Vector2i(800, 500)
			vsize = viewport.size
		center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
	)

	step("When the user clicks the center of the viewport", func():
		var req := pick_request(center)
		pick_target = VoxelPicking.start_pick(req.origin, req.dir, req.cells, req.forward).target
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.position = center
		viewport.push_input(click)
		click.pressed = false
		viewport.push_input(click)
	)

	step("Then the clicked cell is painted with the brush color", func():
		expect(State.document.frames[0].cells.has(pick_target), "clicked cell is painted")
		expect(State.document.frames[0].cells[pick_target] == Color.from_rgba8(200, 60, 60), "painted cell has the brush color")
	)
