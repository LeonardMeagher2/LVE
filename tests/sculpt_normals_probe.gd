extends "res://plugins/Sculpt/SculptTool.gd"

## A test-only probe for the normal source tests.
##
## It counts the frames that came back fitted. The Face source must never return
## a fitted frame, so the counts prove that no fit result reaches the tool on the
## hover path and on the pick path. A smooth refit is checked through the locked
## stroke frame instead, because that path fits directly.
##
## The hover now runs on the preview worker. The probe reads the controller
## counters, so it counts the published hover frames and the fitted ones without
## a production hook.

## The fitted frames that [method _frame_for_pick] returned since the last reset.
var fitted_frames := 0
## The calls of [method _frame_for_pick] since the last reset.
var fit_calls := 0
## The published hover frames that came back fitted. The controller owns the
## count, and the probe forwards it.
var hover_fitted: int:
	get:
		return _preview.hover_fitted_count if _preview != null else 0
## The hover frames that the controller published.
var hover_frames: int:
	get:
		return _preview.hover_frame_calls if _preview != null else 0


## Clears the counters. It changes no tool state.
func reset_normals_probe() -> void:
	fitted_frames = 0
	fit_calls = 0
	if _preview != null:
		_preview.hover_fitted_count = 0


func _frame_for_pick(pick: PickResult, origin: Vector3) -> SculptFrame:
	fit_calls += 1
	var frame := super._frame_for_pick(pick, origin)
	if frame != null and frame.fitted:
		fitted_frames += 1
	return frame
