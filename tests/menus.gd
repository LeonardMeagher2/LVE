extends "res://tests/test.gd"

var _inst: Node = null
var _file_menu: MenuButton


func _initialize() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	_inst = scene.instantiate()
	root.add_child(_inst)
	test("file menu lists the editing actions", _run)


func _run() -> void:
	for i in 2:
		await process_frame

	step("Given the editor is open", func():
		_file_menu = _inst.get_node("Root/MenuBar/File")
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
