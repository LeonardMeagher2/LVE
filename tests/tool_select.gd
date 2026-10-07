extends "res://tests/test.gd"

var brush_button: MenuButton


func _ready() -> void:
	test("the tool menu button selects on the first click and opens its menu on the second", _run)


func _run() -> void:
	step("Given the inactive brush tool button", func():
		for b in main.get_node("%ToolBar").get_children():
			if b is MenuButton and b.tooltip_text == "Brush tools":
				brush_button = b
				break
		expect(brush_button != null, "the brush tool is a menu button")
		brush_button.button_pressed = false
	)

	step("When the user clicks the inactive button", func():
		_click(brush_button)
	)

	step("Then the tool activates and the menu stays closed", func():
		expect(brush_button.button_pressed, "the button is pressed")
		expect(not brush_button.get_popup().is_visible(), "the menu stays closed")
	)

	step("When the user clicks the active button", func():
		_click(brush_button)
	)

	step("Then the menu opens", func():
		expect(brush_button.get_popup().is_visible(), "the menu opens")
		expect(brush_button.button_pressed, "the button stays pressed")
	)

	step("When the user dismisses the menu", func():
		brush_button.get_popup().hide()
	)

	step("Then the tool stays active", func():
		expect(brush_button.button_pressed, "the button stays pressed after the menu closes")
	)


func _click(button: Control) -> void:
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.position = button.get_global_rect().get_center()
	click.pressed = true
	get_tree().root.push_input(click, true)
	click.pressed = false
	get_tree().root.push_input(click, true)
