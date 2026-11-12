extends Resource

## The shared transform tool settings.
##
## The resource holds the transform tool and its options. It is shared by the
## transform toolbar, the option bar, and the tools.

## Emitted when [member tool] changes.
signal tool_changed(tool: Tools)
## Emitted when the option bar requests a commit.
signal commit_requested()
## Emitted when the option bar requests a cancel.
signal cancel_requested()

## Whether a transform drag is in progress. The option bar enables the commit
## and cancel buttons from it.
var transforming: bool = false :
	set(value):
		if value == transforming:
			return
		transforming = value
		emit_changed()

## The transform tool.
enum Tools {
	## Move the selection.
	MOVE,
	## Rotate the selection.
	ROTATE,
	## Scale the selection.
	SCALE,
}

## The active transform tool.
@export var tool: Tools = Tools.MOVE :
	set(value):
		if value == tool:
			return
		tool = value
		tool_changed.emit(tool)
		emit_changed()

## Whether a rotate drag snaps every angle to a 90 degree step. When it is off,
## the drag snaps to one degree and pulls to a nearby cardinal angle.
@export var snap: bool = true :
	set(value):
		if value == snap:
			return
		snap = value
		emit_changed()

## Whether a scale drag keeps one factor on every axis.
@export var uniform: bool = true :
	set(value):
		if value == uniform:
			return
		uniform = value
		emit_changed()


## Emits [signal commit_requested].
func commit() -> void:
	commit_requested.emit()


## Emits [signal cancel_requested].
func cancel() -> void:
	cancel_requested.emit()
