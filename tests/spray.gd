extends "res://tests/test.gd"

# One process runs the spray can tests. The tests drive the real viewport input
# path and seed the sampling, so a run repeats exactly. The user arguments after
# `--` name the tests to run.

const PLATE := 8
const BLOCK := 4
const SEED := 20261020

const VoxelBrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")
const VoxelPreview := preload("res://Globals/Rendering/VoxelPreview.gd")

var _settings := preload("res://plugins/paint/settings.tres")

var viewport: SubViewport
var center := Vector2.ZERO
var tool: Node3D
var frame: VoxelFrame
var before: VoxelFrame
var after: VoxelFrame
var preview: Array[Vector3i] = []
var moved: Array[Vector3i] = []
var rerolled: Array[Vector3i] = []
var victim := Vector3i.ZERO
var cursor: MeshInstance3D
var seen_meshes := {}
var motion_max_us := 0
var shown_batch: Array[Vector3i] = []
var _dense_local: Array[Vector3i] = []
var _dense_spots: Array[Vector3i] = []
var _dense_result := {}
var _final_job
var _reference_job
var _rng_before := 0
var _history_before := 0


func _ready() -> void:
	timeout = 30.0
	test("the press paints exactly the previewed batch and the release rerolls the next one", _preview_parity, "spray_preview")
	test("a completed click rerolls the next preview and a still hover does not", _reroll_after_click, "spray_reroll")
	test("a lone candidate rerolls to itself", _reroll_single_candidate, "spray_reroll_single")
	test("the preview holds for one brush cell and follows a moved brush", _position, "spray_position")
	test("the speed samples distinct occupied spot centers", _distinct_centers, "spray_centers")
	test("the count caps at the available candidates", _candidate_shortage, "spray_shortage")
	test("the spot diameter paints the exact brush sphere", _spot_footprint, "spray_spot")
	test("the spot diameter clamps to its range", _diameter_clamp, "spray_diameter_clamp")
	test("the spray search size limits the sampled centers", _search_size, "spray_search_size")
	test("the selection limits the sampled centers", _selection_limit, "spray_selection")
	test("one undo and one redo cover the whole spray", _undo_redo, "spray_undo")
	test("Escape rolls the spray back and a switch commits it", _cancel_and_switch, "spray_cancel")
	test("a context change rolls the spray back", _context_change, "spray_context")
	test("the spray writes the current full material", _full_material, "spray_material")
	test("the spray job covers its whole pattern at every sample", _repeated_offset, "spray_repeat")
	test("a mostly empty spray region offers only its real voxels", _sparse_region, "spray_sparse")
	test("a wide radius on a sparse frame offers only the real voxels", _wide_radius, "spray_wide")
	test("a spot diameter skips a hole inside its sphere", _spot_hole, "spray_hole")
	test("the dense spot union at the maximum matches the exact sphere union", _dense_union, "spray_dense_union")
	test("a mirrored destination that is empty stays out of the preview and the write", _mirror_empty, "spray_mirror")
	test("the rendered preview sits on the world cells, not a doubled translation", _rendered_position, "spray_render_position")
	test("the rendered preview draws no redundant symmetry mirror", _rendered_mirror, "spray_render_mirror")
	test("the preview drops a cell that the frame no longer holds", _stale_occupancy, "spray_stale")
	test("a lost mouse release ends the spray stroke", _lost_release, "spray_release")
	test("an unchanged hover never resamples the batch", _preview_reuse, "spray_reuse")
	test("a material-only change keeps the sampled batch", _material_keeps_sample, "spray_material_hold")
	test("a replaced chunk revalidates the batch", _chunk_identity_revalidates, "spray_chunk_replace")
	test("a frame replacement keeps or drops the batch", _restore_and_replace, "spray_restore")
	test("a cleared frame drops the batch and hides the cursor", _clear_drops, "spray_clear")
	test("a selection that excludes the brush cell hides the preview", _empty_batch_hides, "spray_empty_batch")
	test("a moving cursor installs its preview before the release", _moving_preview, "spray_moving")
	test("a moving click paints exactly the offered sample", _moving_click, "spray_moving_click")
	test("a coalesced cursor does not resurrect across a frame clear", _coalesced_clear_hides, "spray_coalesced_clear")
	test("a lagging cursor paints the displayed snapshot, not the pending sample", _display_parity, "spray_display")
	test("a lagging cursor never paints the surface of another cell", _ownership_gate, "spray_ownership")
	test("the spray write skips the second symmetry expansion with exact parity", _write_parity, "spray_write_parity")
	test("the spray write keeps its selection and existing-only filters", _write_filters, "spray_write_filters")
	test("the spray write draws no random number and records one undo action", _write_rng_undo, "spray_write_undo")
	test("a frame change clears the displayed preview", _display_clears, "spray_display_clear")
	test("a selection change clears the displayed preview", _selection_clears, "spray_display_selection")


# Each test starts from a fresh document, the default symmetry, and the default
# spray options.
func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.current_color = Color.RED
	_settings.diameter = 1
	_settings.spot_diameter = 1
	_settings.spray_size = 9
	_settings.speed = 8
	frame = State.get_current_voxel_frame()
	viewport = editor_viewport()
	viewport.get_parent().stretch = false
	viewport.size = Vector2i(800, 500)
	center = Vector2(400.0, 250.0)
	camera_rig().is_orthogonal = true
	camera_rig().set_view("top")
	select_toolbar_item("paint", "Spray Can")
	tool = plugin("PaintPlugin")._spray_tool
	tool.seed_spray(SEED)
	await get_tree().process_frame


# A square plate on the floor plane, so the top view lands on its surface.
func _plate() -> void:
	for x in range(-PLATE, PLATE + 1):
		for z in range(-PLATE, PLATE + 1):
			frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.BLUE))
	camera_rig().center_on(frame.get_bounds())


# Three voxels in a row, so the candidate pool is smaller than the speed.
func _small_plate() -> void:
	for x in 3:
		frame.set_cell(Vector3i(x, 0, 0), VoxelFrame.material(Color.BLUE))
	camera_rig().center_on(frame.get_bounds())


# A solid block around the origin, so a spot sphere is fully occupied. A surface
# pick would clip the sphere, so the footprint test reads the whole shape.
func _block() -> void:
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	for x in range(-BLOCK, BLOCK + 1):
		for y in range(-BLOCK, BLOCK + 1):
			for z in range(-BLOCK, BLOCK + 1):
				frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.BLUE))
	camera_rig().center_on(frame.get_bounds())


# Samples the batch for one cell without a ray.
func _hover_cell(cell: Vector3i) -> void:
	var pick := PickResult.new()
	pick.target = cell
	pick.hit = cell
	tool.update_visual(pick)


# The brush sphere offsets for one diameter. The spray spot uses this same
# shared helper, so the two shapes must agree.
func _pattern_offsets(diameter: int) -> Array[Vector3i]:
	var offsets: Array[Vector3i] = []
	offsets.assign(BrushToolSettings.build_pattern(diameter, BrushToolSettings.BrushShape.SPHERE).keys())
	return offsets


# The whole brush sphere of one diameter centered on a cell.
func _pattern_cells(center: Vector3i, diameter: int) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	for offset in _pattern_offsets(diameter):
		cells.append(center + offset)
	return cells


# The brush sphere cells that the frame holds. A hole inside the sphere stays out.
func _occupied_pattern(center: Vector3i, diameter: int) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	for offset in _pattern_offsets(diameter):
		var cell := center + offset
		if frame.has(cell):
			cells.append(cell)
	return cells


