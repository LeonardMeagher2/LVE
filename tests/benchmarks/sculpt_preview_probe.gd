extends "res://plugins/Sculpt/SculptTool.gd"

## A test-only probe for the sculpt preview benchmark.
##
## The probe wraps the real hover path, the preview rebuild, and the mesh
## request with thin timers and counters. It changes no behavior and no result.
## The sculpt preview benchmark is the only caller.
##
## Timing rules. A counter named `_us` measures only the body of one method. A
## counter named `_total_us` includes the nested calls of that method. The
## benchmark derives the difference and labels it derived. No reported total adds
## a nested total to another total.
##
## The counters:
##
## * `pick_total_us` wraps [method _pick_start], so it holds the ray pick, the
##   plane fit, and the plane hit.
## * `fit_us` wraps [method _frame_for_pick] only, so it is the fit alone.
## * `visual_total_us` wraps [method update_visual].
## * `hover_frame_us` wraps [method _compute_hover_frame] only.
## * `rebuild_total_us` wraps [method _rebuild_preview].
## * `hover_samples_total_us` wraps [method _hover_samples], which calls
##   [method _sample_map]. `sample_map_us` wraps [method _sample_map] only.
## * `cells_us` wraps [method _preview_cells_for_samples] only.
## * `set_preview_total_us` wraps [method _set_preview], which reaches the
##   cursor request.
## * `submits` counts the requests that reached the cursor mesh layer.
##   `dedupe_hits` counts the requests the cursor dropped as an identical set.
##   `debounced` counts the requests the cursor delayed by its outline debounce.
## * `dirty_frames` counts the frames whose `_process` saw a dirty preview.
##   `deferred_frames` counts those frames that a running worker job deferred.

# The pick path.
## The inclusive microseconds of [method _pick_start].
var pick_total_us := 0
## The calls of [method _pick_start].
var pick_calls := 0
## The exclusive microseconds of [method _frame_for_pick].
var fit_us := 0
## The calls of [method _frame_for_pick].
var fit_calls := 0

# The visual path.
## The inclusive microseconds of [method update_visual].
var visual_total_us := 0
## The calls of [method update_visual].
var visual_calls := 0
## The exclusive microseconds of [method _compute_hover_frame].
var hover_frame_us := 0
## The calls of [method _compute_hover_frame].
var hover_frame_calls := 0
## The calls that kept the cached hover frame.
var hover_frame_hits := 0
## The calls that rebuilt the hover frame.
var hover_frame_misses := 0

# The preview rebuild.
## The inclusive microseconds of [method _rebuild_preview].
var rebuild_total_us := 0
## The calls of [method _rebuild_preview].
var rebuild_calls := 0
## The inclusive microseconds of [method _hover_samples].
var hover_samples_total_us := 0
## The calls of [method _hover_samples].
var hover_samples_calls := 0
## The exclusive microseconds of [method _sample_map].
var sample_map_us := 0
## The calls of [method _sample_map].
var sample_map_calls := 0
## The exclusive microseconds of [method _preview_cells_for_samples].
var cells_us := 0
## The calls of [method _preview_cells_for_samples].
var cells_calls := 0
## The inclusive microseconds of [method _set_preview].
var set_preview_total_us := 0
## The calls of [method _set_preview].
var set_preview_calls := 0
## The requests that reached the cursor mesh layer.
var submits := 0
## The requests the cursor dropped as an identical set.
var dedupe_hits := 0
## The requests the cursor delayed by its outline debounce.
var debounced := 0
## The requests whose cache key was already seen in this process. The preview
## layer keeps one static mesh cache, so such a request can reuse a surface.
var cache_hits := 0
## The cache keys seen in this process. It survives a probe instance, because the
## preview mesh cache survives it too.
static var _seen_keys := {}
## The inclusive microseconds of [method _grab_sources_for].
var grab_preview_us := 0
## The calls of [method _grab_sources_for].
var grab_preview_calls := 0
## The inclusive microseconds of [method _hover_smooth_cells].
var hover_smooth_us := 0
## The calls of [method _hover_smooth_cells].
var hover_smooth_calls := 0

# The frames.
## The frames whose `_process` saw a dirty preview.
var dirty_frames := 0
## The dirty frames that a running worker job deferred.
var deferred_frames := 0

# The last preview result, for the parity record.
## The cells of the last rebuild.
var last_cells := {}
## The number of cells of the last rebuild.
var last_cells_count := 0
## The order-free digest of the last rebuild cells.
var last_cells_digest := 0

