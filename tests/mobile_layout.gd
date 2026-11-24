extends "res://addons/test_kit/test_case.gd"

const MOBILE_SCENE := "res://ui/Mobile/MainMobile.tscn"

var main: Control


func _ready() -> void:
	settle_frames = 2
	test("the mobile scene builds the editor panels", _panels, "mobile_panels")


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
		expect(main.get_node("%DockTabs") is TabContainer, "the dock holds tabs")
		expect(main.get_node("%StatusBar") != null, "the status bar exists")
	)
