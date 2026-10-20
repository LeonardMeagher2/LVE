extends Resource

## The shared selection tool settings.
##
## The resource holds the selection tool, the selection mode, and the options.
## It is shared by the selection toolbar, the option bar, and the tools. The
## `changed` signal notifies its observers.

## Emitted when [member tool] changes.
signal tool_changed(tool: Tools)

## The selection tool.
enum Tools {
	## Select a screen rectangle.
	BOX,
	## Select a connected region of one material.
	WAND,
	## Select a screen polygon.
	LASSO
}

## How a new selection combines with the old one.
enum SelectMode {
	## Replace the old selection.
	REPLACE,
	## Add to the old selection.
	ADD,
	## Remove from the old selection.
	SUBTRACT
}

## The active selection tool.
@export var tool: Tools = Tools.BOX :
	set(value):
		if value == tool:
			return
		tool = value
		tool_changed.emit(tool)
		emit_changed()

## The selection mode.
@export var mode: SelectMode = SelectMode.REPLACE :
	set(value):
		if value == mode:
			return
		mode = value
		emit_changed()

## Whether the wand selects a connected region of one material.
@export var connected: bool = true :
	set(value):
		if value == connected:
			return
		connected = value
		emit_changed()

# Keep empty grid cells inside the frame bounds in the selection.
## Whether the selection keeps empty cells inside the frame bounds.
@export var include_empty: bool = false :
	set(value):
		if value == include_empty:
			return
		include_empty = value
		emit_changed()

# Keep only the voxels that the camera sees. The hidden voxels behind them drop out.
## Whether the selection keeps only the voxels that the camera sees.
@export var depth_test: bool = true :
	set(value):
		if value == depth_test:
			return
		depth_test = value
		emit_changed()
