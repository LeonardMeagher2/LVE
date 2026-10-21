extends "res://plugins/paint/SprayTool.gd"

## A test-only probe for the spray latency benchmark.
##
## The probe times the real sampler, the pick, the cursor request, and the batch
## validation. It changes no behavior and no result. The benchmark reads the
## counters after each input event.
##
## The probe also exposes the per-instance shape caches, so the benchmark can
## measure a cold first sample.

## The microseconds of the last sampler call.
var sample_us := 0
## The sampler calls since the last reset.
var sample_calls := 0
## The cells of the last sampled batch.
var sample_cells := 0
## The microseconds of the last pick.
var pick_us := 0
## The microseconds of the last cursor update.
var visual_us := 0
## The microseconds of the last cursor request.
var show_us := 0
## The cursor requests since the last reset.
var show_calls := 0
## The microseconds of the last input event inside the tool.
var input_us := 0
## The microseconds of the last batch validation.
var batch_us := 0


## Clears the timing counters. It does not change the tool state.
func reset_probe() -> void:
	sample_us = 0
	sample_calls = 0
	sample_cells = 0
	pick_us = 0
	visual_us = 0
	show_us = 0
	show_calls = 0
	input_us = 0
	batch_us = 0


## Drops the per-instance shape caches. The next sample then pays the cold build.
func clear_shape_caches() -> void:
	_spot_offsets_cache = {}
	_spot_radius_cache = {}
	_sphere_offsets_cache = {}


func handle_input(event: InputEvent, pos: Vector2) -> bool:
	var started := Time.get_ticks_usec()
	var consumed := super.handle_input(event, pos)
	input_us = Time.get_ticks_usec() - started
	return consumed


func pick_start(request: PickRequest) -> PickResult:
	var started := Time.get_ticks_usec()
	var result := super.pick_start(request)
	pick_us = Time.get_ticks_usec() - started
	return result


func pick_drag(request: PickRequest) -> PickResult:
	var started := Time.get_ticks_usec()
	var result := super.pick_drag(request)
	pick_us = Time.get_ticks_usec() - started
	return result


func update_visual(pick: PickResult) -> void:
	var started := Time.get_ticks_usec()
	super.update_visual(pick)
	visual_us = Time.get_ticks_usec() - started


func _ensure_batch(center: Vector3i, frame: VoxelFrame, context: VoxelFrame.EditContext, material: PackedFloat32Array) -> bool:
	var started := Time.get_ticks_usec()
	var fresh := super._ensure_batch(center, frame, context, material)
	batch_us = Time.get_ticks_usec() - started
	return fresh


func _sample(center: Vector3i, frame: VoxelFrame, context: VoxelFrame.EditContext) -> Array[Vector3i]:
	var started := Time.get_ticks_usec()
	var cells := super._sample(center, frame, context)
	sample_us = Time.get_ticks_usec() - started
	sample_calls += 1
	sample_cells = cells.size()
	return cells


func _show_spots(cells: Array[Vector3i]) -> void:
	var started := Time.get_ticks_usec()
	super._show_spots(cells)
	show_us = Time.get_ticks_usec() - started
	show_calls += 1
