extends "res://tests/benchmarks/sculpt_preview_probe.gd"

## A test-only probe that can run the frozen old hover path beside the current
## production path.
##
## `use_reference == false` runs production through `super`. The candidate of a
## later optimization is production itself, so that side needs no copy here.
##
## `use_reference == true` runs a frozen copy of the hover path that the baseline
## measured: the pick fits a frame for the press, the hover fits one more, and
## the preview rebuild builds the footprint map and the cell set on the main
## thread on every dirty frame. The copy stays old after production changes, so
## an A/B keeps a stable reference. It is not a candidate and it claims no gain.
##
## The copy is the frozen reference path at commit 483c5f9. Production now owns
## the hover frame, the hover key, and the preview cache in the preview
## controller, so this file keeps those values in its own `_ref` fields. It calls
## only helpers that still exist and that keep the old behavior: `_active_frame`,
## `_context`, `_settings`, `_depth`, `_forward`, `_frame_for_pick`, `_plane_for`,
## `_plane_hit`, `_set_preview`, `_grab_sources_for`, `_stroke_preview_cells`,
## `_smooth_preview_cells`, `_build_smooth_fields`, and `_smooth_field_cells`.
## If production renames or removes one of those, this file fails to compile.
## That loud failure is deliberate: a silent fallback would corrupt the
## comparison.
##
## The frozen map keeps the old bounded search of `_depth(radius)`. The current
## stroke path uses a taller height lookup, so the A/B reports a difference if
## the taller bound changes a cell. The frozen map also keeps the old inline
## claim rule, and not the shared resolver of the current production path.
##
## `_frame_for_pick` and `_sample_map` are not overridden here. Their probe hooks
## route the frozen bodies through `_frame_for_pick_body` and `_sample_map_body`,
## so the timers stay exact on both paths.

const SurfaceQuery := preload("./sculpt_preview_surface.gd")

## Whether the tool runs the frozen old hover path.
var use_reference := false
## Whether the fit and the footprint map read the frozen old surface query. It
## changes no cell set, so it isolates the query cost from the fit count.
var use_reference_surface := false

# The frozen old hover state. Production moved these values into the preview
# controller, so the frozen path keeps its own copy here.
var _ref_frame: SculptFrame
var _ref_point := Vector3.ZERO
var _ref_seed := false
var _ref_key := Vector3i.MAX
var _ref_entry := Vector3i.MAX
var _ref_dirty := true

# The frozen stage times, reported beside the controller stages. The old probe
# wrapped the hover fit, the footprint map, and the cell pass. The current probe
# has no separate sample-loop field, so the map stage is the reported sample
# stage.
var _ref_hover_us := 0
var _ref_hover_calls := 0
var _ref_hover_hits := 0
var _ref_hover_misses := 0
var _ref_sample_us := 0
var _ref_sample_calls := 0
var _ref_cells_us := 0
var _ref_cells_calls := 0


## Returns true while the visible preview is stale. The frozen path owns its own
## flag, and production reads the controller flag.
func is_preview_dirty() -> bool:
	if use_reference:
		return _ref_dirty
	return _preview_dirty


## Returns the frame fit of one hit. The frozen query runs when the surface
## reference is on, and the production fit otherwise.
func _fit_surface(frame: VoxelFrame, hit: Vector3i, entry: Vector3i, radius: int, fallback: SculptFrame) -> SculptFrame:
	if use_reference_surface:
		return SurfaceQuery.fit(frame, hit, entry, radius, fallback)
	return SculptFrame.fit(frame, hit, entry, radius, fallback)


func _frame_for_pick_body(pick: PickResult, origin: Vector3) -> SculptFrame:
	if use_reference or use_reference_surface:
		return _ref_frame_for_pick(pick, origin)
	return super._frame_for_pick_body(pick, origin)


# The frozen old `_frame_for_pick` body. The frozen reference used one body for
# the production query and one for the frozen query. This file keeps one body
# and selects the query in `_fit_surface`, so the geometry and the fit count are
# the same on both query settings. The Face source still returns the exact face
# and runs no local fit, as the shipped body did. The 483c5f9 frozen-query copy
# omitted the Face check. This file keeps the shipped check, so the geometry
# follows the shipped rule on both query settings.
func _ref_frame_for_pick(pick: PickResult, origin: Vector3) -> SculptFrame:
	if pick.hit != VoxelPicking.NONE:
		var entry := pick.entry
		if entry == Vector3i.ZERO:
			entry = Vector3i.ZERO
			entry[VoxelPicking.view_axis(_forward())] = 1
		var fallback := SculptFrame.from_face(pick.hit, entry)
		if _normal_source() == SculptSettings.NormalSource.FACE:
			return fallback
		return _fit_surface(State.get_current_voxel_frame(), pick.hit, entry, _settings.radius, fallback)
	var floor_axis: int = State.floor_axis
	var level := float(State.floor_index) - 0.5
	var floor_sign := 1 if origin[floor_axis] >= level else -1
	return SculptFrame.from_floor(floor_axis, floor_sign, level, pick.target)


