extends "res://tests/test.gd"

var brush_button: MenuButton


func _ready() -> void:
	test("the brush button lists its modes and switches tools", _run)


func _run() -> void:
	step("Given the toolbar with a brush menu button", func():
		for b in main.get_node("%ToolBar").get_children():
			if b is MenuButton and b.tooltip_text == "Brush tools":
				brush_button = b
				break
		expect(brush_button != null, "the brush tool is a menu button")
	)

	step("Then its popup lists the brush modes", func():
		var popup := brush_button.get_popup()
		expect(popup.item_count == 4, "the menu lists all four brush modes")
		expect(popup.get_item_text(0) == "Pencil", "first mode is Pencil")
		expect(popup.get_item_text(1) == "Paint", "second mode is Paint")
		expect(popup.get_item_text(2) == "Line", "third mode is Line")
		expect(popup.get_item_text(3) == "Eraser", "fourth mode is Eraser")
	)

	step("When the user selects the paint mode", func():
		brush_button.get_popup().index_pressed.emit(1)
	)

	step("Then the paint mode is active and the button shows it", func():
		expect(brush_button.get_popup().get_item_icon(1) == brush_button.icon, "the button shows the active mode icon")
	)
	step("When the user selects the line mode", func():
		brush_button.get_popup().index_pressed.emit(2)
	)
	step("Then the line uses the brush button and shared options", func():
		expect(brush_button.get_popup().get_item_icon(2) == brush_button.icon, "the button shows the line icon")
		expect(plugin("BrushPlugin")._tool.name == "LineTool", "the line tool is active in the brush plugin")
		expect(plugin("BrushPlugin")._options.is_inside_tree(), "the shared brush options are visible")
	)
	step("When the user selects the eraser mode", func():
		brush_button.get_popup().index_pressed.emit(3)
	)
	step("Then the eraser uses the brush button and shared options", func():
		expect(brush_button.get_popup().get_item_icon(3) == brush_button.icon, "the brush button shows the eraser icon")
		expect(plugin("BrushPlugin")._tool == plugin("BrushPlugin")._brush_tool, "the eraser uses the brush stroke tool")
		expect(plugin("EraserPlugin") == null, "the eraser is part of the brush plugin")
	)
	step("When the user selects Pencil and presses the eraser shortcut", func():
		brush_button.get_popup().index_pressed.emit(0)
		var event := InputEventKey.new()
		event.physical_keycode = KEY_E
		event.pressed = true
		brush_button._shortcut_input(event)
	)
	step("Then the eraser shortcut selects the eraser brush mode", func():
		expect(brush_button.icon == brush_button.get_popup().get_item_icon(3), "the eraser shortcut shows the eraser icon")
	)
	step("When the user selects Pencil and presses the paint shortcut", func():
		brush_button.get_popup().index_pressed.emit(0)
		var event := InputEventKey.new()
		event.physical_keycode = KEY_P
		event.pressed = true
		brush_button._shortcut_input(event)
	)
	step("Then the paint shortcut selects the paint brush mode", func():
		expect(brush_button.icon == brush_button.get_popup().get_item_icon(1), "the paint shortcut shows the paint icon")
	)
	step("When the user selects Pencil and presses the line shortcut", func():
		brush_button.get_popup().index_pressed.emit(0)
		var event := InputEventKey.new()
		event.physical_keycode = KEY_L
		event.pressed = true
		brush_button._shortcut_input(event)
	)
	step("Then the line shortcut selects the line brush mode", func():
		expect(brush_button.icon == brush_button.get_popup().get_item_icon(2), "the line shortcut shows the line icon")
		expect(plugin("BrushPlugin")._tool.name == "LineTool", "the line shortcut activates the line tool")
	)
