extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO


func _ready() -> void:
	test("the pencil paints with the color picked in the toolbar", _run)


func _run() -> void:
	step("Given a pencil and an empty grid", func():
		viewport = editor_viewport()
		var container := viewport.get_parent()
		container.stretch = false
		viewport.size = Vector2i(800, 500)
		center = Vector2(400.0, 250.0)
		activate_tool("Toolbar")
	)

	step("When the user picks a color in the toolbar", func():
		var panel := main.find_child("PalettePanel", true, false)
		var picker := panel.get_node("%ColorPicker") as ColorPicker
		picker.color = Color.from_rgba8(200, 60, 60)
		picker.color_changed.emit(picker.color)
	)

	step("Then the brush paints with the picked color", func():
		var req := pick_request(center)
		var target := VoxelPicking.start_pick(req.origin, req.dir, req.frame, req.forward).target
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.position = center
		viewport.push_input(click)
		click.pressed = false
		viewport.push_input(click)
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.has(target), "the clicked cell is painted")
		expect(frame.get_color(target) == Color.from_rgba8(200, 60, 60), "the painted cell has the picked color")
	)
