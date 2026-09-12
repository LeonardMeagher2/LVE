extends Resource

signal tool_changed(tool: Tools)
signal commit_requested()
signal cancel_requested()

var transforming: bool = false :
	set(value):
		if value == transforming:
			return
		transforming = value
		emit_changed()

enum Tools {
	MOVE,
	ROTATE,
	SCALE,
}

@export var tool: Tools = Tools.MOVE :
	set(value):
		if value == tool:
			return
		tool = value
		tool_changed.emit(tool)
		emit_changed()

@export var snap: bool = true :
	set(value):
		if value == snap:
			return
		snap = value
		emit_changed()

@export var uniform: bool = true :
	set(value):
		if value == uniform:
			return
		uniform = value
		emit_changed()


func commit() -> void:
	commit_requested.emit()


func cancel() -> void:
	cancel_requested.emit()
