class_name SculptPrep
extends RefCounted

## The pure stroke preparation math of the sculpt tool.
##
## The tool and its worker jobs read one definition of the footprint
## preparation. The tool needs it for a small dab and the worker needs it for a
## large dab, so the definition must not live on the node.
##
## Every function is pure. It reads one explicit sample map, one explicit
## progress map, and the tool id. It never reads [code]State[/code] or a node,
## and it never changes its inputs. A worker can therefore run it while the main
## thread keeps processing input.
##
## The tool preloads this script, so a job resolves it without the global class
## cache.

const SculptSettings := preload("./SculptToolSettings.gd")

## The tolerance that snaps accumulated progress to an integer step boundary. A
## split of one probe influence then applies the same steps as one call. The
## value is far below one voxel, so a true fractional influence is unaffected.
const PROGRESS_EPSILON := 1e-6


## Returns the stable logical column of one sample.
##
## The layer model writes one column along the dominant axis of the normal and
## keeps the other two world coordinates. Those two coordinates stay fixed while
## the column grows, and the effect origin only moves along the normal, so the
## same physical column keeps the same key at any height. The axis and its signed
## orientation join the key, so two opposing normals never merge their credited
## influence. The column cell is the resolved surface, or the empty seed when the
## surface is missing. A layer model reads at most one surface per column, so two
## disconnected runs never share a key.
static func column_key(sample: Dictionary) -> Vector3i:
	var normal: Vector3 = sample["normal"]
	var axis := SculptGeometry.dominant_axis(normal)
	var sign_bit := 1 if normal[axis] >= 0.0 else 0
	var cell: Vector3i = sample["surface"]
	if cell == VoxelPicking.NONE:
		cell = SculptGeometry.cell_at((sample["point"] as Vector3) - normal * 0.5)
	return Vector3i(axis * 2 + sign_bit, cell[(axis + 1) % 3], cell[(axis + 2) % 3])


## Returns the credited-influence key of one sample.
##
## Grow keys by the stable logical column, so a rising effect origin keeps one
## entry per physical column and no soft-edge credit resets. Flatten keeps its
## anchor key, because its operation plane is fixed and its anchors are already
## stable at any height.
static func progress_key(sample: Dictionary, tool: int) -> Vector3i:
	if tool == SculptSettings.Tools.GROW:
		return column_key(sample)
	return sample["anchor"]


## Returns the progress map after one application earns influence on the given
## samples. The input map stays unchanged, so a worker can read it.
##
## One logical column takes one unique influence. Two rows that map to the same
## column, such as a tilted disc, must not sum, or one dab would double the
## column. The progress keeps the full earned amount, so a soft edge keeps its
## fractional influence across dabs. The strength is the step count of one
## application at full weight. An application count that earns nothing returns
## the input map itself, so an idle call never reallocates the history.
static func accumulated(progress: Dictionary, samples: Dictionary, tool: int, strength: float, applications: float) -> Dictionary:
	if applications <= 0.0:
		return progress
	var weights := {}
	for anchor in samples:
		var sample: Dictionary = samples[anchor]
		var key := progress_key(sample, tool)
		var weight: float = sample["weight"]
		if not weights.has(key) or weight > float(weights[key]):
			weights[key] = weight
	if weights.is_empty():
		return progress
	var out := progress.duplicate()
	for key in weights:
		out[key] = float(out.get(key, 0.0)) + strength * float(weights[key]) * applications
	return out


## Returns one entry per logical column with at least one whole step to apply.
##
## The row holds the anchor, the stable key, the sample point and normal, the
## plane origin, and the tracked surface, so the tick reads one definition. Two
## rows that share a key keep the first one, so one dab applies one step per
## column. The step list order follows the sample map order.
static func collect_steps(samples: Dictionary, progress: Dictionary, tool: int) -> Array:
	var out := []
	var seen := {}
	for anchor in samples:
		var sample: Dictionary = samples[anchor]
		var key := progress_key(sample, tool)
		if seen.has(key):
			continue
		seen[key] = true
		var steps := int(floor(float(progress.get(key, 0.0)) + PROGRESS_EPSILON))
		if steps <= 0:
			continue
		out.append({
			"anchor": anchor,
			"key": key,
			"point": sample["point"],
			"normal": sample["normal"],
			"plane_origin": sample["plane_origin"],
			"surface": sample["surface"],
			"steps": steps,
		})
	return out


