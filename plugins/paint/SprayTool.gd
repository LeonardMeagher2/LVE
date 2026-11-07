extends "res://plugins/brush/StrokeTool.gd"

## The spray can tool.
##
## The tool paints random spots around the brush cell. It samples distinct
## exposed spot centers from the existing voxels inside the spray search size. A
## voxel is exposed when at least one of its six face neighbors is empty. Each
## spot center paints every exposed existing voxel inside a sphere of the spot
## diameter. Diameter 1 paints the spot center alone. The spot sphere is the
## shared brush sphere of that diameter, and the search size is the shared brush
## sphere of that width, so an even size keeps the brush alignment.
##
## The tool samples once for one brush cell and shows the exact voxels of that
## batch. The preview holds while the brush cell, the frame, the settings, the
## edit context, and the occupancy stay the same. The press and every brush cell
## change paint the exact previewed batch, so a preview never disagrees with the
## stroke. A press on a different cell drops a batch that belongs to another cell,
## so a pending hover never makes the click paint the previous cell. The cursor
## reports the request token of its installed surface. A lagging surface of
## another cell never paints, even when the current batch already names the press
## cell. A completed click rerolls the next preview, so the next click paints a
## new sample. The tool never paints and never rerolls while the pointer holds
## still.
##
## A small batch samples inline, in the input event. A batch whose indexed work
## estimate passes [constant INLINE_SAMPLE_LIMIT] samples on the worker pool, so
## the input frame never pays a long sample, a cold spot pattern build, or a wide
## spot union. One hover sample runs at a time and the newest request waits behind
## it, so a steady sweep installs results in request order instead of restarting.
## A completed result installs only while its frame, its edit context, and its
## chunk revisions still hold, so a stale sample cannot reach the cursor.
##
## Every accepted stroke batch queues in brush cell order and is never dropped.
## A release, a tool switch, and a frame change close the stroke only after the
## last accepted batch wrote, so the switch cannot discard queued work.
##
## An inline sample draws from the shared random source at once. A worker sample
## captures the exact random state, draws from its own copy, and commits the end
## state only when the result is adopted. A cancelled or obsolete hover therefore
## consumes no shared draw, and an older worker result cannot rewind a stream that
## already advanced.
##
## The whole spray is one history action. Escape and a context change roll it
## back.

## The pure size helpers. They own the sphere mask and the reach of the search
## size and the spot diameter.
const VoxelBrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")
## The pure sampler kernel. It reads no Node, no State, and no settings.
const SpraySampler := preload("./SpraySampler.gd")
## The cancellable worker job of one spray sample.
const SpraySamplingJob := preload("./SpraySamplingJob.gd")

## The indexed work at or below which a batch samples inline.
##
## The unit is one row operation. Eight nonempty chunk-row scans (2048) plus a
## small sphere and footprint allowance fit one input event. A wider sphere, a
## large selection, or a footprint union crosses to the worker pool.
##
## The estimate excludes the one-time occupancy-row build of a cold chunk. That
## build reads one dense chunk grid (CHUNK_SIZE cubed slots) and writes
## CHUNK_SIZE squared masks per touched nonempty chunk. A point search that
## crosses a chunk corner touches at most eight chunks, so a cold build can add
## up to 32768 slot reads outside the estimate. The limit is a warm-path budget,
## not a bound on the cold build. The benchmarks report `index_builds` and
## `index_grid_reads`, so the cold cost is measured instead of assumed.
const INLINE_SAMPLE_LIMIT := 2200

## One accepted stroke brush cell and every input that its sample needs.
##
## The record captures the settings and the context at the moment that the tool
## accepts the cell. A later settings change therefore cannot alter an accepted
## sample that still waits behind a running worker.
class Intent extends RefCounted:
	var center := Vector3i.ZERO
	var frame: VoxelFrame
	var context: VoxelFrame.EditContext
	var material := PackedFloat32Array()
	var estimate := 0
	var spot_size := 1
	var search_size := 9
	var speed := 8

	## Returns true when another record describes the same sample.
	func matches(other: Intent) -> bool:
		return center == other.center and frame == other.frame \
			and context == other.context and material == other.material \
			and estimate == other.estimate and spot_size == other.spot_size \
			and search_size == other.search_size and speed == other.speed

## The captured identity of one sampled batch.
##
## The cursor returns the token of the surface that it installed, so a press can
## tell whether the visible cells belong to the cell, the frame, and the edit
## context that the press uses. A lagging surface of the same cell and context
## stays the exact batch that the press paints. A surface of another cell never
## paints. The tool makes one token per sampled batch, never one per cell, and it
## never changes a token after it creates it.
class BatchToken extends RefCounted:
	var center := VoxelPicking.NONE
	var frame: VoxelFrame
	var axes := 0
	var origin_twice := Vector3i.ZERO
	var selection := {}

