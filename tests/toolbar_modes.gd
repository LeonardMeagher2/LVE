extends "res://tests/test.gd"

var _inst: Node = null
var _toolbar: EditorToolStrip
var _brush_button: Button


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("a long press on a tool button opens its mode menu", _run)


func _run() -> void:
	step("Given the toolbar with a brush button", func():
		_toolbar = _inst.get_node("Content/Root/Body/RightStrip")
		_brush_button = _toolbar._tool_buttons[0]
		expect(_toolbar._tool_buttons.size() == 6, "the toolbar shows one button per tool")
	)

	step("When the user holds the brush button for half a second", func():
		_brush_button.button_down.emit()
	)
	await get_tree().create_timer(0.7).timeout

	step("Then a menu lists the brush modes", func():
		expect(_toolbar._menu.visible, "the mode menu opens")
		expect(_toolbar._menu.item_count == 2, "the menu lists both brush modes")
	)

	step("When the user selects the paint mode", func():
		_toolbar._menu.id_pressed.emit(1)
	)

	step("Then the paint mode is active and the button shows it", func():
		expect(State.tool == State.tools.brush_paint, "the paint mode tool is active")
		expect(_brush_button.icon == State.tools.brush_paint.icon, "the button shows the active mode icon")
	)