func _sample_map_body(sculpt_frame: SculptFrame, center_point: Vector3, radius: int, falloff: float, known: Dictionary = {}) -> Dictionary:
	if use_reference or use_reference_surface:
		return _ref_sample_map(sculpt_frame, center_point, radius, falloff, known, use_reference_surface)
	return super._sample_map_body(sculpt_frame, center_point, radius, falloff, known)


# The frozen old footprint map. It keeps the old bounded `_depth(radius)`, the
# old scan order, and the old inline claim rule. The query switch changes only
# the surface read, so the A/B can separate query cost from geometry.
func _ref_sample_map(sculpt_frame: SculptFrame, center_point: Vector3, radius: int, falloff: float, known: Dictionary, frozen_query: bool) -> Dictionary:
	var built := {}
	var claimed := {}
	var context := _context()
	var active := _active_frame()
	var depth := _depth(radius)
	for mask in _masks_for(context):
		var reflected := sculpt_frame.reflected(context, mask)
		var center := center_point if mask == 0 else SculptFrame.mirror_point(center_point, context, mask)
		for entry in SculptGeometry.disk_offsets(radius):
			var weight := SculptGeometry.weight_at(entry["distance"], float(radius), falloff)
			if weight <= 0.0:
				continue
			var point: Vector3 = center + float(entry["u"]) * reflected.tangent_u + float(entry["v"]) * reflected.tangent_v
			var anchor := SculptGeometry.cell_at(point)
			var surface: Vector3i = known[anchor] if known.has(anchor) else _ref_surface_along(active, point, reflected.normal, depth, frozen_query)
			var claim := surface if surface != VoxelPicking.NONE else anchor
			if claimed.has(claim):
				var winner: Vector3i = claimed[claim]
				if float(built[winner]["weight"]) >= weight:
					continue
				built.erase(winner)
			claimed[claim] = anchor
			built[anchor] = {
				"anchor": anchor,
				"point": point,
				"normal": reflected.normal,
				"plane_origin": reflected.origin,
				"weight": weight,
				"surface": surface,
			}
	return built


# Reads one column through the frozen query or the shipped query. The frozen
# query is the only read that the surface reference changes.
func _ref_surface_along(frame: VoxelFrame, point: Vector3, normal: Vector3, depth: int, frozen_query: bool) -> Vector3i:
	if frozen_query:
		return SurfaceQuery.surface_along(frame, point, normal, depth, {})
	return SculptGeometry.surface_along(frame, point, normal, depth, {})


func _mark_preview_dirty() -> void:
	# The frozen key is local, so it must drop on every invalidation. A mode
	# switch then never reuses a frame that the other path left behind.
	_ref_dirty = true
	_ref_key = Vector3i.MAX
	if not use_reference:
		super._mark_preview_dirty()


# The shipped tool now invalidates the preview controller on a document change.
# The frozen path did that through `_mark_preview_dirty`, so this adapter keeps
# the old local invalidation and never touches the new controller in the frozen
# mode. The local key drops in both modes, so a mode switch never reuses a frame
# from an older document.
func _on_document_changed() -> void:
	_ref_dirty = true
	_ref_key = Vector3i.MAX
	if not use_reference:
		super._on_document_changed()


func update_visual(pick: PickResult) -> void:
	if not use_reference:
		super.update_visual(pick)
		return
	var started := Time.get_ticks_usec()
	if pick.plane == null:
		pick.plane = _plane
	_last_pick = pick
	if pick.target == VoxelPicking.NONE:
		visible = false
		_ref_dirty = false
		_set_preview({})
	else:
		if _edit == null:
			_ref_compute_hover_frame(pick)
		_ref_dirty = true
	visual_total_us += Time.get_ticks_usec() - started
	visual_calls += 1


func _process(_delta: float) -> void:
	if not use_reference:
		super._process(_delta)
		return
	if _ref_dirty:
		dirty_frames += 1
		if _busy():
			deferred_frames += 1
		else:
			_rebuild_preview()


