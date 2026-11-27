extends VoxelTool


const TerrainSettings := preload("./TerrainToolSettings.gd")
const SmoothOperation := preload("./SmoothOperation.gd")
const TerrainRing := preload("./TerrainRing.gd")
const BrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")
const VoxelLineMesh := preload("res://Globals/Rendering/VoxelLineMesh.gd")
const Prep := preload("./TerrainPrep.gd")


const INLINE_EDIT_LIMIT := 4096
const PREP_CANDIDATE_LIMIT := 512
const PREP_BATCH_MAX := 8
const PREP_BATCH_TARGET_US := 50000
const HEIGHT_LOOKUP_LIMIT := 64
const DABS_PER_DRAIN := 32
const DRAIN_BUDGET_US := 8000
const MIN_DAB_PIXELS := 3.0
const FLATTEN_THRESHOLD := 0.5
const STATE_LIMIT := 65536
const SMOOTH_SOURCE_SEARCH := 3
const OCCUPANCY_READ_CHECKPOINT := 4096
const OCCUPANCY_BOX_LIMIT := 4
const OCCUPANCY_BOX_SPAN := 1 << 20


var _settings: TerrainToolSettings = preload("./TerrainSettings.tres")


var _stroke_tool := 0
var _stroke_build_mode := 0
var _stroke_radius := 4
var _stroke_strength := 1
var _stroke_falloff := 0.5
var _stroke_material := PackedFloat32Array()
var _stroke_context: VoxelFrame.EditContext
var _stroke_selection := {}
var _stroke_frame: TerrainFrame
var _cursor_frame: TerrainFrame
var _press_ray_origin := Vector3.ZERO
var _press_ray_dir := Vector3.ZERO
var _ray_origin := Vector3.INF
var _ray_dir := Vector3.INF
var _stroke_floor_axis := 1
var _stroke_floor_cell := 0
var _stroke_center_point := Vector3.ZERO
var _samples := {}
var _base_surfaces := {}
var _stroke_columns := {}
var _segments: Array = []
var _segment_head := 0
var _dab_path: StrokeLine.Cursor
var _drain_active := false
var _drain_stroke_id := -1
var _end_requested := false
var _close_action := "Build"
var _stroke_id := 0
var _stroke_tx: VoxelEditTransaction
var _source_document: VoxelDocument
var _source_frame: VoxelFrame
var _pending_frame: TerrainFrame
var _press_point := Vector3.ZERO
var _path_anchor := VoxelPicking.NONE
var _drag_ray_origin := Vector3.INF
var _drag_ray_dir := Vector3.INF
var _drag_ray_moved := true
var _stroke_forward := Vector3.ZERO
var _camera_perspective := false
var _camera_focus := Vector3.ZERO
var _stroke_ray_dir := Vector3.ZERO
var _press_ray_offset := Vector3.ZERO
var _press_camera_transform := Transform3D()
var _press_projection := -1
var _dab_ray_origin := Vector3.INF
var _dab_ray_dir := Vector3.INF
var _smooth_hit := VoxelPicking.NONE
var _smooth_entry := Vector3i.ZERO


var _smooth_fields: Array = []


var _tick_job: TerrainTickJob
var _prep_batch := 1
var _smooth_job: SmoothJob
var _operation_id := 0
var _last_pick: PickResult
var _visual_hit := VoxelPicking.NONE
var _visual_target := VoxelPicking.NONE
var _visual_valid := false
var _settings_tool := 0
var _settings_build_mode := 0
var _settings_radius := 4
var _settings_falloff := 0.5


var _preview: TerrainPreview
var _stroke_chunks := {}
var _stroke_flush_queued := false
var _footprint: MeshInstance3D
var _footprint_meshes := {}
var _idle_pose_frame: TerrainFrame
var _hover_frame: TerrainFrame:
	get:
		return _preview.hover_frame() if _preview != null else null
var _stroke_frame_index := -1


var _preview_dirty: bool:
	get:
		return _preview.is_dirty() if _preview != null else false


