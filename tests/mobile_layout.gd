extends "res://addons/test_kit/test_case.gd"

const MOBILE_SCENE := "res://ui/Mobile/MainMobile.tscn"

var main: Control


func _ready() -> void:
	settle_frames = 2
	test("the mobile scene builds the editor panels", _panels, "mobile_panels")
	test("the dock toggles show one panel and hide the dock", _dock_toggles, "dock_toggles")
	test("the frame playback sits at the bottom on a phone", _playback_row, "playback_row")
	test("gestures zoom and pan the viewport", _gestures, "gestures")
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


func _dock_toggles() -> void:
	var palette: Control = main.get_node("%PalettePanel")
	var frames: Control = main.get_node("%BottomDock")
	var frames_toggle: Button = main.get_node("%FramesToggle")
	var palette_toggle: Button = main.get_node("%PaletteToggle")
	step("Given the dock shows the palette", func():
		expect(palette.visible, "the palette shows")
		expect(not frames.visible, "the frame dock is hidden")
	)
	step("Then both toggles share the row", func():
		expect(palette_toggle.size_flags_horizontal == Control.SIZE_EXPAND_FILL, "the palette toggle expands")
		expect(frames_toggle.size_flags_horizontal == Control.SIZE_EXPAND_FILL, "the frames toggle expands")
		expect(is_equal_approx(palette_toggle.size.x, frames_toggle.size.x), "the toggles are the same width")
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

func _playback_row() -> void:
	var dock: Control = main.get_node("%BottomDock")
	step("Then the playback controls sit in their own bottom row", func():
		var row := dock.get_node_or_null("PlaybackRow")
		expect(row is HBoxContainer, "the playback row exists")
		expect(row.get_node_or_null("Playback") != null, "the playback controls moved there")
		expect(row.alignment == BoxContainer.ALIGNMENT_CENTER, "the playback row is centred")
		expect(dock.get_node("HBoxContainer").alignment == BoxContainer.ALIGNMENT_CENTER, "the frame row is centred")
	)
	step("Then the frame bar no longer sets a wide minimum", func():
		expect(dock.get_combined_minimum_size().x < 320.0, "the dock minimum stays narrow")
	)


func _gestures() -> void:
	var viewport: Node = main.get_node("%Viewport")
	var scene: Node = viewport.get_node("%ViewportScene")
	var rig: Node = viewport.get_node("%CameraRig")
	step("Given the viewport at its normal zoom", func():
		expect(rig.zoom_percent() > 0.0, "the camera reports a zoom")
	)
	step("When a magnify gesture spreads the fingers", func():
		var before: float = rig.zoom_percent()
		var magnify := InputEventMagnifyGesture.new()
		magnify.factor = 1.5
		scene.call("_input", magnify)
		expect(rig.zoom_percent() > before, "spreading the fingers zooms in")
	)
	step("When a pan gesture moves two fingers", func():
		var before: Vector3 = rig.global_position
		var pan := InputEventPanGesture.new()
		pan.delta = Vector2(40, 0)
		scene.call("_input", pan)
		expect(not rig.global_position.is_equal_approx(before), "the camera pans")
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
