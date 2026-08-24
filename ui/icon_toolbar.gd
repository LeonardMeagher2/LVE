class_name IconToolbar
extends HBoxContainer

signal new_document
signal open_file
signal save_file
signal save_file_as
signal undo
signal redo

@onready var _new: Button = %NewBtn
@onready var _open: Button = %OpenBtn
@onready var _save: Button = %SaveBtn
@onready var _save_as: Button = %SaveAsBtn
@onready var _undo: Button = %UndoBtn
@onready var _redo: Button = %RedoBtn


func _ready() -> void:
	_new.pressed.connect(new_document.emit)
	_open.pressed.connect(open_file.emit)
	_save.pressed.connect(save_file.emit)
	_save_as.pressed.connect(save_file_as.emit)
	_undo.pressed.connect(undo.emit)
	_redo.pressed.connect(redo.emit)