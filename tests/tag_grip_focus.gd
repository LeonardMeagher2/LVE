extends "res://tests/test.gd"

var cell: Node
var gui_releases := 0


func _ready() -> void:
	timeout = 20.0
	test("a tag grip drag hands the pointer release to the GUI", _run)


func _grid() -> Node:
	return main.find_child("FrameGrid", true, false)


func _range_cells() -> Array:
	var out: Array = []
	for child in _grid().get_children():
		if not child is AnimationFrame:
			out.append(child)
	return out


func _run() -> void:
	step("Given four frames and the default tag over all of them", func():
		main.set_ui_scale(1.0, false)
		State.set_document(VoxelDocument.new())
		State.add_frame()
		State.add_frame()
		State.add_frame()
	)
	await get_tree().process_frame
	await get_tree().process_frame

	step("Then the end grip is on the last frame", func():
		var cells := _range_cells()
		expect(cells.size() == 4, "four range cells are shown")
		expect(cells[3].get_node("%EndGrip").is_visible_in_tree(), "the end grip is visible")
		cell = cells[3]
		cell.gui_input.connect(_on_cell_gui_input)
	)

	step("When the user drags the end grip to the third frame", func():
		var cells := _range_cells()
		var start: Vector2 = cells[3].get_global_rect().get_center()
		var target: Vector2 = cells[2].get_global_rect().get_center()
		_button(start, true)
		_motion(target, target - start, MOUSE_BUTTON_MASK_LEFT)
		_button(target, false)
	)

	step("Then the tag ends on the third frame", func():
		expect(State.document.tags[0].to == 2, "the tag ends on the third frame")
	)

	step("Then the GUI receives the release and clears the pointer capture", func():
		# The GUI holds the pointer on the pressed cell until it processes the
		# release. A release that the input stage consumes never reaches the GUI,
		# so the cell keeps the pointer. The viewport then receives no motion,
		# and the tool cursor stops following the mouse.
		expect(gui_releases == 1, "the cell receives the release in the GUI stage")
	)


func _on_cell_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		gui_releases += 1


func _button(position: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.position = position
	event.global_position = position
	get_tree().root.push_input(event)


func _motion(position: Vector2, relative: Vector2, mask: int) -> void:
	var event := InputEventMouseMotion.new()
	event.button_mask = mask
	event.position = position
	event.global_position = position
	event.relative = relative
	get_tree().root.push_input(event)
