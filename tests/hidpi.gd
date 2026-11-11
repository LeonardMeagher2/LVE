extends "res://tests/test.gd"

var _window_size := Vector2i.ZERO
var _font_size := 0
var _button_size := Vector2.ZERO


func _ready() -> void:
	test("text and SVG icons scale together without changing their logical sizes", _run)


func _run() -> void:
	step("Given the editor at one hundred percent scale", func():
		main.set_ui_scale(1.0, false)
		_window_size = get_window().size
		_font_size = main.get_node("%StatusBar").get_node("StatusLeft").get_theme_font_size("font_size")
		print("Display scale: %s, DPI: %s, automatic UI scale: %s" % [DisplayServer.screen_get_scale(), DisplayServer.screen_get_dpi(), main._automatic_ui_scale()])
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then every icon has its original SVG dimensions", func():
		var icons := DirAccess.open("res://icons")
		for file in icons.get_files():
			if not file.ends_with(".svg"):
				continue
			var texture: Texture2D = load("res://icons/" + file)
			expect(texture is DPITexture, "%s supports display-scale rasterization" % file)
			var expected := Vector2(19, 24) if file == "grip.svg" else Vector2(24, 24)
			expect(texture.get_size() == expected, "%s keeps its logical size" % file)
		_button_size = main.get_node("%MenuBar").get_node("NewBtn").size
	)
	step("When the user doubles the UI scale", func():
		main.set_ui_scale(2.0, false)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then text and icons use the same display scale", func():
		expect(get_window().content_scale_factor == 2.0, "the complete interface uses double scale")
		expect(get_window().size == _window_size, "changing UI scale keeps the physical window size")
		expect(main.get_node("%StatusBar").get_node("StatusLeft").get_theme_font_size("font_size") == _font_size, "text keeps its logical font size")
		expect(main.get_node("%MenuBar").get_node("NewBtn").size == _button_size, "icons keep their logical button size")
		var selector: OptionButton = main.get_node("%StatusBar").get_node("%UIScale")
		expect(selector.get_item_id(selector.selected) == 200, "the scale selector shows two hundred percent")
		if DisplayServer.get_name() != "headless":
			RenderingServer.force_draw()
			var image := get_tree().root.get_texture().get_image()
			expect(image.get_size() == get_window().size, "the scaled interface renders at the physical window resolution")
			image.save_png(_dir() + "/scale_200.png")
	)
	step("When the user restores automatic scaling", func():
		main.set_ui_scale(0.0, false)
	)
	step("Then the interface follows the display scale", func():
		expect(is_equal_approx(get_window().content_scale_factor, main._automatic_ui_scale()), "automatic scaling follows the current display")
	)
	main.set_ui_scale(1.0, false)
