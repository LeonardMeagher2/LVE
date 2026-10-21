extends "res://plugins/brush/StrokeTool.gd"

## The spray can tool.
##
## The tool paints random spots around the brush cell. It samples distinct
## occupied spot centers from the existing voxels inside the spray radius. Each
## spot center paints every existing voxel inside a sphere of the spot diameter.
## Diameter 1 paints the spot center alone. The spot sphere is the shared brush
## sphere of that diameter, so the even diameters keep the brush alignment.
##
## The tool samples once for one brush cell and shows the exact voxels of that
## batch. The preview holds while the brush cell, the frame, the settings, the
## edit context, and the occupancy stay the same. The press and every brush cell
## change paint the exact previewed batch, so a preview never disagrees with the
## stroke. A completed click rerolls the next preview, so the next click paints a
## new sample. The tool never paints and never rerolls while the pointer holds
## still.
##
## The whole spray is one history action. Escape and a context change roll it
## back.

var _paint_settings: PaintToolSettings
var _rng := RandomNumberGenerator.new()
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


func _init() -> void:
	_paint_settings = preload("./settings.tres")
	_settings = _paint_settings


func _ready() -> void:
	super._ready()
	_rng.randomize()


# A tool switch detaches this node and the base releases its context and history
# subscriptions, so a change while detached cannot invalidate the batch. A
# re-entry drops it, so the next hover samples the current frame again.
func _enter_tree() -> void:
	_invalidate_batch()
	super._enter_tree()


# A detach drops the batch, so its chunk snapshot never outlives the batch.
func _exit_tree() -> void:
	_invalidate_batch()
	super._exit_tree()


## Seeds the sampling random source. A test uses it for a repeatable spray.
func seed_spray(seed_value: int) -> void:
	_rng.seed = seed_value


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
			if _edit != null or _job:
				return true
			var ray := _ray(pos)
			var pick := _pick_start(ray[0], ray[1])
			if pick.hit == VoxelPicking.NONE:
				return false
			if open_stroke() == null:
				return false
			_plane = pick.plane
			_last_target = pick.target
			_stroke_active = true
			update_visual(pick)
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
	_invalidate_batch()
	super._cancel_edit()


func _on_settings_changed() -> void:
	# A settings change rebuilds the batch.
	_invalidate_batch()
	super._on_settings_changed()


# Undo and redo change the frame under the cursor. The displayed batch may no
# longer hold, so hide the cursor and resample on the next update.
func _on_history_changed() -> void:
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
		_batch_fresh = _ensure_batch(pick.hit, _source_frame, _edit_context, _stroke_material)
		_show_spots(_batch_cells)
		return
	_ensure_batch(pick.hit, State.get_current_voxel_frame(), State.drawing_context(), State.current_material)
	_show_spots(_batch_cells)


# Clears the batch, so the next cursor update samples a new one.
func _invalidate_batch() -> void:
	_batch_center = VoxelPicking.NONE
	_batch_cells = []
	_batch_material = VoxelFrame.material(Color.WHITE)
	_batch_frame = null
	_batch_fresh = false
	_batch_chunks = {}
	_batch_version += 1
	_preview_version = -1


# Samples the batch for one brush cell. It returns true when it sampled a new
# batch. The batch holds while the brush cell, the frame, the material, the
# symmetry, the selection, and the occupancy stay the same.
func _ensure_batch(center: Vector3i, frame: VoxelFrame, context: VoxelFrame.EditContext, material: PackedFloat32Array) -> bool:
	if frame == null or context == null:
		return false
	if center == _batch_center and frame == _batch_frame and material == _batch_material and context.axes == _batch_axes and context.origin_twice == _batch_origin and context.selection == _batch_selection and _batch_holds(frame):
		return false
	# A changed frame, material, symmetry, or selection makes the displayed
	# surface stale. Hide it, so a click can never paint a preview of another
	# context while the new sample builds.
	var context_changed := frame != _batch_frame or material != _batch_material or context.axes != _batch_axes or context.origin_twice != _batch_origin or context.selection != _batch_selection
	if context_changed:
		_clear_cursor_preview()
	_batch_center = center
	_batch_frame = frame
	_batch_material = material.duplicate()
	_batch_axes = context.axes
	_batch_origin = context.origin_twice
	_batch_selection = context.selection
	_batch_cells = _sample(center, frame, context)
	_snapshot_batch_chunks(frame)
	# The batch changed, so the cursor must submit the new preview.
	_batch_version += 1
	return true


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
# older snapshot while a newer sample waits on the worker. The press then paints
# the visible cells, so the click never applies a different known sample. An
# empty or stale displayed surface falls back to the current sample, which is the
# first-click case.
func _apply_offered() -> void:
	var shown := _installed_cells()
	if shown.is_empty() or not _offered_cells_valid(shown):
		_apply_batch()
		return
	var cells: Array[Vector3i] = []
	cells.assign(shown.keys())
	_queue_centers(cells)


