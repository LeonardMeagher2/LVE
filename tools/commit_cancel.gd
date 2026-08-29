extends HBoxContainer

@export var option: ToolOption
@export var group := ""

const COMMIT := "commit"
const CANCEL := "cancel"


func _ready() -> void:
	$commit.pressed.connect(_on_commit)
	$cancel.pressed.connect(_on_cancel)


func _on_commit() -> void:
	State.set_tool_option(group, COMMIT, null)


func _on_cancel() -> void:
	State.set_tool_option(group, CANCEL, null)