## Returns the tracked surface of every existing anchor, keyed by anchor. A
## persisting column then never re-scans its column. The input map is unchanged.
static func known_surfaces(samples: Dictionary) -> Dictionary:
	var known := {}
	for anchor in samples:
		var sample: Dictionary = samples[anchor]
		known[sample["anchor"]] = sample["surface"]
	return known


## Returns the operation plane of a Smooth dab refitted to the current surface.
##
## The previous frame is the fallback and the seed, so a sparse or degenerate
## fit keeps the previous orientation and the normal never flips. The entered
## face of the actual hit wins when it is nearly perpendicular to the stroke
## normal, so a vertical side fits its own axis. The result is the unchanged
## [param stroke_frame] when no surface is found, so the caller keeps its frame.
##
## The stroke axis is the default seed, so a slope keeps the shipped rounding.
static func refit_smooth_frame(frame: VoxelFrame, stroke_frame: SculptFrame, center_point: Vector3, entry: Vector3i, source: int, radius: int, depth: int) -> SculptFrame:
	if stroke_frame == null:
		return null
	var hit := SculptGeometry.cell_at(center_point)
	var axis := SculptGeometry.dominant_axis(stroke_frame.normal)
	var use_entry := Vector3i.ZERO
	use_entry[axis] = 1 if stroke_frame.normal[axis] >= 0.0 else -1
	if entry != Vector3i.ZERO and absf(Vector3(entry).normalized().dot(stroke_frame.normal)) < 0.5:
		use_entry = entry
	if not frame.has(hit):
		var surface := SculptGeometry.surface_along(frame, center_point, Vector3(use_entry).normalized(), depth, {})
		if surface == VoxelPicking.NONE:
			return stroke_frame
		hit = surface
	if source == SculptSettings.NormalSource.FACE:
		return SculptFrame.from_face(hit, use_entry)
	return SculptFrame.fit(frame, hit, use_entry, radius, stroke_frame)


## Returns one rounding field per active symmetry mask.
##
## The candidates follow the local surface along the fitted normal, so a thin
## spike top and a sloped surface are both reached. The patch stops at the brush
## disc and at [param reach] cells along the normal. The falloff sets the weight
## of each cell. A cell is writable only when the frozen selection allows it.
##
## [param context] supplies the symmetry. A selection that is not the context's
## own is copied into a fresh context, so the frozen context is never mutated.
## [param job] supplies the cancel checkpoints of a worker. The result is
## unchanged when the job is null or uncancelled.
static func smooth_fields(frame: VoxelFrame, sculpt_frame: SculptFrame, center_point: Vector3, radius: int, falloff: float, context: VoxelFrame.EditContext, selection: Dictionary, depth: int, reach: int, job: VoxelFrame.EditJob = null) -> Array:
	var use_context := context
	if use_context != null and not is_same(use_context.selection, selection):
		var copy := VoxelFrame.EditContext.new()
		copy.axes = use_context.axes
		copy.origin_twice = use_context.origin_twice
		copy.selection = selection
		use_context = copy
	return SculptPreview.compute_smooth_fields(frame, sculpt_frame, center_point, radius, falloff, use_context, depth, reach, job)


## Returns the new rounding fields with the fractional pass carry and the
## world-cell credits of the surviving candidates of the previous fields. A
## candidate that left the patch loses its credit, so a moved brush never keeps
## an unrelated cell. The previous list is unchanged.
static func merge_smooth_fields(fields: Array, previous: Array) -> Array:
	for index in fields.size():
		if index >= previous.size():
			continue
		var old: Dictionary = previous[index]
		var old_credits: Dictionary = old["credits"]
		var credits := {}
		for cell: Vector3i in fields[index]["cells"]:
			if old_credits.has(cell):
				credits[cell] = old_credits[cell]
		fields[index]["credits"] = credits
		fields[index]["carry"] = float(old["carry"])
	return fields