class TerrainTickJob extends VoxelFrame.EditJob:
	var stroke_id := 0
	var operation_id := 0
	var edited_frame: VoxelFrame
	var samples: Array = []
	var tool := 0
	var build_mode := 0
	var floor_axis := 1
	var floor_cell := 0
	var threshold := 0.5
	var material := PackedFloat32Array()
	var selection := {}
	var surfaces := {}
	var applied_columns := {}
	var changed_chunks: Array[Vector3i] = []

	var preparing := false
	var prep_terrain_frame: TerrainFrame
	var prep_center := Vector3.ZERO
	var prep_ray_origin := Vector3.INF
	var prep_ray_dir := Vector3.INF
	var prep_forward := Vector3.BACK
	var prep_radius := 4
	var prep_falloff := 0.5
	var prep_depth := 8
	var prep_context: VoxelFrame.EditContext
	var prep_known := {}
	var prep_known_columns := {}
	var prep_base_known := {}
	var prep_strength := 1
	var prepared_samples = null
	var prepared_frame: TerrainFrame
	var prepared_base_known = null
	var prep_centers: Array = []
	var prep_cells: Array = []
	var work_us := 0

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
				for cell: Vector3i in prep_cells:
					prep_center = prep_terrain_frame.plane_point(cell) if prep_terrain_frame != null else Vector3(cell)
					if not _prepare_center():
						return
		else:
			if _apply_samples() == null:
				return
		work_us = Time.get_ticks_usec() - started

	func _prepare_center() -> bool:
		if not _prepare():
			return false
		if _apply_samples() == null:
			return false
		for anchor in surfaces:
			if prepared_samples.has(anchor):
				prepared_samples[anchor]["surface"] = surfaces[anchor]
		prep_known = Prep.known_surfaces(prepared_samples)
		for column in applied_columns:
			prep_known_columns[column] = applied_columns[column]
		return true

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
			if tool == TerrainSettings.Tools.BUILD:
				applied_columns[TerrainGeometry.column_key(anchor, sample["normal"])] = surface
		changed_chunks.append_array(apply_cells(edited_frame, changes))
		return true

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

	func _fill_material(surface: Vector3i, changes: Dictionary) -> PackedFloat32Array:
		if surface != VoxelPicking.NONE:
			if changes.has(surface):
				var pending: PackedFloat32Array = changes[surface]
				if not VoxelFrame.is_empty(pending):
					return pending
			if edited_frame.has(surface):
				return edited_frame.get_material(surface)
		return material


class SmoothJob extends VoxelFrame.EditJob:
	var stroke_id := 0
	var operation_id := 0
	var edited_frame: VoxelFrame
	var fields: Array = []
	var passes := 1
	var radius := 1
	var remove_threshold := 0.5
	var add_threshold := 0.5
	var changed_chunks: Array[Vector3i] = []
	var cancelled := false
	var gather_reads := 0

	var preparing := false
	var prep_terrain_frame: TerrainFrame
	var prep_center := Vector3.ZERO
	var prep_radius := 4
	var prep_falloff := 0.5
	var prep_depth := 8
	var prep_context: VoxelFrame.EditContext
	var prep_selection := {}
	var prep_entry := Vector3i.ZERO
	var prepared_frame: TerrainFrame
	var prepared_fields = null

	func run() -> void:
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
			var outcome := SmoothOperation.advance(occupied, cells, passes, radius, remove_threshold, add_threshold, field["weights"], cancel, field.get("box", []), bool(field.get("ordered", false)))
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

	func _checkpoint(completed: int) -> bool:
		return checkpoint(completed)

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

	func _box_volume(low: Vector3i, high: Vector3i) -> int:
		var x := high.x - low.x + 1
		var y := high.y - low.y + 1
		var z := high.z - low.z + 1
		if x <= 0 or y <= 0 or z <= 0 or x > OCCUPANCY_BOX_SPAN or y > OCCUPANCY_BOX_SPAN or z > OCCUPANCY_BOX_SPAN:
			return 0
		return x * y * z

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

	func _local_normal(cell: Vector3i) -> Vector3:
		var occupied := {}
		for offset: Vector3i in SmoothOperation.NEIGHBOR_OFFSETS:
			var point := cell + offset
			if edited_frame.has(point):
				occupied[point] = true
		var normal = SmoothOperation.surface_normal(occupied, cell)
		return normal if normal != null else Vector3.ZERO

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
	if is_inside_tree() or _edit != null or _tick_job != null or _smooth_job != null:
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
	if _preview != null:
		_preview.invalidate()


