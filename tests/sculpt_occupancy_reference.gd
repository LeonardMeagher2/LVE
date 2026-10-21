extends RefCounted

# Frozen copy of the Smooth occupancy gather, taken before the bounded local box
# scan replaced the per-candidate frame lookups.
#
# `SmoothJobReference` extends the live Smooth job and overrides only
# `_occupancy`, so the rest of the job body keeps its one definition. The frozen
# loop reuses `SmoothOperation.kernel_offsets` and `VoxelFrame.has`, which this
# unit did not change. Re-read this file when either of those changes.
#
# This file is the reference for `tests/sculpt_occupancy.gd`. Never update it to
# hide a regression.

const SCULPT := preload("res://plugins/Sculpt/SculptTool.gd")
const SmoothOperation := preload("res://plugins/Sculpt/SmoothOperation.gd")


## Returns one Smooth job that gathers its occupancy with the frozen loop.
static func new_job() -> SmoothJobReference:
	return SmoothJobReference.new()


## One Smooth rounding tick with the frozen per-candidate occupancy gather.
class SmoothJobReference extends SCULPT.SmoothJob:
	## The frame lookups of every gather of this job. One candidate costs one
	## kernel of lookups.
	var lookups := 0

	func _occupancy(cells: Array) -> Variant:
		var occupied := {}
		var offsets: Array = SmoothOperation.kernel_offsets(radius)
		var completed := 0
		for cell: Vector3i in cells:
			for offset: Vector3i in offsets:
				var point := cell + offset
				if edited_frame.has(point):
					occupied[point] = true
			completed += 1
			lookups += offsets.size()
			if completed % 256 == 0 and not checkpoint(completed):
				return null
		return occupied
