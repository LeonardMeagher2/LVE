extends "res://tests/test.gd"

var brush_button: MenuButton
var paint_button: MenuButton


func _ready() -> void:
	test("the brush and paint buttons list their tools and switch tools", _run)


func _run() -> void:
	step("Given the toolbar with a brush menu button and a paint menu button", func():
		for b in main.get_node("%ToolBar").get_children():
			if b is MenuButton and b.tooltip_text == "Brush tools":
				brush_button = b
			elif b is MenuButton and b.tooltip_text == "Paint tools":
				paint_button = b
		expect(brush_button != null, "the brush tool is a menu button")
		expect(paint_button != null, "the paint tool is a menu button")
	)

	step("Then the brush popup lists the brush modes", func():
		var popup := brush_button.get_popup()
		expect(popup.item_count == 3, "the menu lists the three brush modes")
		expect(popup.get_item_text(0) == "Pencil", "first mode is Pencil")
		expect(popup.get_item_text(1) == "Line", "second mode is Line")
		expect(popup.get_item_text(2) == "Eraser", "third mode is Eraser")
	)
	step("And the paint popup lists the paint tools", func():
		var popup := paint_button.get_popup()
		expect(popup.item_count == 3, "the menu lists the three paint tools")
		expect(popup.get_item_text(0) == "Paintbrush", "first tool is Paintbrush")
		expect(popup.get_item_text(1) == "Bucket Fill", "second tool is Bucket Fill")
		expect(popup.get_item_text(2) == "Spray Can", "third tool is Spray Can")
	)

	step("When the user selects the line mode", func():
		brush_button.get_popup().index_pressed.emit(1)
	)
	step("Then the line uses the brush button and shared options", func():
		expect(brush_button.get_popup().get_item_icon(1) == brush_button.icon, "the button shows the line icon")
		expect(plugin("BrushPlugin")._tool.name == "LineTool", "the line tool is active in the brush plugin")
		expect(plugin("BrushPlugin")._options.is_inside_tree(), "the shared brush options are visible")
	)
	step("When the user selects the eraser mode", func():
		brush_button.get_popup().index_pressed.emit(2)
	)
	step("Then the eraser uses the brush button and shared options", func():
		expect(brush_button.get_popup().get_item_icon(2) == brush_button.icon, "the brush button shows the eraser icon")
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
		expect(brush_button.icon == brush_button.get_popup().get_item_icon(2), "the eraser shortcut shows the eraser icon")
	)
	step("When the user selects Pencil and presses the line shortcut", func():
		brush_button.get_popup().index_pressed.emit(0)
		var event := InputEventKey.new()
		event.physical_keycode = KEY_L
		event.pressed = true
		brush_button._shortcut_input(event)
	)
	step("Then the line shortcut selects the line brush mode", func():
		expect(brush_button.icon == brush_button.get_popup().get_item_icon(1), "the line shortcut shows the line icon")
		expect(plugin("BrushPlugin")._tool.name == "LineTool", "the line shortcut activates the line tool")
	)
	step("When the user presses the paint shortcut", func():
		var event := InputEventKey.new()
		event.physical_keycode = KEY_P
		event.pressed = true
		paint_button._shortcut_input(event)
	)
	step("Then the paint shortcut selects the paintbrush", func():
		expect(paint_button.icon == paint_button.get_popup().get_item_icon(0), "the paint shortcut shows the paintbrush icon")
		expect(plugin("PaintPlugin")._tool == plugin("PaintPlugin")._paintbrush_tool, "the paintbrush is active in the paint plugin")
		expect(plugin("PaintPlugin")._options.is_inside_tree(), "the paint options are visible")
	)
	step("When the user selects the bucket fill tool", func():
		paint_button.get_popup().index_pressed.emit(1)
	)
	step("Then the fill tool uses the paint button and its options", func():
		expect(paint_button.get_popup().get_item_icon(1) == paint_button.icon, "the button shows the bucket fill icon")
		expect(plugin("PaintPlugin")._tool == plugin("PaintPlugin")._fill_tool, "the fill tool is active in the paint plugin")
		expect(plugin("FillPlugin") == null, "the fill plugin is gone")
	)
	step("When the user selects the paintbrush and presses the spray shortcut", func():
		paint_button.get_popup().index_pressed.emit(0)
		var event := InputEventKey.new()
		event.physical_keycode = KEY_T
		event.pressed = true
		paint_button._shortcut_input(event)
	)
	step("Then the spray shortcut selects the spray can", func():
		expect(paint_button.icon == paint_button.get_popup().get_item_icon(2), "the spray shortcut shows the spray icon")
		expect(plugin("PaintPlugin")._tool == plugin("PaintPlugin")._spray_tool, "the spray can is active in the paint plugin")
	)
	step("When the user selects the paintbrush and presses the fill shortcut", func():
		paint_button.get_popup().index_pressed.emit(0)
		var event := InputEventKey.new()
		event.physical_keycode = KEY_F
		event.pressed = true
		paint_button._shortcut_input(event)
	)
	step("Then the fill shortcut selects the bucket fill", func():
		expect(paint_button.icon == paint_button.get_popup().get_item_icon(1), "the fill shortcut shows the bucket fill icon")
		expect(plugin("PaintPlugin")._tool == plugin("PaintPlugin")._fill_tool, "the bucket fill is active in the paint plugin")
	)
	step("When the user selects the eraser mode on the brush", func():
		brush_button.get_popup().index_pressed.emit(2)
	)
	step("Then the shared group releases the paint button", func():
		expect(not paint_button.button_pressed, "the brush replaces the paint tool")
		expect(plugin("BrushPlugin")._tool == plugin("BrushPlugin")._brush_tool, "the brush stroke tool is active")
	)
	step("When the user selects the bucket fill tool again", func():
		paint_button.get_popup().index_pressed.emit(1)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the clipboard options attach to the paint option bar", func():
		var clipboard_options: Node = plugin("ClipboardPlugin")._options
		expect(clipboard_options.get_parent() == plugin("PaintPlugin")._options, "the clipboard options follow the active paint tool")
	)

	step("Given the user selects the pencil brush mode", func():
		brush_button.get_popup().index_pressed.emit(0)
		expect(plugin("BrushPlugin")._options.is_inside_tree(), "the brush options are visible")
	)
	step("When the user changes the brush diameter and shape", func():
		var options: Node = plugin("BrushPlugin")._options
		options.get_node("Diameter").set("value", 6.0)
		(options.get_node("Shape/Sphere") as BaseButton).pressed.emit()
	)
	step("Then the brush settings hold the new diameter and shape", func():
		var settings = plugin("BrushPlugin")._settings
		expect(settings.diameter == 6, "the brush diameter is six")
		expect(settings.shape == BrushToolSettings.BrushShape.SPHERE, "the brush shape is the sphere")
	)
	step("When the user switches to the paintbrush", func():
		paint_button.get_popup().index_pressed.emit(0)
	)
	step("Then the paint settings keep their defaults", func():
		var settings = plugin("PaintPlugin")._settings
		expect(settings.diameter == 1, "the paint diameter keeps its default")
		expect(settings.shape == PaintToolSettings.BrushShape.CUBE, "the paint shape keeps its default cube")
	)
	step("When the user changes the paint diameter and shape", func():
		var options: Node = plugin("PaintPlugin")._options
		options.get_node("Brush/Diameter").set("value", 9.0)
		(options.get_node("Brush/Shape/Sphere") as BaseButton).pressed.emit()
	)
	step("Then the paint settings hold the new diameter and shape", func():
		var settings = plugin("PaintPlugin")._settings
		expect(settings.diameter == 9, "the paint diameter is nine")
		expect(settings.shape == PaintToolSettings.BrushShape.SPHERE, "the paint shape is the sphere")
	)
	step("When the user switches back to the brush", func():
		brush_button.get_popup().index_pressed.emit(0)
	)
	step("Then the brush keeps its own values", func():
		var settings = plugin("BrushPlugin")._settings
		expect(settings.diameter == 6, "the brush diameter is still six")
		expect(settings.shape == BrushToolSettings.BrushShape.SPHERE, "the brush shape is still the sphere")
	)
	step("When the user switches back to the paintbrush", func():
		paint_button.get_popup().index_pressed.emit(0)
	)
	step("Then the paint keeps its own values", func():
		var settings = plugin("PaintPlugin")._settings
		expect(settings.diameter == 9, "the paint diameter is still nine")
		expect(settings.shape == PaintToolSettings.BrushShape.SPHERE, "the paint shape is still the sphere")
	)
	step("When the user restores the brush defaults", func():
		var options: Node = plugin("BrushPlugin")._options
		(options.get_node("Shape/Cube") as BaseButton).pressed.emit()
		options.get_node("Diameter").set("value", 1.0)
	)
	step("Then the brush defaults return and the paint values stay", func():
		var brush_settings = plugin("BrushPlugin")._settings
		var paint_settings = plugin("PaintPlugin")._settings
		expect(brush_settings.diameter == 1, "the brush diameter is back to the default")
		expect(brush_settings.shape == BrushToolSettings.BrushShape.CUBE, "the brush shape is back to the cube")
		expect(paint_settings.diameter == 9, "the paint diameter is unaffected")
		expect(paint_settings.shape == PaintToolSettings.BrushShape.SPHERE, "the paint shape is unaffected")
	)
	step("When the user restores the paint defaults", func():
		var options: Node = plugin("PaintPlugin")._options
		(options.get_node("Brush/Shape/Cube") as BaseButton).pressed.emit()
		options.get_node("Brush/Diameter").set("value", 1.0)
	)
	step("Then the paint defaults return", func():
		var settings = plugin("PaintPlugin")._settings
		expect(settings.diameter == 1, "the paint diameter is back to the default")
		expect(settings.shape == PaintToolSettings.BrushShape.CUBE, "the paint shape is back to the cube")
	)
