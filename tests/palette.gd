extends "res://tests/test.gd"

var panel: Node = null
var grid: Node = null


func _ready() -> void:
	test("the palette marks the swatch that matches the current color", _run)


func _marked(i: int) -> bool:
	var b := grid.get_child(i) as Button
	return b.button_pressed


func _run() -> void:
	step("Given a palette with one red swatch", func():
		panel = main.find_child("PalettePanel", true, false)
		grid = panel.get_node("%SwatchGrid")
		State.document.add_color(Color.RED)
		panel._rebuild_swatches()
	)

	step("When the working color becomes red", func():
		State.set_color(Color.RED)
	)

	step("Then the red swatch is marked", func():
		expect(grid.get_child_count() == 1, "one swatch exists")
		expect(_marked(0), "matching swatch is marked")
	)

	step("When the working color becomes blue", func():
		State.set_color(Color.BLUE)
	)

	step("Then no swatch is marked", func():
		expect(not _marked(0), "no swatch is marked")
	)

	step("When the user clicks the red swatch", func():
		var b := grid.get_child(0) as Button
		b.button_pressed = true
	)

	step("Then the red swatch is marked again", func():
		expect(_marked(0), "clicked swatch is marked")
		expect(State.current_color == Color.RED, "the working color is the swatch color")
	)
