extends VoxelTool


## The terrain tool.
##
## The tool grows, flattens, smooths, or grabs voxels on a surface plane.
## A press reads the local voxel surface, so a slope follows the
## surface instead of a cube face. A read that is too sparse or too ambiguous
## falls back to the clicked face. A press that misses the model uses the floor
## plane. Build and Flatten lock the surface plane for the stroke. Smooth re-reads
## its operation plane to the accepted surface, while its input anchors stay on
## the frozen cursor plane.
##
## Build, Flatten, and Smooth apply one dab on the press and one dab for every
## cell the pointer crosses. A still pointer adds nothing. Each dab applies the
## full strength at full weight, so the default strength of one shows one layer
## at the brush center. The falloff scales the influence of each dab, so a soft
## edge keeps a fractional influence across dabs. The input path is a queue of
## motion segments, and its crossed cells are generated one at a time as the
## queue drains, so a long motion never builds a full path array and no accepted
## cell is dropped. A long drain yields a frame between bounded batches. An
## accepted press or motion anchor is the cell of the frozen cursor plane, so a
## later surface read never moves it. Each Build and Flatten column keeps its own support
## lookup on that fixed plane. The lookup reaches 64 cells, beyond the old
## per-radius bound. It does not provide unrestricted height. Grab is a
## proportional stretch drag on the true camera-facing plane. A large dab or drag
## runs on the worker pool: the
## footprint map of a Build or Flatten dab, the rounding fields of a Smooth dab,
## and every write. A small dab stays inline, so a press with a small brush
## edits in its input event. A burst of input drains after the release and
## commits as one history action. Escape and an edit context change roll the
## stroke back.


const TerrainSettings := preload("./TerrainToolSettings.gd")
const SmoothOperation := preload("./SmoothOperation.gd")
const TerrainRing := preload("./TerrainRing.gd")
# The shared pure preparation math. The tool and its worker jobs preload it, so
# a job resolves it without the global class cache.
const Prep := preload("./TerrainPrep.gd")


## The estimated work above which a dab or a drag runs on the worker pool.
const INLINE_EDIT_LIMIT := 4096
## The footprint candidates above which a dab builds its map on the worker pool.
## The map and the surface scan follow the disc, so their cost grows with the
## disc area. A small disc stays inline, so a press edits in its input event. A
## large disc runs on the worker, so the frame that accepted it keeps processing
## input. The symmetry count multiplies the candidates, because every active mask
## adds its own footprint.
const PREP_CANDIDATE_LIMIT := 512
# A large dab runs on the worker pool, and the main thread waits whole render
# frames for the result. A batch of several crossed centers pays that wait once.
# The target is a few frames of worker time: a batch shorter than one frame
# wastes the wait, and a much longer one delays the visible result.
const PREP_BATCH_MAX := 8
const PREP_BATCH_TARGET_US := 50000
## The height lookup depth of one Build or Flatten footprint column. The walk is
## bounded, and the bound matches the deepest footprint walk the tool already
## shipped at the maximum radius. A taller bound than the old per-radius depth
## resolves a column whose support sits above it, which is the artificial height
## limit. The operation plane never moves, so the kernel coverage and the profile
## inside the old bound are unchanged.
const HEIGHT_LOOKUP_LIMIT := 64
## The largest Grab drag distance in voxels.
const GRAB_MAX_DISTANCE := 48.0
## The most dabs one drain applies. A longer accepted path continues on the next
## deferred drain, so a giant jump never blocks one frame and no accepted cell is
## dropped.
const DABS_PER_DRAIN := 32
## The main-thread time one drain may spend applying dabs before it yields a
## frame. A long frame starves pointer input, so the budget is time, not count.
const DRAIN_BUDGET_US := 8000
## The minimum screen distance between two accepted Build, Flatten, or Smooth
## dabs. A view nearly parallel to the cursor plane moves the anchor several
## cells per pixel, so a move the user cannot see must not add a layer.
const MIN_DAB_PIXELS := 3.0
## The half-cell distance that decides a flatten cut, a fill, or a settled
## sample.
const FLATTEN_THRESHOLD := 0.5
## The kept state entries above which the stroke drops the entries that left
## the footprint.
const STATE_LIMIT := 65536
## The largest cell distance of the local material search of a Smooth fill.
const SMOOTH_SOURCE_SEARCH := 3
## The most snapshot reads one local occupancy gather makes between two
## cancellation checks. One chunk holds this many grid slots, so a scan checks
## once per chunk.
const OCCUPANCY_READ_CHECKPOINT := 4096
## The largest box volume that the local occupancy gather accepts, as a multiple
## of the per-candidate kernel lookups it replaces. One grid slot read is far
## cheaper than one frame lookup, so a box several times the lookup count still
## wins. The cap also bounds the gathered set and the box between a scattered
## candidate set. A larger box keeps the exact per-candidate loop.
const OCCUPANCY_BOX_LIMIT := 4
## Limit each box span before multiplying the dimensions. Keep the exact loop
## for larger spans, so the volume product never overflows.
const OCCUPANCY_BOX_SPAN := 1 << 20


var _settings: TerrainToolSettings = preload("./settings.tres")


# The stroke state.
var _stroke_tool := 0
var _stroke_build_mode := 0
var _stroke_radius := 4
var _stroke_strength := 1
var _stroke_falloff := 0.5
var _stroke_material := PackedFloat32Array()
var _stroke_context: VoxelFrame.EditContext
var _stroke_selection := {}
var _stroke_frame: TerrainFrame
# The frozen spacing reference of the stroke. The pick anchors and the dab
# centers use it, so the input path never depends on a later surface read of the Smooth
# operation plane. The operation plane is [member _stroke_frame].
var _cursor_frame: TerrainFrame
# The pointer ray of the press. Smooth builds its view-facing cursor plane from
# it, so the anchor and the dab center stay near the surface on a slope.
var _press_ray_origin := Vector3.ZERO
var _press_ray_dir := Vector3.ZERO
# The pointer ray of the latest motion. Build uses it to find the surface under
# the cursor for the ground, even when that surface is outside the brush read.
var _ray_origin := Vector3.INF
var _ray_dir := Vector3.INF
# The explicit floor plane of the open stroke. The press captures it, so a floor
# UI change during a later drain never moves an accepted Build dab. The cell is the
# first buildable cell on the stroke side, so a stroke from below seeds below the
# plane.
var _stroke_floor_axis := 1
var _stroke_floor_cell := 0
var _stroke_center_point := Vector3.ZERO
var _samples := {}
## The surface of each column before this stroke first sampled it. The ground
## follows this base, so the brush never lifts itself.
var _base_surfaces := {}
## The tracked top of every logical column this stroke touched. A column that
## leaves the brush and comes back reuses this top, so a revisit never re-reads
## a grown column from the old plane.
var _stroke_columns := {}
# The accepted input path. Each entry is one motion segment, held as its two
# endpoint cells. The crossed cells are generated at drain time, so a long
# motion never builds a full path array and no accepted cell is dropped.
var _segments: Array = []
var _segment_head := 0
# The cursor over the crossed cells of the active segment. One entry is one real
# motion, so the queue never grows with the number of crossed cells.
var _dab_path: StrokeLine.Cursor
var _drain_active := false
# The stroke id of the running drain. A zombie drain that resumes after a frame
# yield must not retire the flag of a newer drain.
var _drain_stroke_id := -1
var _end_requested := false
var _close_action := "Build"
var _stroke_id := 0
var _stroke_tx: VoxelEditTransaction
var _source_document: VoxelDocument
var _source_frame: VoxelFrame
var _pending_frame: TerrainFrame
# The ray and plane intersection of the press. The press anchor is the cell of
# this point, so a later motion at the same pointer position gives the same
# anchor and adds no dab.
var _press_point := Vector3.ZERO
# The anchor cell of the last dab. The stroke walks the crossed cells from this
# anchor to the new pick cell, so the same path gives the same dabs at any
# event rate.
var _path_anchor := VoxelPicking.NONE
# The pointer ray of the last drag pick, and whether it moved since then. A
# repeat of the same ray adds no dab, so a Smooth plane read while the pointer
# holds still never invents a dab.
var _drag_ray_origin := Vector3.INF
var _drag_ray_dir := Vector3.INF
var _drag_ray_moved := true
# The Smooth placement state. The stroke captures the camera ray of every
# accepted motion, and each dab reconstructs its own ray and resolves the real
# hit on the accepted frame at dab time. No hit position is resolved at input
# time, so a queued dab never depends on when a worker published.
var _stroke_forward := Vector3.ZERO
# The Smooth placement camera family, captured at the press. The projection mode
# picks the family: a perspective or frustum camera shares one focus, an
# orthographic camera keeps one direction and translates the origin. A live
# camera never changes an accepted dab.
var _camera_perspective := false
var _camera_focus := Vector3.ZERO
var _stroke_ray_dir := Vector3.ZERO
var _press_ray_offset := Vector3.ZERO
var _press_camera_transform := Transform3D()
var _press_projection := -1
var _dab_ray_origin := Vector3.INF
var _dab_ray_dir := Vector3.INF
# The resolved actual hit and entry of the last Smooth dab.
var _smooth_hit := VoxelPicking.NONE
var _smooth_entry := Vector3i.ZERO


# The Grab state.
var _grab_sources: Array = []
var _grab_source_cells := {}
var _grab_baseline: VoxelFrame
var _grab_anchor := VoxelPicking.NONE
var _grab_drag := VoxelPicking.NONE
var _grab_pending_delta = null
var _grab_empty := false
# The chunk locations the drag has published. A drag recomputes from the
# baseline, so the next publish restores the earlier locations too.
var _grab_published := {}


# The Smooth state. One rounding field per active symmetry mask. A field holds
# the writable candidate cells and its fractional pass carry. The rounding reads
# the frozen occupancy of the candidates, so a mask that shares a cell with
# another never loses a side.
var _smooth_fields: Array = []


var _tick_job: TerrainTickJob
# How many crossed centers one prep job takes. The worker time of the last
# batch sets it, so a broad brush stays at one and a narrow one takes several.
var _prep_batch := 1
var _grab_job: GrabJob
var _smooth_job: SmoothJob
var _operation_id := 0
var _last_pick: PickResult
# The last posed cell and target. A motion inside the same cell does not re-pose
# the ring. The entered face is not part of the gate: a ray that grazes a convex
# edge can report either face for the same cell, and that flipped the ring.
var _visual_hit := VoxelPicking.NONE
var _visual_target := VoxelPicking.NONE
var _visual_valid := false
var _settings_tool := 0
var _settings_build_mode := 0
var _settings_radius := 4
var _settings_falloff := 0.5
var _ball_cache := {}


# The hover preview controller. It owns the hover frame, the cached cells, and
# the worker that computes a cache miss. The tool keeps only the thin adapters:
# the live inputs, the pause rule, the captured view, and the publish.
var _preview: TerrainPreview
# The chunks the recent dabs touched. One signal per frame publishes them.
var _stroke_chunks := {}
var _stroke_flush_queued := false
# The one white footprint ring that every tool poses on the picked cell.
var _footprint: MeshInstance3D
# The ring mesh of each radius. The ring is the same on every cell, so a radius
# builds its mesh once.
var _footprint_meshes := {}
# The frame the last ring pose used. It is the surface hover frame when the idle
# read is ready, so a reader sees the orientation the press will use.
var _idle_pose_frame: TerrainFrame
# The hover frame of the last published hover result. The controller owns it, so
# the tool only forwards it. A normal source test reads it.
var _hover_frame: TerrainFrame:
	get:
		return _preview.hover_frame() if _preview != null else null
# The frame index of the open stroke, so a cell change in another frame never
# invalidates the preview of this one.
var _stroke_frame_index := -1


## Whether the visible preview may not match the current inputs. The hover
## controller owns the flag. The stroke and the Grab paths clear it when they
## publish, and the frame loop reads it.
var _preview_dirty: bool:
	get:
		return _preview.is_dirty() if _preview != null else false