func _same_cell_set(first: Array[Vector3i], second: Array[Vector3i]) -> bool:
	if first.size() != second.size():
		return false
	for cell in first:
		if not second.has(cell):
			return false
	return true


func _sprayed_cells() -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	for x in range(-PLATE, PLATE + 1):
		for z in range(-PLATE, PLATE + 1):
			var cell := Vector3i(x, 0, z)
			if frame.has(cell) and frame.get_color(cell) != Color.BLUE:
				cells.append(cell)
	return cells


func _sprayed_count() -> int:
	return _sprayed_cells().size()


func _screen_pos_of(cell: Vector3i) -> Vector2:
	return camera_rig().unproject_position(Vector3(cell))


func _press(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = pos
	viewport.push_input(event)


func _release(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	event.position = pos
	viewport.push_input(event)


func _motion(pos: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.push_input(event)


func _hover(pos: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	viewport.push_input(event)


func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	get_tree().root.push_input(event)


# Waits until the cursor preview installs its mesh. A solid preview builds on a
# worker, so the test must let the worker finish and the preview install it.
func _settle_cursor(cursor: MeshInstance3D) -> void:
	for i in 240:
		await get_tree().process_frame
		if cursor.is_settled() and cursor.mesh != null:
			return


# Drops the shared preview mesh cache, so the next preview request builds on a
# worker and cannot install during the input event. The spray scene does not
# depend on cache warmth.
func _clear_preview_cache() -> void:
	VoxelPreview._mesh_cache.clear()
	VoxelPreview._cache_order.clear()
	VoxelPreview._cache_bytes = 0


# The world AABB of every visible mesh of the cursor and its mirror children.
# A mirror child is a separate MeshInstance3D, so the cursor mesh alone does not
# show it.
func _rendered_aabb(root: Node3D) -> AABB:
	var result := AABB()
	var found := false
	for mesh_node in _mesh_nodes(root):
		if not mesh_node.visible or mesh_node.mesh == null:
			continue
		var world: AABB = mesh_node.global_transform * mesh_node.mesh.get_aabb()
		result = result.merge(world) if found else world
		found = true
	return result


func _mesh_nodes(root: Node) -> Array[MeshInstance3D]:
	var nodes: Array[MeshInstance3D] = []
	if root is MeshInstance3D:
		nodes.append(root)
	for child in root.get_children():
		nodes.append_array(_mesh_nodes(child))
	return nodes


# The world AABB of a set of cells. A voxel spans one unit centered on its cell
# coordinate, so it reaches half a unit on each side.
func _cells_aabb(cells: Array[Vector3i]) -> AABB:
	if cells.is_empty():
		return AABB()
	var min_corner := Vector3(INF, INF, INF)
	var max_corner := Vector3(-INF, -INF, -INF)
	for cell in cells:
		min_corner = min_corner.min(Vector3(cell) - Vector3(0.5, 0.5, 0.5))
		max_corner = max_corner.max(Vector3(cell) + Vector3(0.5, 0.5, 0.5))
	return AABB(min_corner, max_corner - min_corner)


func _same_aabb(first: AABB, second: AABB) -> bool:
	return first.position.is_equal_approx(second.position) and first.size.is_equal_approx(second.size)


func _preview_parity() -> void:
	step("Given a plate and a spray with five spot centers", func():
		_plate()
		tool.seed_spray(SEED)
		_settings.speed = 5
	)
	step("When the pointer hovers over a plate voxel", func():
		_hover(center)
		preview = tool.preview_cells()
	)
	step("Then the preview holds the sampled occupied cells", func():
		expect(preview.size() == 5, "the preview holds one cell per sampled spot center")
		expect(_sprayed_count() == 0, "the hover alone paints nothing")
		for cell in preview:
			expect(frame.has(cell), "every previewed cell is an existing voxel")
	)
	step("When the user presses", func():
		_press(center)
	)
	step("Then the press paints exactly the previewed cells", func():
		expect(_sprayed_count() == preview.size(), "the press paints the previewed batch")
		for cell in preview:
			expect(frame.get_color(cell) == State.current_color, "every previewed cell took the paint material")
	)
	step("When the user releases", func():
		_release(center)
	)
	step("Then the release rerolls the next preview and paints nothing", func():
		rerolled = tool.preview_cells()
		expect(rerolled != preview, "the completed click samples a new preview")
		expect(_sprayed_count() == preview.size(), "the reroll paints nothing")
	)
	step("When the user presses the same cell again", func():
		_press(center)
	)
	step("Then the second press paints exactly the rerolled preview", func():
		var painted := {}
		for cell in preview:
			painted[cell] = true
		for cell in rerolled:
			painted[cell] = true
		expect(_sprayed_count() == painted.size(), "the second press paints the rerolled batch")
		for cell in rerolled:
			expect(frame.get_color(cell) == State.current_color, "every rerolled cell took the paint material")
		_release(center)
	)


# A completed click must reroll the next preview. A still pointer must not. The
# seeded pool holds many candidates, so two samples almost surely differ.
func _reroll_after_click() -> void:
	step("Given a plate and a spray with a seeded pool of many candidates", func():
		_plate()
		tool.seed_spray(SEED)
		_settings.speed = 3
		_hover(center)
		preview = tool.preview_cells()
	)
	step("When the user completes a click", func():
		_press(center)
		expect(_sprayed_count() == preview.size(), "the first click paints its preview alone")
		_release(center)
	)
	step("Then the next preview rerolls", func():
		rerolled = tool.preview_cells()
		expect(rerolled != preview, "the completed click samples a new preview")
		expect(_sprayed_count() == preview.size(), "the reroll paints nothing")
		for cell in rerolled:
			expect(frame.has(cell), "every rerolled cell is an existing voxel")
	)
	step("When the pointer holds the same cell across frames", func():
		for i in 3:
			tool.update_visual(tool._last_pick)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the still hover keeps the rerolled preview", func():
		expect(tool.preview_cells() == rerolled, "a still pointer never rerolls on its own")
		expect(_sprayed_count() == preview.size(), "a still hover paints nothing")
	)
	step("When the user completes a second click on the same cell", func():
		var second: Array[Vector3i] = tool.preview_cells()
		_press(center)
		_release(center)
		expect(second == rerolled, "the second click paints the previewed batch")
		expect(_sprayed_count() > preview.size(), "the second click painted new voxels")
		expect(tool.preview_cells() != second, "the second click rerolls again")
	)


# One candidate leaves no random choice, so a reroll must keep the same preview.
func _reroll_single_candidate() -> void:
	step("Given one voxel and a spray with one candidate", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.BLUE))
		camera_rig().center_on(frame.get_bounds())
		tool.seed_spray(SEED)
		_settings.speed = 8
		_settings.spray_size = 1
		_settings.spot_diameter = 1
		_hover(_screen_pos_of(Vector3i.ZERO))
		preview = tool.preview_cells()
	)
	step("When the user completes a click", func():
		_press(_screen_pos_of(Vector3i.ZERO))
		_release(_screen_pos_of(Vector3i.ZERO))
	)
	step("Then the reroll offers the lone candidate again", func():
		expect(preview.size() == 1, "the preview holds the lone voxel")
		expect(tool.preview_cells() == preview, "a lone candidate rerolls to itself")
		expect(_sprayed_count() == 1, "the click painted the lone voxel")
	)


func _position() -> void:
	step("Given a plate and a spray with four spot centers", func():
		_plate()
		tool.seed_spray(SEED)
		_settings.speed = 4
	)
	step("When the pointer hovers over one voxel", func():
		_hover(center)
		preview = tool.preview_cells()
	)
	step("Then repeated cursor updates keep the same batch", func():
		for i in 3:
			tool.update_visual(tool._last_pick)
		expect(tool.preview_cells() == preview, "the same brush cell keeps the same batch")
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then time does not change the batch", func():
		expect(tool.preview_cells() == preview, "the preview holds across frames")
		expect(_sprayed_count() == 0, "no voxel is painted while the pointer holds still")
	)
	step("When the user presses and drags to another voxel", func():
		_press(center)
		_motion(_screen_pos_of(Vector3i(4, 0, 0)))
		moved = tool.preview_cells()
		_release(_screen_pos_of(Vector3i(4, 0, 0)))
	)
	step("Then the new brush cell sampled and painted a new batch", func():
		expect(moved != preview, "a changed brush cell samples a new batch")
		expect(_sprayed_count() > 0, "the moved spray painted voxels")
	)
	step("When the pointer hovers over empty space", func():
		var count := _sprayed_count()
		_hover(center + Vector2(0.0, 220.0))
		expect(not tool.visible, "the cursor hides over an empty cell")
		expect(_sprayed_count() == count, "an empty hover paints nothing")
	)


func _distinct_centers() -> void:
	step("Given a plate and a spray with three spot centers", func():
		_plate()
		tool.seed_spray(SEED)
		_settings.speed = 3
	)
	step("When the user presses and releases", func():
		_press(center)
		_release(center)
	)
	step("Then exactly three distinct occupied centers are painted", func():
		expect(_sprayed_count() == 3, "the spray paints one voxel per sampled spot center")
		expect(tool.preview_cells().size() == 3, "the batch holds three distinct centers")
	)


func _candidate_shortage() -> void:
	step("Given three voxels and a spray with eight spot centers", func():
		_small_plate()
		tool.seed_spray(SEED)
		_settings.speed = 8
	)
	step("When the user presses and releases", func():
		_press(center)
		_release(center)
	)
	step("Then every available center is painted and no sample is wasted", func():
		expect(_sprayed_count() == 3, "the count caps at the three available candidates")
	)


# The spot footprint must be the shared brush sphere of the spot diameter, so an
# even diameter keeps the brush's even alignment instead of a rounded radius.
func _spot_footprint() -> void:
	for diameter in [1, 2, 3, 4, 5]:
		step("Given a solid block and a spray spot diameter of %d" % diameter, func():
			_block()
			tool.seed_spray(SEED)
			_settings.speed = 1
			_settings.spray_size = 1
			_settings.spot_diameter = diameter
			_hover_cell(Vector3i.ZERO)
			preview = tool.preview_cells()
		)
		step("Then the spot is the exact brush sphere of that diameter", func():
			expect(_same_cell_set(preview, _pattern_cells(Vector3i.ZERO, diameter)), "the diameter %d spot matches the brush sphere" % diameter)
		)


# The spot diameter clamps to the same range as the brush diameter.
func _diameter_clamp() -> void:
	step("When the user sets the spot diameter below its minimum", func():
		_settings.spot_diameter = 0
	)
	step("Then the minimum clamps to one", func():
		expect(_settings.spot_diameter == 1, "the minimum spot diameter is one")
	)
	step("When the user sets the spot diameter above its maximum", func():
		_settings.spot_diameter = 100
	)
	step("Then the maximum matches the brush range", func():
		expect(_settings.spot_diameter == 64, "the maximum spot diameter matches the brush maximum")
	)


func _search_size() -> void:
	step("Given a plate and a spray search size of one", func():
		_plate()
		tool.seed_spray(SEED)
		_settings.spray_size = 1
	)
	step("When the user presses and releases", func():
		_press(center)
		_release(center)
	)
	step("Then only the brush cell can be painted", func():
		expect(_sprayed_count() == 1, "a size of one offers the brush cell alone")
	)


func _selection_limit() -> void:
	step("Given a plate with one selected voxel and a wide spray", func():
		_plate()
		State.selection.add(Vector3i.ZERO)
		State.selection_changed.emit()
		tool.seed_spray(SEED)
		_settings.speed = 8
	)
	step("When the user presses and releases", func():
		_press(center)
		_release(center)
	)
	step("Then only the selected voxel can be painted", func():
		expect(_sprayed_count() == 1, "the selection limits the candidate pool")
	)


func _undo_redo() -> void:
	step("Given a plate and a press that painted voxels", func():
		_plate()
		before = frame.copy_frame()
		tool.seed_spray(SEED)
		_settings.speed = 5
		_press(center)
		_release(center)
	)
	step("Then one undo and one redo cover the whole spray", func():
		after = frame.copy_frame()
		expect(_sprayed_count() > 0, "the press painted voxels")
		expect(State.undo_redo.get_history_count() == 1, "the spray records exactly one action")
		State.undo_redo.undo()
		expect(frame.storage_data() == before.storage_data(), "one undo restores the plate exactly")
		State.undo_redo.redo()
		expect(frame.storage_data() == after.storage_data(), "one redo restores the exact spray")
	)


func _cancel_and_switch() -> void:
	step("Given a spray stroke that painted voxels", func():
		_plate()
		before = frame.copy_frame()
		tool.seed_spray(SEED)
		_settings.speed = 5
		_press(center)
		expect(_sprayed_count() > 0, "the press painted voxels")
	)
	step("When the user presses Escape", func():
		_key(KEY_ESCAPE)
	)
	step("Then the spray rolls back with no history", func():
		expect(frame.storage_data() == before.storage_data(), "Escape restores the plate exactly")
		expect(not State.undo_redo.has_undo(), "the cancelled spray records no history")
		expect(tool._edit == null, "the cancelled spray releases its edit")
	)
	step("Given a fresh spray stroke that painted voxels", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		State.undo_redo.clear_history()
		_plate()
		before = frame.copy_frame()
		tool.seed_spray(SEED)
		_press(center)
		expect(_sprayed_count() > 0, "the second spray painted voxels")
	)
	step("When the user switches to the brush", func():
		activate_tool("Toolbar")
	)
	step("Then the switch commits the spray as one action", func():
		expect(tool._edit == null, "the switch releases the spray edit")
		expect(State.undo_redo.has_undo(), "the switched spray records one action")
		State.undo_redo.undo()
		expect(frame.storage_data() == before.storage_data(), "one undo restores the plate after the switch")
	)


func _context_change() -> void:
	step("Given a spray stroke that painted voxels", func():
		_plate()
		before = frame.copy_frame()
		tool.seed_spray(SEED)
		_settings.speed = 5
		_press(center)
		expect(_sprayed_count() > 0, "the press painted voxels")
	)
	step("When the user adds a frame", func():
		State.add_frame()
	)
	step("Then the source frame keeps no spray and the new frame stays empty", func():
		expect(frame.storage_data() == before.storage_data(), "the context change restores the plate exactly")
		expect(tool._edit == null, "the context change releases the spray edit")
		expect(State.get_current_voxel_frame().count() == 0, "the new frame receives no stale spray")
	)


func _full_material() -> void:
	var metal := VoxelFrame.material(Color.RED, Color(0.5, 0.25, 0.125), 1.0, 0.25)
	step("Given a plate and a full metal material", func():
		_plate()
		State.set_material(metal)
		tool.seed_spray(SEED)
		_settings.speed = 5
		_press(center)
		_release(center)
	)
	step("Then every sprayed voxel holds the current full material", func():
		var cells := _sprayed_cells()
		expect(cells.size() > 0, "the spray changed at least one voxel")
		if cells.is_empty():
			return
		expect(frame.get_material(cells[0]) == metal, "the sprayed voxel holds every material value")
	)


func _repeated_offset() -> void:
	step("Given a spray stroke with no queued sample", func():
		_plate()
		tool.seed_spray(SEED)
		_press(center)
	)
	step("Then the spray job covers its whole pattern at every sample", func():
		var job: Variant = tool._build_job()
		expect(job.previous_center == Vector3i.MAX, "the spray never skips a repeated offset")
		_release(center)
	)


func _sparse_region() -> void:
	step("Given three scattered voxels and a wide spray", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.BLUE))
		frame.set_cell(Vector3i(1, 0, 0), VoxelFrame.material(Color.BLUE))
		frame.set_cell(Vector3i(30, 0, 0), VoxelFrame.material(Color.BLUE))
		camera_rig().center_on(frame.get_bounds())
		tool.seed_spray(SEED)
		_settings.speed = 8
		_settings.spray_size = 13
	)
	step("When the pointer hovers the first voxel", func():
		_hover(_screen_pos_of(Vector3i.ZERO))
		preview = tool.preview_cells()
	)
	step("Then the preview offers only the real voxels of the region", func():
		expect(preview.size() == 2, "the far voxel is outside the spray radius")
		for cell in preview:
			expect(frame.has(cell), "every previewed cell is a real voxel")
	)
	step("When the user presses and releases", func():
		_press(_screen_pos_of(Vector3i.ZERO))
		_release(_screen_pos_of(Vector3i.ZERO))
	)
	step("Then the write touches no empty cell", func():
		expect(_sprayed_count() == preview.size(), "the press paints the previewed voxels")
		expect(frame.count() == 3, "the spray adds no voxel")
		expect(frame.get_color(Vector3i(30, 0, 0)) == Color.BLUE, "the distant voxel keeps its color")
	)


