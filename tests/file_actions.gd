extends "res://tests/test.gd"

var bar: Node = null


func _ready() -> void:
	test("toolbar lists the file actions", _run)


func _run() -> void:
	step("Given the editor is open", func():
		bar = main.get_node("%MenuBar")
	)

	step("Then the toolbar has New, Open, Save, and Save As buttons", func():
		expect(bar.get_node_or_null("NewBtn") != null, "new button exists")
		expect(bar.get_node_or_null("OpenBtn") != null, "open button exists")
		expect(bar.get_node_or_null("SaveBtn") != null, "save button exists")
		expect(bar.get_node_or_null("SaveAsBtn") != null, "save as button exists")
	)
