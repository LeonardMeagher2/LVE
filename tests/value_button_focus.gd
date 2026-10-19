extends "res://tests/test.gd"

var field: Button
var gui_releases := 0


func _ready() -> void:
	test("a value drag hands the pointer release to the GUI", _run)


func _run() -> void:
	step("Given a diameter button", func():
		main.set_ui_scale(1.0, false)
		field = plugin("BrushPlugin")._options.get_node("Diameter")
		field.value = 1.0
		field.gui_input.connect(_on_field_gui_input)
	)

	step("When the user drags the diameter button", func():
		var start: Vector2 = field.get_global_rect().get_center()
		_button(start, true)
		_motion(start + Vector2(8, 0), Vector2(8, 0), MOUSE_BUTTON_MASK_LEFT)
		_motion(start + Vector2(40, 0), Vector2(32, 0), MOUSE_BUTTON_MASK_LEFT)
		_button(start + Vector2(40, 0), false)
	)

	step("Then the drag changes the diameter and finishes", func():
		expect(field.value == 14.0, "forty pixels raises the diameter from one to fourteen")
		expect(not field.get_line_edit().visible and not field.get_node("Fill").visible, "the release returns to the value button")
	)

	step("Then the GUI receives the release and clears the pointer capture", func():
		# The GUI holds the pointer on the pressed button until it processes the
		# release. A release that the input stage consumes never reaches the GUI,
		# so the button keeps the pointer. The viewport then receives no motion,
		# and the tool cursor stops following the mouse.
		expect(gui_releases == 1, "the button receives the release in the GUI stage")
	)


func _on_field_gui_input(event: InputEvent) -> void:
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