## One cancellable build or flatten tick.
##
## The job reads the surface of every sample from a frame snapshot and writes
## the resulting cells. It reports the tracked surfaces.
## [method VoxelFrame.EditJob.run] is the worker body.
##
## A large dab also sets [member preparing], so the job builds its footprint map
## and its step list from the preparation inputs before it writes. The map then
## runs on the worker too, and the main thread that accepted the dab keeps
## processing input.
class TerrainTickJob extends VoxelFrame.EditJob:
	## The stroke id that the job belongs to.
	var stroke_id := 0
	## The operation id that the job belongs to.
	var operation_id := 0
	## The frame snapshot to read and write.
	var edited_frame: VoxelFrame
	## The footprint samples.
	var samples: Array = []
	## The terrain tool.
	var tool := 0
	## The build direction.
	var build_mode := 0
	## The captured floor plane and the first buildable cell on the stroke side.
	var floor_axis := 1
	var floor_cell := 0
	## The flatten cut and fill threshold.
	var threshold := 0.5
	## The material of every added cell.
	var material := PackedFloat32Array()
	## The selected cells. An empty dictionary allows every cell.
	var selection := {}
	## The tracked surface per sample anchor.
	var surfaces := {}
	## The top of every logical column this job wrote, keyed by column. The main
	## thread merges it into the stroke cache when the job publishes.
	var applied_columns := {}
	## The chunk locations that the tick changed.
	var changed_chunks: Array[Vector3i] = []

	## Whether the job builds its own footprint map and step list before it
	## writes. A small dab leaves it false and passes [member samples] directly.
	var preparing := false
	## The locked frame of the dab. The job reads its normal and its tangent
	## basis, and it never changes the frame.
	var prep_terrain_frame: TerrainFrame
	## The dab center point on the locked frame.
	var prep_center := Vector3.ZERO
	## The pointer ray of the batch, so the ground follows the surface under the
	## cursor even when it is outside the brush read.
	var prep_ray_origin := Vector3.INF
	var prep_ray_dir := Vector3.INF
	var prep_forward := Vector3.BACK
	## The footprint radius, falloff, and bounded scan depth of the map.
	var prep_radius := 4
	var prep_falloff := 0.5
	var prep_depth := 8
	## The frozen edit context of the stroke. It supplies the symmetry masks.
	var prep_context: VoxelFrame.EditContext
	## The tracked surface of every existing anchor, so a persisting column
	## never re-scans. The job reads it and never changes it.
	var prep_known := {}
	## The tracked top of every logical column of the stroke, keyed by column.
	## The job reads it and never changes it.
	var prep_known_columns := {}
	## The base surface of every anchor before this stroke wrote it. The job adds
	## new anchors and publishes the map back.
	var prep_base_known := {}
	## The voxel layers one dab adds at full weight.
	var prep_strength := 1
	## The new sample map the preparation built, or null when the job did not
	## prepare. The main thread adopts it when the job publishes.
	var prepared_samples = null
	## The recentered operation plane of the preparation, or null when the job did
	## not prepare or the tool is not Build.
	var prepared_frame: TerrainFrame
	## The base surfaces the preparation built, or null when the job did not
	## prepare.
	var prepared_base_known = null
	## The dab centers of one accepted batch, in path order. Each center reads
	## the frame and the surface that the previous center left.
	var prep_centers: Array = []
	## The crossed anchor cells of one accepted batch. The job projects each cell
	## with the frame the previous center left, so the moving ground matches the
	## cell-by-cell path.
	var prep_cells: Array = []
	## The worker time of the whole batch. The tool uses it to size the next one.
	var work_us := 0

	## Computes and applies the tick. This is the worker body.
	func run() -> void:
		var started := Time.get_ticks_usec()
		if preparing:
			if prep_cells.is_empty():
				if prep_centers.is_empty():
					prep_centers = [prep_center]
				for center in prep_centers:
					prep_center = center
					if not _prepare_center():
						return
			else:
				# The ground recenters after each center, so the next center is
				# projected with the frame that center left. This matches the
				# cell-by-cell path.
				for cell: Vector3i in prep_cells:
					prep_center = prep_terrain_frame.plane_point(cell) if prep_terrain_frame != null else Vector3(cell)
					if not _prepare_center():
						return
		else:
			if _apply_samples() == null:
				return
		work_us = Time.get_ticks_usec() - started

	# Prepares and applies one center of the batch.
	func _prepare_center() -> bool:
		if not _prepare():
			return false
		if _apply_samples() == null:
			return false
		# The next dab sees the surface this one left, exactly as the main thread
		# would have left it between dabs.
		for anchor in surfaces:
			if prepared_samples.has(anchor):
				prepared_samples[anchor]["surface"] = surfaces[anchor]
		prep_known = Prep.known_surfaces(prepared_samples)
		# The next center of the batch sees the columns this one raised, even
		# when they left the footprint.
		for column in applied_columns:
			prep_known_columns[column] = applied_columns[column]
		return true

	## Applies the step list of one center. Returns null when a cancel stopped it.
	func _apply_samples() -> Variant:
		stage("Terraining voxels", samples.size())
		var changes := {}
		var completed := 0
		for sample in samples:
			var anchor: Vector3i = sample["anchor"]
			var surface: Vector3i = sample["surface"]
			var steps: int = sample["steps"]
			for _step_index in steps:
				var outcome = _step(sample, surface, changes)
				if outcome == null:
					break
				surface = outcome
				completed += 1
				if completed % 512 == 0 and not checkpoint(completed):
					return null
			surfaces[anchor] = surface
			# Flatten's step cell is not the column top, so only Build records a
			# tracked top for the stroke cache.
			if tool == TerrainSettings.Tools.BUILD:
				applied_columns[TerrainGeometry.column_key(anchor, sample["normal"])] = surface
		changed_chunks.append_array(apply_cells(edited_frame, changes))
		return true

	# Builds the footprint map and the whole step list on the worker. The map
	# reads the frame snapshot before any write, so the order matches the inline
	# path. Returns false when a cancel stopped the preparation.
	func _prepare() -> bool:
		stage("Preparing footprint", prep_radius)
		if not checkpoint(0):
			return false
		var built := TerrainPreview.compute_sample_map(edited_frame, prep_terrain_frame, prep_center, prep_radius, prep_falloff, prep_context, prep_depth, prep_known, self, null, prep_base_known, floor_axis, floor_cell, prep_known_columns)
		if not checkpoint(0):
			return false
		prepared_base_known = prep_base_known
		if tool == TerrainSettings.Tools.BUILD and prep_terrain_frame != null:
			var center := _ground_surface(built, prep_center)
			prep_terrain_frame = prep_terrain_frame.recenter_to(center, float(prep_radius))
			prepared_frame = prep_terrain_frame
		prepared_samples = built
		samples = Prep.collect_steps(built, tool, prep_strength)
		return checkpoint(0)

	## Returns the base surface under the batch pointer for the Build ground.
	func _ground_surface(samples: Dictionary, center_point: Vector3) -> Vector3i:
		if prep_terrain_frame == null:
			return VoxelPicking.NONE
		var hit := VoxelPicking.NONE
		if prep_ray_origin != Vector3.INF and prep_ray_dir != Vector3.INF:
			var use_slice := prep_context != null and prep_context.slice_axis >= 0
			var pick := VoxelPicking.start_pick(prep_ray_origin, prep_ray_dir, edited_frame, prep_forward, use_slice)
			hit = pick.hit
		if hit == VoxelPicking.NONE:
			return TerrainPreview.center_surface(samples, center_point)
		var key := TerrainGeometry.column_key(hit, prep_terrain_frame.normal)
		if not prep_base_known.has(key):
			prep_base_known[key] = hit
		return prep_base_known[key]

	# Applies one voxel step to one sample. Returns the new surface, or null
	# when the sample cannot continue.
	func _step(sample: Dictionary, surface: Vector3i, changes: Dictionary) -> Variant:
		if tool == TerrainSettings.Tools.FLATTEN:
			return _flatten_step(sample, surface, changes)
		return _build_step(sample, surface, changes)

	func _build_step(sample: Dictionary, surface: Vector3i, changes: Dictionary) -> Variant:
		var normal: Vector3 = sample["normal"]
		var add := build_mode == TerrainSettings.BuildMode.ADD
		var action := TerrainGeometry.build_layer_cells(edited_frame, changes, surface, normal, sample.get("seed", sample["anchor"]), add, selection)
		var cells: Array = action["cells"]
		if cells.is_empty():
			return null
		# The slice and the document size limit the plan, not the write. A cell
		# that the limit refuses stops the column before the tracked surface can
		# move past it.
		for cell: Vector3i in cells:
			if prep_context != null and not prep_context.allows(cell):
				return null
		var next: Vector3i = action["next"]
		if next != VoxelPicking.NONE and prep_context != null and not prep_context.allows(next):
			return VoxelPicking.NONE
		var value := material if add else VoxelFrame.material(Color.TRANSPARENT)
		for cell: Vector3i in cells:
			changes[cell] = value
		return next

	func _flatten_step(sample: Dictionary, surface: Vector3i, changes: Dictionary) -> Variant:
		var normal: Vector3 = sample["normal"]
		var action := TerrainGeometry.flatten_action(edited_frame, changes, surface, normal, sample["anchor"], sample["plane_origin"], threshold, selection)
		var cell: Vector3i = action["cell"]
		if cell == VoxelPicking.NONE:
			return null
		if prep_context != null and not prep_context.allows(cell):
			return null
		if action.get("add", false):
			changes[cell] = _fill_material(surface, changes)
			return cell
		changes[cell] = VoxelFrame.material(Color.TRANSPARENT)
		var inward := TerrainGeometry.dominant_step(surface, normal, -1)
		if prep_context != null and not prep_context.allows(inward):
			return VoxelPicking.NONE
		if TerrainGeometry.is_occupied(edited_frame, changes, inward):
			return inward
		return VoxelPicking.NONE

	# The full material of the local original support of one raised layer. A
	# pending change wins over the snapshot, so a layer raised earlier in the
	# same job carries its inherited material onward. A column that started
	# empty has no local source, so it uses the captured active material. A kept
	# or cut cell is never repainted.
	func _fill_material(surface: Vector3i, changes: Dictionary) -> PackedFloat32Array:
		if surface != VoxelPicking.NONE:
			if changes.has(surface):
				var pending: PackedFloat32Array = changes[surface]
				if not VoxelFrame.is_empty(pending):
					return pending
			if edited_frame.has(surface):
				return edited_frame.get_material(surface)
		return material


## One cancellable Grab drag.
##
## The job starts from the baseline frame snapshot and moves every captured
## source by its own scaled offset. It keeps the unrelated geometry and the
## full materials. It writes a move only when the destination stays inside the
## selection. [method VoxelFrame.EditJob.run] is the worker body.
class GrabJob extends VoxelFrame.EditJob:
	## The stroke id that the job belongs to.
	var stroke_id := 0
	## The operation id that the job belongs to.
	var operation_id := 0
	## The frame snapshot to read and write. It starts as the baseline copy.
	var edited_frame: VoxelFrame
	## The planned moves. Each entry holds the source cell, the full material,
	## the scaled cell offset, and the weight.
	var moves: Array = []
	## The captured source cells, keyed by cell position.
	var sources := {}
	## The selected cells. An empty dictionary allows every cell.
	var selection := {}
	## The frozen edit context that limits the slice and the document size.
	var context: VoxelFrame.EditContext
	## The chunk locations that the drag changed.
	var changed_chunks: Array[Vector3i] = []

	## Computes and applies the drag. This is the worker body.
	func run() -> void:
		stage("Grabbing voxels", moves.size())
		var planned := []
		for move in moves:
			var source: Vector3i = move["source"]
			var destination: Vector3i = source + move["delta"]
			if destination == source or not _allows(destination) or _blocked(destination):
				continue
			planned.append(move)
		# A higher weight moves first. A tie breaks by the canonical world cell,
		# so two equal weights never depend on the sort order. The first writer of
		# an overlapping destination then wins the same way on every run.
		planned.sort_custom(func(a, b):
			var weight_a := float(a["weight"])
			var weight_b := float(b["weight"])
			if weight_a != weight_b:
				return weight_a > weight_b
			var source_a: Vector3i = a["source"]
			var source_b: Vector3i = b["source"]
			if source_a.y != source_b.y:
				return source_a.y < source_b.y
			if source_a.z != source_b.z:
				return source_a.z < source_b.z
			return source_a.x < source_b.x
		)
		var changes := {}
		for move in planned:
			changes[move["source"]] = VoxelFrame.material(Color.TRANSPARENT)
		var writes := {}
		var completed := 0
		for move in planned:
			var source: Vector3i = move["source"]
			var material: PackedFloat32Array = move["material"]
			var destination: Vector3i = source + move["delta"]
			for cell in StrokeLine.cells(source, destination):
				if cell == source or _blocked(cell) or not _allows(cell) or writes.has(cell):
					continue
				writes[cell] = material
			completed += 1
			if completed % 512 == 0 and not checkpoint(completed):
				return
		for cell in writes:
			changes[cell] = writes[cell]
		changed_chunks = apply_cells(edited_frame, changes)

	func _blocked(cell: Vector3i) -> bool:
		return edited_frame.has(cell) and not sources.has(cell)

	func _allows(cell: Vector3i) -> bool:
		if context != null:
			return context.allows(cell)
		return selection.is_empty() or selection.has(cell)


