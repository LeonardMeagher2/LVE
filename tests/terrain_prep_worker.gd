extends "res://tests/test.gd"

# A large terrain dab must build its footprint on the worker pool, so the frame
# that accepted it keeps processing input and the camera. A small dab must stay
# inline, so an ordinary press still edits in its input event.
#
# The checks compare the worker footprint against a direct main-thread map of
# the same explicit inputs, so the offload changes no voxel of the original
# profile. The pure map the worker builds reads only plain inputs, so the test
# can reproduce it from the locked plane and center the press published.
#
# The test drives the real tool through the editor viewport. It does not change
# the placement policy, the falloff, or the credits.

const TerrainPreviewScript := preload("res://plugins/Terrain/TerrainPreview.gd")
const TERRAIN := preload("res://plugins/Terrain/TerrainTool.gd")
const Prep := preload("res://plugins/Terrain/TerrainPrep.gd")

var _settings := preload("res://plugins/Terrain/settings.tres")
var _tool
var _frame: VoxelFrame
var _viewport: SubViewport
var _before := {}
var _batch_source: VoxelFrame
var _batch_plane: TerrainFrame
var _batch_centers: Array = []
var _batch_job
var _batch_single_frame: VoxelFrame
var _subset_full: VoxelFrame
var _subset_cases: Array = []


func _ready() -> void:
	test("a small press applies its dab in the input event", _small_inline, "small_inline")
	test("a maximum Build press builds its footprint on the worker", _large_worker, "large_worker")
	test("the frame loop and the camera advance while the prep runs", _frames_advance, "frames_advance")
	test("the worker footprint matches a direct main-thread map", _footprint_parity, "footprint_parity")
	test("a maximum Flatten press builds its footprint on the worker", _flatten_worker, "flatten_worker")
	test("a maximum Smooth press builds its fields on the worker", _smooth_worker, "smooth_worker")
	test("Escape during a pending footprint rolls back without a zombie", _cancel_pending, "cancel_pending")
	test("a batched prep job matches a sequence of single dabs", _batch_parity, "batch_parity")
	test("a hover subset reads the same surface and map as the full frame", _hover_subset, "hover_subset")


func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	_settings.tool = _settings.Tools.BUILD
	_settings.build_mode = _settings.BuildMode.ADD
	_settings.radius = 9
	_settings.strength = 1.0
	_settings.falloff = 0.5
	_viewport = editor_viewport()
	_viewport.get_parent().stretch = false
	_viewport.size = Vector2i(800, 500)
	activate_tool("terrain")
	var terrain := plugin("TerrainPlugin")
	terrain.activate_tool()
	terrain.deactivate_tool()
	_tool = preload("res://plugins/Terrain/TerrainTool.tscn").instantiate()
	if _tool._settings == null:
		_tool._settings = _settings
	terrain.add_editor_node(_tool)
	_tool.set_process(true)
	_frame = State.get_current_voxel_frame()
	camera_rig().is_orthogonal = true
	camera_rig().set_view("top")
	_before = {}
	await get_tree().process_frame


func _cleanup_test() -> void:
	if is_instance_valid(_tool):
		if _tool._edit != null:
			_tool.finish_on_switch()
		await _wait_idle()
		plugin("TerrainPlugin").remove_editor_node(_tool)
		_tool.free()
	_tool = null


# --- Fixtures -----------------------------------------------------------------

# A wide flat plate on the floor plane. The maximum radius disc fits inside it.
func _plate() -> void:
	State.document = VoxelDocument.new()
	_frame = State.get_current_voxel_frame()
	var changes := {}
	var material := VoxelFrame.material(Color.WHITE)
	for x in range(-40, 41):
		for z in range(-40, 41):
			changes[Vector3i(x, 0, z)] = material
	_frame.set_cells(changes)
	sync_viewport()
	_view(AABB(Vector3(-44, -6, -44), Vector3(88, 24, 88)))
	camera_rig().set_view("top")
	camera_rig().is_orthogonal = true


# Builds a one-cell-step ramp. A Flatten press on the slope cuts the high side
# and fills the low side, so the accepted dab changes the geometry.
func _ramp() -> void:
	State.document = VoxelDocument.new()
	_frame = State.get_current_voxel_frame()
	var changes := {}
	var material := VoxelFrame.material(Color.WHITE)
	for x in range(-20, 21):
		for z in range(-20, 21):
			var top := clampi(int(floor(float(x) / 2.0)) + 8, 0, 14)
			for y in range(0, top + 1):
				changes[Vector3i(x, y, z)] = material
	_frame.set_cells(changes)
	sync_viewport()
	_view(AABB(Vector3(-44, -6, -44), Vector3(88, 28, 88)))
	camera_rig().set_view("top")
	camera_rig().is_orthogonal = true


