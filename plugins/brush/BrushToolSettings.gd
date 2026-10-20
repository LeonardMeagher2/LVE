class_name BrushToolSettings
extends Resource

## The shared brush tool settings.
##
## The settings hold the brush mode, the shape, the diameter, and the
## pixel-perfect flag. The resource is shared by the brush toolbar, the option
## bar, and the tools. The `changed` signal notifies its observers.

## The brush action.
enum BrushMode {
	## Draw single cells along the pointer.
	PENCIL,
	## Draw the brush footprint.
	PAINT,
	## Draw a straight line between two points.
	LINE,
	## Erase the brush footprint.
	ERASER
}

## The brush footprint shape.
enum BrushShape {
	## A filled cube.
	CUBE,
	## A filled sphere.
	SPHERE,
	## The last copied selection pattern.
	SELECTION
}

## The brush diameter in cells. It clamps to the range 1 through 64.
@export var diameter := 1:
	set(value):
		value = clampi(value, 1, 64)
		if value == diameter:
			return
		diameter = value
		_cached_pattern = {}
		_cached_offsets = []
		emit_changed()

## The brush footprint shape.
@export var shape: BrushShape = BrushShape.CUBE:
	set(value):
		if value == shape:
			return
		shape = value
		_cached_pattern = {}
		_cached_offsets = []
		emit_changed()

## The copied selection pattern, keyed by offset from the pattern center.
var selection_pattern := {}
## The copied selection materials, keyed by offset from the pattern center.
var selection_material_pattern := {}
var _cached_pattern := {}
# The pattern keys in insertion order. A plain array iterates about twice as fast
# as the dictionary, and a shape brush needs only the offsets. The dictionary
# stays for the material lookup that a selection brush and a paste require.
## The selection pattern keys in insertion order.
var selection_offsets: Array = []
var _cached_offsets: Array = []

## One cancellable job that builds a brush pattern.
##
## [method VoxelFrame.EditJob.run] is the worker body.
class PatternJob extends VoxelFrame.EditJob:
	## The brush diameter in cells.
	var diameter := 1
	## The brush shape.
	var shape := BrushShape.CUBE
	## The built pattern, keyed by offset from the center.
	var pattern := {}
	## The pattern keys in insertion order.
	var offsets: Array = []

	## Builds the pattern. This is the worker body.
	func run() -> void:
		pattern = BrushToolSettings.build_pattern(diameter, shape, self)
		if not pattern.is_empty():
			offsets = pattern.keys()

## One cancellable job that copies a frame or a selection into a brush pattern.
##
## [method VoxelFrame.EditJob.run] is the worker body.
class CopyJob extends VoxelFrame.EditJob:
	## The source frame snapshot.
	var source_frame: VoxelFrame
	## The source cells as a dictionary keyed by cell position. An empty mask
	## copies the whole frame.
	var selection_mask := {}
	## The copied colors, keyed by offset from the pattern center.
	var pattern := {}
	## The copied full materials, keyed by offset from the pattern center.
	var pattern_materials := {}
	## The pattern center in cell units.
	var center := Vector3i.ZERO
	var _colors := {}
	var _materials := {}
	var _bounds := AABB()

	## Copies the source. This is the worker body.
	func run() -> void:
		stage("Preparing voxel source", selection_mask.size() if not selection_mask.is_empty() else source_frame.count())
		var completed := 0
		if selection_mask.is_empty():
			for chunk in source_frame.chunks.values():
				for cell_position: Vector3i in chunk.world_cells():
					_include(cell_position, chunk.get_material(cell_position))
					completed += 1
					if completed % 4096 == 0 and not checkpoint(completed):
						return
		else:
			for cell_position: Vector3i in selection_mask:
				_include(cell_position, VoxelFrame.material(source_frame.get_color(cell_position), source_frame.get_emission(cell_position), source_frame.get_metallic(cell_position), source_frame.get_roughness(cell_position)))
				completed += 1
				if completed % 4096 == 0 and not checkpoint(completed):
					return
		center = Vector3i(_bounds.get_center().floor())
		stage("Preparing voxel pattern", _colors.size())
		completed = 0
		for cell_position: Vector3i in _colors:
			pattern[cell_position - center] = _colors[cell_position]
			pattern_materials[cell_position - center] = _materials[cell_position]
			completed += 1
			if completed % 4096 == 0 and not checkpoint(completed):
				return

	func _include(cell_position: Vector3i, cell_material: PackedFloat32Array) -> void:
		var cell_color := VoxelFrame.material_color(cell_material)
		if cell_color == Color.TRANSPARENT:
			return
		_colors[cell_position] = cell_color
		_materials[cell_position] = cell_material
		var cell_bounds := AABB(Vector3(cell_position) - Vector3.ONE * 0.5, Vector3.ONE)
		_bounds = _bounds.merge(cell_bounds) if _bounds.has_volume() else cell_bounds


## Uses a copied pattern as the selection brush shape. [param copied_pattern]
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


## Returns the brush pattern, keyed by offset from the center. A shape pattern
## above 4096 cells is not cached, so the caller must build it.
func pattern() -> Dictionary:
	if shape == BrushShape.SELECTION:
		return selection_pattern
	if _cached_pattern.is_empty() and estimated_size() <= 4096:
		_cached_pattern = build_pattern(diameter, shape)
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


## Builds a brush pattern for one diameter and shape. Returns a dictionary keyed
## by offset from the center. An optional [param job] supplies the cancel
## checkpoints and the progress stage.
static func build_pattern(brush_diameter: int, brush_shape: int, job: VoxelFrame.EditJob = null) -> Dictionary:
	var cells := {}
	var first_offset := -floori(brush_diameter * 0.5)
	var center := (brush_diameter - 1) * 0.5
	if job:
		job.stage("Preparing brush shape", brush_diameter ** 3)
	var completed := 0
	for x in brush_diameter:
		for y in brush_diameter:
			for z in brush_diameter:
				if brush_shape != BrushShape.SPHERE or Vector3(x - center, y - center, z - center).length_squared() <= brush_diameter * brush_diameter * 0.25:
					cells[Vector3i(x + first_offset, y + first_offset, z + first_offset)] = Color.TRANSPARENT
				completed += 1
				if job and completed % 4096 == 0 and not job.checkpoint(completed):
					return {}
	return cells

## The brush action.
@export var mode:BrushMode = BrushMode.PENCIL :
	set(value):
		if value == mode:
			return
		mode = value
		emit_changed()

## Whether a stroke drops transient cells. It keeps the stroke connected.
@export var pixel_perfect:bool = false :
	set(value):
		if value == pixel_perfect:
			return
		pixel_perfect = value
		emit_changed()