## One cancellable Smooth rounding tick.
##
## The job runs the local occupancy rounding of every symmetry field on a frame
## snapshot. It reads the frozen snapshot and its own copy of the field state, so
## one tick is deterministic and a worker never reads a shared mutable set. A
## removed cell is transparent. A new fill inherits the full material of its
## nearest local original support cell, never the active paint. [method
## VoxelFrame.EditJob.run] is the worker body.
class SmoothJob extends VoxelFrame.EditJob:
	## The stroke id that the job belongs to.
	var stroke_id := 0
	## The operation id that the job belongs to.
	var operation_id := 0
	## The frame snapshot to read and write.
	var edited_frame: VoxelFrame
	## The rounding fields. Each field holds "cells" and "weights".
	## The tool copies the state before it hands it to the worker.
	var fields: Array = []
	## The pass count of one dab. The falloff weight of each cell scales it.
	var passes := 1
	## The kernel radius of the local occupancy density.
	var radius := 1
	## The convex and the concave cutoffs.
	var remove_threshold := 0.5
	var add_threshold := 0.5
	## The chunk locations that the tick changed.
	var changed_chunks: Array[Vector3i] = []
	## Whether a cancellation stopped the tick before it computed.
	var cancelled := false
	## The snapshot reads of the last occupancy gather, or the reads it made
	## before a cancellation stopped it. A box scan counts one read per grid slot
	## and the exact loop counts one per frame lookup. A test reads this to report
	## the query count.
	var gather_reads := 0

	## Whether the job reads its operation plane and builds its rounding fields
	## before it rounds. A large dab sets it, so the surface read and the field build
	## run on the worker too.
	var preparing := false
	## The locked frame of the dab, before the surface read. The job reads its normal
	## only.
	var prep_terrain_frame: TerrainFrame
	## The dab center point and its footprint inputs.
	var prep_center := Vector3.ZERO
	var prep_radius := 4
	var prep_falloff := 0.5
	var prep_depth := 8
	## The frozen edit context of the stroke. It supplies the symmetry masks.
	var prep_context: VoxelFrame.EditContext
	## The selection of the frozen context, compared by value.
	var prep_selection := {}
	## The entered face of the dab and the normal source of the stroke.
	var prep_entry := Vector3i.ZERO
	## The operation plane after the surface read, or null.
	var prepared_frame: TerrainFrame
	## The rounding fields the preparation built, or null when the job did not
	## prepare. The main thread adopts them when the job publishes.
	var prepared_fields = null

	## Runs every field on the snapshot. This is the worker body.
	func run() -> void:
		# A pre-cancelled job must not compute or publish.
		if not checkpoint(0):
			cancelled = true
			return
		if preparing and not _prepare():
			cancelled = true
			return
		var total := 0
		for field in fields:
			total += (field["cells"] as Array).size()
		stage("Smoothing voxels", total)
		var additions := {}
		var removals := {}
		var cancel := Callable(self, "_checkpoint")
		for index in fields.size():
			var field: Dictionary = fields[index]
			var cells: Array = field["cells"]
			var occupied = _occupancy(cells)
			if occupied == null:
				cancelled = true
				return
			var outcome := SmoothOperation.advance(occupied, cells, passes, radius, remove_threshold, add_threshold, field["weights"], cancel)
			if outcome.has("cancelled"):
				cancelled = true
				return
			for cell: Vector3i in outcome["remove"]:
				removals[cell] = true
			for cell: Vector3i in outcome["add"]:
				additions[cell] = true
		var changes := {}
		for cell: Vector3i in additions:
			if removals.has(cell):
				continue
			var source := _source_material(cell)
			if source.is_empty():
				continue
			changes[cell] = source
		for cell: Vector3i in removals:
			changes[cell] = VoxelFrame.material(Color.TRANSPARENT)
		if changes.is_empty():
			return
		changed_chunks = apply_cells(edited_frame, changes)

	# Reads the operation plane from the current surface and builds the rounding
	# fields on the worker. The snapshot is read before any write, so the order
	# matches the inline path. Returns false when a cancel stopped it.
	func _prepare() -> bool:
		prepared_frame = Prep.smooth_surface_frame(edited_frame, prep_terrain_frame, prep_center, prep_entry, prep_radius, prep_depth)
		if not checkpoint(0):
			return false
		if prepared_frame == null:
			return false
		var built := Prep.smooth_fields(prep_center, prep_radius, prep_falloff, prep_context, prep_selection, self)
		if not checkpoint(0):
			return false
		prepared_fields = built
		fields = prepared_fields
		return checkpoint(0)

	# The progress check the module calls inside its per-cell loops.
	func _checkpoint(completed: int) -> bool:
		return checkpoint(completed)

	# The occupied cells the rounding reads: every candidate and its kernel
	# neighborhood. The halo feeds the density of a candidate at the patch edge,
	# and a pass never writes outside the candidates. A cancellation stops the
	# gather, so a large patch never builds the whole set after a cancel.
	#
	# A compact patch gathers its halo with one bounded box scan of the snapshot
	# chunks. The scan reads each grid slot once, so it replaces the per-candidate
	# frame lookups with raw grid reads. The scan can also hold an occupied cell
	# that no candidate reads, and a pass reads only the kernel of a candidate, so
	# such an extra cell never changes a decision.
	#
	# A scattered or a deep candidate set makes the box much larger than the
	# lookups it replaces. That set keeps the exact per-candidate loop, so a
	# sparse frame never scans or allocates a huge box.
	func _occupancy(cells: Array) -> Variant:
		gather_reads = 0
		if not checkpoint(0):
			return null
		var offsets: Array = SmoothOperation.kernel_offsets(radius)
		if cells.is_empty():
			return {}
		var low: Vector3i = cells[0]
		var high: Vector3i = cells[0]
		var completed := 0
		for cell: Vector3i in cells:
			low = low.min(cell)
			high = high.max(cell)
			completed += 1
			if completed % OCCUPANCY_READ_CHECKPOINT == 0 and not checkpoint(completed):
				return null
		var padding := maxi(radius, 1)
		low -= Vector3i.ONE * padding
		high += Vector3i.ONE * padding
		var budget := OCCUPANCY_BOX_LIMIT * maxi(cells.size() * offsets.size(), 1)
		var volume := _box_volume(low, high)
		if volume > 0 and volume <= budget:
			return _occupancy_box(low, high, cells.size(), volume)
		return _occupancy_cells(cells, offsets)

	# The slot count of one box, or zero when the box cannot be scanned. The
	# caller then keeps the exact per-candidate loop.
	func _box_volume(low: Vector3i, high: Vector3i) -> int:
		var x := high.x - low.x + 1
		var y := high.y - low.y + 1
		var z := high.z - low.z + 1
		if x <= 0 or y <= 0 or z <= 0 or x > OCCUPANCY_BOX_SPAN or y > OCCUPANCY_BOX_SPAN or z > OCCUPANCY_BOX_SPAN:
			return 0
		return x * y * z

	# The occupied cells of one bounded box, read once per grid slot. The box
	# holds every candidate and its kernel neighborhood, so the result holds every
	# cell the rounding reads. The scan checks for a cancellation once per chunk,
	# so at most [constant OCCUPANCY_READ_CHECKPOINT] reads pass between two
	# checks. The reported progress stays in candidate units, so the status bar
	# keeps its meaning. Returns null when a cancellation stops the scan.
	func _occupancy_box(low: Vector3i, high: Vector3i, candidates: int, volume: int) -> Variant:
		var size := VoxelFrame.CHUNK_SIZE
		var occupied := {}
		var reads := 0
		var low_chunk := VoxelFrame.chunk_position(low)
		var high_chunk := VoxelFrame.chunk_position(high)
		for chunk_z in range(low_chunk.z, high_chunk.z + 1):
			for chunk_y in range(low_chunk.y, high_chunk.y + 1):
				for chunk_x in range(low_chunk.x, high_chunk.x + 1):
					var location := Vector3i(chunk_x, chunk_y, chunk_z)
					var chunk: VoxelFrame.Chunk = edited_frame.chunks.get(location)
					if chunk == null:
						continue
					var origin := location * size
					var x0 := maxi(low.x - origin.x, 0)
					var y0 := maxi(low.y - origin.y, 0)
					var z0 := maxi(low.z - origin.z, 0)
					var x1 := mini(high.x - origin.x, size - 1)
					var y1 := mini(high.y - origin.y, size - 1)
					var z1 := mini(high.z - origin.z, size - 1)
					if x1 < x0 or y1 < y0 or z1 < z0:
						continue
					var rows := chunk.occupancy_rows()
					for row in rows.masks.size():
						var mask := rows.masks[row]
						if mask == 0:
							continue
						var local_y := row % size
						var local_z := row / size
						if local_y < y0 or local_y > y1 or local_z < z0 or local_z > z1:
							continue
						var x_mask := mask & (((1 << (x1 - x0 + 1)) - 1) << x0)
						while x_mask != 0:
							var local_x := VoxelFrame.Chunk.first_column(x_mask)
							x_mask &= x_mask - 1
							occupied[Vector3i(origin.x + local_x, origin.y + local_y, origin.z + local_z)] = true
					reads += (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1)
					if not checkpoint(reads * candidates / volume):
						gather_reads = reads
						return null
		gather_reads = reads
		return occupied

	# The exact per-candidate gather. It reads only the kernel neighborhood of
	# every candidate, so a scattered set never scans the box between the
	# candidates. It is the fallback when the box is out of budget.
	func _occupancy_cells(cells: Array, offsets: Array) -> Variant:
		var occupied := {}
		var completed := 0
		for cell: Vector3i in cells:
			for offset: Vector3i in offsets:
				var point := cell + offset
				if edited_frame.has(point):
					occupied[point] = true
			completed += 1
			if completed % 256 == 0 and not checkpoint(completed):
				gather_reads = completed * offsets.size()
				return null
		gather_reads = cells.size() * offsets.size()
		return occupied

	# The full material of the nearest local original support of one filled cell.
	# The support sits behind the fill along the local outward normal, so the
	# search prefers the occupied cell most inward of the normal and then the
	# nearest one. The result is deterministic and never takes a distant source.
	# An empty result means no local source exists, so the fill is skipped rather
	# than seeded from the active paint.
	func _source_material(cell: Vector3i) -> PackedFloat32Array:
		if edited_frame.has(cell):
			return edited_frame.get_material(cell)
		var normal: Vector3 = _local_normal(cell)
		var best := VoxelPicking.NONE
		var best_dot := INF
		var best_distance := INF
		for offset: Vector3i in _source_offsets():
			var point := cell + offset
			if not edited_frame.has(point):
				continue
			var distance := float(offset.length_squared())
			var dot := Vector3(offset).dot(normal)
			if dot < best_dot - 1e-6 or (absf(dot - best_dot) <= 1e-6 and distance < best_distance):
				best = point
				best_dot = dot
				best_distance = distance
		if best == VoxelPicking.NONE:
			return PackedFloat32Array()
		return edited_frame.get_material(best)

	# The outward normal of one cell, from the face occupancy of the snapshot. A
	# cell with no defined normal falls back to the zero vector, so the support
	# search then prefers the nearest occupied cell.
	func _local_normal(cell: Vector3i) -> Vector3:
		var occupied := {}
		for offset: Vector3i in SmoothOperation.NEIGHBOR_OFFSETS:
			var point := cell + offset
			if edited_frame.has(point):
				occupied[point] = true
		var normal = SmoothOperation.surface_normal(occupied, cell)
		return normal if normal != null else Vector3.ZERO

	# The neighbor offsets of one cell, sorted by squared distance. The order is
	# fixed, so a tie between two equal sources breaks by the offset order.
	static func _source_offsets() -> Array:
		if _source_offsets_cache.is_empty():
			var built: Array = []
			for x in range(-SMOOTH_SOURCE_SEARCH, SMOOTH_SOURCE_SEARCH + 1):
				for y in range(-SMOOTH_SOURCE_SEARCH, SMOOTH_SOURCE_SEARCH + 1):
					for z in range(-SMOOTH_SOURCE_SEARCH, SMOOTH_SOURCE_SEARCH + 1):
						if x == 0 and y == 0 and z == 0:
							continue
						built.append(Vector3i(x, y, z))
			built.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
				var distance_a := a.length_squared()
				var distance_b := b.length_squared()
				if distance_a != distance_b:
					return distance_a < distance_b
				if a.z != b.z:
					return a.z < b.z
				if a.y != b.y:
					return a.y < b.y
				return a.x < b.x
			)
			_source_offsets_cache = built
		return _source_offsets_cache

	static var _source_offsets_cache: Array = []


func _enter_tree() -> void:
	if not tree_exited.is_connected(_release_context_subscriptions):
		tree_exited.connect(_release_context_subscriptions)
	if not State.edit_context_changing.is_connected(_cancel_edit):
		State.edit_context_changing.connect(_cancel_edit)
	if not State.history_changed.is_connected(_on_history_changed):
		State.history_changed.connect(_on_history_changed)
	if not _settings.changed.is_connected(_on_settings_changed):
		_settings.changed.connect(_on_settings_changed)
	if not State.symmetry_changed.is_connected(_mark_preview_dirty):
		State.symmetry_changed.connect(_mark_preview_dirty)
	if not State.selection_changed.is_connected(_mark_preview_dirty):
		State.selection_changed.connect(_mark_preview_dirty)
	if not State.floor_plane_changed.is_connected(_mark_preview_dirty):
		State.floor_plane_changed.connect(_mark_preview_dirty)
	if not State.slice_changed.is_connected(_mark_preview_dirty):
		State.slice_changed.connect(_mark_preview_dirty)
	if not State.size_changed.is_connected(_mark_preview_dirty):
		State.size_changed.connect(_mark_preview_dirty)
	if not State.chunks_changed.is_connected(_on_frame_cells_changed):
		State.chunks_changed.connect(_on_frame_cells_changed)
	if not State.cells_changed.is_connected(_on_frame_cells_changed):
		State.cells_changed.connect(_on_frame_cells_changed)
	if not State.document_changed.is_connected(_on_document_changed):
		State.document_changed.connect(_on_document_changed)
	if not State.frame_changed.is_connected(_mark_preview_dirty):
		State.frame_changed.connect(_mark_preview_dirty)


func _ready() -> void:
	_settings_tool = _settings.tool
	_settings_build_mode = _settings.build_mode
	_settings_radius = _settings.radius
	_settings_falloff = _settings.falloff
	_preview = TerrainPreview.new()
	_preview.provider = _preview_inputs
	_preview.publisher = _set_preview
	_preview.pauser = _preview_paused
	_preview.view_provider = _live_view
	_preview.hider = _hide_preview_visible
	_setup_footprint()
	visible = false


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	if _tick_job:
		_tick_job.cancel()
		_tick_job.wait_for_worker()
		_tick_job = null
	if _grab_job:
		_grab_job.cancel()
		_grab_job.wait_for_worker()
		_grab_job = null
	if _smooth_job:
		_smooth_job.cancel()
		_smooth_job.wait_for_worker()
		_smooth_job = null
	if _preview != null:
		_preview.join()
	State.finish_operation(_operation_id)
	_operation_id = 0
	var tx := _edit
	_edit = null
	if tx != null:
		State.cancel_edit(tx)
	_release_context_subscriptions()


func _exit_tree() -> void:
	_last_pick = null
	if _preview != null:
		_preview.join()
		_preview.clear_all()
	_hide_footprint()
	visible = false
	if _settings.changed.is_connected(_on_settings_changed):
		_settings.changed.disconnect(_on_settings_changed)
	_disconnect_preview_signals()


