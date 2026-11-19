class_name PaintToolSettings
extends "res://plugins/brush/StampToolSettings.gd"


signal tool_changed(tool: Tools)


enum Tools {

	PAINTBRUSH,

	FILL,

	SPRAY,

	DITHER
}


const PatternJob := preload("res://plugins/brush/StampPatternJob.gd")


@export var tool: Tools = Tools.PAINTBRUSH :
	set(value):
		if value == tool:
			return
		tool = value
		tool_changed.emit(tool)
		emit_changed()


@export var connected:bool = true :
	set(value):
		if value == connected:
			return
		connected = value
		emit_changed()


@export_range(1, 64, 1) var spot_diameter := 1 :
	set(value):
		value = VoxelBrushSize.clamp_size(value)
		if value == spot_diameter:
			return
		spot_diameter = value
		emit_changed()


@export_range(1, 64, 1) var spray_size := 9 :
	set(value):
		value = VoxelBrushSize.clamp_size(value)
		if value == spray_size:
			return
		spray_size = value
		emit_changed()


var spray_radius: int :
	get:
		return VoxelBrushSize.size_to_radius(spray_size)
	set(value):
		spray_size = VoxelBrushSize.radius_to_size(value)


@export_range(1, 64, 1) var speed := 8 :
	set(value):
		value = clampi(value, 1, 64)
		if value == speed:
			return
		speed = value
		emit_changed()


@export_range(0.0, 1.0, 0.01) var dither_density := 0.5:
	set(value):
		value = clampf(value, 0.0, 1.0)
		if is_equal_approx(value, dither_density):
			return
		dither_density = value
		emit_changed()


func _build_pattern(brush_diameter: int, brush_shape: int) -> Dictionary:
	return PatternJob.build_pattern(brush_diameter, brush_shape)


func create_pattern_job():
	return PatternJob.new()


static func build_pattern(brush_diameter: int, brush_shape: int, job = null) -> Dictionary:
	return PatternJob.build_pattern(brush_diameter, brush_shape, job)
