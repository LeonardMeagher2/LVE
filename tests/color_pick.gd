extends "res://tests/test.gd"

var viewport: SubViewport
var center := Vector2.ZERO
var original_material := VoxelFrame.material(Color.BLUE)


func _ready() -> void:
	test("the color picker edits the brush material without changing the palette or existing voxels", _run)


func _run() -> void:
	step("Given a pencil and an empty grid", func():
		viewport = editor_viewport()
		var container := viewport.get_parent()
		container.stretch = false
		viewport.size = Vector2i(800, 500)
		center = Vector2(400.0, 250.0)
		activate_tool("Toolbar")
		State.set_palette([original_material])
		State.select_palette_entry(0)
		expect(State.current_palette_index == 0, "the blue swatch starts selected")
		State.get_current_voxel_frame().set_cell(Vector3i(24, 0, 0), original_material)
	)

	step("When the user picks a color in the toolbar", func():
		var panel := main.find_child("PalettePanel", true, false)
		var picker := panel.get_node("%ColorPicker") as ColorPicker
		picker.color = Color.from_rgba8(200, 60, 60)
		picker.color_changed.emit(picker.color)
	)
	step("Then the brush material changes without changing the palette", func():
		var picked := VoxelFrame.material(Color.from_rgba8(200, 60, 60), Color.BLACK, 0.0, 1.0)
		expect(State.current_material == picked, "the picker supplies the future brush material")
		expect(State.current_palette_index == -1, "a picked color selects no saved swatch")
		expect(State.get_palette() == [original_material], "picking a color preserves every saved swatch")
		var frame := State.get_current_voxel_frame()
		var marker := Vector3i(24, 0, 0)
		expect(frame.get_color(marker) == VoxelFrame.material_color(original_material), "the existing voxel retains its original color")
		expect(frame.get_emission(marker) == Color.BLACK and frame.get_metallic(marker) == 0.0 and frame.get_roughness(marker) == 1.0, "the existing voxel retains its original material values")
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