func _release_context_subscriptions() -> void:
	if is_inside_tree() or _edit != null or _tick_job != null or _grab_job != null or _smooth_job != null:
		return
	if State.edit_context_changing.is_connected(_cancel_edit):
		State.edit_context_changing.disconnect(_cancel_edit)
	if State.history_changed.is_connected(_on_history_changed):
		State.history_changed.disconnect(_on_history_changed)
	_disconnect_preview_signals()


func _disconnect_preview_signals() -> void:
	if State.symmetry_changed.is_connected(_mark_preview_dirty):
		State.symmetry_changed.disconnect(_mark_preview_dirty)
	if State.selection_changed.is_connected(_mark_preview_dirty):
		State.selection_changed.disconnect(_mark_preview_dirty)
	if State.floor_plane_changed.is_connected(_mark_preview_dirty):
		State.floor_plane_changed.disconnect(_mark_preview_dirty)
	if State.slice_changed.is_connected(_mark_preview_dirty):
		State.slice_changed.disconnect(_mark_preview_dirty)
	if State.size_changed.is_connected(_mark_preview_dirty):
		State.size_changed.disconnect(_mark_preview_dirty)
	if State.chunks_changed.is_connected(_on_frame_cells_changed):
		State.chunks_changed.disconnect(_on_frame_cells_changed)
	if State.cells_changed.is_connected(_on_frame_cells_changed):
		State.cells_changed.disconnect(_on_frame_cells_changed)
	if State.document_changed.is_connected(_on_document_changed):
		State.document_changed.disconnect(_on_document_changed)
	if State.frame_changed.is_connected(_mark_preview_dirty):
		State.frame_changed.disconnect(_mark_preview_dirty)


func _mark_preview_dirty() -> void:
	# A geometry or a context input changed, so the cached hover cells and the
	# visible outline are no longer trustworthy. The controller drops the cache
	# and hides the outline, and the next request rebuilds from the live inputs.
	if _preview != null:
		_preview.invalidate()


func _on_frame_cells_changed(frame: int, _affected: Array[Vector3i]) -> void:
	# A geometry change in another frame cannot move this frame's preview. The
	# open stroke keeps the frame it captured at the press.
	var current := _stroke_frame_index if _edit != null else State.current_frame
	if frame != current:
		return
	_mark_preview_dirty()


func _on_settings_changed() -> void:
	var tool_changed := _settings.tool != _settings_tool
	var mode_changed := _settings.build_mode != _settings_build_mode
	var geometry_changed := (
		tool_changed or mode_changed
		or _settings.radius != _settings_radius
		or _settings.falloff != _settings_falloff
	)
	_settings_tool = _settings.tool
	_settings_build_mode = _settings.build_mode
	_settings_radius = _settings.radius
	_settings_falloff = _settings.falloff
	# The ring is fixed white, so no settings change refreshes a cursor material.
	# The strength and the color change no preview cell, so they never dirty the
	# geometry. The radius, the falloff, the tool, and the mode all change the
	# footprint or the plane.
	if geometry_changed:
		_mark_preview_dirty()
	if _edit != null and (tool_changed or mode_changed):
		# The open stroke keeps the context it captured, so a tool or mode change
		# ends it like a switch and the next stroke uses the new setting.
		finish_on_switch()


## Handles one input event. Escape rolls an open stroke back. A motion without
## the left button finishes a stroke whose release was lost.
func handle_input(event: InputEvent, pos: Vector2) -> bool:
	if event.is_action_pressed("ui_cancel") and _edit != null:
		_cancel_edit()
		return true
	# A press must not take over an edit that is still finishing. The base class
	# would reuse this tool's open handle and reset the plane of work that is
	# already accepted. A release, a motion, and Escape stay available, and a
	# cancelled stroke leaves no handle, so a press after Escape still opens a
	# new stroke.
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT and button.pressed and _edit != null and not _edit.is_closed():
			return true
	if event is InputEventMouseMotion and _stroke_active and (event as InputEventMouseMotion).button_mask == 0:
		_end()
	return super.handle_input(event, pos)


## Opens this tool's stroke and captures its start state.
func open_stroke() -> VoxelEditTransaction:
	if _edit != null and not _edit.is_closed():
		return _edit
	var tx := super.open_stroke()
	if tx == null:
		return null
	_stroke_id += 1
	_stroke_tx = tx
	_stroke_tool = _settings.tool
	_stroke_build_mode = _settings.build_mode
	_stroke_radius = _settings.radius
	_stroke_strength = _settings.strength
	_stroke_falloff = _settings.falloff
	_stroke_material = State.current_material.duplicate()
	_stroke_context = tx.edit_context
	_stroke_selection = tx.edit_context.selection
	_stroke_floor_axis = State.floor_axis
	_stroke_floor_cell = State.floor_index
	_stroke_frame_index = State.current_frame
	_source_document = State.document
	_source_frame = State.get_current_voxel_frame()
	_end_requested = false
	_samples = {}
	_base_surfaces = {}
	_stroke_columns = {}
	_clear_pending()
	_stroke_frame = null
	_cursor_frame = null
	_stroke_center_point = Vector3.ZERO
	_press_point = Vector3.ZERO
	_path_anchor = VoxelPicking.NONE
	_drag_ray_origin = Vector3.INF
	_drag_ray_dir = Vector3.INF
	_drag_ray_moved = true
	_stroke_forward = Vector3.ZERO
	_camera_perspective = false
	_camera_focus = Vector3.ZERO
	_stroke_ray_dir = Vector3.ZERO
	_press_ray_offset = Vector3.ZERO
	_press_camera_transform = Transform3D()
	_press_projection = -1
	_dab_ray_origin = Vector3.INF
	_dab_ray_dir = Vector3.INF
	_ray_origin = Vector3.INF
	_ray_dir = Vector3.INF
	_smooth_hit = VoxelPicking.NONE
	_smooth_entry = Vector3i.ZERO
	_grab_sources = []
	_grab_source_cells = {}
	_grab_baseline = null
	_grab_anchor = VoxelPicking.NONE
	_grab_drag = VoxelPicking.NONE
	_grab_pending_delta = null
	_grab_empty = false
	_grab_published.clear()
	_prep_batch = 1
	_clear_smooth()
	# A press retires the hover at once: the running job is cancelled without a
	# wait and its epoch moves, so no finished hover result can ever reach the
	# cursor over the stroke. The worker is joined by the next frame.
	if _preview != null:
		_preview.cancel_pending()
		_preview.invalidate()
	return tx


func _apply_pick(target: Vector3i, hit: Vector3i) -> void:
	if _stroke_tool == TerrainSettings.Tools.GRAB:
		_stroke_center_point = Vector3(target)
		# Grab records the cheap face frame of the picked voxel, so a reader of
		# the stroke frame always has one.
		_stroke_frame = _pending_frame
		_capture_grab(target)
		return
	_stroke_frame = _pending_frame
	if _stroke_frame == null:
		_stroke_frame = TerrainFrame.from_face(target, Vector3i(0, 1, 0))
	# The cursor plane freezes at the press. The pick anchors and the dab centers
	# use it, so a later surface read of the Smooth operation plane never moves them.
	_cursor_frame = _stroke_frame
	if _stroke_frame.on_floor:
		# The visible floor is the grid plane. The floor frame plane is the outer
		# face of the first buildable layer, one cell above that grid, so an
		# angled ray meets it one cell toward the camera. The cursor plane places
		# the anchors and the dab centers, so it must be the grid. The press and
		# every later motion then name the same floor cell.
		_cursor_frame = _floor_grid_frame(_stroke_frame)
		var grid_point = _cursor_frame.to_plane().intersects_ray(_press_ray_origin, _press_ray_dir)
		_press_point = grid_point if grid_point != null else _cursor_frame.origin
	if _stroke_tool == TerrainSettings.Tools.SMOOTH:
		# A surface plane on a slope drifts off the surface along the slope. Smooth uses
		# the view-facing plane through the same origin, so the anchor and the dab
		# center stay near the surface for the whole stroke.
		var cursor := TerrainFrame.new()
		var view := VoxelPicking.view_axis(_forward())
		cursor.normal = Vector3.ZERO
		cursor.normal[view] = 1.0
		cursor.origin = _stroke_frame.origin
		cursor.axis = view
		_cursor_frame = cursor
		var point = cursor.to_plane().intersects_ray(_press_ray_origin, _press_ray_dir)
		_press_point = point if point != null else cursor.origin
	# The press anchor is the cell of the press ray and cursor plane
	# intersection. A later motion at the same pointer position gives the same
	# anchor.
	_path_anchor = TerrainGeometry.cell_at(_press_point)
	_stroke_center_point = _plane_point(_path_anchor)
	# The press dab uses the exact press ray. The rest of the stroke reconstructs
	# each ray from the captured camera family through its canonical cursor-plane
	# point. The orthographic offset keeps the sub-cell phase of the first click.
	_press_ray_offset = _press_ray_origin - _plane_point(_path_anchor)
	_dab_ray_origin = _press_ray_origin
	_dab_ray_dir = _press_ray_dir
	# The press applies one dab at once, so a click that never moves still
	# changes the model before the next frame.
	_run_dab(_path_anchor)
	if _preview != null:
		_preview.invalidate()


## Returns a copy of a frame moved onto the floor grid plane.
##
## The floor frame plane sits on the outer face of the first buildable layer, one
## cell above the grid that the user sees. A floor press and every later motion
## must name the same cell, so they use this plane.
func _floor_grid_frame(frame: TerrainFrame) -> TerrainFrame:
	var grid := TerrainFrame.new()
	grid.normal = frame.normal
	grid.tangent_u = frame.tangent_u
	grid.tangent_v = frame.tangent_v
	grid.axis = frame.axis
	grid.sign = frame.sign
	grid.follows_surface = frame.follows_surface
	grid.on_floor = true
	grid.origin = frame.origin
	# The stroke captured its floor cell at the press. A floor change mid-stroke
	# must not move the remaining dab centres.
	grid.origin[_stroke_floor_axis] = float(_stroke_floor_cell) - 0.5
	return grid


## Returns the cursor plane for the open stroke.
##
## A stroke that started on the floor keeps the grid plane, so the anchors and
## the dab centers name the floor cell under the pointer. The Build ground moves
## the operation plane, and the cursor plane must not jump back to the outer face
## of the first buildable layer when it does.
func _stroke_cursor_frame() -> TerrainFrame:
	if _stroke_frame.on_floor:
		return _floor_grid_frame(_stroke_frame)
	return _stroke_frame


## Returns true when the new anchor is far enough from the last accepted one on
## screen.
##
## A view nearly parallel to the cursor plane moves the plane cell several times
## per pixel, mostly along the view ray. That cell change is almost invisible, so
## a screen-space gate stops a small mouse move from adding layers the user
## cannot see. A cell change that is visible on screen still passes.
func _dab_moved_enough(from_cell: Vector3i, to_cell: Vector3i) -> bool:
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null:
		return true
	var from_point := _plane_point(from_cell)
	var to_point := _plane_point(to_cell)
	if camera.is_position_behind(from_point) or camera.is_position_behind(to_point):
		return true
	return camera.unproject_position(from_point).distance_to(camera.unproject_position(to_point)) >= MIN_DAB_PIXELS


func _apply_stroke_to(to: Vector3i) -> void:
	if _stroke_tool == TerrainSettings.Tools.GRAB:
		_update_grab(to)
		return
	if _path_anchor == VoxelPicking.NONE or to == VoxelPicking.NONE:
		return
	# A surface read of the Smooth plane can change the pick cell without pointer
	# movement. Skip that case, so a held pointer never invents a dab.
	if not _drag_ray_moved:
		return
	# A view nearly parallel to the cursor plane moves the anchor several cells
	# per pixel. Require a visible screen move, so a tiny jitter adds no layer.
	# Smooth drags on a view-facing plane, so its anchor has no view stretch and
	# its path must stay equal to a coalesced drag.
	if _stroke_tool != TerrainSettings.Tools.SMOOTH and not _dab_moved_enough(_path_anchor, to):
		return
	# Queue the whole motion as one segment. The drain generates the crossed
	# cells, so one large motion applies the same dabs as the same path
	# delivered one cell at a time. Each dab reconstructs its ray from the
	# captured camera family, so the result never depends on the batching.
	_enqueue_segment(_path_anchor, to)
	_path_anchor = to
	if _preview != null:
		_preview.invalidate()


func _end() -> void:
	_end_requested = true
	_stroke_active = false
	# Drain the accepted dabs even when a worker still runs. The stroke commits
	# only after the queue is empty and the last job is finished.
	_settle_dabs()


## Ends the stroke like a release when a tool or mode switch detaches this tool.
func finish_on_switch() -> void:
	if _edit == null:
		return
	_end()


func close_stroke(_action: String = "Stroke") -> void:
	var tx := _edit
	if tx == null:
		return
	_edit = null
	State.finish_edit(tx, _close_action)


func _finish_stroke() -> void:
	if _edit != null and _edit != _stroke_tx:
		return
	_close_action = _action_name()
	_end_requested = false
	_clear_pending()
	_stroke_context = null
	_stroke_selection = {}
	_stroke_frame = null
	_cursor_frame = null
	_samples = {}
	_base_surfaces = {}
	_stroke_columns = {}
	_clear_smooth()
	_grab_sources = []
	_grab_source_cells = {}
	_grab_baseline = null
	_grab_anchor = VoxelPicking.NONE
	_grab_drag = VoxelPicking.NONE
	_grab_pending_delta = null
	_grab_published.clear()
	_stroke_tx = null
	_source_document = null
	_source_frame = null
	_last_pick = null
	if _preview != null:
		_preview.clear_all()
	_hide_footprint()
	visible = false
	super._end()


func _action_name() -> String:
	match _stroke_tool:
		TerrainSettings.Tools.FLATTEN:
			return "Flatten"
		TerrainSettings.Tools.GRAB:
			return "Grab"
		TerrainSettings.Tools.SMOOTH:
			return "Smooth"
	return "Build"


