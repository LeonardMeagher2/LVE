extends "res://addons/test_kit/test_case.gd"

const MOBILE_SCENE := "res://ui/Mobile/MainMobile.tscn"

var main: Control


func _ready() -> void:
	settle_frames = 2
	test("the mobile scene builds the editor panels", _panels, "mobile_panels")
	test("the mobile menu shows documents in a dropdown", _document_menu, "document_menu")


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


func _document_menu() -> void:
	var menu := main.get_node("%MenuBar")
	step("Then the menu hides the tab bar and adds a document dropdown", func():
		expect(not menu.get_node("%DocumentTabs").visible, "the tab bar is hidden")
		var dropdown := menu.find_child("DocumentTabMenu", false, false)
		expect(dropdown != null, "the document dropdown exists")
		expect(dropdown.get_node("%Tabs") is OptionButton, "the dropdown lists documents")
	)
	step("Then the dropdown lists every open document", func():
		var list: OptionButton = menu.find_child("DocumentTabMenu", false, false).get_node("%Tabs")
		expect(list.item_count == State.tabs.size(), "the dropdown matches the open documents")
	)