# Returns the immutable cells of the cursor's installed surface, or an empty
# dictionary. The tool reads them without changing them.
func _installed_cells() -> Dictionary:
	if not has_node("Cursor"):
		return {}
	return $Cursor.installed_cells()


# Returns true when every displayed cell still exists and the display context
# still matches the current frame and selection. The cursor hides a stale surface
# on a context change, so this is the last guard against a removed cell.
func _offered_cells_valid(shown: Dictionary) -> bool:
	var frame := _source_frame if _stroke_active and _source_frame != null else State.get_current_voxel_frame()
	var context := _edit_context if _stroke_active and _edit_context != null else State.drawing_context()
	if frame == null or context == null:
		return false
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


# Samples distinct occupied spot centers inside the spray radius, then the
# voxels of their spot-diameter footprints. The result is the exact write set.
func _sample(center: Vector3i, frame: VoxelFrame, context: VoxelFrame.EditContext) -> Array[Vector3i]:
	# The spot sphere reaches this far from its center, so the whole union sits
	# inside the reach ball.
	var reach := _paint_settings.spray_radius + _spot_radius(_paint_settings.spot_diameter)
	# Gather the occupied allowed cells of the whole reach once. The candidate
	# pool and the footprints read this local set, so the sampler never scans an
	# empty corner of the reach cube.
	var local := _local_cells(center, reach, frame, context)
	var candidates := _candidates(center, local)
	var count := mini(_paint_settings.speed, candidates.size())
	if count <= 0:
		return []
	# A partial shuffle picks distinct centers without replacement. The candidate
	# array is fresh, so the shuffle runs in place and needs no index array.
	var spots: Array[Vector3i] = []
	for i in count:
		var pick := _rng.randi_range(i, candidates.size() - 1)
		var swap := candidates[i]
		candidates[i] = candidates[pick]
		candidates[pick] = swap
		spots.append(candidates[i])
	var changes := _footprints(spots, local)
	# Every change is already occupied and selection-filtered, so an identity
	# context needs no expansion. A symmetry or selection context still expands,
	# because its mirrored destinations must exist too.
	var cells: Array[Vector3i] = []
	if context.axes == 0 and context.selection.is_empty():
		cells.assign(changes.keys())
		return cells
	cells.assign(context.expand(changes, frame, true, null).keys())
	return cells


# The occupied cells that the selection allows inside the spray radius. The
# spray samples from this pool, so a sample never lands on an empty cell.
func _candidates(center: Vector3i, local: Array[Vector3i]) -> Array[Vector3i]:
	var limit := _paint_settings.spray_radius * _paint_settings.spray_radius
	var cells: Array[Vector3i] = []
	for cell in local:
		if Vector3(cell - center).length_squared() <= limit:
			cells.append(cell)
	return cells


# The voxels that the spot centers paint. Each spot covers every local voxel
# inside a sphere of the spot diameter. The sphere is the shared brush sphere of
# that diameter, so the even-diameter spots keep the brush alignment. Diameter 1
# paints the spot center alone.
func _footprints(spots: Array[Vector3i], local: Array[Vector3i]) -> Dictionary:
	var changes := {}
	# Diameter 1 paints the spot center alone, so the changes are the centers and
	# no sphere test is needed.
	if _paint_settings.spot_diameter == 1:
		for spot in spots:
			changes[spot] = _batch_material
		return changes
	var offsets := _spot_offsets(_paint_settings.spot_diameter)
	# A sparse local set is cheaper to test against every spot. A dense one is
	# cheaper to test against the spot sphere of every spot.
	if local.size() < offsets.size():
		var pattern := {}
		for offset in offsets:
			pattern[offset] = true
		for spot in spots:
			for cell in local:
				if pattern.has(cell - spot):
					changes[cell] = _batch_material
		return changes
	var occupied := {}
	for cell in local:
		occupied[cell] = true
	for spot in spots:
		for offset in offsets:
			var cell := spot + offset
			if occupied.has(cell):
				changes[cell] = _batch_material
	return changes