# The dense spot union must equal the exact union of the spot spheres. The
# interval union in the production footprint path trades the per-spot cell test
# for a scanline union, so it must keep the exact cell set at the maximum size.
func _dense_union() -> void:
	var spots: Array[Vector3i] = [Vector3i.ZERO, Vector3i(20, 0, 0), Vector3i(0, -20, 12), Vector3i(9, 9, 9)]
	step("Given a dense block and four maximum spot centers", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		for x in range(-12, 13):
			for y in range(-12, 13):
				for z in range(-12, 13):
					frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.BLUE))
		_settings.spot_diameter = 64
		_settings.spray_size = 64
		tool._batch_material = VoxelFrame.material(Color.WHITE)
		var local: Array[Vector3i] = []
		for cell in frame.positions():
			local.append(cell)
		_dense_local = local
		_dense_spots = spots
	)
	step("When the production footprint unions the four spot spheres", func():
		_dense_result = tool._footprints(_dense_spots, _dense_local)
	)
	step("Then the union holds exactly the sphere cells of the four spots", func():
		var expected := {}
		for spot in _dense_spots:
			for offset in VoxelBrushSize.sphere_offsets(64):
				var cell := spot + offset
				if frame.has(cell):
					expected[cell] = true
		expect(_dense_result.size() == expected.size(), "the dense union holds every sphere cell of the four spots")
		var got: Array[Vector3i] = []
		got.assign(_dense_result.keys())
		var want: Array[Vector3i] = []
		want.assign(expected.keys())
		expect(_same_cell_set(got, want), "the dense union matches the exact sphere union")
	)