func _on_frame_cells_changed(frame: int, _affected: Array[Vector3i]) -> void:
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
	if geometry_changed:
		_mark_preview_dirty()
	if _edit != null and (tool_changed or mode_changed):
		finish_on_switch()


func handle_input(event: InputEvent, pos: Vector2) -> bool:
	if event.is_action_pressed("ui_cancel") and _edit != null:
		_cancel_edit()
		return true
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT and button.pressed and _edit != null and not _edit.is_closed():
			return true
	if event is InputEventMouseMotion and _stroke_active and (event as InputEventMouseMotion).button_mask == 0:
		_end()
	return super.handle_input(event, pos)


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
	_stroke_chunks = {}
	_stroke_flush_queued = false
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
	_prep_batch = 1
	_clear_smooth()
	if _preview != null:
		_preview.cancel_pending()
		_preview.invalidate()
	return tx


func _apply_pick(target: Vector3i, hit: Vector3i) -> void:
	_stroke_frame = _pending_frame
	if _stroke_frame == null:
		_stroke_frame = TerrainFrame.from_face(target, Vector3i(0, 1, 0))
	_cursor_frame = _stroke_frame
	if _stroke_frame.on_floor:
		_cursor_frame = _floor_grid_frame(_stroke_frame)
		var grid_point = _cursor_frame.to_plane().intersects_ray(_press_ray_origin, _press_ray_dir)
		_press_point = grid_point if grid_point != null else _cursor_frame.origin
	if _stroke_tool == TerrainSettings.Tools.SMOOTH:
		var cursor := TerrainFrame.new()
		var view := VoxelPicking.view_axis(_forward())
		cursor.normal = Vector3.ZERO
		cursor.normal[view] = 1.0
		cursor.origin = _stroke_frame.origin
		cursor.axis = view
		_cursor_frame = cursor
		var point = cursor.to_plane().intersects_ray(_press_ray_origin, _press_ray_dir)
		_press_point = point if point != null else cursor.origin
	_path_anchor = TerrainGeometry.cell_at(_press_point)
	_stroke_center_point = _plane_point(_path_anchor)
	_press_ray_offset = _press_ray_origin - _plane_point(_path_anchor)
	_dab_ray_origin = _press_ray_origin
	_dab_ray_dir = _press_ray_dir
	_run_dab(_path_anchor)
	if _preview != null:
		_preview.invalidate()


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
	grid.origin[_stroke_floor_axis] = float(_stroke_floor_cell) - 0.5
	return grid


func _stroke_cursor_frame() -> TerrainFrame:
	if _stroke_frame.on_floor:
		return _floor_grid_frame(_stroke_frame)
	return _stroke_frame


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
	if _path_anchor == VoxelPicking.NONE or to == VoxelPicking.NONE:
		return
	if not _drag_ray_moved:
		return
	if _stroke_tool != TerrainSettings.Tools.SMOOTH and not _dab_moved_enough(_path_anchor, to):
		return
	_enqueue_segment(_path_anchor, to)
	_path_anchor = to
	if _preview != null:
		_preview.invalidate()


func _end() -> void:
	_end_requested = true
	_stroke_active = false
	_settle_dabs()


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
	_flush_stroke_chunks()
	_stroke_chunks = {}
	_stroke_flush_queued = false
	_stroke_context = null
	_stroke_selection = {}
	_stroke_frame = null
	_cursor_frame = null
	_samples = {}
	_base_surfaces = {}
	_stroke_columns = {}
	_clear_smooth()
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
		TerrainSettings.Tools.SMOOTH:
			return "Smooth"
	return "Build"