func _cancel_edit() -> void:
	if _tick_job:
		_tick_job.cancel()
	if _grab_job:
		_grab_job.cancel()
	if _smooth_job:
		_smooth_job.cancel()
	# Drop the accepted path, so a stale completion cannot apply a cancelled dab.
	_clear_pending()
	# The zombie drain retires itself through its token, so the cancel leaves the
	# flag alone. A new stroke starts its own drain at once.
	_samples = {}
	_base_surfaces = {}
	_stroke_columns = {}
	_stroke_frame = null
	_cursor_frame = null
	_clear_smooth()
	_grab_sources = []
	_grab_source_cells = {}
	_grab_baseline = null
	_grab_pending_delta = null
	_grab_anchor = VoxelPicking.NONE
	_grab_drag = VoxelPicking.NONE
	_grab_published.clear()
	_stroke_active = false
	_plane = null
	_last_target = VoxelPicking.NONE
	_path_anchor = VoxelPicking.NONE
	_stroke_tx = null
	_source_document = null
	_source_frame = null
	_last_pick = null
	if _preview != null:
		_preview.invalidate()
	visible = false
	_hide_footprint()
	State.finish_operation(_operation_id)
	_operation_id = 0
	abort_stroke()
	_release_context_subscriptions()


func _on_history_changed() -> void:
	if _edit != null:
		_cancel_edit()


# --- Dab applications -------------------------------------------------------


# The tool edits on input, not on elapsed time. The frame loop only rebuilds a
# dirty hover preview, so a held pointer never adds a dab on its own.
#
# The hover surface read and the footprint map run on a worker. A stroke or a Grab hover
# publishes on the main thread, because those are cheap and must not wait.
func _process(_delta: float) -> void:
	if _preview == null:
		return
	# Join a finished hover worker and publish a valid result. A running worker
	# is never awaited here.
	_preview.poll()
	if _edit != null or _busy():
		if _preview_dirty:
			_rebuild_preview()
		return
	if _settings.tool == TerrainSettings.Tools.GRAB:
		if _preview_dirty:
			_rebuild_preview()
		return
	_preview.process()


## Applies one dab at the current brush center.
##
## The hook is a kernel probe for tests and benchmarks. The dab applies the
## strength at full weight, and the solo Smooth pass count is one, so
## [param influence] is not read. Two calls apply two dabs. The runtime never
## calls it.
func advance_stroke(influence: float) -> void:
	if _edit == null or _stroke_tool == TerrainSettings.Tools.GRAB:
		return
	if _busy():
		return
	_apply_influence(influence)


# Applies one dab at the current brush center. One dab adds the strength scaled
# by the falloff at every voxel in the footprint. The applications value is the
# Smooth pass count, and Build and Flatten ignore it.
func _apply_influence(applications: float) -> void:
	if _stroke_tool == TerrainSettings.Tools.SMOOTH:
		_smooth_tick()
		return
	if _samples.is_empty():
		return
	_run_tick()


# Queues one motion segment. The crossed cells are generated when the drain
# reaches the segment, so the queue holds one entry per real motion and no
# accepted cell is ever dropped.
func _enqueue_segment(from: Vector3i, to: Vector3i) -> void:
	if _edit == null or _stroke_tool == TerrainSettings.Tools.GRAB:
		return
	if from == VoxelPicking.NONE or to == VoxelPicking.NONE or from == to:
		return
	_segments.append([from, to])
	_settle_dabs()


# Returns true while the accepted path still holds a dab that is not applied.
func _has_pending() -> bool:
	return _dab_path != null or _segment_head < _segments.size()


# Returns the next crossed anchor cell of the accepted path, or null when the
# path is finished. The cursor generates the crossed cells one at a time.
func _next_dab_cell() -> Variant:
	while _dab_path != null or _segment_head < _segments.size():
		if _dab_path == null:
			var segment: Array = _segments[_segment_head]
			_segment_head += 1
			_dab_path = StrokeLine.Cursor.new(segment[0], segment[1])
		var cell = _dab_path.next_cell()
		if cell != null:
			# Reconstruct the ray of the canonical anchor from the captured camera
			# family. A perspective camera runs the ray from its focus through the
			# cursor-plane point. An orthographic camera keeps its direction and
			# translates the press origin with the plane point.
			var anchor_world := _plane_point(cell)
			if _camera_perspective:
				_dab_ray_origin = _camera_focus
				_dab_ray_dir = (anchor_world - _camera_focus).normalized()
			else:
				_dab_ray_origin = anchor_world + _press_ray_offset
				_dab_ray_dir = _stroke_ray_dir
			return cell
		_dab_path = null
	_clear_pending()
	return null


# Drops the accepted path. A cancel calls it, so a stale completion cannot apply
# a dab of the cancelled stroke.
func _clear_pending() -> void:
	_segments.clear()
	_segment_head = 0
	_dab_path = null


## Applies the accepted dabs in order, in bounded batches. A batch of small dabs
## runs inline. A large dab runs on the worker pool, and its completion resumes
## the drain. A batch boundary yields one frame, so a giant jump never blocks one
## frame and no accepted cell is dropped. The stroke finishes only when the
## accepted path is consumed and no job runs.
##
## The drain owns an explicit token: the stroke id and the transaction it started
## with. A cancelled or replaced stroke cannot retire a newer drain, and a zombie
## drain that resumes after the frame yield reads the token before it touches the
## path, the shared flag, or the finish. A new stroke then starts its own drain at
## once, so a bounded batch is never doubled by a stale loop.
func _settle_dabs() -> void:
	var stroke_id := _stroke_id
	var tx := _stroke_tx
	if _drain_active and _drain_stroke_id == stroke_id:
		return
	_drain_active = true
	_drain_stroke_id = stroke_id
	while _edit != null and _stroke_id == stroke_id and _stroke_tx == tx:
		var budget := DABS_PER_DRAIN
		var deadline := Time.get_ticks_usec() + DRAIN_BUDGET_US
		while budget > 0 and not _busy() and _has_pending():
			var cell = _next_dab_cell()
			if cell == null:
				break
			var consumed := 1
			if _stroke_tool != TerrainSettings.Tools.SMOOTH and _dab_is_large(_stroke_radius):
				# One worker job covers several crossed centers. The job applies
				# them in order, so it matches a sequence of single dabs.
				var batch: Array = [cell]
				while consumed < _prep_batch and budget - consumed > 0 and _has_pending():
					var next = _next_dab_cell()
					if next == null:
						break
					batch.append(next)
					consumed += 1
				_stroke_center_point = _plane_point(batch[batch.size() - 1])
				_start_prep_batch(batch)
			else:
				_run_dab(cell)
			budget -= consumed
			# A slow dab yields at once, so a 95 ms frame never delays the
			# pointer sampling that shapes the rest of the stroke.
			if Time.get_ticks_usec() >= deadline:
				break
		if not _busy() and not _has_pending():
			break
		await _next_frame()
	# Only the drain that still owns the token retires the flag and the stroke.
	if _drain_active and _drain_stroke_id == stroke_id:
		_drain_active = false
	if _stroke_id == stroke_id and _end_requested and _edit != null and _edit == _stroke_tx:
		_finish_stroke()


# Waits for the next process frame. The main loop comes from the engine, so the
# wait still works when a switch removed the tool from the tree.
func _next_frame() -> void:
	var loop := Engine.get_main_loop() as SceneTree
	if loop != null:
		await loop.process_frame


# Runs one dab at an anchor cell. The dab rebuilds the footprint or the rounding
# field at the anchor, then applies one application.
func _run_dab(cell: Vector3i) -> void:
	if _stroke_tool == TerrainSettings.Tools.SMOOTH:
		_run_smooth_dab()
		return
	# Build and Flatten share one fixed operation plane. The footprint center is
	# the canonical anchor cell projected onto the frozen cursor plane, so every
	# dab keeps the same tangent kernel and a long stroke keeps coherent bands.
	# The per-column support lookup lifts the old height limit without moving the
	# plane and without re-projecting the footprint onto a grown height.
	_apply_dab_at(_plane_point(cell))


## Applies one Build or Flatten dab at the given effect center.
##
## A small dab builds its footprint inline, so a press with an ordinary brush
## edits in its input event. A large dab builds the footprint on the worker
## pool, so the frame that accepted it keeps processing input. Both paths read
## one definition of the map and the credited influence.
func _apply_dab_at(center_point: Vector3) -> void:
	_stroke_center_point = center_point
	if _dab_is_large(_stroke_radius):
		_start_prep_dab(center_point)
		return
	_rebuild_samples(center_point)
	_apply_influence(1.0)
	_mark_hover_dirty()


# Returns true when one dab of this radius and symmetry count must build its
# footprint on the worker pool. The estimate reads the radius and the active mask
# count only. It allocates nothing, so the press never builds the disc cache on
# the main thread.
func _dab_is_large(radius: int) -> bool:
	return _dab_estimate(radius) > PREP_CANDIDATE_LIMIT


# The footprint candidate count of one radius and symmetry count. Three quarters
# of the disc area is a close estimate of the shipped disc size and needs no
# allocation.
func _dab_estimate(radius: int) -> int:
	return radius * radius * 3 * _mask_count()


func _mask_count() -> int:
	return TerrainPreview.masks_for(_context()).size()


# Starts one Build or Flatten dab whose footprint map, step list, and writes all
# run on the worker pool. The job holds its own progress copy and its own frame
# snapshot, so a cancel or a new stroke never changes what it reads.
func _start_prep_dab(center_point: Vector3) -> void:
	_start_prep_batch([center_point])


# Starts one worker job for a batch of crossed centers, in path order. A batch
# pays one frame wait for several dabs, and each center reads the frame left by
# the previous one, so the result matches a sequence of single dabs.
func _start_prep_batch(cells: Array) -> void:
	var job := TerrainTickJob.new()
	job.stroke_id = _stroke_id
	job.preparing = true
	# A worker reads and writes its own frame. `job_frame` shares the chunk
	# objects without copying the whole frame, and the job copies a chunk
	# before it writes it. The stroke owns the edit, so the source does not
	# change while the job runs.
	job.edited_frame = VoxelFrame.job_frame(_source_frame)
	job.samples = []
	job.tool = _stroke_tool
	job.build_mode = _stroke_build_mode
	job.floor_axis = _stroke_floor_axis
	job.floor_cell = _stroke_floor_cell
	job.threshold = FLATTEN_THRESHOLD
	job.material = _stroke_material
	job.selection = _stroke_selection
	job.prep_terrain_frame = _stroke_frame
	job.prep_ray_origin = _ray_origin
	job.prep_ray_dir = _ray_dir
	# Only Build reads the prep forward, and it reads it on the worker. A tool
	# without a captured forward must not ask the live camera here: the tool may
	# already be outside the tree while its accepted dabs drain.
	job.prep_forward = _stroke_forward if _stroke_forward != Vector3.ZERO else Vector3.BACK
	if not cells.is_empty() and typeof(cells[0]) == TYPE_VECTOR3I:
		job.prep_cells = cells
		job.prep_center = _plane_point(cells[cells.size() - 1])
	else:
		job.prep_centers = cells
		job.prep_center = cells[cells.size() - 1]
	job.prep_radius = _stroke_radius
	job.prep_falloff = _stroke_falloff
	# The worker map reaches the tall support bound, so a column above the small
	# footprint depth still resolves.
	job.prep_depth = _height_depth()
	job.prep_context = _stroke_context
	job.prep_known = Prep.known_surfaces(_samples)
	job.prep_known_columns = _stroke_columns.duplicate()
	job.prep_base_known = _base_surfaces.duplicate()
	job.prep_strength = _stroke_strength
	_tick_job = job
	_operation_id = State.begin_operation("Terraining voxels", _dab_candidates() * cells.size(), true, self, _cancel_edit)
	job.operation_id = _operation_id
	_run_tick_worker(job)


# The footprint candidate count of the current stroke, for the operation total.
func _dab_candidates() -> int:
	return _dab_estimate(_stroke_radius)


## Runs one Smooth dab on the real surface under its reconstructed ray.
##
## The ray comes from the captured segment rays, so a queued dab never depends on
## the live camera or on when a worker published. The hit and the entered face
## resolve on the accepted frame at this call, so the 3D patch follows the real
## surface. A ray that misses the model consumes the input spacing but applies no
## Smooth edit and seeds nothing.
func _run_smooth_dab() -> void:
	var origin := _dab_ray_origin
	var dir := _dab_ray_dir
	if dir == Vector3.ZERO or dir == Vector3.INF:
		return
	if origin == Vector3.INF:
		origin = _press_ray_origin
	# The dab uses the slice of the captured stroke context, exactly like the
	# press, so a column outside the slab cannot move the Smooth centre.
	var use_slice := _stroke_context != null and _stroke_context.slice_axis >= 0
	var actual := VoxelPicking.start_pick(origin, dir, _source_frame, _stroke_forward if _stroke_forward != Vector3.ZERO else _forward(), use_slice)
	_smooth_hit = actual.hit
	_smooth_entry = actual.entry
	if actual.hit == VoxelPicking.NONE:
		return
	_stroke_center_point = Vector3(actual.hit)
	if _dab_is_large(_stroke_radius):
		_start_prep_smooth()
		return
	_rebuild_smooth()
	_apply_influence(1.0)
	# The surface read changed the operation normal, so the ring must follow the normal
	# the dab used even when the pointer did not move.
	_pose_footprint(_last_pick)
	_mark_hover_dirty()


