class_name PaintToolSettings
extends "res://plugins/brush/StampToolSettings.gd"

## The shared paint settings.
##
## The resource holds the active paint tool and the options of each paint tool.
## The paint toolbar, the paint option bar, and the paint tools share it. The
## `changed` signal notifies its observers.
##
## The paint settings are independent of the brush settings. The brush and the
## paintbrush keep their own diameter and shape. The stamp shape, the pattern
## cache, and the pattern methods come from [StampToolSettings]. This class names
## the pattern jobs, because a shared settings class that named them kept the
## whole script graph alive at exit.

## Emitted when [member tool] changes.
signal tool_changed(tool: Tools)

## The paint tool.
enum Tools {
	## Recolor existing voxels with the brush footprint.
	PAINTBRUSH,
	## Recolor a connected or a matching region.
	FILL,
	## Paint random spots inside a radius.
	SPRAY
}


const PatternJob := preload("res://plugins/brush/StampPatternJob.gd")
const CopyJob := preload("res://plugins/brush/StampCopyJob.gd")

## The active paint tool.
@export var tool: Tools = Tools.PAINTBRUSH :
	set(value):
		if value == tool:
			return
		tool = value
		tool_changed.emit(tool)
		emit_changed()

## Whether the bucket fill floods the six face neighbors. A false value fills
## every matching cell in the frame.
@export var connected:bool = true :
	set(value):
		if value == connected:
			return
		connected = value
		emit_changed()

## The diameter in cells of one spray spot. The spot paints every existing voxel
## inside a sphere of this diameter. Diameter 1 paints the spot center alone. It
## clamps to the range 1 through 32, which keeps the largest spot inside the old
## search radius without a long inline sample on a dense model.
@export var spot_diameter := 1 :
	set(value):
		value = clampi(value, 1, 32)
		if value == spot_diameter:
			return
		spot_diameter = value
		emit_changed()

## The radius in cells of the spray search area. The spray samples its spot
## centers from the existing voxels inside this radius.
@export var spray_radius := 4 :
	set(value):
		value = clampi(value, 0, 16)
		if value == spray_radius:
			return
		spray_radius = value
		emit_changed()

## The number of distinct spot centers that one click or one brush cell change
## samples. A spot diameter above one can paint more voxels than this count.
@export var speed := 8 :
	set(value):
		value = clampi(value, 1, 64)
		if value == speed:
			return
		speed = value
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
