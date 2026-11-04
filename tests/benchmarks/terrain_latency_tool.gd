extends "res://plugins/Terrain/TerrainTool.gd"

# Keep the old gather frozen for an in-process comparison through real strokes.
# This test-only tool changes the job constructor, not the input or publication.
const ReferenceJobs := preload("res://tests/terrain_occupancy_reference.gd")
const Rounding := preload("res://plugins/Terrain/SmoothOperation.gd")

var use_reference := false


func _run_smooth(fields: Array, seconds: float) -> void:
	if not use_reference:
		super._run_smooth(fields, seconds)
		return
	var job := ReferenceJobs.new_job()
	job.stroke_id = _stroke_id
	job.edited_frame = _source_frame.copy_frame()
	job.fields = []
	var work := 0
	for field in fields:
		var cells: Array = field["cells"]
		work += cells.size()
		job.fields.append({
			"cells": cells,
			"weights": (field["weights"] as Dictionary).duplicate(),
			"credits": (field["credits"] as Dictionary).duplicate(),
			"carry": float(field["carry"]),
		})
	job.seconds = seconds
	job.rate = _stroke.strength
	job.radius = Rounding.KERNEL_RADIUS
	job.remove_threshold = Rounding.REMOVE_THRESHOLD
	job.add_threshold = Rounding.ADD_THRESHOLD
	_smooth_job = job
	if work <= INLINE_EDIT_LIMIT:
		job.run()
		_finish_smooth(job)
	else:
		_operation_id = State.begin_operation("Smoothing voxels", work, true, self, _cancel_edit)
		job.operation_id = _operation_id
		_run_smooth_worker(job)
