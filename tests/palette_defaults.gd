extends "res://tests/test.gd"

var settings_path := ""
var custom_colors := PackedColorArray([Color.MAGENTA, Color.from_rgba8(20, 40, 60, 128), Color.YELLOW])
var original_default := PackedColorArray()
var palette_menu: MenuButton


func _ready() -> void:
	test("startup and new documents use a saved default palette without replacing opened palettes", _run)


func _run() -> void:
	step("Then the startup document uses the configured default palette", func():
		original_default = State.default_palette.duplicate()
		palette_menu = main.find_child("PalettePanel", true, false).get_node("%PaletteMenu")
		expect(State.get_palette() == original_default, "the startup document contains the configured default swatches")
		expect(not State.get_palette().is_empty(), "the startup palette contains colors")
		expect(State.current_color == State.get_palette()[0], "startup selects the first palette color")
		expect(not State.undo_redo.has_undo(), "the startup palette adds no undo action")
		settings_path = "user://voxi_palette_default_%s.cfg" % Time.get_ticks_usec()
	)
	step("When no saved default palette exists", func():
		State.load_default_palette(settings_path)
		main.get_node("%MenuBar").get_node("NewBtn").pressed.emit()
	)
	step("Then a new document uses the built-in palette", func():
		expect(State.get_palette() == State.get_builtin_palette(), "the new document contains the built-in swatches")
		expect(State.get_palette().size() == 27, "the built-in palette contains 27 colors")
		var unique := {}
		var opaque_colors := true
		for color in State.get_palette():
			unique[color] = true
			opaque_colors = opaque_colors and color.a == 1.0
		expect(unique.size() == 27, "all built-in swatches have distinct colors")
		expect(State.get_palette().has(Color.BLACK) and State.get_palette().has(Color.WHITE), "the built-in palette includes black and white")
		expect(opaque_colors, "all built-in swatches are opaque")
		var colors := State.get_palette()
		var vivid_first := true
		var hues_increase := true
		for index in range(3, 15):
			vivid_first = vivid_first and colors[index].s == 1.0 and colors[index].v == 1.0
			if index > 3:
				hues_increase = hues_increase and colors[index].h > colors[index - 1].h
		expect(vivid_first and hues_increase, "twelve fully saturated colors follow the grayscale in rainbow order")
		var full_saturation := true
		for index in range(3, 21):
			full_saturation = full_saturation and colors[index].s == 1.0
		expect(full_saturation, "main colors and shadows have full saturation")
		var shadow_contrast := true
		var highlight_shifts := true
		for index in 6:
			var base_light := colors[3 + index * 2].srgb_to_linear().get_luminance()
			var shadow_light := colors[15 + index].srgb_to_linear().get_luminance()
			var highlight_light := colors[21 + index].srgb_to_linear().get_luminance()
			shadow_contrast = shadow_contrast and shadow_light < base_light
			highlight_shifts = highlight_shifts and highlight_light > base_light and colors[21 + index].s < 1.0 and colors[21 + index].h != colors[3 + index * 2].h
		expect(shadow_contrast, "each main hue has a darker shadow")
		expect(highlight_shifts, "highlight colors are lighter tints with shifted hues")
		expect(colors[0] == Color.BLACK and colors[1] == Color("808080") and colors[2] == Color.WHITE, "the palette starts with black, gray, and white")
		expect(State.current_color == Color.BLACK, "new documents select the first grayscale swatch")
		expect(_restore_index() == -1, "Restore built-in default is hidden for the built-in default")
		expect(not palette_menu.visible, "the More button is hidden for the built-in palette")
	)
	step("When the user saves the current palette as the default", func():
		State.set_palette(custom_colors)
		expect(palette_menu.visible, "the More button appears for a changed palette")
		expect(_restore_index() == -1, "editing the current palette preserves the built-in startup default")
		expect(State.save_default_palette(settings_path) == OK, "the custom default is saved")
		State.set_palette(PackedColorArray([Color.GREEN]))
	)
	step("Then later palette edits preserve the saved default", func():
		expect(State.default_palette == custom_colors, "the saved default keeps its original colors")
		expect(_restore_index() != -1, "Restore built-in default appears for a custom default")
	)
	step("When the application reads the saved default again", func():
		State.default_palette = State.get_builtin_palette()
		State.load_default_palette(settings_path)
		main.get_node("%MenuBar").get_node("NewBtn").pressed.emit()
	)
	step("Then the new document uses the saved colors and order", func():
		expect(State.get_palette() == custom_colors, "the saved default retains RGBA colors and order")
		expect(State.current_color == custom_colors[0], "new documents select the first custom palette color")
		expect(palette_menu.visible, "custom palettes keep the default controls available")
		expect(not State.undo_redo.has_undo(), "the new document starts with an empty undo history")
	)
	step("When the user opens a document with a different palette", func():
		var document := VoxiDocument.new()
		document.palette.assign([Color.BLUE, Color.RED])
		State.document = document
	)
	step("Then the opened document retains its own palette", func():
		expect(State.get_palette() == PackedColorArray([Color.BLUE, Color.RED]), "the document palette takes precedence over the default")
	)
	step("When the user applies the default palette from the palette menu", func():
		var panel := main.find_child("PalettePanel", true, false)
		panel.get_node("%PaletteMenu").get_popup().id_pressed.emit(PalettePanel.PaletteAction.USE_DEFAULT)
	)
	step("Then the current palette uses the default and supports undo", func():
		expect(State.get_palette() == custom_colors, "the palette menu applies the saved default")
		State.undo_redo.undo()
		expect(State.get_palette() == PackedColorArray([Color.BLUE, Color.RED]), "undo restores the opened document palette")
	)
	step("When the user restores the built-in startup default", func():
		expect(State.reset_default_palette(settings_path) == OK, "the custom startup default is removed")
	)
	step("Then the current document keeps its palette", func():
		expect(State.get_palette() == PackedColorArray([Color.BLUE, Color.RED]), "resetting the startup default preserves the current document palette")
		expect(not FileAccess.file_exists(settings_path), "the saved custom default is removed from storage")
		State.load_default_palette(settings_path)
		State.document = null
		expect(State.get_palette() == State.get_builtin_palette(), "later documents use the built-in default again")
		expect(_restore_index() == -1, "Restore built-in default is hidden after restoration")
		expect(not palette_menu.visible, "the More button is hidden after the built-in palette returns")
	)
	step("When the user has an empty palette", func():
		State.set_palette(PackedColorArray())
	)
	step("Then the saved default requires at least one color", func():
		expect(State.save_default_palette(settings_path) == ERR_INVALID_DATA, "an empty palette cannot replace the startup default")
		expect(not FileAccess.file_exists(settings_path), "the rejected default creates no settings file")
	)
	State.default_palette = original_default


func _restore_index() -> int:
	var panel := main.find_child("PalettePanel", true, false)
	return panel.get_node("%PaletteMenu").get_popup().get_item_index(PalettePanel.PaletteAction.RESET_DEFAULT)