# Starts one Smooth dab whose surface read, field build, rounding, and writes all run
# on the worker pool.
func _start_prep_smooth() -> void:
	var job := SmoothJob.new()
	job.stroke_id = _stroke_id
	job.preparing = true
	job.edited_frame = VoxelFrame.job_frame(_source_frame)
	job.passes = _stroke_strength
	job.radius = SmoothOperation.KERNEL_RADIUS
	job.remove_threshold = SmoothOperation.REMOVE_THRESHOLD
	job.add_threshold = SmoothOperation.ADD_THRESHOLD
	job.prep_terrain_frame = _stroke_frame
	job.prep_center = _stroke_center_point
	job.prep_radius = _stroke_radius
	job.prep_falloff = _stroke_falloff
	job.prep_depth = _footprint_depth(_stroke_radius)
	job.prep_context = _context()
	job.prep_selection = _stroke_selection
	job.prep_entry = _smooth_entry
	_smooth_job = job
	_operation_id = State.begin_operation("Smoothing voxels", _dab_candidates(), true, self, _cancel_edit)
	job.operation_id = _operation_id
	_run_smooth_worker(job)


# Returns the world point of one anchor cell on the frozen stroke plane. The
# anchor is a world cell and the plane is frozen at the press, so the same path
# gives the same dab points at any event rate and no surface read moves them.
func _plane_point(cell: Vector3i) -> Vector3:
	if _cursor_frame == null:
		return Vector3(cell)
	return _cursor_frame.plane_point(cell)


# Returns true while a dab or a drag runs on the worker pool.
func _busy() -> bool:
	return _tick_job != null or _grab_job != null or _smooth_job != null


# Returns true when a finished worker job still belongs to the current stroke and
# may publish its result. Every dab job (tick, grab, smooth) shares this check: a
# newer stroke, an expired cancel request, a closed handle, or a swapped document
# or frame rejects the result.
func _job_is_current(job: Variant) -> bool:
	if job.stroke_id != _stroke_id or not job.checkpoint(0):
		return false
	if _edit == null or _edit != _stroke_tx:
		return false
	return State.document == _source_document and State.get_current_voxel_frame() == _source_frame


func _rebuild_samples(center_point: Vector3) -> void:
	_samples = _sample_map(_stroke_frame, center_point, _stroke_radius, _stroke_falloff, Prep.known_surfaces(_samples))
	if _stroke_tool == TerrainSettings.Tools.BUILD and _stroke_frame != null:
		var center := _ground_surface(center_point)
		_stroke_frame = _stroke_frame.recenter_to(center, float(_stroke_radius))
		_cursor_frame = _stroke_cursor_frame()
	_prune_state()


## Returns the base surface under the pointer for the Build ground. The raycast
## finds the surface even when it is outside the brush read. A column this stroke
## already sampled keeps its cached base, so the brush never lifts itself.
func _ground_surface(center_point: Vector3) -> Vector3i:
	if _stroke_frame == null:
		return VoxelPicking.NONE
	var hit := VoxelPicking.NONE
	if _ray_origin != Vector3.INF and _ray_dir != Vector3.INF:
		var forward := _stroke_forward if _stroke_forward != Vector3.ZERO else _forward()
		var use_slice := _stroke_context != null and _stroke_context.slice_axis >= 0
		var pick := VoxelPicking.start_pick(_ray_origin, _ray_dir, _active_frame(), forward, use_slice)
		hit = pick.hit
	if hit == VoxelPicking.NONE:
		return TerrainPreview.center_surface(_samples, center_point)
	var key := TerrainGeometry.column_key(hit, _stroke_frame.normal)
	if not _base_surfaces.has(key):
		_base_surfaces[key] = hit
	return _base_surfaces[key]


## Returns the footprint samples keyed by their anchor cell. The samples come
## from every active symmetry mask. [param known] maps an anchor cell to its
## tracked surface, so a persisting column never re-scans. A repeated claimed
## surface keeps the highest weight, so two samples never write the same cell and
## no sample blocks or stalls a neighbor.
##
## Every candidate is collected first, then resolved once. The resolver keeps one
## row per anchor and one row per claim, so a tilted disc whose entries share an
## anchor or a claim can never leave a dangling owner. The surface scan of every
## eligible entry runs in the same order as before, so the query stream is
## unchanged.
func _sample_map(terrain_frame: TerrainFrame, center_point: Vector3, radius: int, falloff: float, known: Dictionary = {}) -> Dictionary:
	# The body is shared with the hover worker, so the stroke and the preview
	# read one definition at one depth. The tall support bound keeps a column
	# above the small footprint depth reachable.
	return TerrainPreview.compute_sample_map(_active_frame(), terrain_frame, center_point, radius, falloff, _context(), _height_depth(), known, null, null, _base_surfaces, _stroke_floor_axis, _stroke_floor_cell, _stroke_columns)


## Returns the stable logical column of one sample. The definition is shared with
## the worker job, so the tool and the job agree on the key.
static func _column_key(sample: Dictionary) -> Vector3i:
	return Prep.column_key(sample)


func _prune_state() -> void:
	# The stroke cache is one entry per column the stroke touched. A stroke that
	# touches more columns than the state limit drops it. A later revisit then
	# re-reads, and the tall depth still resolves the column.
	if _stroke_columns.size() > STATE_LIMIT:
		_stroke_columns = {}


func _collect_steps() -> Array:
	return Prep.collect_steps(_samples, _stroke_tool, _stroke_strength)


## Returns the footprint depth of the active tool for the given radius.
##
## All tools use the same depth formula for consistency.
func _footprint_depth(radius: int) -> int:
	return TerrainPreview.depth_for(radius)


## Returns the height lookup depth of one footprint column.
##
## The walk stays bounded, but a taller bound resolves a column whose support
## sits above the old footprint depth. The operation plane never moves, so the
## kernel coverage is unchanged and the profile of every column inside the old
## bound is exactly the shipped one. Only a column that the old bound reported as
## a missing surface gains its real support, which is the artificial height limit
## this removes.
func _height_depth() -> int:
	if _stroke_tool == TerrainSettings.Tools.BUILD:
		# A stroke raises one column by many layers, and the read starts at the
		# plane. The bound must stay tall, not brush sized, or a grown column
		# reads as a missing surface on the return pass.
		return mini(HEIGHT_LOOKUP_LIMIT, maxi(8, _stroke_radius * 2))
	return HEIGHT_LOOKUP_LIMIT


func _run_tick() -> void:
	var columns := _collect_steps()
	if columns.is_empty():
		return
	var job := TerrainTickJob.new()
	job.stroke_id = _stroke_id
	job.samples = columns
	job.tool = _stroke_tool
	job.build_mode = _stroke_build_mode
	job.floor_axis = _stroke_floor_axis
	job.floor_cell = _stroke_floor_cell
	job.threshold = FLATTEN_THRESHOLD
	job.material = _stroke_material
	job.selection = _stroke_selection
	job.prep_context = _stroke_context
	var work := 0
	for column in columns:
		work += int(column["steps"])
	# An inline dab edits the stroke frame in place. A copy per crossed cell is
	# the cost that blocks the frame and starves pointer input on a large model.
	# A worker dab must not write the frame that the renderer and the hover read,
	# so only that path takes a job copy.
	job.edited_frame = _source_frame if work <= INLINE_EDIT_LIMIT else VoxelFrame.job_frame(_source_frame)
	_tick_job = job
	if work <= INLINE_EDIT_LIMIT:
		job.run()
		_finish_tick(job)
	else:
		_operation_id = State.begin_operation("Terraining voxels", work, true, self, _cancel_edit)
		job.operation_id = _operation_id
		_run_tick_worker(job)


func _run_tick_worker(job: TerrainTickJob) -> void:
	await State.run_edit_job(job, job.operation_id, "Terrain tick")
	if _tick_job != job:
		return
	_finish_tick(job)
	_settle_dabs()


func _finish_tick(job: TerrainTickJob) -> void:
	if _tick_job == job:
		_tick_job = null
	if _operation_id == job.operation_id:
		_operation_id = 0
	State.finish_operation(job.operation_id)
	if not _job_is_current(job):
		return
	# A preparing dab built its own map and step list on the worker, so adopt
	# them before the applied surfaces update the sample map.
	if job.prepared_samples != null:
		_samples = job.prepared_samples
	if job.prepared_base_known != null:
		_base_surfaces = job.prepared_base_known
	if job.prepared_frame != null and _stroke_tool == TerrainSettings.Tools.BUILD:
		_stroke_frame = job.prepared_frame
		_cursor_frame = _stroke_cursor_frame()
	for anchor in job.surfaces:
		if _samples.has(anchor):
			_samples[anchor]["surface"] = job.surfaces[anchor]
	for column in job.applied_columns:
		_stroke_columns[column] = job.applied_columns[column]
	if job.prepared_samples != null:
		_prune_state()
	# An inline job edited the stroke frame itself, so there is nothing to publish.
	# A worker job edited its own copy, so its changed chunks become the stroke
	# frame. Publishing by location costs the changed chunk count, not the frame.
	if job.edited_frame != _source_frame:
		_source_frame.apply_published(job.changed_chunks, job.edited_frame)
	State.document._bounds_dirty = true
	# One signal per frame carries every chunk this frame touched. A signal per
	# dab makes the renderer pay its bookkeeping once per crossed cell.
	for chunk in job.changed_chunks:
		_stroke_chunks[chunk] = true
	if not _stroke_chunks.is_empty() and not _stroke_flush_queued:
		_stroke_flush_queued = true
		_flush_stroke_chunks.call_deferred()
	# Size the next batch from the worker time of this one, so the main thread
	# waits about one frame for a whole batch instead of one frame per dab.
	if job.preparing and job.work_us > 0:
		var centers := maxi(maxi(job.prep_centers.size(), job.prep_cells.size()), 1)
		var per_dab := job.work_us / centers
		_prep_batch = clampi(PREP_BATCH_TARGET_US / maxi(per_dab, 1), 1, PREP_BATCH_MAX)
	_mark_hover_dirty()


# Publishes every chunk the recent dabs touched, once per frame.
func _flush_stroke_chunks() -> void:
	_stroke_flush_queued = false
	if _stroke_chunks.is_empty():
		return
	var chunks: Array[Vector3i] = []
	chunks.assign(_stroke_chunks.keys())
	_stroke_chunks.clear()
	State.chunks_changed.emit(State.current_frame, chunks)


# --- Grab -------------------------------------------------------------------


func _capture_grab(anchor: Vector3i) -> void:
	_grab_anchor = anchor
	_grab_drag = anchor
	_grab_baseline = _source_frame.copy_frame()
	_grab_sources = []
	_grab_source_cells = {}
	var radius := _stroke_radius
	for mask in _masks_for(_stroke_context):
		var center := _stroke_context.reflect(anchor, mask)
		for offset in _ball_offsets(radius):
			var cell := center + offset
			if _grab_source_cells.has(cell):
				continue
			if not _source_frame.has(cell):
				continue
			if not _allows_selection(cell):
				continue
			var distance := Vector3(offset).length()
			var weight := TerrainGeometry.weight_at(distance, float(radius), _stroke_falloff)
			# A zero weight cannot move, so the source never joins the drag.
			if weight <= 0.0:
				continue
			_grab_source_cells[cell] = true
			_grab_sources.append({
				"cell": cell,
				"material": _source_frame.get_material(cell),
				"mask": mask,
				"weight": weight,
			})
	_grab_empty = _grab_sources.is_empty()
	_mark_hover_dirty()


func _allows_selection(cell: Vector3i) -> bool:
	if _stroke_context != null:
		return _stroke_context.allows(cell)
	return _stroke_selection.is_empty() or _stroke_selection.has(cell)


func _ball_offsets(size: int) -> Array[Vector3i]:
	if _ball_cache.has(size):
		return _ball_cache[size]
	var offsets: Array[Vector3i] = []
	var radius := float(size) * 0.5
	var radius_squared := radius * radius
	var reach := ceili(radius)
	for x in range(-reach, reach + 1):
		for y in range(-reach, reach + 1):
			for z in range(-reach, reach + 1):
				if x * x + y * y + z * z <= radius_squared:
					offsets.append(Vector3i(x, y, z))
	_ball_cache[size] = offsets
	return offsets


func _update_grab(to: Vector3i) -> void:
	if _grab_empty or _grab_baseline == null or to == VoxelPicking.NONE:
		return
	var delta := Vector3(to - _grab_anchor)
	if delta.length() > GRAB_MAX_DISTANCE:
		delta = delta.normalized() * GRAB_MAX_DISTANCE
		to = _grab_anchor + Vector3i(delta.round())
	if to == _grab_drag:
		return
	_grab_drag = to
	if _grab_job != null:
		_grab_pending_delta = to - _grab_anchor
		return
	_run_grab(to - _grab_anchor)


func _run_grab(delta: Vector3i) -> void:
	if _grab_baseline == null:
		return
	var moves := []
	for source in _grab_sources:
		var mask: int = source["mask"]
		var anchor_mirror := _stroke_context.reflect(_grab_anchor, mask)
		var moved_mirror := _stroke_context.reflect(_grab_anchor + delta, mask)
		var mirrored: Vector3i = moved_mirror - anchor_mirror
		var weight: float = source["weight"]
		var scaled := Vector3i(
			roundi(float(mirrored.x) * weight),
			roundi(float(mirrored.y) * weight),
			roundi(float(mirrored.z) * weight)
		)
		if scaled == Vector3i.ZERO:
			continue
		moves.append({"source": source["cell"], "material": source["material"], "delta": scaled, "weight": weight})
	if moves.is_empty():
		_publish_grab_baseline()
		_after_grab()
		return
	var job := GrabJob.new()
	job.stroke_id = _stroke_id
	job.edited_frame = VoxelFrame.job_frame(_grab_baseline)
	job.moves = moves
	job.sources = _grab_source_cells
	job.selection = _stroke_selection
	job.context = _stroke_context
	var work := 0
	for move in moves:
		var offset: Vector3i = move["delta"]
		work += absi(offset.x) + absi(offset.y) + absi(offset.z) + 1
	_grab_job = job
	if work <= INLINE_EDIT_LIMIT:
		job.run()
		_finish_grab(job)
	else:
		_operation_id = State.begin_operation("Grabbing voxels", work, true, self, _cancel_edit)
		job.operation_id = _operation_id
		_run_grab_worker(job)


