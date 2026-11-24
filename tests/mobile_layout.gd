extends "res://addons/test_kit/test_case.gd"

const MOBILE_SCENE := "res://ui/Mobile/MainMobile.tscn"

var main: Control


func _ready() -> void:
	settle_frames = 2
	test("the mobile scene builds the editor panels", _panels, "mobile_panels")
	test("a horizontal swipe switches the dock page", _dock_swipe, "dock_swipe")
	test("the menu hides tabs and keeps one document", _single_document, "single_document")


func before_test() -> void:
	main = load(MOBILE_SCENE).instantiate()
	main.set("restore_saved_agent", false)
	main.set("autosave_enabled", false)
	add_child(main)
	await get_tree().process_frame


func after_test() -> void:
	if is_instance_valid(main):
		main.free()
	main = null
	State.stop()


func _panels() -> void:
	step("Then the shared editor nodes resolve by unique name", func():
		expect(main.get_node("%Viewport") != null, "the viewport exists")
		expect(main.get_node("%ToolBar") is Container, "the tool bar is a container")
		expect(main.get_node("%OptionBar") is Container, "the option bar is a container")
		expect(main.get_node("%StatusBar") != null, "the status bar exists")
	)
	step("Then the content sits inside the safe margin", func():
		var content: Control = main.get_node("Content")
		expect(content.offset_left >= 16.0, "the left edge is inset")
		expect(content.offset_top >= 16.0, "the top edge is inset")
		expect(content.offset_right <= -16.0, "the right edge is inset")
		expect(content.offset_bottom <= -16.0, "the bottom edge is inset")
	)


func _dock_swipe() -> void:
	var palette: Control = main.get_node("%PalettePanel")
	var frames: Control = main.get_node("%BottomDock")
	step("Given the dock shows the palette", func():
		expect(palette.visible, "the palette shows")
		expect(not frames.visible, "the frame dock is hidden")
	)
	step("When the dock is swiped left", func():
		main.call("_apply_dock_swipe", Vector2(-120, 8))
	)
	step("Then the frame dock shows", func():
		expect(frames.visible, "the frame dock shows")
		expect(not palette.visible, "the palette hides")
	)
	step("When the dock is swiped right again", func():
		main.call("_apply_dock_swipe", Vector2(120, -6))
	)
	step("Then the palette returns", func():
		expect(palette.visible, "the palette shows again")
		expect(not frames.visible, "the frame dock hides")
	)
	step("Then a short or vertical drag switches nothing", func():
		main.call("_apply_dock_swipe", Vector2(-20, 40))
		expect(palette.visible, "a vertical drag keeps the page")
	)


func _single_document() -> void:
	var menu := main.get_node("%MenuBar")
	step("Then the document tab bar is hidden", func():
		expect(not menu.get_node("%DocumentTabs").visible, "the tab bar hides")
	)
	step("Then opening a document replaces the current tab", func():
		var before := State.tabs.size()
		expect(menu.open_document("res://splash.lve", false, false), "the document opens")
		expect(State.tabs.size() == before, "the open document replaces the tab")
		State.stop()
	)