# A spot sphere that crosses a hole must keep the hole out of the preview and
# the write, so a spot never paints an empty cell.
func _spot_hole() -> void:
	step("Given a plate with a hole beside the brush voxel", func():
		_plate()
		frame.set_cell(Vector3i(1, 0, 0), VoxelFrame.material(Color.TRANSPARENT))
		tool.seed_spray(SEED)
		_settings.speed = 1
		_settings.spray_size = 1
		_settings.spot_diameter = 3
	)
	step("When the pointer hovers the brush voxel", func():
		_hover(center)
		preview = tool.preview_cells()
	)
	step("Then the preview skips the hole", func():
		expect(not preview.has(Vector3i(1, 0, 0)), "the empty hole stays out of the preview")
		expect(_same_cell_set(preview, _occupied_pattern(Vector3i.ZERO, 3)), "the footprint holds only the real sphere cells")
		for cell in preview:
			expect(frame.has(cell), "every previewed cell is a real voxel")
	)
	step("When the user presses and releases", func():
		_press(center)
		_release(center)
	)
	step("Then the write fills only the real footprint", func():
		expect(_sprayed_count() == preview.size(), "the press paints exactly the previewed footprint")
		expect(not frame.has(Vector3i(1, 0, 0)), "the hole stays empty")
	)


func _mirror_empty() -> void:
	step("Given a voxel whose X mirror is empty", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i(2, 0, 0), VoxelFrame.material(Color.BLUE))
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3.ZERO
		camera_rig().center_on(frame.get_bounds())
		tool.seed_spray(SEED)
		_settings.speed = 1
		_settings.spray_size = 1
		_settings.spot_diameter = 1
	)
	step("When the pointer hovers that voxel", func():
		_hover(_screen_pos_of(Vector3i(2, 0, 0)))
		preview = tool.preview_cells()
	)
	step("Then the empty mirror stays out of the preview", func():
		expect(preview.size() == 1, "only the real voxel is offered")
		expect(not preview.has(Vector3i(-2, 0, 0)), "the empty mirrored destination is dropped")
	)
	step("When the user presses and releases", func():
		_press(_screen_pos_of(Vector3i(2, 0, 0)))
		_release(_screen_pos_of(Vector3i(2, 0, 0)))
	)
	step("Then the write leaves the empty mirror empty", func():
		expect(_sprayed_count() == 1, "the write covers the real voxel alone")
		expect(not frame.has(Vector3i(-2, 0, 0)), "the empty mirror receives no voxel")
	)
	step("Given an occupied mirror on both sides", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i(2, 0, 0), VoxelFrame.material(Color.BLUE))
		frame.set_cell(Vector3i(-2, 0, 0), VoxelFrame.material(Color.BLUE))
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3.ZERO
		camera_rig().center_on(frame.get_bounds())
		tool.seed_spray(SEED)
		_hover(_screen_pos_of(Vector3i(2, 0, 0)))
		preview = tool.preview_cells()
	)
	step("Then the occupied mirror joins the preview", func():
		expect(preview.size() == 2, "the occupied mirror is written with the source voxel")
		expect(preview.has(Vector3i(-2, 0, 0)), "the occupied mirror is offered")
		_press(_screen_pos_of(Vector3i(2, 0, 0)))
		_release(_screen_pos_of(Vector3i(2, 0, 0)))
		expect(_sprayed_count() == 2, "the write covers both real voxels")
	)


# The rendered mesh must sit on the world cells of the batch. A tool that moves
# to the brush cell and also passes world cells to the cursor translates the
# mesh a second time.
func _rendered_position() -> void:
	var hover_cell := Vector3i(3, 0, 2)
	step("Given a plate and a spray with five spots", func():
		_plate()
		tool.seed_spray(SEED)
		_settings.speed = 5
	)
	step("When the pointer hovers a voxel away from the origin", func():
		_hover(_screen_pos_of(hover_cell))
		preview = tool.preview_cells()
	)
	await _settle_cursor(tool.get_node("Cursor"))
	step("Then the rendered geometry sits on exactly the previewed cells", func():
		expect(preview.size() == 5, "the preview holds the sampled spots")
		expect(_same_aabb(_rendered_aabb(tool), _cells_aabb(preview)), "the rendered world geometry matches the previewed cells")
		expect(tool.position.is_equal_approx(Vector3.ZERO), "the tool stays at the origin")
	)


