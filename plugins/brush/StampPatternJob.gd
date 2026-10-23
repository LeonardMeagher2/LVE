extends VoxelFrame.EditJob

## One cancellable job that builds a stamp pattern.
##
## [method VoxelFrame.EditJob.run] is the worker body. The job lives in its own
## script, because a shared settings class that named [VoxelFrame] directly kept
## the whole document and renderer script graph alive at exit.
##
## The job names no settings class. A script that named its own settings class
## kept the settings script alive in a reference cycle at exit.

# The pure size helpers. The helper names no project script, so the preload adds
# no reference cycle. The helper owns the sphere mask and the offset range, so
# the brush shape has one source of truth.
const VoxelBrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")

# The sphere value of `StampToolSettings.BrushShape.SPHERE`. The job cannot name
# the settings class, because that closes a script reference cycle.
const SPHERE := 1

## The stamp diameter in cells.
var diameter := 1
## The stamp shape.
var shape := 0
## The built pattern, keyed by offset from the center.
var pattern := {}
## The pattern keys in insertion order.
var offsets: Array = []


## Builds the pattern. This is the worker body.
func run() -> void:
	pattern = build_pattern(diameter, shape, self)
	if not pattern.is_empty():
		offsets = pattern.keys()


## Builds a stamp pattern for one diameter and shape. Returns a dictionary keyed
## by offset from the center. An optional [param job] supplies the cancel
## checkpoints and the progress stage.
static func build_pattern(brush_diameter: int, brush_shape: int, job: VoxelFrame.EditJob = null) -> Dictionary:
	var cells := {}
	var first_offset := VoxelBrushSize.first_offset(brush_diameter)
	var last_offset := VoxelBrushSize.last_offset(brush_diameter)
	var sphere := brush_shape == SPHERE
	if job:
		job.stage("Preparing brush shape", brush_diameter ** 3)
	var completed := 0
	for x in range(first_offset, last_offset + 1):
		for y in range(first_offset, last_offset + 1):
			for z in range(first_offset, last_offset + 1):
				if not sphere or VoxelBrushSize.contains_sphere(brush_diameter, Vector3i(x, y, z)):
					cells[Vector3i(x, y, z)] = Color.TRANSPARENT
				completed += 1
				if job and completed % 4096 == 0 and not job.checkpoint(completed):
					return {}
	return cells
