extends "res://addons/test_kit/test_case.gd"

const MOBILE_SCENE := "res://ui/Mobile/MainMobile.tscn"

var main: Control


func _ready() -> void:
	settle_frames = 2
	test("the mobile scene builds the editor panels", _panels, "mobile_panels")
	test("the dock toggles show one panel and hide the dock", _dock, "dock_toggles")


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


func _dock() -> void:
	var palette: Control = main.get_node("%PalettePanel")
	var frames: Control = main.get_node("%BottomDock")
	var frames_toggle: Button = main.get_node("%FramesToggle")
	step("Given the dock shows the palette", func():
		expect(palette.visible, "the palette shows")
		expect(not frames.visible, "the frame dock is hidden")
	)
	step("When the frames toggle is pressed", func():
		frames_toggle.button_pressed = true
	)
	step("Then the frame dock replaces the palette", func():
		expect(frames.visible, "the frame dock shows")
		expect(not palette.visible, "the palette hides")
	)
	step("When the active toggle is pressed again", func():
		frames_toggle.button_pressed = false
	)
	step("Then the whole dock body hides", func():
		expect(not main.get_node("%DockBody").visible, "the dock body hides")
	)