var _paint_settings: PaintToolSettings
var _rng := RandomNumberGenerator.new()
## The number of committed random draws. A worker captures the epoch with its
## state, so an older result never rewinds a stream that already advanced.
var _rng_epoch := 0
## The shared spot shape cache. The main thread and the sample workers share it.
var _shape_cache := SpraySampler.ShapeCache.new()
# One immutable selection mask index for the current editor selection snapshot.
# The cache is keyed by the dictionary identity of `State.selection.all_cells()`.
# A selection write replaces that dictionary, so a stale identity never hits. A
# raw mutable context never matches the editor snapshot and is never cached.
var _selection_source := {}
var _selection_index: RefCounted = null
# The last pair of different read-only snapshots that compared equal. The pair
# avoids a repeated content scan when a stroke context and the live context are
# different dictionaries with the same cells.
var _selection_equal_a := {}
var _selection_equal_b := {}
## The chunk row builds of the last sample.
var last_index_builds := 0
## The dense grid slots that those builds read.
var last_index_grid_reads := 0
## The row masks that those builds wrote.
var last_index_build_slots := 0
## The selection mask builds of the last sample.
var last_selection_builds := 0
## The inline work estimate that the last gate compared.
var last_work_estimate := 0
## The chunks that the last worker snapshot captured.
var last_capture_chunks := 0
## The total indexed row operations of the last sample.
var last_row_ops := 0
## The occupied footprint cells that the last sample visited.
var last_footprint_visits := 0
# The batch that the preview shows and the next change paints.
var _batch_center := VoxelPicking.NONE
var _batch_cells: Array[Vector3i] = []
var _batch_material := VoxelFrame.material(Color.WHITE)
var _batch_axes := 0
var _batch_origin := Vector3i.ZERO
var _batch_selection := {}
# The frame the batch sampled from. A document or frame change makes the batch
# stale, because its cells belong to the old frame.
var _batch_frame: VoxelFrame
# The captured identity of the current batch. The cursor keeps the token of the
# surface that it installed, so a press can attribute the visible cells to the
# request that produced them. A null token means no owned surface is installed.
var _batch_token: BatchToken
# Whether the last cursor update sampled a new batch.
var _batch_fresh := false
# The chunk identity and voxel revision of every chunk that holds a batch cell.
# A mutation bumps the revision or replaces the chunk, so a repeated cursor
# update revalidates the batch only when one of these changes.
var _batch_chunks := {}
# The batch version. It moves on every new sample and on every invalidation, so
# the cursor can tell whether it already shows the current batch.
var _batch_version := 0
# The batch version that the cursor shows, or -1 before the first submission.
var _preview_version := -1
# Whether the cursor holds a non-empty preview mesh from this tool.
var _preview_active := false
# The preview dict that this tool last handed to the cursor, and the chunk
# witness of the batch it draws. The witness validates the whole installed
# surface with one test per chunk instead of one test per cell.
var _shown_spots := {}
var _shown_witness := {}
# The prepared preview payload of the current batch, or null when the batch was
# sampled inline. A large batch samples on the worker, which builds the payload
# off the main thread, so `_show_spots` never builds the color dictionary or
# hashes the keys on the main thread for a large batch.
var _batch_payload

# The in-flight stroke sample. Every accepted brush cell queues until this job
# and the write pipeline consumed it.
var _sample_job: SpraySamplingJob = null
var _sample_operation_id := 0
# The accepted stroke brush cells, in order. Each record captures its own inputs.
var _pending_intents: Array[Intent] = []
var _intent_running := false
# Whether the current input event is the press that opens the stroke. The press
# samples its own captured batch and never waits for a hover result.
var _press_pending := false
# Whether a release waits for the accepted samples to write.
var _pending_end := false
var _reroll_pending := false

# The in-flight hover sample and the newest request behind it.
var _hover_sample_job: SpraySamplingJob = null
var _hover_sample_operation_id := 0
var _hover_request := {}
# The request epoch. It moves on every hover request, so a result can be matched
# to the request that asked for it.
var _hover_epoch := 0
# The newest request epoch that installed. A result installs only when its epoch
# is newer, so an older sample never replaces a newer one.
var _hover_installed_epoch := 0


func _init() -> void:
	_paint_settings = preload("./settings.tres")
	_settings = _paint_settings


func _ready() -> void:
	super._ready()
	_rng.randomize()
	_rng_epoch += 1


# A tool switch detaches this node and the base releases its context and history
# subscriptions, so a change while detached cannot invalidate the batch. A
# re-entry drops it, so the next hover samples the current frame again.
func _enter_tree() -> void:
	_invalidate_batch()
	# A selection or document change while detached was missed, so the cache
	# starts empty on every re-entry.
	clear_selection_cache()
	super._enter_tree()
	# The cache describes the live editor selection. A selection write or a
	# document switch makes the built masks stale even when no hover runs.
	if not State.selection_changed.is_connected(_on_selection_changed):
		State.selection_changed.connect(_on_selection_changed)
	if not State.document_changed.is_connected(_on_document_changed):
		State.document_changed.connect(_on_document_changed)


# A detach drops the batch, so its chunk snapshot never outlives the batch. A
# hover sample is optional work, so it stops here. An accepted stroke sample
# keeps running and the runner publishes it, so a switch never discards queued
# brush cells.
func _exit_tree() -> void:
	clear_selection_cache()
	if State.selection_changed.is_connected(_on_selection_changed):
		State.selection_changed.disconnect(_on_selection_changed)
	if State.document_changed.is_connected(_on_document_changed):
		State.document_changed.disconnect(_on_document_changed)
	_invalidate_batch()
	super._exit_tree()


# A freed node cannot await, so it cancels and joins its own samples here. The
# handles are cleared before the base teardown and its signals.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_teardown_hover_sample()
		_teardown_samples()
	super._notification(what)


func _process(delta: float) -> void:
	super._process(delta)
	_pump_hover_sample()
	# A release that waited for its samples rerolls the next preview once the
	# stroke really closed, so the reroll never races the accepted cells.
	if _reroll_pending and _edit == null and _sample_job == null and _pending_intents.is_empty():
		_reroll_pending = false
		_invalidate_batch()
		if _last_pick:
			update_visual(_last_pick)


## Seeds the sampling random source. A test uses it for a repeatable spray. The
## inline path draws from this source, and a worker batch captures its exact
## state, so a seeded tool repeats the same samples on either path.
func seed_spray(seed_value: int) -> void:
	_rng.seed = seed_value
	_rng_epoch += 1


## Drops the shared spot shape cache. The next sample pays the cold build.
func clear_shape_caches() -> void:
	_shape_cache.clear()


## Drops the cached selection masks. A selection write also misses the identity
## check on its own, so this is a memory release, not a correctness requirement.
func clear_selection_cache() -> void:
	_selection_source = {}
	_selection_index = null
	_selection_equal_a = {}
	_selection_equal_b = {}


# A selection write releases the cached masks even when no hover runs. An old
# late job also fails the identity check, so it cannot recache stale masks.
func _on_selection_changed() -> void:
	clear_selection_cache()


# A document switch changes the frame and the selection, so the cached masks
# cannot describe the new document.
func _on_document_changed() -> void:
	clear_selection_cache()


