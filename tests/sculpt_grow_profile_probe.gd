extends "res://plugins/Sculpt/SculptTool.gd"

## A test-only probe that records the canonical anchor cell of every applied dab.
##
## The probe never changes production behavior. It delegates to
## [method SculptTool._run_dab] and records the anchor the drain passed, so a test
## can predict the credited influence of every column from the fixed kernel.

## The canonical anchor cell of every Grow or Flatten dab, in application order.
var dab_anchors: Array[Vector3i] = []


## Clears the recorded dab anchors.
func reset_profile() -> void:
	dab_anchors = []


func _run_dab(cell: Vector3i) -> void:
	super._run_dab(cell)
	if _stroke_tool == SculptSettings.Tools.GROW or _stroke_tool == SculptSettings.Tools.FLATTEN:
		dab_anchors.append(cell)
