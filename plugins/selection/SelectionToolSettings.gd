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

# Keep empty grid cells inside the frame bounds in the selection.
@export var include_empty: bool = false :
	set(value):
		if value == include_empty:
			return
		include_empty = value
		emit_changed()

# Keep only the voxels that the camera sees. The hidden voxels behind them drop out.
@export var depth_test: bool = true :
	set(value):
		if value == depth_test:
			return
		depth_test = value
		emit_changed()