# Returns true when two selection dictionaries hold the same cells.
##
## A read-only snapshot compares by identity first, so the common production
## hover never scans 125k entries. Two different read-only snapshots compare by
## content once and the equal pair is remembered. A raw mutable dictionary never
## compares by content: an aliased dictionary can change without a new identity.
func _same_selection(first: Dictionary, second: Dictionary) -> bool:
	if not first.is_read_only() or not second.is_read_only():
		return false
	if is_same(first, second):
		return true
	var cached_pair := (is_same(first, _selection_equal_a) and is_same(second, _selection_equal_b)) or (is_same(first, _selection_equal_b) and is_same(second, _selection_equal_a))
	if cached_pair:
		return true
	if first != second:
		return false
	_selection_equal_a = first
	_selection_equal_b = second
	return true


# Returns the cached masks of one frozen editor selection snapshot, or null.
func _cached_selection_index(selection: Dictionary) -> RefCounted:
	if selection.is_empty() or not selection.is_read_only():
		clear_selection_cache()
		return null
	if not is_same(selection, State.selection.all_cells()):
		clear_selection_cache()
		return null
	if is_same(_selection_source, selection) and _selection_index != null:
		return _selection_index
	return null


# Keeps one built selection index only when it still describes the current
# editor snapshot. A raw mutable context never matches and is never cached.
func _remember_selection_index(selection: Dictionary, index: RefCounted) -> void:
	if not selection.is_read_only() or not is_same(selection, State.selection.all_cells()):
		clear_selection_cache()
		return
	if index == null:
		return
	_selection_source = selection
	_selection_index = index


## Returns [code]true[/code] when no hover or stroke sample is pending. A caller
## waits on it to settle a benchmark.
func is_sample_settled() -> bool:
	return _hover_sample_job == null and _sample_job == null and _pending_intents.is_empty()


## Returns the cells of the current batch. The next press or brush cell change
## paints exactly these cells.
func preview_cells() -> Array[Vector3i]:
	return _batch_cells.duplicate()


## Returns [code]true[/code] when a press pick uses the add target in front of
## the clicked face. A spray press uses the picked cell.
func _pick_adds() -> bool:
	return false


## Returns [code]true[/code] when the cursor needs an occupied cell.
func _requires_hit() -> bool:
	return true


## Returns [code]true[/code] when the tool changes only cells that already
## exist.
func _paints_existing() -> bool:
	return true


## Returns the drag pick. A spray drag picks the surface cell, so the pointer
## stays on the surface.
func pick_drag(request: PickRequest) -> PickResult:
	return VoxelPicking.start_pick(request.origin, request.dir, request.frame, request.forward)


func open_stroke() -> VoxelEditTransaction:
	var tx := super.open_stroke()
	if tx == null:
		return null
	# Every batch cell writes one cell, so the stamp pattern holds one offset.
	_stroke_pattern = {Vector3i.ZERO: Color.TRANSPARENT}
	_stroke_offsets = [Vector3i.ZERO]
	_stroke_diameter = 1
	_stroke_shape = StampSettings.BrushShape.CUBE
	_stroke_pattern_size = 1
	return tx


## Handles one input event. A press paints the previewed batch. A drag paints a
## new batch for each brush cell. Escape cancels the stroke.
func handle_input(event: InputEvent, pos: Vector2) -> bool:
	if event.is_action_pressed("ui_cancel") and _edit != null:
		_cancel_edit()
		return true
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			# A cancelled stroke can leave its runner and worker live for one more
			# frame. A new stroke must wait for them to retire, or its accepted
			# cells would strand behind the old runner.
			if _edit != null or _job or _intent_running or _sample_job != null:
				return true
			var ray := _ray(pos)
			var pick := _pick_start(ray[0], ray[1])
			if pick.hit == VoxelPicking.NONE:
				return false
			if open_stroke() == null:
				return false
			# The installed batch can belong to another cell or another context
			# while the current cell still waits on the worker. Drop it, so the
			# press paints its own cell. A batch already sampled for this cell and
			# context stays, so a lagging cursor still paints the exact surface it
			# shows. An installed surface of another cell is also ignored by its
			# request token, even when `_batch_center` already names the press cell.
			var stale := _batch_center != pick.hit or _batch_frame != _source_frame
			if not stale and _edit_context != null:
				stale = _batch_axes != _edit_context.axes or _batch_origin != _edit_context.origin_twice or not _same_selection(_batch_selection, _edit_context.selection)
			if stale:
				_invalidate_batch()
				_clear_cursor_preview()
			_plane = pick.plane
			_last_target = pick.target
			_stroke_active = true
			# The press keeps its own batch. A large batch queues as an accepted
			# cell, so its write set uses the captured frame and not a hover result.
			_press_pending = true
			update_visual(pick)
			_press_pending = false
			# The press paints the batch that the cursor actually shows. A lagging
			# coalescing preview shows an older sample, so the press paints that
			# visible sample instead of the newer one that has not installed.
			_apply_offered()
		else:
			if _stroke_active:
				_finish_click()
		return true
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _stroke_active and not (motion.button_mask & MOUSE_BUTTON_MASK_LEFT):
			# The button is up while the stroke is open, so the release event was
			# lost. End the click instead of leaving the edit open.
			_finish_click()
			return true
		if _stroke_active and _plane != null and motion.button_mask & MOUSE_BUTTON_MASK_LEFT:
			var ray := _ray(pos)
			var pick := _pick_drag(ray[0], ray[1])
			update_visual(pick)
			if _batch_fresh:
				_apply_batch()
			return true
		if motion.button_mask == 0:
			var ray := _ray(pos)
			update_visual(_pick_start(ray[0], ray[1]))
			return true
		return false
	return false


# Ends one click like a release and rerolls the next preview. The click already
# queued its own cells, so the reroll cannot change them. A tool switch calls the
# base end directly, so it never rerolls here.
func _finish_click() -> void:
	_end()
	if _pending_end:
		# An accepted sample still writes for this stroke. The reroll waits for
		# the stroke to close, so it never races the queued brush cells.
		_reroll_pending = true
		return
	_invalidate_batch()
	if _last_pick:
		update_visual(_last_pick)


## Ignores the press pick. The brush cell update samples the batch.
func _apply_pick(_target: Vector3i, _hit: Vector3i) -> void:
	pass