func _rebuild_preview() -> void:
	if not use_reference:
		super._rebuild_preview()
		return
	var started := Time.get_ticks_usec()
	_ref_dirty = false
	if _edit != null:
		if _stroke_tool == SculptSettings.Tools.GRAB:
			_set_preview(_grab_source_cells)
		elif _stroke_tool == SculptSettings.Tools.SMOOTH:
			_set_preview(_smooth_preview_cells())
		else:
			_set_preview(_stroke_preview_cells())
	elif _last_pick == null or _last_pick.target == VoxelPicking.NONE:
		_set_preview({})
	elif _settings.tool == SculptSettings.Tools.GRAB:
		_set_preview(_grab_sources_for(_last_pick.target))
	else:
		_ref_compute_hover_frame(_last_pick)
		if _ref_frame == null:
			_set_preview({})
		elif _settings.tool == SculptSettings.Tools.SMOOTH:
			_set_preview(_ref_hover_smooth_cells())
		else:
			var samples := _ref_hover_samples(_ref_frame, _ref_point)
			var cells_started := Time.get_ticks_usec()
			var cells := _ref_preview_cells_for_samples(samples, _active_frame(), _settings.tool, _settings.grow_mode, _ref_seed, _context().selection)
			_ref_cells_us += Time.get_ticks_usec() - cells_started
			_ref_cells_calls += 1
			_set_preview(cells)
	rebuild_total_us += Time.get_ticks_usec() - started
	rebuild_calls += 1


# The frozen old hover frame. It fits once per changed hit and entry, keeps the
# same cache key, and keeps the same miss and floor rules. The 483c5f9 copy did
# not include the normal source in its key, so this copy keeps that key.
func _ref_compute_hover_frame(pick: PickResult) -> void:
	var before := _ref_frame
	var started := Time.get_ticks_usec()
	_ref_hover_frame_body(pick)
	_ref_hover_us += Time.get_ticks_usec() - started
	_ref_hover_calls += 1
	if _ref_frame == before:
		_ref_hover_hits += 1
	else:
		_ref_hover_misses += 1
	# The old probe incremented these fields directly, and the benchmark reads
	# them right after the input event. The publish sync would otherwise hide the
	# fit that the input just ran.
	hover_frame_us = _ref_hover_us
	hover_frame_calls = _ref_hover_calls
	hover_frame_hits = _ref_hover_hits
	hover_frame_misses = _ref_hover_misses


func _ref_hover_frame_body(pick: PickResult) -> void:
	var active := _active_frame()
	if active == null:
		_ref_frame = null
		return
	if pick.hit == VoxelPicking.NONE:
		# A miss uses the floor plane. A parallel ray leaves no target, so the
		# hover has no frame and the sentinel arithmetic never runs.
		if pick.target == VoxelPicking.NONE:
			_ref_frame = null
			return
		var floor_axis: int = State.floor_axis
		var level := float(State.floor_index) - 0.5
		var floor_sign := 1 if pick.target[floor_axis] >= State.floor_index else -1
		_ref_frame = SculptFrame.from_floor(floor_axis, floor_sign, level, pick.target)
		_ref_point = _ref_frame.origin
		_ref_seed = true
		return
	_ref_seed = false
	if _ref_key == pick.hit and _ref_entry == pick.entry and _ref_frame != null:
		return
	_ref_key = pick.hit
	_ref_entry = pick.entry
	var entry := pick.entry
	if entry == Vector3i.ZERO:
		entry = Vector3i.ZERO
		entry[VoxelPicking.view_axis(_forward())] = 1
	var fallback := SculptFrame.from_face(pick.hit, entry)
	if _settings.normal_source == SculptSettings.NormalSource.FACE:
		_ref_frame = fallback
	else:
		_ref_frame = _fit_surface(active, pick.hit, entry, _settings.radius, fallback)
	_ref_point = _ref_frame.origin


# The frozen old sample loop. It calls the probe body so the frozen query still
# reaches `_ref_sample_map`, and it times the map body. The current probe reports
# the map body as its sample stage, so the loop needs no separate field.
func _ref_hover_samples(frame: SculptFrame, center_point: Vector3) -> Array:
	var started := Time.get_ticks_usec()
	var built := _sample_map_body(frame, center_point, _settings.radius, _settings.falloff)
	_ref_sample_us += Time.get_ticks_usec() - started
	_ref_sample_calls += 1
	var samples := []
	for key in built:
		samples.append(built[key])
	return samples


# The frozen old Smooth hover. The shipped body kept its definition, so the
# frozen path calls it. At 483c5f9 the Smooth hover never used the frozen surface
# query, and this file keeps that split.
func _ref_hover_smooth_cells() -> Dictionary:
	return _smooth_field_cells(_build_smooth_fields(_ref_frame, _ref_point, _settings.radius, _settings.falloff, _context().selection), _active_frame())