func _cancel_edit() -> void:
	if _tick_job:
		_tick_job.cancel()
	if _smooth_job:
		_smooth_job.cancel()
	_clear_pending()
	_stroke_chunks = {}
	_stroke_flush_queued = false
	_samples = {}
	_base_surfaces = {}
	_stroke_columns = {}
	_stroke_frame = null
	_cursor_frame = null
	_clear_smooth()
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


func _process(_delta: float) -> void:
	if _preview == null:
		return
	_preview.poll()
	if _edit != null or _busy():
		if _preview_dirty:
			_rebuild_preview()
		return
	_preview.process()


func advance_stroke(influence: float) -> void:
	if _edit == null:
		return
	if _busy():
		return
	_apply_influence(influence)


func _apply_influence(applications: float) -> void:
	if _stroke_tool == TerrainSettings.Tools.SMOOTH:
		_smooth_tick()
		return
	if _samples.is_empty():
		return
	_run_tick()


func _enqueue_segment(from: Vector3i, to: Vector3i) -> void:
	if _edit == null:
		return
	if from == VoxelPicking.NONE or to == VoxelPicking.NONE or from == to:
		return
	_segments.append([from, to])
	_settle_dabs()


func _has_pending() -> bool:
	return _dab_path != null or _segment_head < _segments.size()


func _next_dab_cell() -> Variant:
	while _dab_path != null or _segment_head < _segments.size():
		if _dab_path == null:
			var segment: Array = _segments[_segment_head]
			_segment_head += 1
			_dab_path = StrokeLine.Cursor.new(segment[0], segment[1])
		var cell = _dab_path.next_cell()
		if cell != null:
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


func _clear_pending() -> void:
	_segments.clear()
	_segment_head = 0
	_dab_path = null


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
			if Time.get_ticks_usec() >= deadline:
				break
		if not _busy() and not _has_pending():
			break
		await _next_frame()
	if _drain_active and _drain_stroke_id == stroke_id:
		_drain_active = false
	if _stroke_id == stroke_id and _end_requested and _edit != null and _edit == _stroke_tx:
		_finish_stroke()


func _next_frame() -> void:
	var loop := Engine.get_main_loop() as SceneTree
	if loop != null:
		await loop.process_frame


func _run_dab(cell: Vector3i) -> void:
	if _stroke_tool == TerrainSettings.Tools.SMOOTH:
		_run_smooth_dab()
		return
	_apply_dab_at(_plane_point(cell))


func _apply_dab_at(center_point: Vector3) -> void:
	_stroke_center_point = center_point
	if _dab_is_large(_stroke_radius):
		_start_prep_dab(center_point)
		return
	_rebuild_samples(center_point)
	_apply_influence(1.0)
	_mark_hover_dirty()


func _dab_is_large(radius: int) -> bool:
	return _dab_estimate(radius) > PREP_CANDIDATE_LIMIT


func _dab_estimate(radius: int) -> int:
	return radius * radius * 3 * _mask_count()


func _mask_count() -> int:
	return TerrainPreview.masks_for(_context()).size()


func _start_prep_dab(center_point: Vector3) -> void:
	_start_prep_batch([center_point])


func _start_prep_batch(cells: Array) -> void:
	var job := TerrainTickJob.new()
	job.stroke_id = _stroke_id
	job.preparing = true
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
	job.prep_forward = _stroke_forward if _stroke_forward != Vector3.ZERO else Vector3.BACK
	if not cells.is_empty() and typeof(cells[0]) == TYPE_VECTOR3I:
		job.prep_cells = cells
		job.prep_center = _plane_point(cells[cells.size() - 1])
	else:
		job.prep_centers = cells
		job.prep_center = cells[cells.size() - 1]
	job.prep_radius = _stroke_radius
	job.prep_falloff = _stroke_falloff
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


func _dab_candidates() -> int:
	return _dab_estimate(_stroke_radius)