## The cursor mesh of this tool instance.
var _cursor: MeshInstance3D


## Clears every counter. It does not change the tool state.
func reset_probe() -> void:
	pick_total_us = 0
	pick_calls = 0
	fit_us = 0
	fit_calls = 0
	visual_total_us = 0
	visual_calls = 0
	hover_frame_us = 0
	hover_frame_calls = 0
	hover_frame_hits = 0
	hover_frame_misses = 0
	rebuild_total_us = 0
	rebuild_calls = 0
	hover_samples_total_us = 0
	hover_samples_calls = 0
	sample_map_us = 0
	sample_map_calls = 0
	cells_us = 0
	cells_calls = 0
	set_preview_total_us = 0
	set_preview_calls = 0
	submits = 0
	dedupe_hits = 0
	debounced = 0
	cache_hits = 0
	grab_preview_us = 0
	grab_preview_calls = 0
	hover_smooth_us = 0
	hover_smooth_calls = 0
	dirty_frames = 0
	deferred_frames = 0
	last_cells = {}
	last_cells_count = 0
	last_cells_digest = 0


## Resolves the cursor node of this tool instance.
func bind_cursor() -> void:
	_cursor = get_node_or_null("Cursor") as MeshInstance3D


## Returns the counters of the current measurement.
func counters() -> Dictionary:
	return {
		"pick_us": pick_total_us, "pick_calls": pick_calls,
		"fit_us": fit_us, "fit_calls": fit_calls,
		"visual_us": visual_total_us, "visual_calls": visual_calls,
		"hover_us": hover_frame_us, "hover_calls": hover_frame_calls,
		"hover_hits": hover_frame_hits, "hover_misses": hover_frame_misses,
		"rebuild_us": rebuild_total_us, "rebuilds": rebuild_calls,
		"hover_samples_us": hover_samples_total_us, "hover_samples": hover_samples_calls,
		"sample_us": sample_map_us, "sample_maps": sample_map_calls,
		"cells_us": cells_us, "cells_calls": cells_calls,
		"set_us": set_preview_total_us, "set_calls": set_preview_calls,
		"submits": submits, "dedupe": dedupe_hits, "debounced": debounced, "cache_hits": cache_hits,
		"grab_us": grab_preview_us, "grab_calls": grab_preview_calls,
		"smooth_us": hover_smooth_us, "smooth_calls": hover_smooth_calls,
		"dirty_frames": dirty_frames, "deferred_frames": deferred_frames,
		"cells": last_cells_count, "digest": last_cells_digest,
	}


## Returns the mesh of the cursor as a compact snapshot. The digest folds a
## bounded sample of the vertices, so a long outline stays cheap to summarize.
## The count and the AABB of the same mesh are reported beside it.
func mesh_snapshot() -> Dictionary:
	var empty := {"id": 0, "surfaces": 0, "vertices": 0, "digest": 0, "aabb": AABB(), "cells": last_cells}
	if _cursor == null:
		bind_cursor()
	if _cursor == null or _cursor.mesh == null:
		return empty
	var mesh := _cursor.mesh
	var snapshot := {
		"id": mesh.get_instance_id(),
		"surfaces": mesh.get_surface_count(),
		"vertices": 0,
		"digest": 0,
		"aabb": AABB(),
		"cells": last_cells,
	}
	if mesh.get_surface_count() > 0:
		var arrays := mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		snapshot["vertices"] = vertices.size()
		snapshot["digest"] = vertex_digest(vertices)
		snapshot["aabb"] = mesh.get_aabb()
	return snapshot


## Returns the order-free digest of a cell set. The keys sort first, so two sets
## with the same cells give the same digest.
static func cell_digest(cells: Dictionary) -> int:
	var keys := cells.keys()
	keys.sort()
	return keys.hash()


## Returns the digest of a vertex array. The fold samples at most 64 vertices.
static func vertex_digest(vertices: PackedVector3Array) -> int:
	var total := 0
	var step := maxi(1, vertices.size() / 64)
	for index in range(0, vertices.size(), step):
		var vertex := vertices[index]
		total = (total * 31 + int(round(vertex.x * 8.0))) ^ int(round(vertex.y * 8.0)) ^ (int(round(vertex.z * 8.0)) * 31)
	return total


func _process(delta: float) -> void:
	if _preview_dirty:
		dirty_frames += 1
		if _busy():
			deferred_frames += 1
	super._process(delta)


func _pick_start(origin: Vector3, dir: Vector3) -> PickResult:
	var started := Time.get_ticks_usec()
	var result := _pick_production(origin, dir)
	pick_total_us += Time.get_ticks_usec() - started
	pick_calls += 1
	return result


