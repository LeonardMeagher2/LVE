extends "res://plugins/Sculpt/SculptTool.gd"

## A test-only probe that records the production Grow placement of every dab.
##
## The probe never changes the production behavior. It delegates to
## [method SculptTool._run_dab] and records the observable stroke state after the
## call. The camera capture at the press and the placement policy live in the
## production tool, so the test exercises the real app path.

## The effect center of every Grow dab, in application order.
var grow_centers: Array = []
## The locked normal of every Grow dab.
var grow_normals: Array = []
## Whether every Grow dab seeded the empty floor.
var grow_seeded: Array = []


## Clears the recorded Grow dabs.
func reset_dabs() -> void:
	grow_centers = []
	grow_normals = []
	grow_seeded = []


func _run_dab(cell: Vector3i) -> void:
	super._run_dab(cell)
	if _stroke_tool != SculptSettings.Tools.GROW:
		return
	grow_centers.append(_stroke_center_point)
	grow_normals.append(_stroke_frame.normal if _stroke_frame != null else Vector3.ZERO)
	grow_seeded.append(_stroke_seed_empty)