# The occupied cells that the selection allows inside the reach ball. A sparse
# frame reads its occupied chunks, so an empty region costs little. A dense
# frame reads the ball offsets, so the sampler never walks a whole chunk.
func _local_cells(center: Vector3i, reach: int, frame: VoxelFrame, context: VoxelFrame.EditContext) -> Array[Vector3i]:
	var min_chunk := VoxelFrame.chunk_position(center - Vector3i.ONE * reach)
	var max_chunk := VoxelFrame.chunk_position(center + Vector3i.ONE * reach)
	var locations := _chunk_locations(min_chunk, max_chunk)
	var chunk_cells := 0
	for chunk_location in locations:
		if frame.chunks.has(chunk_location):
			chunk_cells += VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE
	var side := 2 * reach + 1
	var cells: Array[Vector3i] = []
	if chunk_cells > 0 and chunk_cells < side * side * side:
		var limit := reach * reach
		for chunk_location in locations:
			var chunk: VoxelFrame.Chunk = frame.chunks.get(chunk_location)
			if chunk == null:
				continue
			for cell in chunk.world_cells():
				if Vector3(cell - center).length_squared() > limit:
					continue
				if not _allows(cell, frame, context):
					continue
				cells.append(cell)
		return cells
	for offset in _sphere_offsets(reach):
		var cell := center + offset
		if _allows(cell, frame, context):
			cells.append(cell)
	return cells


static func _chunk_locations(min_chunk: Vector3i, max_chunk: Vector3i) -> Array[Vector3i]:
	var locations: Array[Vector3i] = []
	for x in range(min_chunk.x, max_chunk.x + 1):
		for y in range(min_chunk.y, max_chunk.y + 1):
			for z in range(min_chunk.z, max_chunk.z + 1):
				locations.append(Vector3i(x, y, z))
	return locations


# The voxel offsets of one spray spot sphere, cached by diameter. The offsets
# come from the shared brush sphere builder, so the spot shape matches the brush
# sphere of the same diameter, including the even-diameter alignment.
#
# The cache is per instance. A `static var` that a tool method reads kept the
# document and renderer scripts in use at exit.
var _spot_offsets_cache := {}


func _spot_offsets(diameter: int) -> Array[Vector3i]:
	if _spot_offsets_cache.has(diameter):
		return _spot_offsets_cache[diameter]
	var offsets: Array[Vector3i] = []
	offsets.assign(StampPattern.build_pattern(diameter, StampSettings.BrushShape.SPHERE).keys())
	_spot_offsets_cache[diameter] = offsets
	return offsets


# The largest distance from a spot center to one of its sphere cells, rounded
# up. The gather ball must reach at least this far past the spray radius.
var _spot_radius_cache := {}


func _spot_radius(diameter: int) -> int:
	if _spot_radius_cache.has(diameter):
		return _spot_radius_cache[diameter]
	var longest := 0
	for offset in _spot_offsets(diameter):
		longest = maxi(longest, offset.length_squared())
	var radius := ceili(sqrt(float(longest)))
	_spot_radius_cache[diameter] = radius
	return radius


# The offsets of a ball of this radius, cached by radius. The offsets stay in
# the ball, so the sampler never tests a distance or scans an empty corner of
# the cube.
var _sphere_offsets_cache := {}


func _sphere_offsets(radius: int) -> Array[Vector3i]:
	if _sphere_offsets_cache.has(radius):
		return _sphere_offsets_cache[radius]
	var offsets: Array[Vector3i] = []
	var limit := radius * radius
	for x in range(-radius, radius + 1):
		for y in range(-radius, radius + 1):
			for z in range(-radius, radius + 1):
				var offset := Vector3i(x, y, z)
				if offset.length_squared() <= limit:
					offsets.append(offset)
	_sphere_offsets_cache[radius] = offsets
	return offsets


func _allows(cell: Vector3i, frame: VoxelFrame, context: VoxelFrame.EditContext) -> bool:
	return frame.has(cell) and (context.selection.is_empty() or context.selection.has(cell))


# Shows exactly these cells with the full material. An empty list hides the
# cursor. The preview dict is built once per sampled batch and reused while the
# batch holds, so a still hover submits nothing.
func _show_spots(cells: Array[Vector3i]) -> void:
	if cells.is_empty():
		if _preview_active:
			_preview_active = false
			_preview_version = -1
			$Cursor.show_voxels({}, VoxelFrame.material_color(_batch_material), false, 0, false)
		return
	# The material updates even when the batch holds, so a color change reaches
	# the cursor without a new sample.
	$Cursor.set_brush_material(_batch_material)
	if _preview_active and _preview_version == _batch_version:
		return
	var spots := {}
	var color := VoxelFrame.material_color(_batch_material)
	for cell in cells:
		spots[cell] = color
	# A read-only dict is handed to the preview as it is, so no copy is made.
	spots.make_read_only()
	_preview_active = true
	_preview_version = _batch_version
	$Cursor.show_voxels(spots, color, false, 0, false)


# A sparse spray stamps repeated samples at the same cell. The overlap skip of
# the shared job would drop a repeat, so the spray never skips an offset.
func _build_job() -> BrushJob:
	var job := super._build_job()
	job.previous_center = Vector3i.MAX
	return job
