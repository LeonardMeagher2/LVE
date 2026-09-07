extends "res://tests/test.gd"

var brush_button: MenuButton


func _ready() -> void:
	test("the brush button lists its modes and switches tools", _run)


func _run() -> void:
	step("Given the toolbar with a brush menu button", func():
		for b in main.get_node("%ToolBar").get_children():
			if b is MenuButton and b.tooltip_text == "Pencil and paint tools":
				brush_button = b
				break
		expect(brush_button != null, "the brush tool is a menu button")
	)

	step("Then its popup lists the brush modes", func():
		var popup := brush_button.get_popup()
		expect(popup.item_count == 2, "the menu lists both brush modes")
		expect(popup.get_item_text(0) == "Pencil", "first mode is Pencil")
		expect(popup.get_item_text(1) == "Paint", "second mode is Paint")
	)

	step("When the user selects the paint mode", func():
		brush_button.get_popup().index_pressed.emit(1)
	)

	step("Then the paint mode is active and the button shows it", func():
		expect(brush_button.get_popup().get_item_icon(1) == brush_button.icon, "the button shows the active mode icon")
	)
