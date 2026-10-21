class_name StampToolSettings
extends Resource

## The shared stamp settings.
##
## The settings hold the footprint shape, the diameter, the pattern cache, and
## the pixel-perfect flag. The brush settings and the paint settings extend this
## class, so both read the same pattern code.
##
## The class names no project script. The pattern jobs live in their own scripts,
## and each concrete settings class names them. A shared settings class that
## named a job script directly, or that held the job classes itself, kept the
## whole document and renderer script graph alive at exit. The test runner
## reports that as a resource leak.

## The stamp footprint shape.
enum BrushShape {
	## A filled cube.
	CUBE,
	## A filled sphere.
	SPHERE,
	## The last copied selection pattern.
	SELECTION
}

## The stamp diameter in cells. It clamps to the range 1 through 64.
@export var diameter := 1:
	set(value):
		value = clampi(value, 1, 64)
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

## The copied selection pattern, keyed by offset from the pattern center.
var selection_pattern := {}
## The copied selection materials, keyed by offset from the pattern center.
var selection_material_pattern := {}
# The pattern keys in insertion order. A plain array iterates about twice as fast
# as the dictionary, and a shape stamp needs only the offsets. The dictionary
# stays for the material lookup that a selection stamp and a paste require.
## The selection pattern keys in insertion order.
var selection_offsets: Array = []
var _cached_pattern := {}
var _cached_offsets: Array = []


## Uses a copied pattern as the selection stamp shape. [param copied_pattern]
## maps an offset to a color. [param copied_material_pattern] maps an offset to
## a full material. An empty pattern is ignored.
func use_selection(copied_pattern: Dictionary, copied_material_pattern: Dictionary = {}) -> void:
	if copied_pattern.is_empty():
		return
	selection_pattern = copied_pattern
	selection_pattern.make_read_only()
	selection_offsets = copied_pattern.keys()
	selection_material_pattern = copied_material_pattern.duplicate(true)
	selection_material_pattern.make_read_only()
	shape = BrushShape.SELECTION
	emit_changed()


## Returns the estimated pattern cell count.
func estimated_size() -> int:
	return selection_pattern.size() if shape == BrushShape.SELECTION else diameter ** 3


## Returns the stamp pattern, keyed by offset from the center. A shape pattern
## above 4096 cells is not cached, so the caller must build it.
func pattern() -> Dictionary:
	if shape == BrushShape.SELECTION:
		return selection_pattern
	if _cached_pattern.is_empty() and estimated_size() <= 4096:
		_cached_pattern = _build_pattern(diameter, shape)
		_cached_pattern.make_read_only()
	return _cached_pattern


# The offsets of `pattern()` in the same order. A job that finds this empty
# derives it from the pattern, so the two never disagree.
## Returns the offsets of [method pattern] in the same order. An empty result
## means that the caller must derive the offsets from the pattern.
func pattern_offsets() -> Array:
	if shape == BrushShape.SELECTION:
		return selection_offsets
	if _cached_offsets.is_empty() and estimated_size() <= 4096:
		_cached_offsets = pattern().keys()
	return _cached_offsets


## Caches a built pattern for the given diameter and shape. It ignores the
## selection shape.
func cache_pattern(brush_diameter: int, brush_shape: int, cells: Dictionary, offsets: Array = []) -> void:
	if diameter == brush_diameter and shape == brush_shape and shape != BrushShape.SELECTION:
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