# The frozen old cell pass. It is the shipped `_preview_cells_for_samples` body
# of 483c5f9, kept here because production now shares the pass through
# `SculptPreview`.
func _ref_preview_cells_for_samples(samples: Array, frame: VoxelFrame, tool: int, grow_mode: int, seed_empty: bool, selection: Dictionary) -> Dictionary:
	var cells := {}
	var changes := {}
	for sample in samples:
		if float(sample["weight"]) <= 0.0:
			continue
		var surface: Vector3i = sample["surface"]
		var normal: Vector3 = sample["normal"]
		var point: Vector3 = sample["point"]
		match tool:
			SculptSettings.Tools.GROW:
				if grow_mode == SculptSettings.GrowMode.ADD:
					var destination := SculptGeometry.grow_add_cell(frame, changes, surface, normal, point, seed_empty, selection)
					if destination == VoxelPicking.NONE:
						continue
					cells[destination if surface == VoxelPicking.NONE else surface] = true
				else:
					var target := SculptGeometry.grow_remove_cell(surface, selection)
					if target != VoxelPicking.NONE:
						cells[target] = true
			SculptSettings.Tools.FLATTEN:
				var action := SculptGeometry.flatten_action(frame, changes, surface, normal, point, sample["plane_origin"], FLATTEN_THRESHOLD, seed_empty, selection)
				var cell: Vector3i = action["cell"]
				if cell == VoxelPicking.NONE:
					continue
				cells[cell if action.get("seed", false) else surface] = true
	return cells


## Returns the exact preview result of the last rebuild together with the
## installed mesh. The caller compares the arrays element by element, so a hash
## or a count is never the proof of parity.
func exact_snapshot() -> Dictionary:
	if _cursor == null:
		bind_cursor()
	var cells: Array = last_cells.keys()
	cells.sort()
	var snapshot := {
		"cells": cells,
		"vertices": PackedVector3Array(),
		"aabb": AABB(),
		"surfaces": 0,
	}
	if _cursor != null and _cursor.mesh != null:
		snapshot["surfaces"] = (_cursor.mesh as Mesh).get_surface_count()
		if int(snapshot["surfaces"]) > 0:
			snapshot["vertices"] = _cursor.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			snapshot["aabb"] = _cursor.mesh.get_aabb()
	return snapshot


func _pick_production(origin: Vector3, dir: Vector3) -> PickResult:
	# The production pick body, so both paths share the current movement
	# implementation: the pointer ray record, the Grab camera drag, the floor
	# fallback, and the press fit all stay production.
	var pick := super._pick_production(origin, dir)
	# The frozen old hover pick fits here, and the hover then fits one more in
	# [method _ref_compute_hover_frame]. The probe times the whole pick, so the
	# reference `pick_total_us` holds this fit and the candidate `pick_total_us`
	# does not. `fit_us` reports the same fit apart. A press keeps the production
	# fit, because a press has an open edit.
	if use_reference and _edit == null and _settings.tool != SculptSettings.Tools.GRAB:
		_pending_frame = _frame_for_pick(pick, origin)
		pick.plane = _plane_for(_pending_frame.origin, _pending_frame.normal)
		_press_point = _plane_hit(_pending_frame, origin, dir)
	return pick


func reset_probe() -> void:
	super.reset_probe()
	_ref_hover_us = 0
	_ref_hover_calls = 0
	_ref_hover_hits = 0
	_ref_hover_misses = 0
	_ref_sample_us = 0
	_ref_sample_calls = 0
	_ref_cells_us = 0
	_ref_cells_calls = 0


# The probe syncs its stage fields from the preview controller on every publish.
# The frozen path has no controller stages, so this adapter restores the frozen
# totals after that sync. The old probe incremented its stage fields directly.
# The current probe reports its map stage as `hover_samples_total_us`, and that
# field feeds `sample_us`, so the frozen map time goes there.
func _set_preview(cells: Dictionary) -> void:
	super._set_preview(cells)
	if not use_reference:
		return
	hover_frame_us = _ref_hover_us
	hover_frame_calls = _ref_hover_calls
	hover_frame_hits = _ref_hover_hits
	hover_frame_misses = _ref_hover_misses
	hover_samples_total_us = _ref_sample_us
	hover_samples_calls = _ref_sample_calls
	cells_us = _ref_cells_us
	cells_calls = _ref_cells_calls


# Reports the frozen totals in place of the controller stages. The probe fields
# already hold them after a publish, and this overwrite keeps a read between a
# fit and the next publish exact too. The controller counters are zeroed because
# the frozen path never launches or publishes a hover job.
func counters() -> Dictionary:
	var base := super.counters()
	if use_reference:
		base["hover_us"] = _ref_hover_us
		base["hover_calls"] = _ref_hover_calls
		base["hover_hits"] = _ref_hover_hits
		base["hover_misses"] = _ref_hover_misses
		base["hover_samples_us"] = _ref_sample_us
		base["hover_samples"] = _ref_sample_calls
		base["sample_us"] = _ref_sample_us
		base["sample_maps"] = _ref_sample_calls
		base["cells_us"] = _ref_cells_us
		base["cells_calls"] = _ref_cells_calls
		base["rebuilds"] = rebuild_calls
		base["launches"] = 0
		base["publishes"] = 0
		base["discarded"] = 0
		base["snapshot_us"] = 0
	return base