func _run_smooth_dab() -> void:
	var origin := _dab_ray_origin
	var dir := _dab_ray_dir
	if dir == Vector3.ZERO or dir == Vector3.INF:
		return
	if origin == Vector3.INF:
		origin = _press_ray_origin
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
	_pose_footprint(_last_pick)
	_mark_hover_dirty()


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


func _plane_point(cell: Vector3i) -> Vector3:
	if _cursor_frame == null:
		return Vector3(cell)
	return _cursor_frame.plane_point(cell)


func _busy() -> bool:
	return _tick_job != null or _smooth_job != null


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


func _sample_map(terrain_frame: TerrainFrame, center_point: Vector3, radius: int, falloff: float, known: Dictionary = {}) -> Dictionary:
	return TerrainPreview.compute_sample_map(_active_frame(), terrain_frame, center_point, radius, falloff, _context(), _height_depth(), known, null, null, _base_surfaces, _stroke_floor_axis, _stroke_floor_cell, _stroke_columns)


static func _column_key(sample: Dictionary) -> Vector3i:
	return Prep.column_key(sample)


func _prune_state() -> void:
	if _stroke_columns.size() > STATE_LIMIT:
		_stroke_columns = {}


func _collect_steps() -> Array:
	return Prep.collect_steps(_samples, _stroke_tool, _stroke_strength)


func _footprint_depth(radius: int) -> int:
	return TerrainPreview.depth_for(radius)


func _height_depth() -> int:
	if _stroke_tool == TerrainSettings.Tools.BUILD:
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
	if job.edited_frame != _source_frame:
		_source_frame.apply_published(job.changed_chunks, job.edited_frame)
	State.document._bounds_dirty = true
	for chunk in job.changed_chunks:
		_stroke_chunks[chunk] = true
	if not _stroke_chunks.is_empty() and not _stroke_flush_queued:
		_stroke_flush_queued = true
		_flush_stroke_chunks.call_deferred()
	if job.preparing and job.work_us > 0:
		var centers := maxi(maxi(job.prep_centers.size(), job.prep_cells.size()), 1)
		var per_dab := job.work_us / centers
		_prep_batch = clampi(PREP_BATCH_TARGET_US / maxi(per_dab, 1), 1, PREP_BATCH_MAX)
	_mark_hover_dirty()


func _flush_stroke_chunks() -> void:
	_stroke_flush_queued = false
	if _stroke_chunks.is_empty():
		return
	var chunks: Array[Vector3i] = []
	chunks.assign(_stroke_chunks.keys())
	_stroke_chunks.clear()
	var frame := _stroke_frame_index if _stroke_frame_index >= 0 else State.current_frame
	State.chunks_changed.emit(frame, chunks)


func _clear_smooth() -> void:
	_smooth_fields = []


func _rebuild_smooth() -> void:
	_smooth_surface_frame()
	_smooth_fields = _build_smooth_fields(_stroke_center_point, _stroke_radius, _stroke_falloff, _stroke_selection)


func _smooth_surface_frame() -> void:
	if _stroke_frame == null:
		return
	_stroke_frame = Prep.smooth_surface_frame(_active_frame(), _stroke_frame, _stroke_center_point, _smooth_entry, _stroke_radius, _footprint_depth(_stroke_radius))


func _build_smooth_fields(center_point: Vector3, radius: int, falloff: float, selection: Dictionary) -> Array:
	return Prep.smooth_fields(center_point, radius, falloff, _context(), selection)


func _smooth_tick() -> void:
	if _stroke_frame == null or _smooth_fields.is_empty():
		return
	var work := 0
	for field in _smooth_fields:
		work += (field["cells"] as Array).size()
	if work == 0:
		return
	_run_smooth(_smooth_fields)


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
	var stroke_id := _stroke_id
	var tx := _stroke_tx
	var document := _source_document
	var source := _source_frame
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
	if job.prepared_fields == null:
		_smooth_surface_frame()
	_mark_hover_dirty()


func _rebuild_preview() -> void:
	if _edit != null:
		_preview.publish_now()
		return
	_preview.refresh()


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


func _preview_paused() -> bool:
	return _edit != null or _busy()


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


func _hide_preview_visible() -> void:
	visible = false
	_hide_footprint()


