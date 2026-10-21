extends "res://tests/benchmarks/sculpt_preview_probe.gd"

## A test-only probe that can run the frozen old hover path beside the current
## production path.
##
## `use_reference == false` runs production through `super`. The candidate of a
## later optimization is production itself, so that side needs no copy here.
##
## `use_reference == true` runs a frozen copy of the hover path that the baseline
## measured: the pick fits a frame for the press, and then the hover fits one
## more. The copy stays old after production changes, so an A/B keeps a stable
## reference. It is not a candidate and it claims no gain.
##
## The copy is written from `plugins/Sculpt/SculptTool.gd` as read on
## 2026-10-21 (`_pick_start` and `_compute_hover_frame`). It reads
## `_pending_frame`, `_press_point`, `_hover_key`, `_hover_entry`, `_hover_frame`,
## `_hover_point`, and `_hover_seed_empty`, and it calls `_frame_for_pick`,
## `_plane_for`, `_plane_hit`, and `_active_frame`. If production renames or
## removes one of those, this file fails to compile. That loud failure is
## deliberate: a silent fallback would corrupt the comparison.
##
## `_frame_for_pick` and `_sample_map` are not overridden here. Their probe timers
## wrap a body hook, so this file routes the frozen surface query through those
## hooks and the timers stay exact on both paths. The frozen pick feeds the pick
## counters itself, because it does not call the production `_pick_start`.
##
## The frozen pick deliberately omits one production side effect: the movement
## spacing ray that production records at the top of `_pick_start`. That record
## is not part of the hover preview cost, and a press never runs the frozen path
## (a press has an open edit, so `_pick_start` sends it to production). Keep this
## copy free of features that do not change the fit count.

const SurfaceQuery := preload("./sculpt_preview_surface.gd")

## Whether the tool runs the frozen old hover path.
var use_reference := false
## Whether the fit and the footprint map read the frozen old surface query. It
## changes no cell set, so it isolates the query cost from the fit count.
var use_reference_surface := false


## Returns the frame fit of one hit. The frozen query is used when the surface
## reference is on, and the production fit otherwise.
func _fit_surface(frame: VoxelFrame, hit: Vector3i, entry: Vector3i, radius: int, fallback: SculptFrame) -> SculptFrame:
	if use_reference_surface:
		return SurfaceQuery.fit(frame, hit, entry, radius, fallback)
	return SculptFrame.fit(frame, hit, entry, radius, fallback)


func _frame_for_pick_body(pick: PickResult, origin: Vector3) -> SculptFrame:
	if not use_reference_surface:
		return super._frame_for_pick_body(pick, origin)
	# The production frame fit with the frozen surface query.
	if pick.hit != VoxelPicking.NONE:
		var entry := pick.entry
		if entry == Vector3i.ZERO:
			entry = Vector3i.ZERO
			entry[VoxelPicking.view_axis(_forward())] = 1
		var fallback := SculptFrame.from_face(pick.hit, entry)
		return _fit_surface(State.get_current_voxel_frame(), pick.hit, entry, _settings.radius, fallback)
	var floor_axis: int = State.floor_axis
	var level := float(State.floor_index) - 0.5
	var floor_sign := 1 if origin[floor_axis] >= level else -1
	return SculptFrame.from_floor(floor_axis, floor_sign, level, pick.target)


func _sample_map_body(sculpt_frame: SculptFrame, center_point: Vector3, radius: int, falloff: float, known: Dictionary = {}) -> Dictionary:
	if not use_reference_surface:
		return super._sample_map_body(sculpt_frame, center_point, radius, falloff, known)
	return _sample_map_frozen(sculpt_frame, center_point, radius, falloff, known)


# The frozen footprint map: the production loop with the frozen surface query.
func _sample_map_frozen(sculpt_frame: SculptFrame, center_point: Vector3, radius: int, falloff: float, known: Dictionary) -> Dictionary:
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
			var surface: Vector3i = known[anchor] if known.has(anchor) else SurfaceQuery.surface_along(active, point, reflected.normal, depth, {})
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
	# [method _freeze_hover_frame]. The timed span of the probe covers both, so
	# `pick_total_us` reads the same way on both paths. A press keeps the
	# production fit, because a press has an open edit.
	if use_reference and _edit == null and _settings.tool != SculptSettings.Tools.GRAB:
		_pending_frame = _frame_for_pick(pick, origin)
		pick.plane = _plane_for(_pending_frame.origin, _pending_frame.normal)
		_press_point = _plane_hit(_pending_frame, origin, dir)
	return pick


func _compute_hover_frame(pick: PickResult) -> void:
	if not use_reference:
		super._compute_hover_frame(pick)
		return
	var before := _hover_frame
	var started := Time.get_ticks_usec()
	_freeze_hover_frame(pick)
	hover_frame_us += Time.get_ticks_usec() - started
	hover_frame_calls += 1
	if _hover_frame == before:
		hover_frame_hits += 1
	else:
		hover_frame_misses += 1


# The frozen old hover frame. It fits once per changed hit and entry, keeps the
# same cache key, and keeps the same miss and floor rules.
func _freeze_hover_frame(pick: PickResult) -> void:
	var active := _active_frame()
	if active == null:
		_hover_frame = null
		return
	if pick.hit == VoxelPicking.NONE:
		# A miss uses the floor plane. A parallel ray leaves no target, so the
		# hover has no frame and the sentinel arithmetic never runs.
		if pick.target == VoxelPicking.NONE:
			_hover_frame = null
			return
		var floor_axis: int = State.floor_axis
		var level := float(State.floor_index) - 0.5
		var floor_sign := 1 if pick.target[floor_axis] >= State.floor_index else -1
		_hover_frame = SculptFrame.from_floor(floor_axis, floor_sign, level, pick.target)
		_hover_point = _hover_frame.origin
		_hover_seed_empty = true
		return
	_hover_seed_empty = false
	if _hover_key == pick.hit and _hover_entry == pick.entry and _hover_frame != null:
		return
	_hover_key = pick.hit
	_hover_entry = pick.entry
	var entry := pick.entry
	if entry == Vector3i.ZERO:
		entry = Vector3i.ZERO
		entry[VoxelPicking.view_axis(_forward())] = 1
	var fallback := SculptFrame.from_face(pick.hit, entry)
	_hover_frame = _fit_surface(active, pick.hit, entry, _settings.radius, fallback)
	_hover_point = _hover_frame.origin
