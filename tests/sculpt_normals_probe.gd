extends "res://plugins/Sculpt/SculptTool.gd"

## A test-only probe for the normal source tests.
##
## It counts the frames that came back fitted. The Face source must never return
## a fitted frame, so the counts prove that no fit result reaches the tool on the
## hover path and on the pick path. A smooth refit is checked through the locked
## stroke frame instead, because that path fits directly.

## The fitted frames that [method _frame_for_pick] returned since the last reset.
var fitted_frames := 0
## The calls of [method _frame_for_pick] since the last reset.
var fit_calls := 0
## The fitted hover frames since the last reset.
var hover_fitted := 0
## The hover frames built since the last reset.
var hover_frames := 0


## Clears the counters. It changes no tool state.
func reset_normals_probe() -> void:
	fitted_frames = 0
	fit_calls = 0
	hover_fitted = 0
	hover_frames = 0


func _frame_for_pick(pick: PickResult, origin: Vector3) -> SculptFrame:
	fit_calls += 1
	var frame := super._frame_for_pick(pick, origin)
	if frame != null and frame.fitted:
		fitted_frames += 1
	return frame


func _compute_hover_frame(pick: PickResult) -> void:
	super._compute_hover_frame(pick)
	hover_frames += 1
	if _hover_frame != null and _hover_frame.fitted:
		hover_fitted += 1