func _run_grab_worker(job: GrabJob) -> void:
	await State.run_edit_job(job, job.operation_id, "Terrain grab")
	if _grab_job != job:
		return
	_finish_grab(job)


func _finish_grab(job: GrabJob) -> void:
	if _grab_job == job:
		_grab_job = null
	if _operation_id == job.operation_id:
		_operation_id = 0
	State.finish_operation(job.operation_id)
	if job.stroke_id != _stroke_id:
		# A newer stroke owns the tool. Run its queued drag when one waits.
		if _grab_pending_delta != null and _edit == _stroke_tx:
			var queued: Vector3i = _grab_pending_delta
			_grab_pending_delta = null
			_run_grab(queued)
		return
	if not _job_is_current(job):
		return
	# The drag recomputes from the baseline, so a chunk that moved in an earlier
	# update and not in this one must revert. Publish the union of both updates.
	var locations: Array[Vector3i] = []
	for location in _grab_published:
		locations.append(location)
	for location in job.changed_chunks:
		if not _grab_published.has(location):
			_grab_published[location] = true
			locations.append(location)
	_source_frame.apply_published(locations, job.edited_frame)
	State.document._bounds_dirty = true
	if not locations.is_empty():
		State.chunks_changed.emit(State.current_frame, locations)
	if job.stroke_id != _stroke_id:
		return
	if _grab_pending_delta != null:
		var pending: Vector3i = _grab_pending_delta
		_grab_pending_delta = null
		_run_grab(pending)
	else:
		_after_grab()


func _after_grab() -> void:
	_settle_dabs()


func _publish_grab_baseline() -> void:
	if _grab_baseline == null or _edit == null or _edit != _stroke_tx:
		return
	if State.document != _source_document or State.get_current_voxel_frame() != _source_frame:
		return
	var locations: Array[Vector3i] = []
	for location in _grab_published:
		locations.append(location)
	_grab_published.clear()
	_source_frame.apply_published(locations, _grab_baseline)
	State.document._bounds_dirty = true
	if not locations.is_empty():
		State.chunks_changed.emit(State.current_frame, locations)
	_mark_hover_dirty()


# --- Smooth -----------------------------------------------------------------
#
# Smooth rounds the local surface in three dimensions. It keeps one rounding
# field per symmetry mask. A mirror along the layer axis maps a patch onto
# itself, so one shared field would collide and lose a side. Each mask owns its
# own candidate patch, its own falloff weights. The sign of the reflected normal
# sets the outward direction, so a bottom, left, or back press rounds the correct
# side. The rounding reads a frozen occupancy set, so the result never depends on
# the iteration order.


func _clear_smooth() -> void:
	_smooth_fields = []


## Rebuilds the Smooth rounding fields around the current stroke center. The
## plane is re-read from the current surface first, so Smooth follows a changing
## local gradient.
func _rebuild_smooth() -> void:
	_smooth_surface_frame()
	_smooth_fields = _build_smooth_fields(_stroke_center_point, _stroke_radius, _stroke_falloff, _stroke_selection)


## Re-reads the stroke plane from the current surface at the brush location. The
## previous frame is the fallback and the seed, so a sparse or degenerate surface
## keeps the previous orientation and the normal never flips. The pure definition
## is shared with the worker job, so a large dab reads identically.
func _smooth_surface_frame() -> void:
	if _stroke_frame == null:
		return
	_stroke_frame = Prep.smooth_surface_frame(_active_frame(), _stroke_frame, _stroke_center_point, _smooth_entry, _stroke_radius, _footprint_depth(_stroke_radius))


## Returns one rounding field per active symmetry mask. Each field holds the
## writable candidate cells and the per-cell falloff weight.
##
## The candidates fill a sphere of the brush size around the dab point, so the
## rounding reaches every cell the brush covers, up, down, and sideways. The
## falloff sets the weight of each cell, so a soft edge rounds slower than a hard
## center. A cell is writable only when the frozen selection allows it.
func _build_smooth_fields(center_point: Vector3, radius: int, falloff: float, selection: Dictionary) -> Array:
	# The body is shared with the hover worker and the dab worker, so all paths
	# read one definition.
	return Prep.smooth_fields(center_point, radius, falloff, _context(), selection)


## Advances every Smooth field by one dab. The dab runs
## [member TerrainToolSettings.strength] passes, and the falloff weight of each cell
## scales that count. The rounding runs on the worker pool when the patch is
## large, so the neighborhood convolution never blocks the main thread.
func _smooth_tick() -> void:
	if _stroke_frame == null or _smooth_fields.is_empty():
		return
	var work := 0
	for field in _smooth_fields:
		work += (field["cells"] as Array).size()
	if work == 0:
		return
	_run_smooth(_smooth_fields)


## Runs one rounding pass group over the given fields. A small patch runs inline.
## A large patch runs on the worker pool, so the expensive neighborhood
## convolution is off the main thread. The worker receives its own copy of the
## field state, so it never reads a shared mutable set.
func _run_smooth(fields: Array) -> void:
	var job := SmoothJob.new()
	job.stroke_id = _stroke_id
	job.edited_frame = VoxelFrame.job_frame(_source_frame)
	job.fields = []
	var work := 0
	for field in fields:
		var cells: Array = field["cells"]
		work += cells.size()
		job.fields.append({
			"cells": cells,
			"weights": (field["weights"] as Dictionary).duplicate(),
		})
	job.passes = _stroke_strength
	job.radius = SmoothOperation.KERNEL_RADIUS
	job.remove_threshold = SmoothOperation.REMOVE_THRESHOLD
	job.add_threshold = SmoothOperation.ADD_THRESHOLD
	_smooth_job = job
	if work <= INLINE_EDIT_LIMIT:
		job.run()
		_finish_smooth(job)
	else:
		_operation_id = State.begin_operation("Smoothing voxels", work, true, self, _cancel_edit)
		job.operation_id = _operation_id
		_run_smooth_worker(job)


func _run_smooth_worker(job: SmoothJob) -> void:
	await State.run_edit_job(job, job.operation_id, "Smooth tick")
	if _smooth_job != job:
		return
	_finish_smooth(job)
	_settle_dabs()


func _finish_smooth(job: SmoothJob) -> void:
	if _smooth_job == job:
		_smooth_job = null
	if _operation_id == job.operation_id:
		_operation_id = 0
	State.finish_operation(job.operation_id)
	if not _job_is_current(job):
		return
	# Capture the identity, so a signal handler that cancels the stroke or swaps
	# the document cannot make the surface read touch stale state.
	var stroke_id := _stroke_id
	var tx := _stroke_tx
	var document := _source_document
	var source := _source_frame
	# A preparing dab built its fields and read its plane on the worker, so
	# adopt them before the tick publishes.
	if job.prepared_frame != null:
		_stroke_frame = job.prepared_frame
		_pose_footprint(_last_pick)
	if job.prepared_fields != null:
		_smooth_fields = job.prepared_fields
	_source_frame.apply_published(job.changed_chunks, job.edited_frame)
	State.document._bounds_dirty = true
	if not job.changed_chunks.is_empty():
		State.chunks_changed.emit(State.current_frame, job.changed_chunks)
	if _stroke_id != stroke_id or _edit == null or _edit != tx:
		return
	if State.document != document or State.get_current_voxel_frame() != source:
		return
	if _smooth_job != null:
		return
	# Re-read the plane from the accepted snapshot, so the next dab follows the
	# changed surface. The patch stays as it was built, so a burst of dabs at one
	# cell rounds the same cells as one call. The patch is rebuilt only when the
	# brush moves. A preparing dab already read the plane before it built the
	# fields, and the next dab reads again, so no second surface read runs here.
	if job.prepared_fields == null:
		_smooth_surface_frame()
	_mark_hover_dirty()


# --- Preview ----------------------------------------------------------------


## Pumps the preview for one frame. The runtime calls it from [method _process].
## A test calls it to force one request outside the frame loop. A stroke and a
## Grab hover publish the pose on the main thread, because both are cheap.
func _rebuild_preview() -> void:
	if _edit != null:
		_preview.publish_now()
		return
	if _settings.tool == TerrainSettings.Tools.GRAB:
		if _last_pick == null or _last_pick.target == VoxelPicking.NONE:
			_preview.publish_now()
			return
		_preview.publish_now()
		return
	# The hover request runs on the worker. A test or a benchmark calls it to
	# start one request outside the frame loop, and then waits for the controller
	# to settle and reads the published state. It re-checks the cache even when
	# the hover is not dirty, so a raw write with no signal still refreshes.
	_preview.refresh()


## Returns the live inputs of one hover request. The controller freezes the frame
## and runs the surface read on the worker. The builder never reads the surface and never scans the
## surface, so a pointer event stays cheap.
##
## The builder also reports the live view, so the controller can re-check it
## against the request before a finished result reaches the cursor. A press passes
## its own pick, so the reuse check reads the accepted pick and not the older
## hover pick.
func _preview_inputs(pick: PickResult = null) -> Dictionary:
	var use := pick if pick != null else _last_pick
	if use == null:
		return {}
	var hit: Vector3i = use.hit
	var target: Vector3i = use.target
	if hit == VoxelPicking.NONE and target == VoxelPicking.NONE:
		return {}
	var active := _active_frame()
	if active == null:
		return {}
	var view := _live_view()
	return {
		"ready": true,
		"frame": active,
		"frame_id": active.get_instance_id(),
		"hit": hit,
		"entry": use.entry,
		"target": target,
		"forward": _forward(),
		"floor_axis": State.floor_axis,
		"floor_index": State.floor_index,
		"radius": _settings.radius,
		"camera": view["camera"],
		"projection": view["projection"],
		"viewport": view["viewport"],
	}


## Returns true while an open stroke or a running edit blocks the hover. A press
## then never waits for a preview worker.
func _preview_paused() -> bool:
	return _edit != null or _busy()


## Returns the live view, so a zoom, a lens change, or a viewport resize drops a
## stale hover result. The transform is the exact camera transform the renderer
## uses, and the projection is the exact matrix, so an orthographic size or an FOV
## change is caught. A view without a camera reports no valid view.
func _live_view() -> Dictionary:
	if not is_inside_tree():
		return {"valid": false, "camera": Transform3D(), "projection": Projection(), "viewport": Vector2i.ZERO}
	var viewport := get_viewport()
	if viewport == null:
		return {"valid": false, "camera": Transform3D(), "projection": Projection(), "viewport": Vector2i.ZERO}
	var camera := viewport.get_camera_3d()
	if camera == null:
		return {"valid": false, "camera": Transform3D(), "projection": Projection(), "viewport": Vector2i(viewport.get_visible_rect().size)}
	return {
		"valid": true,
		"camera": camera.get_camera_transform(),
		"projection": camera.get_camera_projection(),
		"viewport": Vector2i(viewport.get_visible_rect().size),
	}


## Hides the visible outline without clearing the cursor request. An invalidation
## calls it, so a wrong footprint never shows, and the cursor keeps the mesh it
## already built.
func _hide_preview_visible() -> void:
	visible = false
	_hide_footprint()


# Marks the hover dirty after an input changed the footprint or the surface. The
# controller keeps the visible outline and recomputes when a worker is free.
func _mark_hover_dirty() -> void:
	if _preview != null:
		_preview.mark_intent()


## Handles a document change. A new document discards the frame a running hover
## job reads and the cached result, so the worker is joined before the preview
## rebuilds. The join is bounded by one request.
func _on_document_changed() -> void:
	if _preview == null:
		return
	_preview.join()
	_preview.invalidate()


## Poses the one white footprint ring after a published hover result.
##
## The ring is the whole cursor. It lies in the operation plane of the picked
## cell, so every tool shows the orientation the press will use. No cell set is
## drawn, because the ring predicts no voxel.
func _set_preview() -> void:
	_pose_footprint(_last_pick)


## Binds the ring node and its one fixed material.
func _setup_footprint() -> void:
	_footprint = get_node_or_null("Footprint") as MeshInstance3D
	if _footprint == null:
		return
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color.WHITE
	# The ring must stay readable inside geometry, so it skips the depth test. It
	# then draws through a hill in front of it. A depth-tested ring hides in the
	# voxels around the cursor, which is worse.
	material.no_depth_test = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_footprint.material_override = material
	_footprint.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_footprint.visible = false


