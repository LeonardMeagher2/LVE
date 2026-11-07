class_name TerrainPrep
extends RefCounted

## The pure stroke preparation math of the terrain tool.
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

const TerrainSettings := preload("./TerrainToolSettings.gd")


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
	var cell: Vector3i = sample["surface"]
	if cell == VoxelPicking.NONE:
		cell = TerrainGeometry.cell_at((sample["point"] as Vector3) - normal * 0.5)
	return TerrainGeometry.column_key(cell, normal)


## Returns the credited-influence key of one sample.
##
## Build keys by the stable logical column, so a rising effect origin keeps one
## entry per physical column and no soft-edge credit resets. Flatten keeps its
## anchor key, because its operation plane is fixed and its anchors are already
## stable at any height.
static func progress_key(sample: Dictionary, tool: int) -> Vector3i:
	if tool == TerrainSettings.Tools.BUILD:
		return column_key(sample)
	return sample["anchor"]


## Returns one entry per logical column with at least one whole step to apply.
##
## The step count is the strength scaled by the falloff weight of that column. A
## fraction below one half adds nothing. Two rows that share a key keep the first
## row and the strongest weight, so one dab applies one step list per column. The
## step list order follows the sample map order.
static func collect_steps(samples: Dictionary, tool: int, strength: int) -> Array:
	var out := []
	var order := []
	var best := {}
	for anchor in samples:
		var sample: Dictionary = samples[anchor]
		var key := progress_key(sample, tool)
		if not best.has(key):
			best[key] = {"sample": sample, "weight": 0.0}
			order.append(key)
		var entry: Dictionary = best[key]
		entry["weight"] = maxf(float(entry["weight"]), float(sample["weight"]))
	for key in order:
		var entry: Dictionary = best[key]
		var steps := roundi(float(strength) * float(entry["weight"]))
		if steps <= 0:
			continue
		var sample: Dictionary = entry["sample"]
		out.append({
			"anchor": sample["anchor"],
			"key": key,
			"point": sample["point"],
			"normal": sample["normal"],
			"plane_origin": sample["plane_origin"],
			"surface": sample["surface"],
			"seed": sample.get("seed", sample["anchor"]),
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


## Returns the operation plane of a Smooth dab re-read from the current surface.
##
## The previous frame is the fallback and the seed, so a sparse or degenerate
## read keeps the previous orientation and the normal never flips. The entered
## face of the actual hit wins when it is nearly perpendicular to the stroke
## normal, so a vertical side follows its own axis. The result is the unchanged
## [param stroke_frame] when no surface is found, so the caller keeps its frame.
##
## The stroke axis is the default seed, so a slope keeps the shipped rounding.
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


## Returns one rounding field per active symmetry mask.
##
## The candidates fill a sphere of the brush size around the dab point. The
## falloff sets the weight of each cell. A cell is writable only when the frozen
## selection allows it.
##
## [param context] supplies the symmetry. A selection that is not the context's
## own is copied into a fresh context, so the frozen context is never mutated.
## [param job] supplies the cancel checkpoints of a worker. The result is
## unchanged when the job is null or uncancelled.
static func smooth_fields(center_point: Vector3, radius: int, falloff: float, context: VoxelFrame.EditContext, selection: Dictionary, job: VoxelFrame.EditJob = null) -> Array:
	var use_context := context
	if use_context != null and not is_same(use_context.selection, selection):
		# A duplicate keeps the slice and the document size limit. A manual copy
		# dropped both.
		use_context = use_context.duplicate()
		use_context.selection = selection
	return TerrainPreview.compute_smooth_fields(center_point, radius, falloff, use_context, job)
