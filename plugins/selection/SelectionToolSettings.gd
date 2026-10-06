extends Resource

signal tool_changed(tool: Tools)

enum Tools {
	BOX,
	WAND,
	LASSO
}

enum SelectMode {
	REPLACE,
	ADD,
	SUBTRACT
}

@export var tool: Tools = Tools.BOX :
	set(value):
		if value == tool:
			return
		tool = value
		tool_changed.emit(tool)
		emit_changed()

@export var mode: SelectMode = SelectMode.REPLACE :
	set(value):
		if value == mode:
			return
		mode = value
		emit_changed()

@export var connected: bool = true :
	set(value):
		if value == connected:
			return
		connected = value
		emit_changed()
