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
	## Paint random spots inside a search size.
	SPRAY
}


const PatternJob := preload("res://plugins/brush/StampPatternJob.gd")
const CopyJob := preload("res://plugins/brush/StampCopyJob.gd")
# The shared size helper comes from StampToolSettings. A second const with the
# same name here clashes with the inherited one.

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

## The diameter in cells of one spray spot. The spot paints every exposed voxel
## inside the shared brush sphere of this diameter. Diameter 1 paints the spot
## center alone. It clamps to the range 1 through 64, so the spot matches the
## brush sphere at every size.
@export var spot_diameter := 1 :
	set(value):
		value = VoxelBrushSize.clamp_size(value)
		if value == spot_diameter:
			return
		spot_diameter = value
		emit_changed()

## The width in cells of the spray search area. The spray samples its spot
## centers from the exposed voxels inside the shared brush sphere of this size.
## A voxel is exposed when at least one of its six face neighbors is empty.
## Size 1 offers the brush cell alone. It clamps to the range 1 through 64.
##
## The old spray search radius of 4 spanned 9 cells, so the default size is 9.
## The sphere mask admits more corner and diagonal cells than the old integer
## ball of radius 4, so the default mask changes while it keeps the intended
## physical width.
@export var spray_size := 9 :
	set(value):
		value = VoxelBrushSize.clamp_size(value)
		if value == spray_size:
			return
		spray_size = value
		emit_changed()

## Deprecated: the old spray search radius. It is a view of [member spray_size],
## so the two never disagree. Use [member spray_size] in new code. The old radius
## r spanned 2r + 1 cells, so the getter returns the span-equivalent radius.
var spray_radius: int :
	get:
		return VoxelBrushSize.size_to_radius(spray_size)
	set(value):
		spray_size = VoxelBrushSize.radius_to_size(value)

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
