extends "res://plugins/Terrain/TerrainTool.gd"

## A test-only probe for the normal source tests.
##
## It counts the frames that follow the surface. The Face source must never return
## a surface frame, so the counts prove that no surface frame reaches the tool. The
## hover never calls [method _frame_for_pick], so a hover keeps the call count at
## zero. A press and an open-stroke pick call it once, and a smooth re-read reads
## directly on the locked stroke frame.

## The surface frames that [method _frame_for_pick] returned since the last reset.
var surface_frames := 0
## The calls of [method _frame_for_pick] since the last reset.
var surface_calls := 0


## Clears the counters. It changes no tool state.
func reset_normals_probe() -> void:
	surface_frames = 0
	surface_calls = 0


func _frame_for_pick(pick: PickResult, origin: Vector3) -> TerrainFrame:
	surface_calls += 1
	var frame := super._frame_for_pick(pick, origin)
	if frame != null and frame.follows_surface:
		surface_frames += 1
	return frame
