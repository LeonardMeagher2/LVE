class_name EditorMenuBar
extends HBoxContainer

signal new_document
signal open_file
signal save_file
signal save_file_as
signal quit
signal undo
signal redo
signal reset_view
signal toggle_grid

@onready var _file: MenuButton = $File
@onready var _edit: MenuButton = $Edit
@onready var _view: MenuButton = $View


func _ready() -> void:
	_file.get_popup().id_pressed.connect(_on_file)
	_edit.get_popup().id_pressed.connect(_on_edit)
	_view.get_popup().id_pressed.connect(_on_view)


func _on_file(index: int) -> void:
	match index:
		0: new_document.emit()
		1: open_file.emit()
		2: save_file.emit()
		3: save_file_as.emit()
		4: quit.emit()


func _on_edit(index: int) -> void:
	match index:
		0: undo.emit()
		1: redo.emit()


func _on_view(index: int) -> void:
	match index:
		0: reset_view.emit()
		1: toggle_grid.emit()