## The production pick body. A reference probe overrides this to add the frozen
## old hover fit inside the same timed span, so both paths report one pick total.
func _pick_production(origin: Vector3, dir: Vector3) -> PickResult:
	return super._pick_start(origin, dir)


func _frame_for_pick(pick: PickResult, origin: Vector3) -> SculptFrame:
	var started := Time.get_ticks_usec()
	var frame := _frame_for_pick_body(pick, origin)
	fit_us += Time.get_ticks_usec() - started
	fit_calls += 1
	return frame


## The production frame fit. A reference probe overrides this to route the fit
## through the frozen old surface query inside the same timed span.
func _frame_for_pick_body(pick: PickResult, origin: Vector3) -> SculptFrame:
	return super._frame_for_pick(pick, origin)


func update_visual(pick: PickResult) -> void:
	var started := Time.get_ticks_usec()
	super.update_visual(pick)
	visual_total_us += Time.get_ticks_usec() - started
	visual_calls += 1


func _compute_hover_frame(pick: PickResult) -> void:
	var before := _hover_frame
	var started := Time.get_ticks_usec()
	super._compute_hover_frame(pick)
	hover_frame_us += Time.get_ticks_usec() - started
	hover_frame_calls += 1
	if _hover_frame == before:
		hover_frame_hits += 1
	else:
		hover_frame_misses += 1


func _rebuild_preview() -> void:
	var started := Time.get_ticks_usec()
	super._rebuild_preview()
	rebuild_total_us += Time.get_ticks_usec() - started
	rebuild_calls += 1
	last_cells = _preview_cells
	last_cells_count = _preview_cells.size()
	last_cells_digest = cell_digest(_preview_cells)


func _hover_samples(frame: SculptFrame, center_point: Vector3) -> Array:
	var started := Time.get_ticks_usec()
	var samples := super._hover_samples(frame, center_point)
	hover_samples_total_us += Time.get_ticks_usec() - started
	hover_samples_calls += 1
	return samples


func _sample_map(sculpt_frame: SculptFrame, center_point: Vector3, radius: int, falloff: float, known: Dictionary = {}) -> Dictionary:
	var started := Time.get_ticks_usec()
	var built := _sample_map_body(sculpt_frame, center_point, radius, falloff, known)
	sample_map_us += Time.get_ticks_usec() - started
	sample_map_calls += 1
	return built


## The production footprint map. A reference probe overrides this to route its
## surface queries through the frozen old query inside the same timed span.
func _sample_map_body(sculpt_frame: SculptFrame, center_point: Vector3, radius: int, falloff: float, known: Dictionary = {}) -> Dictionary:
	return super._sample_map(sculpt_frame, center_point, radius, falloff, known)


func _preview_cells_for_samples(samples: Array, frame: VoxelFrame, tool: int, grow_mode: int, seed_empty: bool, selection: Dictionary) -> Dictionary:
	var started := Time.get_ticks_usec()
	var cells := super._preview_cells_for_samples(samples, frame, tool, grow_mode, seed_empty, selection)
	cells_us += Time.get_ticks_usec() - started
	cells_calls += 1
	return cells


func _set_preview(cells: Dictionary) -> void:
	if _cursor == null:
		bind_cursor()
	var before: Dictionary = _cursor._requested_cells if _cursor != null else {}
	var started := Time.get_ticks_usec()
	super._set_preview(cells)
	set_preview_total_us += Time.get_ticks_usec() - started
	set_preview_calls += 1
	if _cursor == null:
		return
	# The cursor replaces `_requested_cells` for every request it accepts. A
	# request it drops as identical leaves the dictionary in place.
	if _cursor._requested_cells == before:
		dedupe_hits += 1
		return
	submits += 1
	if _cursor._request_due_ms > 0:
		debounced += 1
	var cache_key: String = _cursor._requested_cache_key
	if _seen_keys.has(cache_key):
		cache_hits += 1
	_seen_keys[cache_key] = true


func _grab_sources_for(center: Vector3i) -> Dictionary:
	var started := Time.get_ticks_usec()
	var cells := super._grab_sources_for(center)
	grab_preview_us += Time.get_ticks_usec() - started
	grab_preview_calls += 1
	return cells


func _hover_smooth_cells() -> Dictionary:
	var started := Time.get_ticks_usec()
	var cells := super._hover_smooth_cells()
	hover_smooth_us += Time.get_ticks_usec() - started
	hover_smooth_calls += 1
	return cells
