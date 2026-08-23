extends "res://tests/test.gd"

var _inst: Node = null
var _file_menu: MenuButton


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("file menu lists the editing actions", _run)


func _run() -> void:
	step("Given the editor is open", func():
		_file_menu = _inst.get_node("%MenuBar").get_node("%File")
	)

	step("Then the File menu lists New, Open, Save, Save As, and Quit", func():
		expect(_file_menu != null, "file menu exists")
		if _file_menu == null:
			return
		var popup := _file_menu.get_popup()
		expect(popup.get_item_count() == 5, "file menu has 5 items")
		expect(popup.get_item_text(0) == "New", "first menu item is New")
		expect(popup.get_item_text(1) == "Open...", "second menu item is Open...")
		expect(popup.get_item_text(2) == "Save", "third menu item is Save")
		expect(popup.get_item_text(3) == "Save As...", "fourth menu item is Save As...")
		expect(popup.get_item_text(4) == "Quit", "fifth menu item is Quit")
	)