# The batch already holds the mirrored destinations, so the cursor must not
# mirror its mesh again. A second mirror would draw empty or unpermitted voxels.
func _rendered_mirror() -> void:
	step("Given a voxel whose X mirror is empty", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i(2, 0, 0), VoxelFrame.material(Color.BLUE))
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3.ZERO
		camera_rig().center_on(frame.get_bounds())
		tool.seed_spray(SEED)
		_settings.speed = 1
		_settings.spray_size = 1
		_settings.spot_diameter = 1
	)
	step("When the pointer hovers that voxel", func():
		_hover(_screen_pos_of(Vector3i(2, 0, 0)))
		preview = tool.preview_cells()
	)
	await _settle_cursor(tool.get_node("Cursor"))
	step("Then the rendered geometry holds the real voxel alone", func():
		expect(preview.size() == 1 and preview.has(Vector3i(2, 0, 0)), "only the real voxel is offered")
		expect(_same_aabb(_rendered_aabb(tool), _cells_aabb(preview)), "no empty mirrored voxel is drawn")
	)
	step("Given occupied mirrors on both sides of the origin", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i(2, 0, 0), VoxelFrame.material(Color.BLUE))
		frame.set_cell(Vector3i(-2, 0, 0), VoxelFrame.material(Color.BLUE))
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3.ZERO
		camera_rig().center_on(frame.get_bounds())
		tool.seed_spray(SEED)
		_hover(_screen_pos_of(Vector3i(2, 0, 0)))
		preview = tool.preview_cells()
	)
	await _settle_cursor(tool.get_node("Cursor"))
	step("Then the rendered geometry holds both real voxels", func():
		expect(preview.size() == 2, "the batch holds both mirrored voxels")
		expect(_same_aabb(_rendered_aabb(tool), _cells_aabb(preview)), "the rendered geometry matches both voxels")
	)
	step("Given occupied mirrors about a half-unit origin", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i(2, 0, 0), VoxelFrame.material(Color.BLUE))
		frame.set_cell(Vector3i(-1, 0, 0), VoxelFrame.material(Color.BLUE))
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3(0.5, 0.5, 0.5)
		camera_rig().center_on(frame.get_bounds())
		tool.seed_spray(SEED)
		_hover(_screen_pos_of(Vector3i(2, 0, 0)))
		preview = tool.preview_cells()
	)
	await _settle_cursor(tool.get_node("Cursor"))
	step("Then the rendered geometry matches the half-unit mirrors", func():
		expect(preview.size() == 2 and preview.has(Vector3i(-1, 0, 0)), "the half-unit mirror joins the batch")
		expect(_same_aabb(_rendered_aabb(tool), _cells_aabb(preview)), "the rendered geometry matches the half-unit mirror")
	)


# A wide spot on a sparse frame reads the occupied chunks instead of the whole
# reach ball. It must still offer only the real voxels.
func _wide_radius() -> void:
	step("Given one voxel and a spray with the widest spot and search size", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.BLUE))
		camera_rig().center_on(frame.get_bounds())
		tool.seed_spray(SEED)
		_settings.speed = 8
		_settings.spray_size = 64
		_settings.spot_diameter = 64
	)
	step("When the pointer hovers the voxel", func():
		_hover(_screen_pos_of(Vector3i.ZERO))
		preview = tool.preview_cells()
	)
	step("Then the preview offers the lone real voxel alone", func():
		expect(preview.size() == 1 and preview.has(Vector3i.ZERO), "a wide radius offers only the real voxel")
	)
	step("When the user presses and releases", func():
		_press(_screen_pos_of(Vector3i.ZERO))
		_release(_screen_pos_of(Vector3i.ZERO))
	)
	step("Then the write touches no empty cell", func():
		expect(_sprayed_count() == 1, "the press paints the lone voxel")
		expect(frame.count() == 1, "the spray adds no voxel")
	)


# A batch cell that the frame no longer holds must leave the preview. A frame
# switch and a detach and re-entry must drop the stale batch too.
func _stale_occupancy() -> void:
	var hover_cell := Vector3i(3, 0, 0)
	step("Given a plate and a hover preview", func():
		_plate()
		tool.seed_spray(SEED)
		_settings.speed = 8
		_hover(_screen_pos_of(hover_cell))
		preview = tool.preview_cells()
	)
	step("When the frame loses a previewed voxel", func():
		expect(preview.size() > 1, "the preview holds several voxels")
		var victim := preview[0]
		for cell in preview:
			if cell != hover_cell:
				victim = cell
				break
		frame.set_cell(victim, VoxelFrame.material(Color.TRANSPARENT))
		tool.update_visual(tool._last_pick)
		expect(not tool.preview_cells().has(victim), "the removed voxel leaves the preview")
		for cell in tool.preview_cells():
			expect(frame.has(cell), "every previewed cell is still occupied")
	)
	step("When the spray detaches and re-enters over a changed frame", func():
		var current: Array[Vector3i] = tool.preview_cells()
		activate_tool("Toolbar")
		var lost: Vector3i = current[0]
		frame.set_cell(lost, VoxelFrame.material(Color.TRANSPARENT))
		select_toolbar_item("paint", "Spray Can")
		tool = plugin("PaintPlugin")._spray_tool
		tool.seed_spray(SEED)
		_hover(_screen_pos_of(hover_cell))
	)
	step("Then the re-entered preview holds only occupied cells", func():
		for cell in tool.preview_cells():
			expect(frame.has(cell), "every re-entered previewed cell is occupied")
	)


# A press that loses its release event must still end the stroke. A motion with
# no button down while the stroke is open ends it like a release.
func _lost_release() -> void:
	step("Given a plate and a press that painted voxels", func():
		_plate()
		before = frame.copy_frame()
		tool.seed_spray(SEED)
		_settings.speed = 5
		_press(center)
		preview = tool.preview_cells()
		expect(tool._edit != null, "the press opens the stroke")
		expect(_sprayed_count() > 0, "the press painted voxels")
	)
	step("When the pointer moves with the button up and no release event", func():
		_hover(center + Vector2(10.0, 0.0))
	)
	step("Then the stroke ends and commits as one action", func():
		expect(tool._edit == null, "the lost release closes the stroke")
		expect(not tool._stroke_active, "the stroke is no longer active")
		expect(State.undo_redo.get_history_count() == 1, "the spray records one action")
		State.undo_redo.undo()
		expect(frame.storage_data() == before.storage_data(), "one undo restores the plate")
	)


# An unchanged hover must reuse the sampled batch and its prepared preview, so it
# never draws a new sample. The random source state proves the sampler did not
# run again.
func _preview_reuse() -> void:
	var hover_cell := Vector3i(3, 0, 2)
	step("Given a plate and a hover preview", func():
		_plate()
		tool.seed_spray(SEED)
		_settings.speed = 8
		_hover(_screen_pos_of(hover_cell))
		preview = tool.preview_cells()
		expect(preview.size() > 1, "the preview holds several voxels")
	)
	step("When the pointer holds the same cell across many updates", func():
		tool.seed_spray(SEED)
		var state_before: int = tool._rng.state
		for i in 20:
			tool.update_visual(tool._last_pick)
		expect(tool._rng.state == state_before, "an unchanged hover draws no new sample")
	)
	step("Then the batch and the prepared preview stay the same", func():
		expect(tool.preview_cells() == preview, "the batch holds")
		expect(tool._preview_version == tool._batch_version, "the cursor still shows the current batch")
		expect(_sprayed_count() == 0, "a still hover paints nothing")
	)


