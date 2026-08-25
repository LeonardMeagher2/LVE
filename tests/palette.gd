extends "res://tests/test.gd"

var _inst: Node = null
var _panel: Node = null
var _grid: Node = null


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("the palette marks the swatch that matches the current color", _run)


func _marked(i: int) -> bool:
	var b := _grid.get_child(i) as Button
	var sb := b.get_theme_stylebox("normal") as StyleBoxFlat
	return sb.get_border_width(SIDE_LEFT) == 2


func _run() -> void:
	step("Given a palette with one red swatch", func():
		_panel = _inst.get_node("%PalettePanel")
		_grid = _panel.get_node("%SwatchGrid")
		State.document.add_color(Color.RED)
		_panel._rebuild_swatches()
	)

	step("When the working color becomes red", func():
		State.set_color(Color.RED)
	)

	step("Then the red swatch shows the selected border", func():
		expect(_grid.get_child_count() == 1, "one swatch exists")
		expect(_marked(0), "matching swatch is marked")
	)

	step("When the working color becomes blue", func():
		State.set_color(Color.BLUE)
	)

	step("Then no swatch is marked", func():
		expect(not _marked(0), "no swatch is marked")
	)

	step("When the user clicks the red swatch", func():
		var b := _grid.get_child(0) as Button
		b.emit_signal("pressed")
	)

	step("Then the red swatch is marked again", func():
		expect(_marked(0), "clicked swatch is marked")
		expect(State.current_color == Color.RED, "the working color is the swatch color")
	)