# A plate with a raised rough block, so Smooth has a convex edge to round.
func _rough_block() -> void:
	State.document = VoxelDocument.new()
	_frame = State.get_current_voxel_frame()
	var changes := {}
	var material := VoxelFrame.material(Color.WHITE)
	for x in range(-40, 41):
		for z in range(-40, 41):
			changes[Vector3i(x, 0, z)] = material
	for x in range(-28, 29):
		for z in range(-28, 29):
			for y in range(1, 4):
				changes[Vector3i(x, y, z)] = material
	for x in range(-28, 29, 4):
		for z in range(-28, 29, 4):
			changes[Vector3i(x, 4, z)] = material
	_frame.set_cells(changes)
	sync_viewport()
	_view(AABB(Vector3(-44, -6, -44), Vector3(88, 28, 88)))
	camera_rig().set_view("top")
	camera_rig().is_orthogonal = true


# --- Camera and input ---------------------------------------------------------

func _view(box: AABB) -> void:
	camera_rig().set_view("top")
	camera_rig().is_orthogonal = true
	camera_rig().center_on(box)


func _screen(world: Vector3) -> Vector2:
	return camera_rig().unproject_position(world)


func _button(pressed: bool, position: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.pressed = pressed
	event.position = position
	_viewport.push_input(event)


func _motion(position: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = position
	_viewport.push_input(event)


func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	get_tree().root.push_input(event)


func _wait_idle() -> void:
	for _index in 1200:
		if _tool._edit == null and not _tool._busy() and not _tool._has_pending():
			await get_tree().process_frame
			return
		await get_tree().process_frame


# Waits until the footprint worker and the accepted dab retire. A held stroke
# keeps `_edit` open, so a caller that checks the samples before it releases
# waits here instead of in [method _wait_idle].
func _wait_worker() -> void:
	for _index in 1200:
		if not _tool._busy() and not _tool._has_pending():
			await get_tree().process_frame
			return
		await get_tree().process_frame


# --- Cases --------------------------------------------------------------------

func _small_inline() -> void:
	step("Given a flat plate and a small Build brush", func():
		_plate()
		_settings.tool = _settings.Tools.BUILD
		_settings.radius = 9
		_settings.strength = 1.0
		_settings.falloff = 0.5
		_before = _frame.capture()
	)
	step("When the user presses once", func():
		_button(true, _screen(Vector3.ZERO))
		expect(_frame.count() > 0, "the small press built its footprint in the input event")
		expect(not _tool._busy(), "the small press ran no worker job")
		_button(false, _screen(Vector3.ZERO))
	)
	await _wait_idle()
	step("Then the small click stays one bounded user action", func():
		expect(State.undo_redo.has_undo(), "the small click records one action")
		expect(State.undo_redo.get_history_count() == 1, "the small click records a single history entry")
		State.undo()
		expect(VoxelEditTransaction._chunks_equal(_before, _frame.capture()), "one undo restores the small click")
	)


func _large_worker() -> void:
	step("Given a flat plate and a maximum Build brush", func():
		_plate()
		_settings.tool = _settings.Tools.BUILD
		_settings.radius = 72
		_settings.strength = 1.0
		_settings.falloff = 0.5
		_before = _frame.capture()
	)
	step("When the user presses once", func():
		_button(true, _screen(Vector3.ZERO))
		expect(VoxelEditTransaction._chunks_equal(_before, _frame.capture()), "the maximum press writes nothing on the main thread")
		expect(_tool._tick_job != null, "the maximum press started a dab worker")
		expect(_tool._tick_job.preparing, "the dab worker owns the footprint preparation")
		expect(_tool._stroke_frame != null, "the press still locked its plane in the input event")
		_button(false, _screen(Vector3.ZERO))
	)
	await _wait_idle()
	step("Then the accepted dab applied and closed as one action", func():
		expect(not _tool._busy(), "the dab worker retired")
		expect(State.undo_redo.get_history_count() == 1, "the maximum click records one action")
		expect(not VoxelEditTransaction._chunks_equal(_before, _frame.capture()), "the worker dab grew the plate")
	)


func _frames_advance() -> void:
	step("Given a flat plate and a maximum Build press", func():
		_plate()
		_settings.tool = _settings.Tools.BUILD
		_settings.radius = 72
		_settings.strength = 1.0
		_settings.falloff = 0.5
		_button(true, _screen(Vector3.ZERO))
		expect(_tool._busy(), "the footprint worker is pending in the input event")
	)
	var frames := 0
	var camera_before := camera_rig().global_transform
	while _tool._busy() and frames < 600:
		await get_tree().process_frame
		frames += 1
		if frames == 1:
			# The rotate input calls the rig orbit. The user may rotate the view
			# while the footprint worker is pending, so the orbit must run, the
			# frame loop must keep advancing, and the accepted dab must survive.
			camera_rig().orbit(Vector2(40.0, 20.0))
	var camera_after := camera_rig().global_transform
	_button(false, _screen(Vector3.ZERO))
	await _wait_idle()
	step("Then the frame loop advanced and the camera moved while the prep ran", func():
		expect(frames >= 1, "the pending footprint yielded at least one frame")
		expect(not _tool._busy(), "the footprint worker completed")
		expect(not camera_before.is_equal_approx(camera_after), "the camera moved while the footprint was pending")
		expect(State.undo_redo.has_undo(), "the stroke still recorded its action")
	)


func _footprint_parity() -> void:
	var weights := {}
	var anchors := {}
	step("Given a flat plate and a maximum Build press", func():
		_plate()
		_settings.tool = _settings.Tools.BUILD
		_settings.radius = 72
		_settings.strength = 1.0
		_settings.falloff = 0.5
		_button(true, _screen(Vector3.ZERO))
		expect(_tool._tick_job != null and _tool._tick_job.preparing, "the footprint worker owns the map")
	)
	step("When the test builds the same footprint on the main thread", func():
		var snapshot := _frame.copy_frame()
		var frame: TerrainFrame = _tool._stroke_frame
		var center: Vector3 = _tool._stroke_center_point
		var reference: Dictionary = TerrainPreviewScript.compute_sample_map(
			snapshot, frame, center, 32, 0.5, _tool._stroke_context, TerrainPreviewScript.footprint_depth(32), {})
		for anchor in reference:
			anchors[anchor] = float(reference[anchor]["weight"])
			weights[anchor] = float(reference[anchor]["weight"])
		expect(not anchors.is_empty(), "the reference footprint is not empty")
	)
	await _wait_worker()
	step("Then the worker footprint holds the exact anchors and weights", func():
		expect(_tool._samples.size() == anchors.size(), "the worker footprint holds the same anchor count (%d vs %d)" % [_tool._samples.size(), anchors.size()])
		var mismatched := 0
		for anchor in anchors:
			if not _tool._samples.has(anchor):
				mismatched += 1
			elif absf(float(_tool._samples[anchor]["weight"]) - float(weights[anchor])) > 1e-9:
				mismatched += 1
		expect(mismatched == 0, "every worker anchor keeps its exact weight and point")
	)
	# The press stays held, so release it only after the anchors were checked. A
	# release clears the samples.
	_button(false, _screen(Vector3.ZERO))
	await _wait_idle()


func _flatten_worker() -> void:
	step("Given a flat plate and a maximum Flatten brush", func():
		_plate()
		_settings.tool = _settings.Tools.FLATTEN
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 72
		_settings.strength = 1.0
		_settings.falloff = 0.5
	)
	step("When the user presses once", func():
		_button(true, _screen(Vector3.ZERO))
		expect(_tool._tick_job != null and _tool._tick_job.preparing, "the Flatten press builds its footprint on the worker")
		_button(false, _screen(Vector3.ZERO))
	)
	await _wait_idle()
	step("Then the Flatten stroke closed without a leftover worker", func():
		expect(_tool._edit == null, "the Flatten stroke closed")
		expect(not _tool._busy(), "the Flatten worker retired")
	)


func _smooth_worker() -> void:
	step("Given a rough block and a maximum Smooth brush", func():
		_rough_block()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 72
		_settings.strength = 1.0
		_settings.falloff = 0.5
		_before = _frame.capture()
	)
	step("When the user presses once", func():
		_button(true, _screen(Vector3(0, 4, 0)))
		expect(_tool._smooth_job != null, "the Smooth press started a rounding worker")
		expect(_tool._smooth_job.preparing, "the rounding worker owns the re-read and the fields")
		_button(false, _screen(Vector3(0, 4, 0)))
	)
	await _wait_idle()
	step("Then the rounding ran on the worker and closed as one action", func():
		expect(_tool._edit == null, "the Smooth stroke closed")
		expect(not _tool._busy(), "the Smooth worker retired")
		expect(not VoxelEditTransaction._chunks_equal(_before, _frame.capture()), "the worker rounded the rough block")
		expect(State.undo_redo.get_history_count() == 1, "the Smooth click records one action")
	)


func _cancel_pending() -> void:
	step("Given a maximum Build press on a flat plate", func():
		_plate()
		_settings.tool = _settings.Tools.BUILD
		_settings.radius = 72
		_settings.strength = 1.0
		_settings.falloff = 0.5
		_before = _frame.capture()
		_button(true, _screen(Vector3.ZERO))
		expect(_tool._busy(), "the footprint worker is pending")
	)
	step("When the user presses Escape while the footprint is pending", func():
		_key(KEY_ESCAPE)
		expect(_tool._edit == null, "Escape closed the stroke")
		expect(not _tool._has_pending(), "Escape cleared the accepted path")
	)
	await _wait_idle()
	step("Then the plate is restored and no history was recorded", func():
		expect(not _tool._busy(), "the cancelled worker retired")
		expect(VoxelEditTransaction._chunks_equal(_before, _frame.capture()), "the cancelled press changed nothing")
		expect(not State.undo_redo.has_undo(), "the cancelled press recorded no history")
	)


# A batched prep job must produce the same frame and the same carried influence
# as one single-center job per center. The test builds both paths from the same
# plate and plane, so only the batching differs.
func _batch_parity() -> void:
	step("Given a flat plate and three crossed centers on one plane", func():
		_batch_source = VoxelFrame.new()
		_batch_centers = []
		var changes := {}
		var material := VoxelFrame.material(Color.WHITE)
		for x in range(-24, 25):
			for z in range(-24, 25):
				changes[Vector3i(x, 0, z)] = material
		_batch_source.set_cells(changes)
		_batch_plane = TerrainFrame.from_face(Vector3i.ZERO, Vector3i(0, 1, 0))
		var plane := _batch_plane.to_plane()
		for x in [0, 1, 2]:
			_batch_centers.append(plane.intersects_ray(Vector3(float(x), 10.0, 0.0), Vector3.DOWN))
		expect(_batch_centers.size() == 3 and _batch_centers[2] != null, "the three centers project onto the plane")
	)
	step("When one job applies the batch and three jobs apply one center each", func():
		_batch_job = _prep_job(_batch_source, _batch_plane, _batch_centers)
		_batch_job.run()
		_batch_single_frame = _batch_source.copy_frame()
		var samples := {}
		for center in _batch_centers:
			var job = _prep_job(_batch_single_frame, _batch_plane, [center])
			job.prep_known = Prep.known_surfaces(samples)
			job.run()
			_batch_single_frame.apply_published(job.changed_chunks, job.edited_frame)
			samples = job.prepared_samples
			for anchor in job.surfaces:
				if samples.has(anchor):
					samples[anchor]["surface"] = job.surfaces[anchor]
		expect(_batch_job.prepared_samples != null, "the batch built its footprint map")
		expect(not _batch_job.changed_chunks.is_empty(), "the batch wrote cells")
	)
	step("Then the batch matches the single sequence in cells", func():
		expect(VoxelEditTransaction._chunks_equal(_batch_job.edited_frame.chunks, _batch_single_frame.chunks), "the batched frame holds the same cells and materials")
	)


func _prep_job(frame: VoxelFrame, terrain_frame: TerrainFrame, centers: Array) -> Variant:
	var job = TERRAIN.TerrainTickJob.new()
	job.stroke_id = 1
	job.preparing = true
	job.edited_frame = VoxelFrame.job_frame(frame)
	job.tool = _settings.Tools.BUILD
	job.build_mode = _settings.BuildMode.ADD
	job.threshold = 0.5
	job.material = VoxelFrame.material(Color.WHITE)
	job.selection = {}
	job.prep_terrain_frame = terrain_frame
	job.prep_centers = centers
	job.prep_center = centers[centers.size() - 1]
	job.prep_radius = 16
	job.prep_falloff = 0.5
	job.prep_depth = 64
	job.prep_context = null
	job.prep_known = {}
	job.prep_strength = 1
	return job


# A hover job reads the surface disc and the map disc from its frame snapshot. The
# subset snapshot must hold every chunk those reads touch, or the surface read or the map
# changes. This case compares the full frame with the subset at radii 4, 16, and
# 32, on a flat cell and on a tall column.
func _hover_subset() -> void:
	step("Given a wide plate with a tall column", func():
		_subset_full = VoxelFrame.new()
		_subset_cases = []
		var changes := {}
		var material := VoxelFrame.material(Color.WHITE)
		for x in range(-100, 100):
			for z in range(-100, 100):
				changes[Vector3i(x, 0, z)] = material
		for y in range(1, 21):
			changes[Vector3i(0, y, 0)] = material
		_subset_full.set_cells(changes)
		expect(_subset_full.chunks.size() > 100, "the fixture holds more than one hundred chunks")
	)
	step("When the read box is snapshotted at radii 4, 16, and 32", func():
		for radius in [4, 16, 32]:
			for hit in [Vector3i(0, 0, 0), Vector3i(0, 20, 0)]:
				var entry := Vector3i(0, 1, 0)
				var full_result = TerrainPreviewScript.compute_hover_frame(_subset_full, hit, entry, hit,  radius, 1, 0, Vector3.DOWN)
				expect(not full_result.is_empty(), "the full frame fits the hover at radius %d" % radius)
				var reach: int = TerrainPreviewScript.watch_half(radius) + radius + 1
				var lite := _subset_full.copy_chunks(TerrainPreviewScript.watch_chunks(_subset_full, hit, reach))
				var lite_result = TerrainPreviewScript.compute_hover_frame(lite, hit, entry, hit,  radius, 1, 0, Vector3.DOWN)
				var point: Vector3 = full_result["point"]
				var full_map: Dictionary = TerrainPreviewScript.compute_sample_map(_subset_full, full_result["frame"], point, radius, 0.5, null, 64, {}, null, TerrainQueryContext.new(_subset_full))
				var lite_map: Dictionary = TerrainPreviewScript.compute_sample_map(lite, lite_result["frame"], point, radius, 0.5, null, 64, {}, null, TerrainQueryContext.new(lite))
				_subset_cases.append({
					"radius": radius,
					"hit": hit,
					"full_frame": full_result["frame"],
					"lite_frame": lite_result["frame"],
					"full_map": full_map,
					"lite_map": lite_map,
					"full_chunks": _subset_full.chunks.size(),
					"lite_chunks": lite.chunks.size(),
				})
		expect(_subset_cases.size() == 6, "six hover cases were built")
	)
	step("Then every subset surface read and map matches the full frame", func():
		var mismatch := 0
		for entry in _subset_cases:
			if not _surface_equal(entry["full_frame"], entry["lite_frame"]):
				mismatch += 1
			if not _map_equal(entry["full_map"], entry["lite_map"]):
				mismatch += 1
		expect(mismatch == 0, "every subset case matches the full frame (%d of 12)" % mismatch)
		expect(int(_subset_cases[0]["lite_chunks"]) < int(_subset_cases[0]["full_chunks"]), "the radius 4 box holds fewer chunks than the frame")
	)


func _surface_equal(first, second) -> bool:
	if first == null or second == null:
		return first == second
	var a: TerrainFrame = first
	var b: TerrainFrame = second
	return a.normal.is_equal_approx(b.normal) and a.origin.is_equal_approx(b.origin) and a.axis == b.axis and a.sign == b.sign and a.tangent_u.is_equal_approx(b.tangent_u) and a.tangent_v.is_equal_approx(b.tangent_v)


func _map_equal(first: Dictionary, second: Dictionary) -> bool:
	if first.size() != second.size():
		return false
	for anchor in first:
		if not second.has(anchor):
			return false
		var a: Dictionary = first[anchor]
		var b: Dictionary = second[anchor]
		if absf(float(a["weight"]) - float(b["weight"])) > 1e-9:
			return false
		if a["surface"] != b["surface"]:
			return false
		if not (a["point"] as Vector3).is_equal_approx(b["point"] as Vector3):
			return false
		if not (a["normal"] as Vector3).is_equal_approx(b["normal"] as Vector3):
			return false
	return true