## Ignores the motion pick. The brush cell update samples the batch.
func _apply_stroke_to(_to: Vector3i) -> void:
	pass


func _cancel_edit() -> void:
	_pending_end = false
	_cancel_samples()
	_invalidate_batch()
	_clear_cursor_preview()
	super._cancel_edit()


func _on_settings_changed() -> void:
	# A settings change rebuilds the batch.
	_invalidate_batch()
	super._on_settings_changed()


# Undo and redo change the frame under the cursor. The displayed batch may no
# longer hold, so hide the cursor and resample on the next update. A queued
# stroke sample read the frame before the undo, so it stops here like the write
# job of the base class.
func _on_history_changed() -> void:
	_cancel_samples()
	_invalidate_batch()
	_clear_cursor_preview()
	super._on_history_changed()


## Updates the spray cursor for one pick. The cursor shows the exact cells of the
## current batch, so no sphere is drawn.
func update_visual(pick: PickResult) -> void:
	if pick.plane == null:
		pick.plane = _plane
	_last_pick = pick
	_batch_fresh = false
	if pick.target == VoxelPicking.NONE or pick.hit == VoxelPicking.NONE:
		visible = false
		_show_spots([])
		return
	# The batch holds world cells, so the cursor mesh is already in world space.
	# The tool stays at the origin, or the mesh would translate a second time.
	position = Vector3.ZERO
	visible = true
	if _stroke_active:
		_batch_fresh = _ensure_batch_if_cheap(pick.hit, _source_frame, _edit_context, _stroke_material)
		_show_spots(_batch_cells)
		return
	_ensure_hover_batch(pick.hit, State.get_current_voxel_frame(), State.drawing_context(), State.current_material)
	_show_spots(_batch_cells)


# Ends the stroke like a release. The stroke closes only when no accepted sample
# and no queued brush cell remains, so a tool switch and a release never discard
# accepted work.
func _end() -> void:
	_end_requested = false
	_pending_end = true
	_stroke_active = false
	_close_if_idle()


# Closes the stroke when the accepted work is fully written.
func _close_if_idle() -> void:
	if not _pending_end:
		return
	if _sample_job != null or not _pending_intents.is_empty():
		return
	_pending_end = false
	_end_requested = true
	if _job == null:
		_finish_stroke()


# Clears the batch, so the next cursor update samples a new one. A pending hover
# sample is dropped, because its result belongs to the batch this call clears.
func _invalidate_batch() -> void:
	_cancel_hover_sample()
	_reroll_pending = false
	_batch_center = VoxelPicking.NONE
	_batch_cells = []
	_batch_material = VoxelFrame.material(Color.WHITE)
	_batch_frame = null
	_batch_token = null
	_batch_fresh = false
	_batch_chunks = {}
	_batch_payload = null
	_batch_version += 1
	_preview_version = -1
	_hover_installed_epoch = _hover_epoch


# Samples the batch for one brush cell synchronously. It returns true when it
# sampled a new batch. The batch holds while the brush cell, the frame, the
# material, the symmetry, the selection, and the occupancy stay the same.
func _ensure_batch(center: Vector3i, frame: VoxelFrame, context: VoxelFrame.EditContext, material: PackedFloat32Array) -> bool:
	if frame == null or context == null:
		return false
	if center == _batch_center and frame == _batch_frame and material == _batch_material and context.axes == _batch_axes and context.origin_twice == _batch_origin and _same_selection(context.selection, _batch_selection) and _batch_holds(frame):
		return false
	# A changed frame, material, symmetry, or selection makes the displayed
	# surface stale. Hide it, so a click can never paint a preview of another
	# context while the new sample builds.
	var context_changed := frame != _batch_frame or material != _batch_material or context.axes != _batch_axes or context.origin_twice != _batch_origin or not _same_selection(context.selection, _batch_selection)
	if context_changed:
		_clear_cursor_preview()
	_batch_center = center
	_batch_frame = frame
	_batch_material = material.duplicate()
	_batch_axes = context.axes
	_batch_origin = context.origin_twice
	_batch_selection = context.selection
	_batch_token = _make_batch_token(frame, center, context)
	_batch_cells = _sample(center, frame, context)
	_snapshot_batch_chunks(frame)
	# An inline sample holds no prepared payload, so the show path builds the
	# dictionary on the main thread for this small batch.
	_batch_payload = null
	# The batch changed, so the cursor must submit the new preview.
	_batch_version += 1
	return true


# Samples the batch for one stroke brush cell. A small batch samples inline and
# returns true. A large batch becomes one accepted intent and returns false, so
# the input event never pays the gather.
func _ensure_batch_if_cheap(center: Vector3i, frame: VoxelFrame, context: VoxelFrame.EditContext, material: PackedFloat32Array) -> bool:
	if frame == null or context == null:
		return false
	if center == _batch_center and frame == _batch_frame and material == _batch_material and context.axes == _batch_axes and context.origin_twice == _batch_origin and _same_selection(context.selection, _batch_selection) and _batch_holds(frame):
		return false
	var selection_index := _cached_selection_index(context.selection)
	var estimate := SpraySampler.work_estimate(frame, center, _paint_settings.spray_size, _paint_settings.spot_diameter, context.selection, _paint_settings.speed, selection_index)
	last_work_estimate = estimate
	if estimate <= INLINE_SAMPLE_LIMIT:
		return _ensure_batch(center, frame, context, material)
	if not _press_pending:
		_accept_intent(center, frame, context, material, estimate)
	return false


# Queues one accepted stroke brush cell. A repeat of the last accepted sample
# compacts away, because it would sample the same batch again. The record captures
# the cell, the frame, the context, the material, and the sizes, so a later
# settings change cannot alter this sample.
func _accept_intent(center: Vector3i, frame: VoxelFrame, context: VoxelFrame.EditContext, material: PackedFloat32Array, estimate: int) -> void:
	var intent := Intent.new()
	intent.center = center
	intent.frame = frame
	intent.context = context
	intent.material = material.duplicate()
	intent.estimate = estimate
	intent.spot_size = _paint_settings.spot_diameter
	intent.search_size = _paint_settings.spray_size
	intent.speed = _paint_settings.speed
	if not _pending_intents.is_empty() and _pending_intents[_pending_intents.size() - 1].matches(intent):
		return
	_pending_intents.append(intent)
	_run_intents()


