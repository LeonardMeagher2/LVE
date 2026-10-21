extends "res://plugins/brush/StrokeTool.gd"

## The brush and eraser tool.
##
## The tool stamps a brush pattern at each stroke center. A large stamp runs on
## the worker pool. A stroke commits as one history action on release or on a
## tool switch. Escape and an edit context change roll the stroke back.
##
## The tool adds voxels in front of the clicked face, or erases the footprint
## when its mode is [constant BrushToolSettings.BrushMode.ERASER].

# The brush settings, typed so the brush mode is readable. The shared engine
# reads the same resource through its own member.
var _brush_settings: BrushToolSettings


func _init() -> void:
	_brush_settings = preload("./settings.tres")
	_settings = _brush_settings


## Returns [code]true[/code] when a press pick uses the add target in front of
## the clicked face.
func _pick_adds() -> bool:
	return _brush_settings.mode != _brush_settings.BrushMode.ERASER


## Returns [code]true[/code] when the current settings erase the footprint.
func _erases() -> bool:
	return _brush_settings.mode == _brush_settings.BrushMode.ERASER
