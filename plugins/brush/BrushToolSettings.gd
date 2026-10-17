class_name BrushToolSettings
extends Resource

enum BrushMode {
	PENCIL,
	PAINT,
	LINE,
	ERASER
}

enum BrushShape { CUBE, SPHERE, SELECTION }

@export var diameter := 1:
	set(value):
		value = clampi(value, 1, 64)
		if value == diameter:
			return
		diameter = value
		_cached_pattern = {}
		emit_changed()

@export var shape: BrushShape = BrushShape.CUBE:
	set(value):
		if value == shape:
			return
		shape = value
		_cached_pattern = {}
		emit_changed()

var selection_pattern := {}
var selection_material_pattern := {}
var _cached_pattern := {}

class PatternJob extends VoxelFrame.EditJob:
	var diameter := 1
	var shape := BrushShape.CUBE
	var pattern := {}

	func run() -> void:
		pattern = BrushToolSettings.build_pattern(diameter, shape, self)

class CopyJob extends VoxelFrame.EditJob:
	var source_frame: VoxelFrame
	var selection_mask := {}
	var pattern := {}
	var pattern_materials := {}
	var center := Vector3i.ZERO
	var _colors := {}
	var _materials := {}
	var _bounds := AABB()

	func run() -> void:
		stage("Preparing voxel source", selection_mask.size() if not selection_mask.is_empty() else source_frame.count())
		var completed := 0
		if selection_mask.is_empty():
			for chunk in source_frame.chunks.values():
				for cell_position: Vector3i in chunk.cells:
					var base: int = chunk.cells[cell_position] * VoxelFrame.MATERIAL_STRIDE
					_include(cell_position, chunk.materials.slice(base, base + VoxelFrame.MATERIAL_STRIDE))
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


func use_selection(copied_pattern: Dictionary, copied_material_pattern: Dictionary = {}) -> void:
	if copied_pattern.is_empty():
		return
	selection_pattern = copied_pattern
	selection_pattern.make_read_only()
	selection_material_pattern = copied_material_pattern.duplicate(true)
	selection_material_pattern.make_read_only()
	shape = BrushShape.SELECTION
	emit_changed()


func estimated_size() -> int:
	return selection_pattern.size() if shape == BrushShape.SELECTION else diameter ** 3


func pattern() -> Dictionary:
	if shape == BrushShape.SELECTION:
		return selection_pattern
	if _cached_pattern.is_empty() and estimated_size() <= 4096:
		_cached_pattern = build_pattern(diameter, shape)
		_cached_pattern.make_read_only()
	return _cached_pattern


func cache_pattern(brush_diameter: int, brush_shape: int, cells: Dictionary) -> void:
	if diameter == brush_diameter and shape == brush_shape and shape != BrushShape.SELECTION:
		_cached_pattern = cells
		_cached_pattern.make_read_only()


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

@export var mode:BrushMode = BrushMode.PENCIL :
	set(value):
		if value == mode:
			return
		mode = value
		emit_changed()

@export var pixel_perfect:bool = false :
	set(value):
		if value == pixel_perfect:
			return
		pixel_perfect = value
		emit_changed()
