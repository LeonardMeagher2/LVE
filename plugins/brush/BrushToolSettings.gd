class_name BrushToolSettings
extends "res://plugins/brush/StampToolSettings.gd"

## The shared brush tool settings.
##
## The settings hold the brush mode, the shape, the diameter, and the
## pixel-perfect flag. The resource is shared by the brush toolbar, the option
## bar, and the tools. The `changed` signal notifies its observers.
##
## The stamp shape, the pattern cache, and the pattern methods come from
## [StampToolSettings]. This class names the pattern jobs, because a shared
## settings class that named them kept the whole script graph alive at exit.

## The brush action.
enum BrushMode {
	## Draw single cells along the pointer.
	PENCIL,
	## Draw a straight line between two points.
	LINE,
	## Erase the brush footprint.
	ERASER
}


const PatternJob := preload("./StampPatternJob.gd")
const CopyJob := preload("./StampCopyJob.gd")

## The brush action.
@export var mode:BrushMode = BrushMode.PENCIL :
	set(value):
		if value == mode:
			return
		mode = value
		emit_changed()


func _build_pattern(brush_diameter: int, brush_shape: int) -> Dictionary:
	return PatternJob.build_pattern(brush_diameter, brush_shape)


func create_pattern_job():
	return PatternJob.new()


## Builds a stamp pattern for one diameter and shape. Returns a dictionary keyed
## by offset from the center. An optional [param job] supplies the cancel
## checkpoints and the progress stage.
static func build_pattern(brush_diameter: int, brush_shape: int, job = null) -> Dictionary:
	return PatternJob.build_pattern(brush_diameter, brush_shape, job)