func _mark_hover_dirty() -> void:
	if _preview != null:
		_preview.mark_intent()


func _on_document_changed() -> void:
	if _preview == null:
		return
	_preview.join()
	_preview.invalidate()


func _set_preview() -> void:
	_pose_footprint(_last_pick)


func _setup_footprint() -> void:
	_footprint = get_node_or_null("Footprint") as MeshInstance3D
	if _footprint == null:
		return
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color.WHITE
	material.no_depth_test = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_footprint.material_override = material
	_footprint.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_footprint.visible = false


func _pose_footprint(pick: PickResult) -> void:
	if _footprint == null:
		return
	if pick == null or pick.target == VoxelPicking.NONE:
		_hide_footprint()
		return
	var cell := pick.hit if pick.hit != VoxelPicking.NONE else pick.target
	if _edit != null and _path_anchor != VoxelPicking.NONE and (_stroke_tool == TerrainSettings.Tools.BUILD or _stroke_tool == TerrainSettings.Tools.FLATTEN):
		cell = _path_anchor
	var size := clampi(_settings.radius, 1, 32)
	var mesh: ArrayMesh = _footprint_meshes.get(size)
	if mesh == null:
		mesh = VoxelLineMesh.build(BrushSize.disk_outline(size))
		_footprint_meshes[size] = mesh
	_footprint.mesh = mesh
	var frame := _footprint_frame(pick)
	var on_floor := pick.hit == VoxelPicking.NONE and (_edit == null or frame.on_floor)
	if on_floor:
		var axis := State.floor_axis
		var sign := 1 if cell[axis] >= State.floor_index else -1
		frame = TerrainFrame.from_floor(axis, sign, float(State.floor_index) - 0.5, cell)
	_idle_pose_frame = frame
	var origin := Vector3(cell) + frame.normal * 0.5
	if on_floor:
		origin = Vector3(cell)
		origin[State.floor_axis] = float(State.floor_index) - 0.5
	_footprint.global_transform = Transform3D(
		Basis(frame.tangent_u, frame.tangent_v, frame.normal),
		origin
	)
	visible = true
	_footprint.visible = true


func _footprint_frame(pick: PickResult) -> TerrainFrame:
	if _edit != null and _stroke_frame != null and _stroke_tool == TerrainSettings.Tools.SMOOTH:
		return _stroke_frame
	if _edit != null and _cursor_frame != null and _stroke_tool != TerrainSettings.Tools.SMOOTH:
		if _stroke_tool == TerrainSettings.Tools.BUILD:
			return TerrainFrame.cardinal(_cursor_frame)
		return _cursor_frame
	var frame := _preview.hover_frame() if _preview != null else null
	if frame != null and _preview.last_publish_target == pick.target:
		if _settings.tool == _settings.Tools.BUILD:
			return TerrainFrame.cardinal(frame)
		return frame
	return TerrainFrame.from_face(pick.hit, pick.entry)


func _hide_footprint() -> void:
	if _footprint != null:
		_footprint.visible = false
	_visual_valid = false


func _pick_start(origin: Vector3, dir: Vector3) -> PickResult:
	var use_slice := State.slice_enabled
	if _edit != null and _stroke_context != null:
		use_slice = _stroke_context.slice_axis >= 0
	var pick := VoxelPicking.start_pick(origin, dir, State.get_current_voxel_frame(), _forward(), use_slice)
	_drag_ray_moved = origin != _drag_ray_origin or dir != _drag_ray_dir
	_drag_ray_origin = origin
	_drag_ray_dir = dir
	var press := _edit != null and not _end_requested
	if press:
		_press_ray_origin = origin
		_press_ray_dir = dir
		_ray_origin = origin
		_ray_dir = dir
		var floor_level := float(State.floor_index) - 0.5
		_stroke_floor_cell = State.floor_index if origin[State.floor_axis] >= floor_level else State.floor_index - 1
	if not press:
		return pick
	if _settings.tool == TerrainSettings.Tools.SMOOTH or _settings.tool == TerrainSettings.Tools.BUILD:
		_capture_press_camera(origin, dir)
		_stroke_forward = _forward()
	_pending_frame = _frame_for_pick(pick, origin)
	pick.plane = _plane_for(_pending_frame.origin, _pending_frame.normal)
	_press_point = _plane_hit(_pending_frame, origin, dir)
	return pick