# A material-only write bumps the chunk revision but keeps every preview cell
# occupied, so the batch must not reroll.
func _material_keeps_sample() -> void:
	var hover_cell := Vector3i(3, 0, 2)
	step("Given a plate and a hover preview", func():
		_plate()
		tool.seed_spray(SEED)
		_settings.speed = 6
		_hover(_screen_pos_of(hover_cell))
		preview = tool.preview_cells()
		expect(preview.size() > 1, "the preview holds several voxels")
	)
	step("When a previewed voxel is recolored with another material", func():
		var victim: Vector3i = preview[0]
		var location := VoxelFrame.chunk_position(victim)
		var revision: int = frame.chunks[location].voxel_revision
		frame.set_cell(victim, VoxelFrame.material(Color.GREEN))
		expect(frame.chunks[location].voxel_revision != revision, "the material write bumps the chunk revision")
		tool.update_visual(tool._last_pick)
	)
	step("Then the sampled batch holds", func():
		expect(tool.preview_cells() == preview, "a material-only write never rerolls the sample")
		for cell in preview:
			expect(frame.has(cell), "every previewed cell is still occupied")
	)


# A chunk that a direct assignment replaces keeps the batch when it still holds
# every preview cell. A replacement that drops one rerolls the batch, even though
# its revision did not move.
func _chunk_identity_revalidates() -> void:
	var hover_cell := Vector3i(3, 0, 2)
	step("Given a plate and a hover preview", func():
		_plate()
		tool.seed_spray(SEED)
		_settings.speed = 6
		_hover(_screen_pos_of(hover_cell))
		preview = tool.preview_cells()
		expect(preview.size() > 1, "the preview holds several voxels")
	)
	step("When the chunk that holds the batch is replaced by an equal copy", func():
		var location := VoxelFrame.chunk_position(preview[0])
		var replacement: VoxelFrame.Chunk = frame.chunks[location].copy()
		expect(replacement.voxel_revision == frame.chunks[location].voxel_revision, "the copy keeps the revision")
		frame.chunks[location] = replacement
		tool.update_visual(tool._last_pick)
	)
	step("Then the equal replacement keeps the batch", func():
		expect(tool.preview_cells() == preview, "an equal replacement never rerolls the sample")
	)
	step("When a replacement drops a previewed cell", func():
		victim = preview[0]
		var location := VoxelFrame.chunk_position(victim)
		var replacement: VoxelFrame.Chunk = frame.chunks[location].copy()
		replacement.erase(victim)
		frame.chunks[location] = replacement
		tool.update_visual(tool._last_pick)
	)
	step("Then the dropped cell leaves the batch", func():
		expect(not tool.preview_cells().has(victim), "the removed cell leaves the preview")
		for cell in tool.preview_cells():
			expect(frame.has(cell), "every previewed cell is still occupied")
	)


# A frame restore replaces the chunk objects. An equal restore keeps the batch,
# and a restore that dropped a preview cell rerolls it.
func _restore_and_replace() -> void:
	var hover_cell := Vector3i(3, 0, 2)
	step("Given a plate and a hover preview", func():
		_plate()
		tool.seed_spray(SEED)
		_settings.speed = 6
		_hover(_screen_pos_of(hover_cell))
		preview = tool.preview_cells()
		expect(preview.size() > 1, "the preview holds several voxels")
	)
	step("When the frame is replaced by an equal copy", func():
		frame.restore(frame.copy_frame().capture())
		tool.update_visual(tool._last_pick)
	)
	step("Then the equal replacement keeps the batch", func():
		expect(tool.preview_cells() == preview, "an equal frame replacement never rerolls the sample")
	)
	step("When the frame is replaced by a copy that dropped a previewed cell", func():
		victim = preview[0]
		var copy := frame.copy_frame()
		copy.set_cell(victim, VoxelFrame.material(Color.TRANSPARENT))
		frame.restore(copy.capture())
		tool.update_visual(tool._last_pick)
	)
	step("Then the dropped cell leaves the batch", func():
		expect(not tool.preview_cells().has(victim), "the removed cell leaves the preview")
		for cell in tool.preview_cells():
			expect(frame.has(cell), "every previewed cell is occupied")
	)


# A clear removes every chunk, so the batch must drop and the cursor must hide.
func _clear_drops() -> void:
	var hover_cell := Vector3i(3, 0, 2)
	step("Given a plate and a hover preview", func():
		_plate()
		tool.seed_spray(SEED)
		_settings.speed = 6
		_hover(_screen_pos_of(hover_cell))
		preview = tool.preview_cells()
		expect(preview.size() > 1, "the preview holds several voxels")
	)
	step("When the frame is cleared", func():
		frame.clear()
		tool.update_visual(tool._last_pick)
	)
	step("Then the batch drops and the cursor hides", func():
		expect(tool.preview_cells().is_empty(), "a cleared frame drops the batch")
		expect(not tool.get_node("Cursor").visible, "the cursor hides with the empty batch")
	)


# A selection that excludes the brush cell leaves no candidate, so the preview is
# empty and the cursor hides. A hover on a selected cell shows it again.
func _empty_batch_hides() -> void:
	step("Given a plate with a selection that excludes the brush cell", func():
		_plate()
		State.selection.add(Vector3i(7, 0, 7))
		State.selection_changed.emit()
		tool.seed_spray(SEED)
		_settings.speed = 4
	)
	step("When the pointer hovers a cell outside the selection", func():
		_hover(center)
	)
	step("Then the preview is empty and the cursor hides", func():
		expect(tool.preview_cells().is_empty(), "a selection that excludes the brush cell offers no candidate")
		expect(not tool.get_node("Cursor").visible, "the cursor hides over an empty batch")
	)
	step("When the pointer hovers the selected cell", func():
		_hover(_screen_pos_of(Vector3i(7, 0, 7)))
	)
	await _settle_cursor(tool.get_node("Cursor"))
	step("Then the preview shows the selected voxel again", func():
		expect(tool.preview_cells().size() == 1, "the selected voxel offers one candidate")
		expect(tool.get_node("Cursor").visible, "the cursor shows the new batch")
	)


# A live spray drag changes the request every frame. The coalescing cursor must
# still install geometry before the release, and one motion must not freeze the
# main thread on a large inline build.
func _moving_preview() -> void:
	step("Given a plate and a spray with eight spots", func():
		_plate()
		tool.seed_spray(SEED)
		_settings.speed = 8
		cursor = tool.get_node("Cursor")
		seen_meshes = {}
		motion_max_us = 0
		_hover(center)
	)
	step("When the user presses and drags across the plate", func():
		_press(center)
	)
	for i in 8:
		var started := Time.get_ticks_usec()
		_motion(_screen_pos_of(Vector3i(i - 4, 0, i % 3)))
		motion_max_us = maxi(motion_max_us, Time.get_ticks_usec() - started)
		await get_tree().process_frame
		if cursor.mesh != null:
			seen_meshes[cursor.mesh.get_instance_id()] = true
	step("Then the cursor installed fresh geometry during the drag", func():
		expect(seen_meshes.size() >= 2, "the coalescing cursor installs while the pointer moves")
		expect(motion_max_us < 50000, "one motion never freezes the main thread")
	)
	step("When the user releases", func():
		_release(_screen_pos_of(Vector3i(4, 0, 2)))
	)