# One runner owns one accepted stroke sample at a time. It samples in brush cell
# order and queues each batch into the shared write pipeline, so a slow worker
# never reorders or drops an accepted brush cell. A switch detaches the node but
# not the runner, so accepted work still commits.
func _run_intents() -> void:
	if _intent_running:
		return
	_intent_running = true
	while not _pending_intents.is_empty():
		var tx := _edit
		if tx == null:
			_pending_intents.clear()
			break
		var intent: Intent = _pending_intents.pop_front()
		if intent.frame == null or intent.context == null:
			continue
		var job := _build_sample_job(intent.frame, intent.center, intent.context, intent.material, intent.estimate, intent.spot_size, intent.search_size, intent.speed)
		# The accepted cell captured its own sizes, so a settings change while a
		# sample waits never alters the batch or the captured ROI.
		_sample_job = job
		_sample_operation_id = State.begin_operation("Sampling spray", job.local_estimate, true, self, _cancel_edit)
		await State.run_edit_job(job, _sample_operation_id, "Spray sample")
		var current := _sample_job == job
		_sample_job = null
		State.finish_operation(_sample_operation_id)
		_sample_operation_id = 0
		# A cancel or a replacement owns the stroke now, so its sample must not
		# write into the new one.
		if not current or _edit != tx:
			break
		if not job.checkpoint(0):
			break
		# A later write can replace a witness chunk while the sampled cells still
		# exist. Snapshot the current chunks in that case instead of adopting a
		# stale witness.
		var witness := job.witness
		if not _witness_holds(witness, intent.frame):
			if not _cells_hold(intent.frame, job.cells):
				continue
			witness = {}
		_commit_sample_state(job)
		_remember_selection_index(job.selection, job.built_selection_index)
		last_index_builds = job.index_builds
		last_index_grid_reads = job.index_grid_reads
		last_index_build_slots = job.index_build_slots
		last_selection_builds = job.selection_builds
		last_row_ops = job.row_ops
		last_footprint_visits = job.footprint_visits
		if not job.cells.is_empty():
			_adopt_batch(intent.frame, intent.center, intent.context, intent.material, job.cells, witness, job.preview_payload)
			_queue_centers(job.cells)
	_intent_running = false
	_close_if_idle()
	_release_context_subscriptions()


# Cancels every pending stroke sample and drops the queued brush cells.
func _cancel_samples() -> void:
	_pending_intents.clear()
	if _sample_job:
		_sample_job.cancel()


# Cancels and joins every stroke sample. The node cannot await, so the join runs
# here. It is the one blocking wait for a stroke sample.
func _teardown_samples() -> void:
	_cancel_samples()
	if _sample_job:
		_sample_job.wait_for_worker()
		_sample_job = null
	State.finish_operation(_sample_operation_id)
	_sample_operation_id = 0


# Samples the batch for one hover brush cell. A small batch samples inline. A
# large batch becomes the newest request, and one worker sample runs at a time.
func _ensure_hover_batch(center: Vector3i, frame: VoxelFrame, context: VoxelFrame.EditContext, material: PackedFloat32Array) -> void:
	if frame == null or context == null:
		return
	if center == _batch_center and frame == _batch_frame and material == _batch_material and context.axes == _batch_axes and context.origin_twice == _batch_origin and _same_selection(context.selection, _batch_selection) and _batch_holds(frame):
		return
	var selection_index := _cached_selection_index(context.selection)
	var estimate := SpraySampler.work_estimate(frame, center, _paint_settings.spray_size, _paint_settings.spot_diameter, context.selection, _paint_settings.speed, selection_index)
	last_work_estimate = estimate
	if estimate <= INLINE_SAMPLE_LIMIT:
		# The inline sample is the newest result. It blocks every older worker
		# result and drops the request that waited behind it.
		_hover_epoch += 1
		_hover_installed_epoch = _hover_epoch
		_hover_request = {}
		_ensure_batch(center, frame, context, material)
		return
	var context_changed := frame != _batch_frame or material != _batch_material or context.axes != _batch_axes or context.origin_twice != _batch_origin or not _same_selection(context.selection, _batch_selection)
	if context_changed:
		# A stale surface of another context must not stay visible or be painted.
		_clear_cursor_preview()
	_hover_epoch += 1
	_hover_request = {
		"center": center, "frame": frame, "context": context,
		"material": material.duplicate(), "estimate": estimate, "epoch": _hover_epoch,
	}
	_start_hover_sample()


# Starts the newest hover request when no hover sample runs. The running sample
# is never cancelled here, so a steady sweep keeps one worker busy instead of
# restarting it on every event.
func _start_hover_sample() -> void:
	if _hover_sample_job != null or _hover_request.is_empty():
		return
	if _edit != null or _stroke_active:
		_hover_request = {}
		return
	var request := _hover_request
	_hover_request = {}
	var context: VoxelFrame.EditContext = request["context"]
	var job := _build_sample_job(request["frame"], request["center"], context, request["material"], request["estimate"])
	job.request_epoch = request["epoch"]
	_hover_sample_job = job
	_hover_sample_operation_id = State.begin_operation("Sampling spray", job.local_estimate, false, self)
	job.worker_task_id = WorkerThreadPool.add_task(job.run, false, "Spray sample")


# Installs a completed hover sample and starts the newest request behind it.
func _pump_hover_sample() -> void:
	var job: SpraySamplingJob = _hover_sample_job
	if job != null and WorkerThreadPool.is_task_completed(job.worker_task_id):
		WorkerThreadPool.wait_for_task_completion(job.worker_task_id)
		job.worker_task_id = -1
		_hover_sample_job = null
		State.finish_operation(_hover_sample_operation_id)
		_hover_sample_operation_id = 0
		if job.checkpoint(0) and _edit == null and not _stroke_active:
			_install_hover(job)
	_start_hover_sample()