func _capture_press_camera(origin: Vector3, dir: Vector3) -> void:
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	_stroke_ray_dir = dir.normalized()
	_camera_perspective = camera != null and camera.projection != Camera3D.PROJECTION_ORTHOGONAL
	_press_projection = camera.projection if camera != null else Camera3D.PROJECTION_ORTHOGONAL
	_press_camera_transform = camera.global_transform if camera != null else Transform3D()
	_camera_focus = origin if _camera_perspective else Vector3.ZERO


func _plane_hit(frame: TerrainFrame, origin: Vector3, dir: Vector3) -> Vector3:
	var intersection = frame.to_plane().intersects_ray(origin, dir)
	if intersection == null:
		return frame.origin
	return intersection


func _frame_for_pick(pick: PickResult, origin: Vector3) -> TerrainFrame:
	return _raw_frame_for_pick(pick, origin)


func _raw_frame_for_pick(pick: PickResult, origin: Vector3) -> TerrainFrame:
	if pick.hit != VoxelPicking.NONE:
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
	plane.cell_index = roundi(point[plane.axis])
	plane.point = point
	plane.normal = normal
	return plane


func pick_drag(request: PickRequest) -> PickResult:
	if request.plane == null:
		return PickResult.new()
	if _stroke_active and _stroke_tool == TerrainSettings.Tools.BUILD:
		_ray_origin = request.origin
		_ray_dir = request.direction
	if _stroke_active and _cursor_frame != null:
		return _frame_drag(request)
	return VoxelPicking.drag_pick(request.origin, request.direction, request.frame, request.plane)


func _frame_drag(request: PickRequest) -> PickResult:
	var result := PickResult.new()
	if _stroke_tool == TerrainSettings.Tools.SMOOTH and _edit != null and _camera_changed():
		finish_on_switch()
		return result
	_drag_ray_moved = request.origin != _drag_ray_origin or request.direction != _drag_ray_dir
	_drag_ray_origin = request.origin
	_drag_ray_dir = request.direction
	var intersection = _cursor_frame.to_plane().intersects_ray(request.origin, request.direction)
	if intersection == null:
		return result
	result.target = _cursor_cell(intersection)
	result.hit = result.target if request.frame != null and request.frame.has(result.target) else VoxelPicking.NONE
	return result


func _cursor_cell(point: Vector3) -> Vector3i:
	var cell := TerrainGeometry.cell_at(point)
	if _cursor_frame == null:
		return cell
	var axis := TerrainGeometry.cardinal_axis(_cursor_frame.normal)
	if axis >= 0:
		cell[axis] = floori(_cursor_frame.origin[axis] + 0.5)
	return cell


func _camera_changed() -> bool:
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null:
		return false
	if camera.projection != _press_projection:
		return true
	return not camera.global_transform.is_equal_approx(_press_camera_transform)


func update_visual(pick: PickResult) -> void:
	if pick.plane == null:
		pick.plane = _plane
	_last_pick = pick
	if pick.target == VoxelPicking.NONE:
		if _preview != null:
			_preview.clear_all()
		visible = false
		_hide_footprint()
		return
	if _visual_valid and pick.hit == _visual_hit and pick.target == _visual_target:
		_mark_hover_dirty()
		return
	_visual_hit = pick.hit
	_visual_target = pick.target
	_visual_valid = true
	_pose_footprint(pick)
	_mark_hover_dirty()


func _active_frame() -> VoxelFrame:
	return _source_frame if _edit != null else State.get_current_voxel_frame()


func _context() -> VoxelFrame.EditContext:
	return _stroke_context if _edit != null else State.drawing_context()


func _masks_for(context: VoxelFrame.EditContext) -> Array:
	return TerrainPreview.masks_for(context)
