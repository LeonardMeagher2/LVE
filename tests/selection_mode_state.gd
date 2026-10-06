extends "res://tests/test.gd"

var options: Control
var settings := preload("res://Plugins/Selection/settings.tres")


func _ready() -> void:
	test("selection mode buttons show the stored mode on activation and after state changes", _run)


func _run() -> void:
	step("Given the default selection state", func():
		options = plugin("SelectionPlugin")._options
		activate_tool("selection")
	)
	step("Then Replace is the only active mode", func():
		_expect_mode("replace")
	)
	step("When the stored mode changes to Add", func():
		settings.mode = settings.SelectMode.ADD
	)
	step("Then Add is the only active mode", func():
		_expect_mode("add")
	)
	step("When the user clicks Subtract", func():
		options.get_node("subtract").button_pressed = true
	)
	step("Then Subtract is stored and active", func():
		expect(settings.mode == settings.SelectMode.SUBTRACT, "the stored mode is Subtract")
		_expect_mode("subtract")
	)
	step("When the mode changes while the selection options are hidden", func():
		activate_tool("Toolbar")
		settings.mode = settings.SelectMode.ADD
		activate_tool("selection")
	)
	step("Then the options retain the stored Add mode", func():
		_expect_mode("add")
	)
	step("When the selection tool changes to Wand", func():
		select_toolbar_item("selection", "Wand")
		settings.connected = false
	)
	step("Then the mode and connection option match state", func():
		_expect_mode("add")
		expect(options.get_node("Connected").visible, "the wand connection option is visible")
		expect(not options.get_node("Connected").button_pressed, "the connection option shows the stored value")
	)


func _expect_mode(active_name: String) -> void:
	for mode_name in ["replace", "add", "subtract"]:
		expect(options.get_node(mode_name).button_pressed == (mode_name == active_name), "the %s mode button matches state" % mode_name)