# Installs one finished hover sample. The sample installs only while its frame
# and its edit context still hold and while no newer sample installed. A chunk
# that a later write replaced revalidates the batch, so a material-only write
# keeps the sample.
func _install_hover(job: SpraySamplingJob) -> void:
	if job.request_epoch <= _hover_installed_epoch:
		return
	var frame := State.get_current_voxel_frame()
	if frame == null or frame != job.source_frame:
		return
	var context := State.drawing_context()
	if context.axes != job.axes or context.origin_twice != job.origin_twice or not _same_selection(context.selection, job.selection):
		return
	if not _witness_holds(job.witness, frame) and not _cells_hold(frame, job.cells):
		_invalidate_batch()
		return
	# A later write can replace a witness chunk while the sampled cells still
	# exist. Snapshot the current chunks instead of keeping a stale witness.
	var witness := job.witness
	if not _witness_holds(witness, frame):
		witness = {}
	# The job already holds the chunk witness of its own cells, so the install
	# skips the per-cell snapshot.
	_adopt_batch(frame, job.center, context, job.material, job.cells, witness, job.preview_payload)
	_commit_sample_state(job)
	# Cache the index against the selection the job actually sampled, not the
	# live context. A different dictionary with the same cells must not inherit
	# an index it did not build.
	_remember_selection_index(job.selection, job.built_selection_index)
	last_index_builds = job.index_builds
	last_index_grid_reads = job.index_grid_reads
	last_index_build_slots = job.index_build_slots
	last_selection_builds = job.selection_builds
	last_row_ops = job.row_ops
	last_footprint_visits = job.footprint_visits
	_hover_installed_epoch = job.request_epoch


# Returns true when every cell of one batch still exists in the frame. It guards
# the install of a finished sample after a later write changed a witness chunk.
func _cells_hold(frame: VoxelFrame, cells: Array[Vector3i]) -> bool:
	for cell in cells:
		if not frame.has(cell):
			return false
	return true


# Builds the immutable identity of one sampled batch. It holds the captured cell,
# the source frame, and the frozen symmetry and selection, so a press can compare
# the visible surface to its own request without a per-cell check.
func _make_batch_token(frame: VoxelFrame, center: Vector3i, context: VoxelFrame.EditContext) -> BatchToken:
	var token := BatchToken.new()
	token.center = center
	token.frame = frame
	token.axes = context.axes
	token.origin_twice = context.origin_twice
	token.selection = context.selection
	return token


# Records one finished sample as the current batch and shows it. A caller that
# already holds the batch chunk witness passes it, so the install costs one test
# per chunk and not one test per cell.
func _adopt_batch(frame: VoxelFrame, center: Vector3i, context: VoxelFrame.EditContext, material: PackedFloat32Array, cells: Array[Vector3i], witness := {}, payload = null) -> void:
	_batch_center = center
	_batch_frame = frame
	_batch_material = material.duplicate()
	_batch_axes = context.axes
	_batch_origin = context.origin_twice
	_batch_selection = context.selection
	_batch_token = _make_batch_token(frame, center, context)
	_batch_cells = cells
	_batch_payload = payload
	if witness.is_empty():
		_snapshot_batch_chunks(frame)
	else:
		_batch_chunks = witness
	_batch_version += 1
	_show_spots(cells)


# Returns true while every witness chunk is still the object the sample read.
func _witness_holds(witness: Dictionary, frame: VoxelFrame) -> bool:
	for location in witness:
		var entry: Array = witness[location]
		var chunk: VoxelFrame.Chunk = frame.chunks.get(location)
		if chunk == null or chunk != entry[0] or chunk.voxel_revision != entry[1]:
			return false
	return true


# Cancels the running hover sample and drops the queued request. The result is
# optional work, so the caller never waits for it.
func _cancel_hover_sample() -> void:
	_hover_request = {}
	if _hover_sample_job:
		_hover_sample_job.cancel()
		_hover_sample_job = null
	State.finish_operation(_hover_sample_operation_id)
	_hover_sample_operation_id = 0


# Cancels, joins, and drops the hover sample. Only the node teardown joins it,
# because an optional sample must never block a tool switch.
func _teardown_hover_sample() -> void:
	var job: SpraySamplingJob = _hover_sample_job
	_cancel_hover_sample()
	if job:
		job.wait_for_worker()


# Returns true when every cell of the batch still exists in the frame. The check
# compares the identity and the voxel revision of each chunk that holds a batch
# cell, so a repeated cursor update costs one test per chunk instead of one test
# per cell. A chunk change revalidates the whole batch, because a revision also
# moves for a material-only write.
func _batch_holds(frame: VoxelFrame) -> bool:
	for location in _batch_chunks:
		var entry: Array = _batch_chunks[location]
		var chunk: VoxelFrame.Chunk = frame.chunks.get(location)
		if chunk == null or chunk != entry[0] or chunk.voxel_revision != entry[1]:
			return _revalidate_batch(frame)
	return true


# Rechecks every batch cell against the frame and refreshes the chunk snapshot.
# It keeps a batch whose cells all still exist, so a material-only write does not
# reroll a stable sample.
func _revalidate_batch(frame: VoxelFrame) -> bool:
	for cell in _batch_cells:
		if not frame.has(cell):
			return false
	_snapshot_batch_chunks(frame)
	return true


# Records the identity and the voxel revision of each chunk that holds a batch
# cell. The snapshot replaces the previous one, so it never keeps an old chunk.
func _snapshot_batch_chunks(frame: VoxelFrame) -> void:
	_batch_chunks = {}
	for cell in _batch_cells:
		var location := VoxelFrame.chunk_position(cell)
		if _batch_chunks.has(location):
			continue
		var chunk: VoxelFrame.Chunk = frame.chunks.get(location)
		if chunk != null:
			_batch_chunks[location] = [chunk, chunk.voxel_revision]


# Applies the current batch. The batch stays, so the preview holds until the
# brush cell changes.
func _apply_batch() -> void:
	if _batch_cells.is_empty():
		return
	_queue_centers(_batch_cells)


