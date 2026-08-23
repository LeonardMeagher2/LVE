extends "res://tests/test.gd"

var _inst: Node = null
var _toolbar: EditorToolStrip
var _brush_button: MenuButton


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("the brush button lists its modes and switches tools", _run)


func _run() -> void:
	step("Given the toolbar with a brush menu button", func():
		_toolbar = _inst.get_node("%ToolStrip")
		_brush_button = _toolbar.get_child(0)
		expect(_brush_button is MenuButton, "the brush tool is a menu button")
	)

	step("Then its popup lists the brush modes", func():
		var popup := _brush_button.get_popup()
		expect(popup.item_count == 2, "the menu lists both brush modes")
		expect(popup.get_item_text(0) == "Pencil", "first mode is Pencil")
		expect(popup.get_item_text(1) == "Paint", "second mode is Paint")
	)

	step("When the user selects the paint mode", func():
		_brush_button.get_popup().index_pressed.emit(1)
	)

	step("Then the paint mode is active and the button shows it", func():
		expect(State.tool == State.tools.paint_brush, "the paint mode tool is active")
		expect(_brush_button.icon == State.tools.paint_brush.icon, "the button shows the active mode icon")
	)
