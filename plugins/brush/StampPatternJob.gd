extends VoxelFrame.EditJob

## One cancellable job that builds a stamp pattern.
##
## [method VoxelFrame.EditJob.run] is the worker body. The job lives in its own
## script, because a shared settings class that named [VoxelFrame] directly kept
## the whole document and renderer script graph alive at exit.
##
## The job names no settings class. A script that named its own settings class
## kept the settings script alive in a reference cycle at exit.

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
	var first_offset := -floori(brush_diameter * 0.5)
	var center := (brush_diameter - 1) * 0.5
	if job:
		job.stage("Preparing brush shape", brush_diameter ** 3)
	var completed := 0
	for x in brush_diameter:
		for y in brush_diameter:
			for z in brush_diameter:
				if brush_shape != SPHERE or Vector3(x - center, y - center, z - center).length_squared() <= brush_diameter * brush_diameter * 0.25:
					cells[Vector3i(x + first_offset, y + first_offset, z + first_offset)] = Color.TRANSPARENT
				completed += 1
				if job and completed % 4096 == 0 and not job.checkpoint(completed):
					return {}
	return cells
