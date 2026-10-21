extends VoxelFrame.EditJob

## One cancellable job that copies a frame or a selection into a stamp pattern.
##
## [method VoxelFrame.EditJob.run] is the worker body. The job lives in its own
## script, because a shared settings class that named [VoxelFrame] directly kept
## the whole document and renderer script graph alive at exit.

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
			_include(cell_position, source_frame.get_material(cell_position))
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
