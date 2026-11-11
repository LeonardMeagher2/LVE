extends "res://tests/test.gd"

## Checks that the open and save dialog restore their favorite folders and the
## last used folder.

const MENU_SCENE := preload("res://ui/MenuBar/MenuBar.tscn")
const SETTINGS_PATH := "user://file_dialog_test.cfg"

var menu: Node
var favorite: String
var saved_dir := ""


func _ready() -> void:
	test("the file dialog restores favorites and the last folder", _run, "dialog_settings")


func before_test() -> void:
	FileDialog.set_favorite_list(PackedStringArray())
	FileDialog.set_recent_list(PackedStringArray())
	var directory := DirAccess.open("user://")
	if directory:
		directory.remove(SETTINGS_PATH.get_file())


func after_test() -> void:
	if is_instance_valid(menu):
		menu.queue_free()
		menu = null
	var directory := DirAccess.open("user://")
	if directory:
		directory.remove(SETTINGS_PATH.get_file())


func _run() -> void:
	favorite = ProjectSettings.globalize_path("user://")
	step("Given a file dialog with a favorite folder", func():
		menu = MENU_SCENE.instantiate()
		menu.file_settings_path = SETTINGS_PATH
		main.add_child(menu)
	)
	await get_tree().process_frame
	step("When the dialog saves its settings", func():
		FileDialog.set_favorite_list(PackedStringArray([favorite]))
		FileDialog.set_recent_list(PackedStringArray([favorite]))
		menu.get_node("%FileDialog").current_dir = favorite
		saved_dir = menu.get_node("%FileDialog").current_dir
		menu._save_file_dialog()
	)
	step("Then a new dialog restores them", func():
		FileDialog.set_favorite_list(PackedStringArray())
		FileDialog.set_recent_list(PackedStringArray())
		menu._last_dir = ""
		menu._restore_file_dialog()
		expect(FileDialog.get_favorite_list() == PackedStringArray([favorite]), "the favorites are restored")
		expect(FileDialog.get_recent_list() == PackedStringArray([favorite]), "the recent folders are restored")
		expect(menu._last_dir == saved_dir, "the last folder is restored")
	)
