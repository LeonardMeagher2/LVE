class_name StampToolSettings
extends Resource

## The shared stamp settings.
##
## The settings hold the footprint shape, the diameter, the pattern cache, and
## the pixel-perfect flag. The brush settings and the paint settings extend this
## class. The stamp settings use it directly.
##
## The class names no project script. The pattern jobs live in their own scripts,
## and each concrete settings class names them. A shared settings class that
## named a job script directly, or that held the job classes itself, kept the
## whole document and renderer script graph alive at exit. The test runner
## reports that as a resource leak.
##
## The size helpers are a pure utility, so this class names them. The helper
## names no project script, so it adds no reference cycle.

## The pure size helpers. They own the valid diameter range and the clamps.
const VoxelBrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")

## The stamp footprint shape.
enum BrushShape {
	## A filled cube.
	CUBE,
	## A filled sphere.
	SPHERE,
	## The last prepared stamp pattern.
	STAMP
}

## The stamp diameter in cells. It clamps to the range 1 through 64.
@export_range(1, 64, 1) var diameter := 1:
	set(value):
		value = VoxelBrushSize.clamp_size(value)
		if value == diameter:
			return
		diameter = value
		_cached_pattern = {}
		_cached_offsets = []
		emit_changed()

## The stamp footprint shape.
@export var shape: BrushShape = BrushShape.CUBE:
	set(value):
		if value == shape:
			return
		shape = value
		_cached_pattern = {}
		_cached_offsets = []
		emit_changed()

## Whether a stroke drops transient cells. It keeps the stroke connected.
@export var pixel_perfect:bool = false :
	set(value):
		if value == pixel_perfect:
			return
		pixel_perfect = value
		emit_changed()

## The prepared stamp pattern, keyed by offset from the pattern center.
var stamp_pattern := {}
## The prepared stamp materials, keyed by offset from the pattern center.
var stamp_material_pattern := {}
# The pattern keys in insertion order. A plain array iterates about twice as fast
# as the dictionary, and a shape stamp needs only the offsets. The dictionary
# stays for the material lookup that a stamp and a paste require.
## The stamp pattern keys in insertion order.
var stamp_offsets: Array = []
var _cached_pattern := {}
var _cached_offsets := []


## Uses a prepared pattern as the stamp shape. [param copied_pattern] maps an
## offset to a color. [param copied_material_pattern] maps an offset to a full
## material. An empty pattern clears the stamp.
func use_stamp(copied_pattern: Dictionary, copied_material_pattern: Dictionary = {}) -> void:
	stamp_pattern = copied_pattern
	stamp_pattern.make_read_only()
	stamp_offsets = copied_pattern.keys()
	stamp_material_pattern = copied_material_pattern.duplicate(true)
	stamp_material_pattern.make_read_only()
	shape = BrushShape.STAMP
	emit_changed()


## Clears the prepared stamp pattern. The shape stays [constant BrushShape.STAMP].
func clear_stamp() -> void:
	if stamp_pattern.is_empty() and stamp_material_pattern.is_empty():
		return
	stamp_pattern = {}
	stamp_offsets = []
	stamp_material_pattern = {}
	emit_changed()


## Returns the estimated pattern cell count.
func estimated_size() -> int:
	return stamp_pattern.size() if shape == BrushShape.STAMP else diameter ** 3


## Returns the stamp pattern, keyed by offset from the center. A shape pattern
## above 4096 cells is not cached, so the caller must build it.
func pattern() -> Dictionary:
	if shape == BrushShape.STAMP:
		return stamp_pattern
	if _cached_pattern.is_empty() and estimated_size() <= 4096:
		_cached_pattern = _build_pattern(diameter, shape)
		_cached_pattern.make_read_only()
	return _cached_pattern


# The offsets of `pattern()` in the same order. A job that finds this empty
# derives it from the pattern, so the two never disagree.
## Returns the offsets of [method pattern] in the same order. An empty result
## means that the caller must derive the offsets from the pattern.
func pattern_offsets() -> Array:
	if shape == BrushShape.STAMP:
		return stamp_offsets
	if _cached_offsets.is_empty() and estimated_size() <= 4096:
		_cached_offsets = pattern().keys()
	return _cached_offsets


## Caches a built pattern for the given diameter and shape. It ignores the
## stamp shape.
func cache_pattern(brush_diameter: int, brush_shape: int, cells: Dictionary, offsets: Array = []) -> void:
	if diameter == brush_diameter and shape == brush_shape and shape != BrushShape.STAMP:
		_cached_pattern = cells
		_cached_pattern.make_read_only()
		_cached_offsets = offsets


## Builds a pattern for one diameter and shape. A concrete settings class
## overrides it with its own pattern job.
func _build_pattern(_brush_diameter: int, _brush_shape: int) -> Dictionary:
	return {}




## Returns one pattern job. A concrete settings class overrides it with its own
## job class.
func create_pattern_job():
	return null