# A moving cursor must still offer the exact batch that the next press paints. A
# bounded display latency never changes the offered sample.
func _moving_click() -> void:
	step("Given a plate and a spray with five spots", func():
		_plate()
		tool.seed_spray(SEED)
		_settings.speed = 5
	)
	step("When the pointer moves across the plate while hovering", func():
		_hover(_screen_pos_of(Vector3i(1, 0, 0)))
		_hover(_screen_pos_of(Vector3i(2, 0, 1)))
		_hover(_screen_pos_of(Vector3i(3, 0, 2)))
	)
	step("When the user presses at the last hovered cell", func():
		preview = tool.preview_cells()
		_press(_screen_pos_of(Vector3i(3, 0, 2)))
	)
	step("Then the press paints exactly the offered sample", func():
		expect(preview.size() > 0, "the moving cursor offered a sample")
		expect(_sprayed_count() == preview.size(), "the press paints the offered sample alone")
		for cell in preview:
			expect(frame.get_color(cell) == State.current_color, "every offered cell took the paint material")
		_release(_screen_pos_of(Vector3i(3, 0, 2)))
	)


# A coalescing cursor shows a bounded-latency snapshot. A frame clear must hide
# it, and a late worker must not resurrect a stale mesh.
func _coalesced_clear_hides() -> void:
	var hover_cell := Vector3i(3, 0, 2)
	step("Given a spray hover on a plate", func():
		_plate()
		tool.seed_spray(SEED)
		_settings.speed = 8
		_hover(_screen_pos_of(hover_cell))
	)
	await _settle_cursor(tool.get_node("Cursor"))
	step("When the frame is cleared", func():
		frame.clear()
		tool.update_visual(tool._last_pick)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the cursor hides and holds no stale mesh", func():
		expect(tool.preview_cells().is_empty(), "the cleared frame drops the batch")
		expect(not tool.get_node("Cursor").visible, "no stale mesh resurrects after the clear")
	)


# A coalescing cursor can show an older snapshot while a newer sample for the
# same cell waits on the worker. The next press must paint the displayed
# snapshot, so the click and the visible preview never disagree.
func _display_parity() -> void:
	step("Given a plate with a displayed spray preview", func():
		_plate()
		tool.seed_spray(SEED)
		_settings.speed = 8
		cursor = tool.get_node("Cursor")
		_hover(_screen_pos_of(Vector3i(0, 0, 0)))
	)
	await _settle_cursor(cursor)
	step("Then the cursor displays the sampled snapshot A", func():
		shown_batch = tool._batch_cells.duplicate()
		expect(shown_batch.size() > 0, "the displayed batch holds cells")
		expect(cursor.installed_cells().size() == shown_batch.size(), "the installed surface holds A")
	)
	step("When the same cell rerolls and presses before the new sample installs", func():
		# Keep the installed A and its captured frame, material, and context.
		# Reset only the batch cell, so the hover samples a new batch for the
		# same cell without clearing the cursor.
		tool.seed_spray(SEED + 1)
		tool._batch_center = VoxelPicking.NONE
		_clear_preview_cache()
		_hover(_screen_pos_of(Vector3i(0, 0, 0)))
		var pending: Array[Vector3i] = tool.preview_cells()
		expect(pending != shown_batch, "the new sample B differs from A")
		expect(not cursor.is_settled(), "the new sample B builds on a worker")
		expect(cursor.installed_cells().size() == shown_batch.size(), "the new sample B is not installed yet")
		var keys: Array[Vector3i] = []
		keys.assign(cursor.installed_cells().keys())
		expect(_same_cell_set(keys, shown_batch), "the installed surface is still the displayed A")
		_press(_screen_pos_of(Vector3i(0, 0, 0)))
	)
	step("Then the click paints exactly the displayed A", func():
		expect(_same_cell_set(_sprayed_cells(), shown_batch), "the click painted the visible A")
		expect(_sprayed_count() == shown_batch.size(), "the click painted A alone")
		_release(_screen_pos_of(Vector3i(0, 0, 0)))
	)


# A lagging surface belongs to the cell that sampled it. A press on another cell
# must paint its own current batch, never the installed surface of the old cell.
func _ownership_gate() -> void:
	step("Given a displayed preview A for one cell", func():
		_plate()
		tool.seed_spray(SEED)
		_settings.speed = 8
		cursor = tool.get_node("Cursor")
		_hover(_screen_pos_of(Vector3i(0, 0, 0)))
	)
	await _settle_cursor(cursor)
	step("When the pointer moves to cell B and presses before B installs", func():
		shown_batch = tool._batch_cells.duplicate()
		_hover(_screen_pos_of(Vector3i(6, 0, 4)))
		preview = tool.preview_cells()
		expect(preview != shown_batch, "the new sample B differs from A")
		expect(cursor.installed_cells().size() == shown_batch.size(), "B is not installed yet")
		var keys: Array[Vector3i] = []
		keys.assign(cursor.installed_cells().keys())
		expect(_same_cell_set(keys, shown_batch), "the installed surface is still A")
		_press(_screen_pos_of(Vector3i(6, 0, 4)))
	)
	step("Then the press paints its own B and never A", func():
		expect(_same_cell_set(_sprayed_cells(), preview), "the press painted its own batch B")
		expect(_sprayed_count() == preview.size(), "the press painted B alone")
		_release(_screen_pos_of(Vector3i(6, 0, 4)))
	)


# A frame change replaces the document frame, so the displayed surface of the old
# frame must not stay visible.
func _display_clears() -> void:
	step("Given a plate with a displayed spray preview", func():
		_plate()
		tool.seed_spray(SEED)
		_settings.speed = 8
		cursor = tool.get_node("Cursor")
		_hover(_screen_pos_of(Vector3i(3, 0, 2)))
	)
	await _settle_cursor(cursor)
	step("When a frame is added", func():
		State.add_frame()
	)
	step("Then the cursor hides its stale surface", func():
		expect(cursor.installed_cells().is_empty(), "the frame change empties the installed cells")
		expect(not cursor.visible, "the stale preview of the old frame is hidden")
	)


# A selection change alters the allowed cells, so the displayed surface of the
# old selection must not stay visible.
func _selection_clears() -> void:
	step("Given a plate with a displayed spray preview", func():
		_plate()
		tool.seed_spray(SEED)
		_settings.speed = 8
		cursor = tool.get_node("Cursor")
		_hover(_screen_pos_of(Vector3i(3, 0, 2)))
	)
	await _settle_cursor(cursor)
	step("Then the cursor displays the old selection's snapshot A", func():
		shown_batch = tool._batch_cells.duplicate()
		expect(cursor.installed_cells().size() == shown_batch.size(), "the installed surface holds A")
	)
	step("When the selection changes", func():
		State.selection.add(Vector3i(0, 0, 0))
		State.selection_changed.emit()
		tool.update_visual(tool._last_pick)
	)
	step("Then the old selection's displayed surface is gone", func():
		# The new sample may install at once from the mesh cache, so the surface is
		# either empty or the new sample. It must never stay the old selection's A.
		var keys: Array[Vector3i] = []
		keys.assign(cursor.installed_cells().keys())
		expect(not _same_cell_set(keys, shown_batch), "the old selection's installed surface is gone")
	)


