class_name TerrainPrep
extends RefCounted


const TerrainSettings := preload("./TerrainToolSettings.gd")


static func column_key(sample: Dictionary) -> Vector3i:
	var normal: Vector3 = sample["normal"]
	var cell: Vector3i = sample["surface"]
	if cell == VoxelPicking.NONE:
		cell = TerrainGeometry.cell_at((sample["point"] as Vector3) - normal * 0.5)
	return TerrainGeometry.column_key(cell, normal)


static func progress_key(sample: Dictionary, tool: int) -> Vector3i:
	if tool == TerrainSettings.Tools.BUILD:
		return column_key(sample)
	return sample["anchor"]


static func collect_steps(samples: Dictionary, tool: int, strength: int) -> Array:
	var order: Array[Vector3i] = []
	var picked := []
	var weights := PackedFloat64Array()
	var slots := {}
	for anchor in samples:
		var sample: Dictionary = samples[anchor]
		var key := progress_key(sample, tool)
		var weight := float(sample["weight"])
		var slot: int = slots.get(key, -1)
		if slot < 0:
			slots[key] = order.size()
			order.append(key)
			picked.append(sample)
			weights.append(weight)
		elif weight > weights[slot]:
			weights[slot] = weight
	var scale := float(strength)
	var out := []
	for index in order.size():
		var steps := roundi(scale * weights[index])
		if steps <= 0:
			continue
		var sample: Dictionary = picked[index]
		var anchor: Vector3i = sample["anchor"]
		out.append({
			"anchor": anchor,
			"key": order[index],
			"point": sample["point"],
			"normal": sample["normal"],
			"plane_origin": sample["plane_origin"],
			"surface": sample["surface"],
			"seed": sample["seed"] if sample.has("seed") else anchor,
			"steps": steps,
		})
	return out


static func known_surfaces(samples: Dictionary) -> Dictionary:
	var known := {}
	for anchor in samples:
		var sample: Dictionary = samples[anchor]
		known[sample["anchor"]] = sample["surface"]
	return known


static func smooth_surface_frame(frame: VoxelFrame, stroke_frame: TerrainFrame, center_point: Vector3, entry: Vector3i, radius: int, depth: int) -> TerrainFrame:
	if stroke_frame == null:
		return null
	var hit := TerrainGeometry.cell_at(center_point)
	var axis := TerrainGeometry.dominant_axis(stroke_frame.normal)
	var use_entry := Vector3i.ZERO
	use_entry[axis] = 1 if stroke_frame.normal[axis] >= 0.0 else -1
	if entry != Vector3i.ZERO and absf(Vector3(entry).normalized().dot(stroke_frame.normal)) < 0.5:
		use_entry = entry
	if not frame.has(hit):
		var surface := TerrainGeometry.surface_along(frame, center_point, Vector3(use_entry).normalized(), depth, {})
		if surface == VoxelPicking.NONE:
			return stroke_frame
		hit = surface
	return TerrainFrame.from_surface(frame, hit, use_entry, radius, stroke_frame)


static func smooth_fields(center_point: Vector3, radius: int, falloff: float, context: VoxelFrame.EditContext, selection: Dictionary, job: VoxelFrame.EditJob = null) -> Array:
	var use_context := context
	if use_context != null and not is_same(use_context.selection, selection):
		use_context = use_context.duplicate()
		use_context.selection = selection
	return TerrainPreview.compute_smooth_fields(center_point, radius, falloff, use_context, job)