# Applies the batch that the cursor shows. A coalescing cursor can display an
# older snapshot while a newer sample for the same cell waits on the worker. The
# press then paints the visible cells, so the click never applies a different
# known sample. A surface of another cell never paints, because its token does
# not match this press. When no owned and valid surface is displayed, the press
# accepts its own brush cell like a drag step: a large batch queues on the worker,
# so the input frame never pays a long sample, and the stroke closes only after
# that batch wrote.
func _apply_offered() -> void:
	_cancel_hover_sample()
	var shown := _installed_cells()
	# The cursor can show a surface of another cell while a newer sample waits.
	# Paint the visible cells only when the surface belongs to this press's cell,
	# frame, and context. The current batch alone cannot prove ownership.
	if not shown.is_empty() and _shown_owned_by_press(_installed_token()) and _offered_cells_valid(shown):
		# The cursor shows the batch this tool last handed it, so the batch array
		# is its cell list. A prepared 474k-cell dict avoids a 474k key list here.
		if is_same(shown, _shown_spots) and not _batch_cells.is_empty():
			_queue_centers(_batch_cells)
			return
		var cells: Array[Vector3i] = []
		cells.assign(shown.keys())
		_queue_centers(cells)
		return
	var pick := _last_pick
	if pick != null and pick.hit != VoxelPicking.NONE and _source_frame != null and _edit_context != null:
		var selection_index := _cached_selection_index(_edit_context.selection)
		var estimate := SpraySampler.work_estimate(_source_frame, pick.hit, _paint_settings.spray_size, _paint_settings.spot_diameter, _edit_context.selection, _paint_settings.speed, selection_index)
		last_work_estimate = estimate
		if estimate > INLINE_SAMPLE_LIMIT:
			_accept_intent(pick.hit, _source_frame, _edit_context, _stroke_material, estimate)
			return
		_ensure_batch(pick.hit, _source_frame, _edit_context, _stroke_material)
	_apply_batch()


# Returns the immutable cells of the cursor's installed surface, or an empty
# dictionary. The tool reads them without changing them.
func _installed_cells() -> Dictionary:
	if not has_node("Cursor"):
		return {}
	return $Cursor.installed_cells()


# Returns the opaque token of the cursor's installed surface, or null.
func _installed_token() -> Variant:
	if not has_node("Cursor"):
		return null
	return $Cursor.installed_token()


# Returns true when the installed surface belongs to the cell, frame, and context
# of this press. A lagging surface of the same cell and context is the exact
# batch that the press must paint. A surface of another cell must not paint, even
# when the current batch already names the press cell.
func _shown_owned_by_press(token: Variant) -> bool:
	if not (token is BatchToken):
		return false
	var owner := token as BatchToken
	var pick := _last_pick
	if pick == null or pick.hit == VoxelPicking.NONE:
		return false
	if owner.center != pick.hit or owner.frame != _source_frame or _edit_context == null:
		return false
	return owner.axes == _edit_context.axes and owner.origin_twice == _edit_context.origin_twice and _same_selection(owner.selection, _edit_context.selection)


# Returns true when every displayed cell still exists and the display context
# still matches the current frame and selection.
##
## The cursor usually shows the batch this tool last handed it. That surface is
## validated through the batch chunk witness, so a click costs one test per chunk
## and not one test per cell. A surface from an older sample is checked cell by
## cell, because this tool holds no witness for it.
func _offered_cells_valid(shown: Dictionary) -> bool:
	var frame := _source_frame if _stroke_active and _source_frame != null else State.get_current_voxel_frame()
	var context := _edit_context if _stroke_active and _edit_context != null else State.drawing_context()
	if frame == null or context == null:
		return false
	if is_same(shown, _shown_spots):
		# The cursor shows the surface this tool last handed it, so the recorded
		# chunk witness validates it with one test per chunk.
		if _witness_holds(_shown_witness, frame):
			return true
		if not _revalidate_batch(frame):
			return false
		_shown_witness = _batch_chunks
		return true
	for cell in shown:
		if not frame.has(cell):
			return false
		if not context.selection.is_empty() and not context.selection.has(cell):
			return false
	return true


# Hides the cursor and drops its installed surface, so a stale preview of another
# context cannot stay visible or be painted.
func _clear_cursor_preview() -> void:
	if has_node("Cursor"):
		$Cursor.show_selection(null)


# Builds one spray sample job from explicit inputs. The job snapshots only the
# chunks that the sample can read or write, so the worker never reads the live
# frame and never pays a whole-frame copy. It captures the exact random state, so
# a worker draws the same sequence as an inline sample from the same state. The
# optional sizes are the captured values of an accepted intent. The ROI and the
# job fields use the same resolved sizes.
func _build_sample_job(frame: VoxelFrame, center: Vector3i, context: VoxelFrame.EditContext, material: PackedFloat32Array, estimate: int, spot_size := -1, search_size := -1, speed := -1) -> SpraySamplingJob:
	# Resolve the sizes once. The ROI, the job fields, and the random state must
	# describe the same captured sample even when the live settings change later.
	var use_spot: int = _paint_settings.spot_diameter if spot_size < 0 else spot_size
	var use_search: int = _paint_settings.spray_size if search_size < 0 else search_size
	var use_speed: int = _paint_settings.speed if speed < 0 else speed
	var job := SpraySamplingJob.new()
	var locations := SpraySampler.capture_chunks(center, use_search, use_spot, context.axes, context.origin_twice)
	job.frame = frame.copy_chunks(locations)
	job.capture_chunk_count = job.frame.chunks.size()
	last_capture_chunks = job.capture_chunk_count
	job.source_frame = frame
	job.center = center
	job.axes = context.axes
	job.origin_twice = context.origin_twice
	job.selection = context.selection
	job.material = material.duplicate()
	job.spot_size = use_spot
	job.search_size = use_search
	job.speed = use_speed
	job.sample_state = _rng.state
	job.rng_epoch = _rng_epoch
	job.shape_cache = _shape_cache
	job.local_estimate = estimate
	job.selection_index = _cached_selection_index(context.selection)
	return job