## Shows the ring on the picked cell, or hides it when the pick misses.
##
## The mesh depends on the size only, so a size builds one mesh and every cell
## reuses it. The pose snaps to the cell center, so a pointer that moves inside
## one cell keeps the pose.
func _pose_footprint(pick: PickResult) -> void:
	if _footprint == null:
		return
	if pick == null or pick.target == VoxelPicking.NONE:
		_hide_footprint()
		return
	var cell := pick.hit if pick.hit != VoxelPicking.NONE else pick.target
	# A plane-anchored stroke draws the last accepted dab anchor. The ring and
	# the dab then share one cell, so the ring never jitters ahead of the dab.
	if _edit != null and _path_anchor != VoxelPicking.NONE and (_stroke_tool == TerrainSettings.Tools.BUILD or _stroke_tool == TerrainSettings.Tools.FLATTEN):
		cell = _path_anchor
	var size := clampi(_settings.radius, 1, 32)
	var mesh: ArrayMesh = _footprint_meshes.get(size)
	if mesh == null:
		mesh = TerrainRing.build_mesh(TerrainRing.legacy_plane_ring(size))
		_footprint_meshes[size] = mesh
	_footprint.mesh = mesh
	var frame := _footprint_frame(pick)
	# A floor miss shows the floor grid, before and during a stroke. An open
	# Smooth stroke keeps its captured frame instead, so its ring still shows the
	# re-read plane when the pointer leaves the model for a moment.
	var on_floor := pick.hit == VoxelPicking.NONE and (_edit == null or frame.on_floor)
	if on_floor:
		# The floor frame plane is the outer face of the first buildable layer,
		# one cell above the grid. Build the frame here so the pose never reads a
		# stale or a missing hover result.
		var axis := State.floor_axis
		var sign := 1 if cell[axis] >= State.floor_index else -1
		frame = TerrainFrame.from_floor(axis, sign, float(State.floor_index) - 0.5, cell)
	_idle_pose_frame = frame
	# The ring is centered on the picked cell, half a cell out along the pose
	# normal, so its cells cover the voxel cells that the dab writes. A cell
	# corner would shift the ring half a cell across the grid. Projecting onto
	# the frame plane would move the ring away from the cell whenever that plane
	# drifts, as the Smooth surface plane does.
	var origin := Vector3(cell) + frame.normal * 0.5
	if on_floor:
		origin = Vector3(cell)
		origin[State.floor_axis] = float(State.floor_index) - 0.5
	_footprint.global_transform = Transform3D(
		Basis(frame.tangent_u, frame.tangent_v, frame.normal),
		origin
	)
	# The tool node carries the hide state. A hide sets it false, so a pose must
	# set it true or an invisible parent keeps the ring off screen forever.
	visible = true
	_footprint.visible = true


## Returns the plane the ring shows. Grab and the Face source keep the exact
## picked face, and every other state uses the surface hover frame.
func _footprint_frame(pick: PickResult) -> TerrainFrame:
	if _settings.tool == _settings.Tools.GRAB:
		return TerrainFrame.from_face(pick.hit, pick.entry)
	# A Smooth stroke poses the ring on the re-read operation plane, so the ring
	# rotates with the normal the dab is using.
	if _edit != null and _stroke_frame != null and _stroke_tool == TerrainSettings.Tools.SMOOTH:
		return _stroke_frame
	# A Build or Flatten stroke poses the ring on the captured cursor plane, so
	# the ring follows the ground as it recenters.
	if _edit != null and _cursor_frame != null and _stroke_tool != TerrainSettings.Tools.SMOOTH:
		if _stroke_tool == TerrainSettings.Tools.BUILD:
			return TerrainFrame.cardinal(_cursor_frame)
		return _cursor_frame
	var frame := _preview.hover_frame() if _preview != null else null
	# A published read is exact only for the cell it was requested for. A slower
	# read for an older cell must not rotate the ring under a newer pointer.
	if frame != null and _preview.last_publish_target == pick.target:
		if _settings.tool == _settings.Tools.BUILD:
			return TerrainFrame.cardinal(frame)
		return frame
	return TerrainFrame.from_face(pick.hit, pick.entry)


## Hides the ring. The mesh and its pose stay, so the next hover is cheap.
func _hide_footprint() -> void:
	if _footprint != null:
		_footprint.visible = false
	_visual_valid = false


# --- Pick and cursor --------------------------------------------------------


func _pick_start(origin: Vector3, dir: Vector3) -> PickResult:
	var use_slice := State.slice_enabled
	if _edit != null and _stroke_context != null:
		use_slice = _stroke_context.slice_axis >= 0
	var pick := VoxelPicking.start_pick(origin, dir, State.get_current_voxel_frame(), _forward(), use_slice)
	# The pointer ray is the spacing reference of the stroke. A press records it,
	# so the first motion at the same pointer position is not a movement and
	# adds no dab.
	_drag_ray_moved = origin != _drag_ray_origin or dir != _drag_ray_dir
	_drag_ray_origin = origin
	_drag_ray_dir = dir
	# A stroke that already released only drains its accepted dabs. Its captures
	# belong to the press, so a hover must not overwrite the rays, the camera,
	# or the floor cell that the queued dabs read.
	var press := _edit != null and not _end_requested
	if press:
		_press_ray_origin = origin
		_press_ray_dir = dir
		_ray_origin = origin
		_ray_dir = dir
		# The first buildable cell is on the side of the floor plane that the
		# pointer is on, so a stroke from below seeds below the plane.
		var floor_level := float(State.floor_index) - 0.5
		_stroke_floor_cell = State.floor_index if origin[State.floor_axis] >= floor_level else State.floor_index - 1
	if _settings.tool == TerrainSettings.Tools.GRAB:
		if pick.hit != VoxelPicking.NONE:
			pick.target = pick.hit
			pick.plane = _plane_for(Vector3(pick.hit), _forward().normalized())
			# Grab keeps the exact picked face, so a press stores the cheap face
			# frame and runs no surface read.
			if press:
				_pending_frame = TerrainFrame.from_face(pick.hit, pick.entry)
		else:
			pick.plane = null
		return pick
	# An idle hover runs its surface read and its footprint map on the preview
	# worker, so a still pointer pays nothing and a new cell pays one bounded
	# request. The pointer ray above is already recorded, so the stroke spacing
	# baseline is unchanged. A press reads the surface here, because `open_stroke` runs before
	# this call and `_apply_pick` reads `_pending_frame` and `_press_point` at
	# once.
	if not press:
		return pick
	if _settings.tool == TerrainSettings.Tools.SMOOTH or _settings.tool == TerrainSettings.Tools.BUILD:
		# Capture the camera family of the press. A perspective or frustum camera
		# shares one focus, an orthographic camera keeps one direction. Every dab
		# reconstructs its ray from this captured family, so a later camera change
		# never alters an accepted dab. Build locks the direction this way, while
		# Smooth uses the ray for its operation plane too.
		_capture_press_camera(origin, dir)
		_stroke_forward = _forward()
	_pending_frame = _frame_for_pick(pick, origin)
	pick.plane = _plane_for(_pending_frame.origin, _pending_frame.normal)
	_press_point = _plane_hit(_pending_frame, origin, dir)
	return pick


# Captures the camera family of the press from the live camera. The projection
# mode selects the family. A missing camera keeps the orthographic family.
func _capture_press_camera(origin: Vector3, dir: Vector3) -> void:
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	_stroke_ray_dir = dir.normalized()
	_camera_perspective = camera != null and camera.projection != Camera3D.PROJECTION_ORTHOGONAL
	_press_projection = camera.projection if camera != null else Camera3D.PROJECTION_ORTHOGONAL
	_press_camera_transform = camera.global_transform if camera != null else Transform3D()
	# A perspective ray's origin is the camera focus. An orthographic ray's origin
	# is a near-plane point, so the press origin keeps the sub-cell phase of the
	# first click and the rest of the stroke reuses that constant offset.
	_camera_focus = origin if _camera_perspective else Vector3.ZERO


# Returns the ray and frame-plane intersection, or the frame origin when the
# ray is parallel to the plane.
func _plane_hit(frame: TerrainFrame, origin: Vector3, dir: Vector3) -> Vector3:
	var intersection = frame.to_plane().intersects_ray(origin, dir)
	if intersection == null:
		return frame.origin
	return intersection


func _frame_for_pick(pick: PickResult, origin: Vector3) -> TerrainFrame:
	# The operation plane keeps the surface normal, so the pointer anchors follow
	# the slope. Only the ring snaps to the cardinal action axis.
	return _raw_frame_for_pick(pick, origin)


func _raw_frame_for_pick(pick: PickResult, origin: Vector3) -> TerrainFrame:
	if pick.hit != VoxelPicking.NONE:
		# A large press reuses the surface hover frame when the last hover result
		# still matches this press exactly. The surface read then never runs on the main
		# thread. Any mismatch falls through to the read below.
		if _dab_is_large(_settings.radius):
			var reused := _preview.stashed_frame(_preview_inputs(pick)) if _preview != null else null
			if reused != null:
				return reused
		var entry := pick.entry
		if entry == Vector3i.ZERO:
			entry[VoxelPicking.view_axis(_forward())] = 1
		var fallback := TerrainFrame.from_face(pick.hit, entry)
		return TerrainFrame.from_surface(State.get_current_voxel_frame(), pick.hit, entry, _settings.radius, fallback)
	var floor_axis: int = State.floor_axis
	var level := float(State.floor_index) - 0.5
	var floor_sign := 1 if origin[floor_axis] >= level else -1
	return TerrainFrame.from_floor(floor_axis, floor_sign, level, pick.target)


func _plane_for(point: Vector3, normal: Vector3) -> StrokePlane:
	var plane := StrokePlane.new()
	plane.axis = VoxelPicking.view_axis(normal)
	plane.idx = roundi(point[plane.axis])
	plane.point = point
	plane.normal = normal
	return plane


func pick_drag(request: PickRequest) -> PickResult:
	if request.plane == null:
		return PickResult.new()
	if _stroke_active and _stroke_tool == TerrainSettings.Tools.BUILD:
		# The ground follows the surface under the pointer, so keep the latest
		# ray. The write still uses the cursor plane and the sample map.
		_ray_origin = request.origin
		_ray_dir = request.dir
	if _stroke_active and _stroke_tool == TerrainSettings.Tools.GRAB:
		return _view_drag(request)
	if _stroke_active and _cursor_frame != null:
		return _frame_drag(request)
	return VoxelPicking.drag_pick(request.origin, request.dir, request.frame, request.plane)


# Intersects the frozen cursor plane. The plane never changes during the stroke,
# so the same pointer ray gives the same anchor cell even when the Smooth
# operation plane adapts to an accepted dab. The point rounds to the dab anchor.
func _frame_drag(request: PickRequest) -> PickResult:
	var result := PickResult.new()
	if _stroke_tool == TerrainSettings.Tools.SMOOTH and _edit != null and _camera_changed():
		# A camera transform or projection change ends the captured gesture, so no
		# dab mixes the captured family with a live camera.
		finish_on_switch()
		return result
	_drag_ray_moved = request.origin != _drag_ray_origin or request.dir != _drag_ray_dir
	_drag_ray_origin = request.origin
	_drag_ray_dir = request.dir
	var intersection = _cursor_frame.to_plane().intersects_ray(request.origin, request.dir)
	if intersection == null:
		return result
	result.target = _cursor_cell(intersection)
	result.hit = result.target if request.frame != null and request.frame.has(result.target) else VoxelPicking.NONE
	return result


# Rounds a point on the cursor plane to a cell. A cardinal plane fixes one
# coordinate at a half step, so the exact frame origin selects that cell. A
# plain round would flip between two cells when float noise moves the point.
func _cursor_cell(point: Vector3) -> Vector3i:
	var cell := TerrainGeometry.cell_at(point)
	if _cursor_frame == null:
		return cell
	var axis := TerrainGeometry.cardinal_axis(_cursor_frame.normal)
	if axis >= 0:
		cell[axis] = floori(_cursor_frame.origin[axis] + 0.5)
	return cell


# Returns true when the live camera no longer matches the captured press camera.
func _camera_changed() -> bool:
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null:
		return false
	if camera.projection != _press_projection:
		return true
	return not camera.global_transform.is_equal_approx(_press_camera_transform)


# Intersects the true camera-facing plane and rounds the point to a cell.
func _view_drag(request: PickRequest) -> PickResult:
	var plane := request.plane
	var result := PickResult.new()
	var denom := request.dir.dot(plane.normal)
	if absf(denom) < 1e-8:
		return result
	var t: float = (plane.point - request.origin).dot(plane.normal) / denom
	if t <= 0.0:
		return result
	var point: Vector3 = request.origin + request.dir * t
	# A view-aligned plane can be oblique, so the drag keeps all three rounded
	# components. Only a cardinal cursor plane fixes one component.
	result.target = TerrainGeometry.cell_at(point)
	result.hit = result.target if request.frame != null and request.frame.has(result.target) else VoxelPicking.NONE
	return result


## Updates the tool cursor and the preview for one pick.
##
## The builder records the pick and marks the hover dirty. The controller reads
## the frame and builds the footprint on a worker, so a pointer event never runs
## a surface read or a scan on the main thread. Grab draws the occupied sources of
## the view plane, so it needs no surface frame.
func update_visual(pick: PickResult) -> void:
	if pick.plane == null:
		pick.plane = _plane
	_last_pick = pick
	if pick.target == VoxelPicking.NONE:
		if _preview != null:
			# The pointer left the model, so every request is retired and the
			# visible outline is cleared.
			_preview.clear_all()
		visible = false
		_hide_footprint()
		return
	# The ring snaps to a cell. A motion inside the same cell keeps the pose, so
	# terrain reacts to grid movement. The entered face is not part of the gate: a
	# ray that grazes a convex edge can report either face for the same cell. The
	# hover still re-checks its read region, because a raw write can change the
	# surface under the same cell.
	if _visual_valid and pick.hit == _visual_hit and pick.target == _visual_target:
		_mark_hover_dirty()
		return
	_visual_hit = pick.hit
	_visual_target = pick.target
	_visual_valid = true
	# The ring snaps and shows before the worker reads the surface, so a pointer
	# event never waits for a surface read.
	_pose_footprint(pick)
	_mark_hover_dirty()


func _active_frame() -> VoxelFrame:
	return _source_frame if _edit != null else State.get_current_voxel_frame()


func _context() -> VoxelFrame.EditContext:
	return _stroke_context if _edit != null else State.drawing_context()


# Returns the symmetry masks of one edit context. A null context is one mask.
func _masks_for(context: VoxelFrame.EditContext) -> Array:
	return TerrainPreview.masks_for(context)