# The spray samples and expands its batch before the write. The write job must
# not expand the same context again. These cases compare the already-expanded
# write against the previous expansion path on the same cells and frame.
func _write_parity() -> void:
	var cases := [
		{
			"name": "a near chunk boundary with X symmetry",
			"center": Vector3i(-1, 0, -1), "spot": 3, "search": 3, "speed": 5,
			"axes": 1, "origin": Vector3.ZERO, "selection": [],
			"material": VoxelFrame.material(Color.RED),
		},
		{
			"name": "an even spot and search width",
			"center": Vector3i.ZERO, "spot": 4, "search": 4, "speed": 6,
			"axes": 0, "origin": Vector3.ZERO, "selection": [],
			"material": VoxelFrame.material(Color.RED),
		},
		{
			"name": "far coordinates",
			"center": Vector3i(3000, 0, -3000), "spot": 3, "search": 3, "speed": 5,
			"axes": 1, "origin": Vector3.ZERO, "selection": [],
			"material": VoxelFrame.material(Color.RED),
		},
		{
			"name": "an asymmetric selection under X symmetry",
			"center": Vector3i(1, 0, 0), "spot": 3, "search": 3, "speed": 5,
			"axes": 1, "origin": Vector3.ZERO,
			"selection": _half_selection(Vector3i(1, 0, 0)),
			"material": VoxelFrame.material(Color.RED),
		},
		{
			"name": "a full metal material",
			"center": Vector3i.ZERO, "spot": 3, "search": 3, "speed": 5,
			"axes": 1, "origin": Vector3.ZERO, "selection": [],
			"material": VoxelFrame.material(Color.RED, Color(0.5, 0.25, 0.125), 1.0, 0.25),
		},
	]
	for entry in cases:
		step("Given %s" % entry["name"], func():
			var center: Vector3i = entry["center"]
			var material: PackedFloat32Array = entry["material"]
			var axes: int = entry["axes"]
			var origin: Vector3 = entry["origin"]
			var spot: int = entry["spot"]
			var search: int = entry["search"]
			var speed: int = entry["speed"]
			_build_parity_frame(center)
			State.symmetry_axes = axes
			State.symmetry_origin = origin
			State.clear_selection()
			for cell in entry["selection"]:
				var cell_position: Vector3i = cell
				State.selection.add(cell_position)
			State.selection_changed.emit()
			State.set_material(material)
			tool.seed_spray(SEED)
			_settings.spot_diameter = spot
			_settings.spray_size = search
			_settings.speed = speed
			_hover_cell(center)
			preview = tool.preview_cells()
			expect(preview.size() > 0, "the case samples a non-empty batch")
		)
		step("When the write runs with the sampled batch", func():
			expect(tool.open_stroke() != null, "the stroke opens")
			_final_job = tool._build_job()
			_final_job.centers = preview.duplicate()
			_final_job.run()
			_reference_job = tool._build_job()
			_reference_job.centers = preview.duplicate()
			_reference_job.centers_are_final = false
			_reference_job.run()
		)
		step("Then the fast path writes the same cells, materials, and chunks", func():
			var material: PackedFloat32Array = entry["material"]
			expect(_final_job.applied_cells == _reference_job.applied_cells, "the applied cells and materials match")
			expect(_same_chunk_set(_final_job.changed_chunks, _reference_job.changed_chunks), "the changed chunks match")
			expect(_same_frame_content(_final_job.edited_frame, _reference_job.edited_frame), "the written frames match")
			for cell in _final_job.applied_cells:
				expect(_final_job.applied_cells[cell] == material, "every cell holds the captured material")
			tool._cancel_edit()
		)


# The already-expanded fast path still applies the selection mask and the
# existing-only filter. A cell outside the selection or a cell that the write
# snapshot does not hold never writes.
func _write_filters() -> void:
	step("Given a plate with one selected cell and one unselected cell", func():
		_plate()
		State.clear_selection()
		State.selection.add(Vector3i(0, 0, 0))
		State.selection_changed.emit()
		State.set_material(VoxelFrame.material(Color.RED))
		tool.seed_spray(SEED)
		expect(tool.open_stroke() != null, "the stroke opens")
	)
	step("When the final write batch holds the selected and the unselected cell", func():
		var centers: Array[Vector3i] = [Vector3i(0, 0, 0), Vector3i(1, 0, 0)]
		_final_job = tool._build_job()
		_final_job.centers = centers
		_final_job.run()
	)
	step("Then only the selected cell writes", func():
		expect(_final_job.applied_cells.has(Vector3i(0, 0, 0)), "the selected cell writes")
		expect(not _final_job.applied_cells.has(Vector3i(1, 0, 0)), "the unselected cell stays out")
	)
	step("When the write snapshot no longer holds the selected cell", func():
		_final_job.edited_frame.set_cell(Vector3i(0, 0, 0), VoxelFrame.material(Color.TRANSPARENT))
		var second = tool._build_job()
		var centers: Array[Vector3i] = [Vector3i(0, 0, 0)]
		second.centers = centers
		second.edited_frame = _final_job.edited_frame.copy_frame()
		second.run()
		_final_job = second
	)
	step("Then the existing-only filter drops the erased cell", func():
		expect(not _final_job.applied_cells.has(Vector3i(0, 0, 0)), "the erased cell stays out")
		tool._cancel_edit()
	)


# The write must not draw a random number, because the sample already consumed
# its stream. The whole spray stays one undo action with the full material.
func _write_rng_undo() -> void:
	var metal := VoxelFrame.material(Color.RED, Color(0.5, 0.25, 0.125), 1.0, 0.25)
	step("Given a mirrored, selected, full-material spray with a displayed preview", func():
		_plate()
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3.ZERO
		State.clear_selection()
		State.selection.add(Vector3i(2, 0, 0))
		State.selection.add(Vector3i(-2, 0, 0))
		State.selection_changed.emit()
		State.set_material(metal)
		tool.seed_spray(SEED)
		_settings.speed = 6
		_hover(_screen_pos_of(Vector3i(2, 0, 0)))
		preview = tool.preview_cells()
	)
	await _settle_cursor(tool.get_node("Cursor"))
	step("When the press writes the displayed batch", func():
		before = frame.copy_frame()
		_rng_before = tool._rng.state
		_history_before = State.undo_redo.get_history_count()
		_press(_screen_pos_of(Vector3i(2, 0, 0)))
		expect(tool._rng.state == _rng_before, "the write draws no random number")
		expect(_same_cell_set(_sprayed_cells(), preview), "the write paints the displayed batch")
		_release(_screen_pos_of(Vector3i(2, 0, 0)))
	)
	step("Then one undo and one redo cover the exact spray", func():
		expect(State.undo_redo.get_history_count() == _history_before + 1, "the spray records one action")
		State.undo_redo.undo()
		expect(frame.storage_data() == before.storage_data(), "one undo restores the plate")
		State.undo_redo.redo()
		for cell in preview:
			expect(frame.get_material(cell) == metal, "every sprayed cell keeps the full material")
	)


# Builds a small solid frame around one cell, so a spray sample has occupied
# cells at every tested coordinate.
func _build_parity_frame(center: Vector3i) -> void:
	State.document = VoxelDocument.new()
	frame = State.get_current_voxel_frame()
	for x in range(-4, 5):
		for y in range(0, 3):
			for z in range(-4, 5):
				frame.set_cell(center + Vector3i(x, y, z), VoxelFrame.material(Color.BLUE))


# The cells of one half-space of the parity frame. It is asymmetric under the X
# mirror, so the selection filter has a real effect.
func _half_selection(center: Vector3i) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	for x in range(center.x, center.x + 5):
		for y in range(0, 3):
			for z in range(center.z - 4, center.z + 5):
				cells.append(Vector3i(x, y, z))
	return cells


func _same_chunk_set(first: Array[Vector3i], second: Array[Vector3i]) -> bool:
	if first.size() != second.size():
		return false
	var lookup := {}
	for location in first:
		lookup[location] = true
	for location in second:
		if not lookup.has(location):
			return false
	return true


# Compares two frames by chunk content, not by chunk insertion order. The write
# path and the expansion path can group the same cells in a different order.
func _same_frame_content(first: VoxelFrame, second: VoxelFrame) -> bool:
	if first.chunks.size() != second.chunks.size():
		return false
	for location in first.chunks:
		var chunk: VoxelFrame.Chunk = first.chunks[location]
		var other: VoxelFrame.Chunk = second.chunks.get(location)
		if other == null or not chunk.equals(other):
			return false
	return true
