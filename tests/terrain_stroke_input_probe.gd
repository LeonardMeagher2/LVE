extends "res://plugins/Terrain/TerrainTool.gd"

## A test-only probe that can force the worker dab path for one small press and
## records the footprint depth of the preparation job.
##
## The probe changes no placement, map, or write policy. It only makes the
## inline and worker paths reachable with the same small footprint, so a test can
## compare their exact cells.

## Whether every dab takes the worker path.
var force_worker := false
## Whether the last press started a preparation job.
var prep_started := false
## The bounded depth of the last preparation job, or -1 before one runs.
var last_prep_depth := -1


## Clears the recorded preparation state.
func reset_probe() -> void:
	prep_started = false
	last_prep_depth = -1


func _dab_is_large(radius: int) -> bool:
	return force_worker or super._dab_is_large(radius)


func _start_prep_dab(center_point: Vector3) -> void:
	prep_started = true
	super._start_prep_dab(center_point)
	# Read the depth the job really gets, not a copy of the formula.
	last_prep_depth = _tick_job.prep_depth if _tick_job != null else -1