# Commits the random state that a worker sample used. The epoch rejects a result
# whose stream is already stale, so an older job never rewinds draws that an
# inline sample or a newer job already consumed. An obsolete result keeps its
# cells out of the preview but never replaces the current stream.
func _commit_sample_state(job: SpraySamplingJob) -> void:
	if job.rng_epoch != _rng_epoch:
		return
	_rng.state = job.result_state
	_rng_epoch += 1


# Samples one batch synchronously through the pure kernel.
#
# A direct caller passes no random source, so the tool source is used. A worker
# passes its own local source and the captured sizes, so it never reads the
# shared source, and it never reads the shared settings mid-sample.
func _sample(center: Vector3i, frame: VoxelFrame, context: VoxelFrame.EditContext, rng: RandomNumberGenerator = null, material = null, spot_size := -1, search_size := -1, speed := -1) -> Array[Vector3i]:
	var use_rng: RandomNumberGenerator = _rng if rng == null else rng
	var use_material: PackedFloat32Array = _batch_material if material == null else material
	var use_spot: int = _paint_settings.spot_diameter if spot_size < 0 else spot_size
	var use_search: int = _paint_settings.spray_size if search_size < 0 else search_size
	var use_speed: int = _paint_settings.speed if speed < 0 else speed
	var report := {}
	var selection_index := _cached_selection_index(context.selection)
	var cells := SpraySampler.sample(center, frame, context, use_spot, use_search, use_speed, use_rng, use_material, _shape_cache, null, report, selection_index)
	last_index_builds = report.get("index_builds", 0)
	last_index_grid_reads = report.get("index_grid_reads", 0)
	last_index_build_slots = report.get("index_build_slots", 0)
	last_selection_builds = report.get("selection_builds", 0)
	last_row_ops = report.get("row_ops", 0)
	last_footprint_visits = report.get("footprint_visits", 0)
	_remember_selection_index(context.selection, report.get("selection_index"))
	# An inline sample consumes the shared stream at once. A worker sample commits
	# its end state only when its result is adopted.
	if rng == null:
		_rng_epoch += 1
	return cells


# The occupied cells that the search sphere of that size allows in the local set.
# It is the pure sphere mask helper. The live sampler adds the surface and
# selection filters itself.
func _candidates(center: Vector3i, local: Array[Vector3i], search_size := -1) -> Array[Vector3i]:
	var size: int = _paint_settings.spray_size if search_size < 0 else search_size
	return SpraySampler.candidate_cells(center, local, size)


# The voxels that the spot centers paint, read from the local set. It is the
# unfiltered legacy union helper that the union tests call. The live sampler uses
# `SpraySampler.footprints_selected`, which keeps exposed voxels only.
func _footprints(spots: Array[Vector3i], local: Array[Vector3i], spot_size := -1, material = null, job: VoxelFrame.EditJob = null) -> Dictionary:
	var use_spot: int = _paint_settings.spot_diameter if spot_size < 0 else spot_size
	var use_material: PackedFloat32Array = _batch_material if material == null else material
	return SpraySampler.footprints(spots, local, use_spot, use_material, _shape_cache, job)


# The voxel offsets of one spray spot sphere, cached by diameter in the shared
# shape cache. The offsets come from the shared size helper, so the spot shape
# matches the brush sphere of the same diameter.
func _spot_offsets(diameter: int) -> Array[Vector3i]:
	return SpraySampler.offsets(_shape_cache, diameter)


# The scanline rows of one spot sphere, cached by diameter in the shared cache.
func _spot_rows(diameter: int) -> Array:
	return SpraySampler.rows(_shape_cache, diameter)


# The spot sphere as a read-only lookup set, cached by diameter in the shared
# cache. The sparse footprint path reads it, so the widest spot never rebuilds
# its 137376 keys.
func _spot_pattern(diameter: int) -> Dictionary:
	return SpraySampler.pattern(_shape_cache, diameter)


# The largest distance from a spot center to one of its sphere cells. The shared
# helper computes it without building the whole offset set.
func _spot_radius(diameter: int) -> int:
	return VoxelBrushSize.reach(diameter)


# Shows exactly these cells with the full material. An empty list hides the
# cursor. The preview dict is built once per sampled batch and reused while the
# batch holds, so a still hover submits nothing.
func _show_spots(cells: Array[Vector3i]) -> void:
	if cells.is_empty():
		if _preview_active:
			_preview_active = false
			_preview_version = -1
			_shown_spots = {}
			_shown_witness = {}
			$Cursor.show_voxels({}, VoxelFrame.material_color(_batch_material), false, 0, false)
		return
	# The material updates even when the batch holds, so a color change reaches
	# the cursor without a new sample.
	$Cursor.set_brush_material(_batch_material)
	if _preview_active and _preview_version == _batch_version:
		return
	var color := VoxelFrame.material_color(_batch_material)
	if _batch_payload != null:
		# The worker built the read-only color dictionary and the cell hash, so the
		# main thread neither builds the color map nor hashes the keys. The token
		# names the batch that this payload draws, so a cache hit still reports it.
		_preview_active = true
		_preview_version = _batch_version
		_shown_spots = _batch_payload.spots
		_shown_witness = _batch_chunks
		_batch_payload.token = _batch_token
		$Cursor.submit_prepared(_batch_payload)
		return
	var spots := {}
	for cell in cells:
		spots[cell] = color
	# A read-only dict is handed to the preview as it is, so no copy is made.
	spots.make_read_only()
	_preview_active = true
	_preview_version = _batch_version
	# The witness of the batch this dict draws, so a later click validates the
	# visible surface with one test per chunk.
	_shown_spots = spots
	_shown_witness = _batch_chunks
	$Cursor.show_voxels(spots, color, false, 0, false, _batch_token)


# A sparse spray stamps repeated samples at the same cell. The overlap skip of
# the shared job would drop a repeat, so the spray never skips an offset.
##
## The sampler already expanded the captured symmetry and selection, so the write
## must not expand the same context a second time. The shared job still applies
## the selection mask, the existing-only filter, and the captured material to
## every cell.
func _build_job() -> BrushJob:
	var job := super._build_job()
	job.previous_center = Vector3i.MAX
	job.centers_are_final = true
	return job
