extends "res://tests/test.gd"

var _inst: Node = null
var _bar: Node = null


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("toolbar lists the file actions", _run)


func _run() -> void:
	step("Given the editor is open", func():
		_bar = _inst.get_node("%MenuBar")
	)

	step("Then the toolbar has New, Open, Save, and Save As buttons", func():
		expect(_bar.get_node_or_null("%NewBtn") != null, "new button exists")
		expect(_bar.get_node_or_null("%OpenBtn") != null, "open button exists")
		expect(_bar.get_node_or_null("%SaveBtn") != null, "save button exists")
		expect(_bar.get_node_or_null("%SaveAsBtn") != null, "save as button exists")
	)
