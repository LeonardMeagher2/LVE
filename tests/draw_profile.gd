extends "res://tests/test.gd"

# Focused, opt-in profile of the maximum-diameter brush frame gap. This scene is
# a probe, not a regression test. It measures one configuration per process so
# the numbers stay isolated.
#
# With no environment set it runs a small configuration that the full suite can
# afford. Run one configuration on the second monitor with:
#
#   $env:LVE_PROF_DIAMETER="64"; $env:LVE_PROF_SHAPE="cube"
#   godot --path . --screen 1 res://tests/draw_profile.tscn
#
# Environment:
#   LVE_PROF_SHAPE      cube | sphere            (default cube)
#   LVE_PROF_DIAMETER   1..64                    (default 9)
#   LVE_PROF_MODE       continuous | burst       (default continuous)
#   LVE_PROF_VIEWPORTS  1 | 2                    (default 1)
#   LVE_PROF_MOTIONS    int                      (default 16, or 4 for burst)
#   LVE_PROF_MODEL      cube side                (default 32)
#   LVE_PROF_RENDERER   on | off                 (default on)
#   LVE_PROF_MATERIALS  int                      (default 1)
#   LVE_PROF_SMOOTH     1                        (default off)
#   LVE_PROF_ISOLATE    1                        (default off)
#   LVE_PROF_STAGES     1                        (default off)
#   LVE_PROF_TAG        label for the run
#
# The renderer on/off pair separates the surface work from the edit publication
# and UI work. The idle interval is the vsync floor. Nothing here changes
# production behavior. The extra renderer subclass only times its own
# `_process`, so the real renderer path is preserved.

const BUILDER := preload("res://Globals/Rendering/VoxelMeshBuilder.gd")
const BrushScript := preload("res://plugins/brush/BrushTool.gd")
const VIEWPORT_SCENE := preload("res://ui/Viewport/Viewport.tscn")
const VOXEL_MESH := preload("res://VoxelMesh.tres")
const IDLE_FRAMES := 40
const SIGNATURE_REPEATS := 20


# Test-only wrapper. It measures the main-thread cost of the renderer's own
# `_process`, which the frame gap hides. It adds no behavior.
class ProfRenderer extends VoxelRenderer:
	var process_us := 0
	var frames := 0
	var max_process_us := 0
	var last_us := 0

	func _process(delta: float) -> void:
		var started_us := Time.get_ticks_usec()
		super._process(delta)
		var elapsed_us := Time.get_ticks_usec() - started_us
		process_us += elapsed_us
		max_process_us = maxi(max_process_us, elapsed_us)
		last_us = elapsed_us
		frames += 1


var shape := BrushToolSettings.BrushShape.CUBE
var diameter := 9
var mode := "continuous"
var viewports := 1
var motions := 16
var model_side := 32
var renderer_on := true
var stages := false
var tag := ""
var materials := 1
var smooth := false
var isolate_renderers := false

var frame: VoxelFrame
var tool: Node
var prof: ProfRenderer
var extras: Array[VoxelRenderer] = []
var extra_profs: Array[ProfRenderer] = []

var measuring := false
var last_frame_us := 0
var longest_frame_us := 0
var frame_count := 0
var idle_us: Array[int] = []
var stroke_us: Array[int] = []
var max_pending := 0
var max_jobs := 0
var max_installed := 0
var max_retired := 0
var installed_prev := 0
var gap_renderer_us := 0
var gap_pending := 0
var gap_jobs := 0
var gap_publish_us := 0
var max_publish_us := 0
var publish_intervals := 0
var observed_pub_seq := 0
var last_interval_publication_us := 0
var emitted_entries := 0
var unique_chunks := 0
var chunk_positions: Array[Vector3i] = []
var model_us := 0
var pattern_us := 0
var burst_us := 0
var edit_avg_us := 0
var edit_worst_us := 0
var visible_avg_us := 0
var visible_worst_us := 0
var run_done := false


func _ready() -> void:
	timeout = 300.0
	_read_config()
	test("maximum-brush frame gap profile", _run)


func _process(_delta: float) -> void:
	# Consume a publication once. The brush tool publishes after this node's
	# `_process`, so a publication is seen one frame later. The sequence marks it
	# consumed, so an idle frame reports zero.
	var publication_us := _consume_publication()
	last_interval_publication_us = publication_us
	if not measuring:
		return
	var now := Time.get_ticks_usec()
	var interval := now - last_frame_us
	stroke_us.append(interval)
	if interval > longest_frame_us:
		longest_frame_us = interval
		if prof:
			# The renderer ran after this sample last frame, so its last time is
			# the renderer share of the interval just measured.
			gap_renderer_us = prof.last_us
			gap_pending = prof._pending_surface_keys.size()
			gap_jobs = prof._surface_jobs.size()
		gap_publish_us = publication_us
	last_frame_us = now
	frame_count += 1
	if prof:
		max_pending = maxi(max_pending, prof._pending_surface_keys.size())
		max_jobs = maxi(max_jobs, prof._surface_jobs.size())
		max_retired = maxi(max_retired, prof._retired_chunk_instances.size())
		var displayed := prof._displayed_surface_keys.size()
		max_installed = maxi(max_installed, displayed - installed_prev)
		installed_prev = displayed
	if publication_us > 0:
		publish_intervals += 1
	max_publish_us = maxi(max_publish_us, publication_us)


# Return the publication duration for this interval, or zero. The sequence marks
# the publication consumed, so it is never counted twice.
func _consume_publication() -> int:
	var current := BrushScript.profile_finish_seq
	if current == observed_pub_seq:
		return 0
	observed_pub_seq = current
	return BrushScript.profile_finish_us


func _run() -> void:
	step("Given the profile configuration", func():
		_print_display()
	)
	step("Given a controlled model and the real renderer", func():
		_build_model()
		_install_renderers()
	)
	await _settle_all()
	step("Given the configured brush", func():
		_prepare_tool()
	)
	await _measure_idle()
	step("Then the idle frame interval is recorded", func():
		_print_idle()
	)
	step("When the user draws the configured stroke", func():
		_run_stroke()
	)
	while not run_done:
		await get_tree().process_frame
	step("Then the stroke reports its stages", func():
		_print_stroke()
	)
	if stages:
		step("When the cost stages are timed in isolation", func():
			_print_stages()
		)
	# Two frames after the stroke, so the probe consumes the final publication
	# before the idle check.
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then an idle interval does not inherit a publication", func():
		expect(publish_intervals >= 1, "the stroke published at least one edit")
		expect(last_interval_publication_us == 0, "an idle frame after the stroke carries no publication")
	)
	step("Then the profile hook is restored", func():
		BrushScript.profile_enabled = false
		BrushScript.profile_finish_us = 0
		BrushScript.profile_finish_seq = 0
		expect(not BrushScript.profile_enabled, "the brush profiling hook is off")
	)


func _read_config() -> void:
	tag = OS.get_environment("LVE_PROF_TAG")
	var shape_name := OS.get_environment("LVE_PROF_SHAPE")
	if shape_name == "sphere":
		shape = BrushToolSettings.BrushShape.SPHERE
	diameter = _env_int("LVE_PROF_DIAMETER", 9)
	mode = OS.get_environment("LVE_PROF_MODE")
	if mode == "":
		mode = "continuous"
	viewports = _env_int("LVE_PROF_VIEWPORTS", 1)
	model_side = _env_int("LVE_PROF_MODEL", 32)
	motions = _env_int("LVE_PROF_MOTIONS", 4 if mode == "burst" else 16)
	renderer_on = OS.get_environment("LVE_PROF_RENDERER") != "off"
	stages = OS.get_environment("LVE_PROF_STAGES") == "1"
	materials = _env_int("LVE_PROF_MATERIALS", 1)
	smooth = OS.get_environment("LVE_PROF_SMOOTH") == "1"
	isolate_renderers = OS.get_environment("LVE_PROF_ISOLATE") == "1"


func _env_int(name: String, fallback: int) -> int:
	var raw := OS.get_environment(name)
	return int(raw) if raw != "" else fallback


func _print_display() -> void:
	var screen := DisplayServer.window_get_current_screen()
	print("MEASURE config: tag=%s shape=%d diameter=%d mode=%s viewports=%d motions=%d model=%d materials=%d smooth=%s renderer=%s stages=%s" % [
		tag, shape, diameter, mode, viewports, motions, model_side, materials, str(smooth), str(renderer_on), str(stages),
	])
	print("MEASURE display: headless=%s driver=%s api=%s adapter=%s vendor=%s screen=%d screens=%d refresh=%.2f size=%s vsync=%d" % [
		DisplayServer.get_name(),
		"headless" if DisplayServer.get_name() == "headless" else "windowed",
		RenderingServer.get_video_adapter_api_version(),
		RenderingServer.get_video_adapter_name(),
		RenderingServer.get_video_adapter_vendor(),
		screen, DisplayServer.get_screen_count(),
		DisplayServer.screen_get_refresh_rate(screen),
		str(DisplayServer.screen_get_size(screen)),
		DisplayServer.window_get_vsync_mode(),
	])


func _build_model() -> void:
	var started_us := Time.get_ticks_usec()
	State.document = VoxelDocument.new()
	State.document.smooth_normals = smooth
	frame = State.get_current_voxel_frame()
	var palette: Array[PackedFloat32Array] = []
	for index in materials:
		palette.append(VoxelFrame.material(Color.from_rgba8(index * 3, 255 - index * 3, index * 2), Color.BLACK, 0.2, 0.4))
	var cells := {}
	for z in model_side:
		for y in model_side:
			for x in model_side:
				cells[Vector3i(x, y, z)] = palette[(x + y + z) % materials]
	frame.set_cells(cells)
	# A direct frame write does not dirty the document bounds. The brush tool
	# sets the same flag after it restores an edited frame.
	State.document._bounds_dirty = true
	model_us = Time.get_ticks_usec() - started_us
	camera_rig().configure()
	camera_rig().set_view("top")


func _install_renderers() -> void:
	var scene := viewport_scene()
	if renderer_on:
		var old: VoxelRenderer = scene.get_node_or_null("VoxelRenderer")
		var shared_mesh: Mesh = old.mesh if old else VOXEL_MESH
		if old:
			old.free()
		prof = ProfRenderer.new()
		prof.name = "VoxelRenderer"
		prof.mesh = shared_mesh
		scene.add_child(prof)
	if viewports >= 2:
		var second: Node = VIEWPORT_SCENE.instantiate()
		main.add_child(second)
		var second_scene: Node3D = second.get_node("PanelContainer/SubViewportContainer/Viewport/ViewportScene")
		var old_second: VoxelRenderer = second_scene.get_node("VoxelRenderer")
		var second_mesh: Mesh = old_second.mesh
		old_second.free()
		var second_prof := ProfRenderer.new()
		second_prof.name = "VoxelRenderer"
		second_prof.mesh = second_mesh
		second_scene.add_child(second_prof)
		extras.append(second_prof)
		extra_profs.append(second_prof)
	if isolate_renderers:
		_isolate_renderers()


# Remove every other surface renderer from the edit notification, so the
# publication runs on the configured renderer count alone. Diagnostic only. The
# renderers stay in the tree, so no other node holds a freed reference.
func _isolate_renderers() -> void:
	var removed := 0
	for connection in State.chunks_changed.get_connections():
		var callable: Callable = connection["callable"]
		var object: Object = callable.get_object()
		if object is VoxelRenderer and object != prof and not extras.has(object):
			State.chunks_changed.disconnect(callable)
			removed += 1
	print("MEASURE isolate: disconnected %d extra renderers" % removed)


func _prepare_tool() -> void:
	select_toolbar_item("Toolbar", "Pencil")
	tool = plugin("BrushPlugin")._brush_tool
	tool._settings.shape = shape
	tool._settings._cached_pattern = {}
	plugin("BrushPlugin")._options.get_node("Diameter").value = diameter
	expect(tool._settings.diameter == diameter, "the brush uses the configured diameter")
	expect(tool._settings.shape == shape, "the brush uses the configured shape")
	# The pattern is built once and cached, so the stroke measures its steady
	# state. Above diameter sixteen the settings do not cache the pattern, so the
	# first job would otherwise build it inside the stroke.
	var started_us := Time.get_ticks_usec()
	var pattern := BrushToolSettings.build_pattern(diameter, shape)
	tool._settings.cache_pattern(diameter, shape, pattern, pattern.keys())
	pattern_us = Time.get_ticks_usec() - started_us
	BrushScript.profile_enabled = true
	State.chunks_changed.connect(_on_chunks_changed)


func _measure_idle() -> void:
	idle_us.clear()
	# Warm up past the renderer build, the grid rebuild, and the first draws.
	for index in 10:
		await get_tree().process_frame
	var prev := Time.get_ticks_usec()
	for index in IDLE_FRAMES:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		idle_us.append(now - prev)
		prev = now


func _print_idle() -> void:
	var sorted := idle_us.duplicate()
	sorted.sort()
	var median: int = sorted[sorted.size() / 2]
	var p95: int = sorted[mini(sorted.size() - 1, int(sorted.size() * 0.95))]
	print("MEASURE idle: frames=%d median %d us, p95 %d us, min %d us, max %d us, fps %.1f" % [
		idle_us.size(), median, p95, sorted[0], sorted[sorted.size() - 1],
		1000000.0 / maxf(1.0, float(median)),
	])
	print("MEASURE model: %d cells in %d chunks, %d us to build, pattern %d cells in %d us" % [
		frame.count(), frame.chunks.size(), model_us, tool._settings._cached_pattern.size(), pattern_us,
	])


func _origin() -> Vector3:
	return Vector3(model_side * 0.25, model_side * 0.5, model_side * 0.5)


func _run_stroke() -> void:
	longest_frame_us = 0
	frame_count = 0
	stroke_us.clear()
	gap_renderer_us = 0
	gap_pending = 0
	gap_jobs = 0
	gap_publish_us = 0
	max_publish_us = 0
	publish_intervals = 0
	last_interval_publication_us = 0
	observed_pub_seq = BrushScript.profile_finish_seq
	if prof:
		prof.process_us = 0
		prof.frames = 0
		prof.max_process_us = 0
	for extra_prof in extra_profs:
		extra_prof.process_us = 0
		extra_prof.frames = 0
		extra_prof.max_process_us = 0
	max_pending = 0
	max_jobs = 0
	max_installed = 0
	max_retired = 0
	installed_prev = prof._displayed_surface_keys.size() if prof else 0
	emitted_entries = 0
	unique_chunks = 0
	chunk_positions = []
	var origin := _origin()
	var started_us := Time.get_ticks_usec()
	measuring = true
	_button(origin, true)
	# Reset the frame mark here, or the first frame counts the idle time since
	# the last measured frame.
	last_frame_us = Time.get_ticks_usec()
	if mode == "burst":
		var burst_started := Time.get_ticks_usec()
		for step_index in motions:
			_motion(Vector3(origin.x + step_index + 1, origin.y, origin.z))
		burst_us = Time.get_ticks_usec() - burst_started
		await _settle_tool()
		edit_worst_us = Time.get_ticks_usec() - started_us - burst_us
		edit_avg_us = edit_worst_us
		await _settle_all()
		visible_worst_us = Time.get_ticks_usec() - started_us - burst_us
		visible_avg_us = visible_worst_us
	else:
		var edit_total := 0
		var visible_total := 0
		for step_index in motions:
			var target := Vector3(origin.x + step_index + 1, origin.y, origin.z)
			var motion_started := Time.get_ticks_usec()
			_motion(target)
			await _settle_tool()
			var edit_us := Time.get_ticks_usec() - motion_started
			await _settle_all()
			var visible_us := Time.get_ticks_usec() - motion_started
			edit_total += edit_us
			visible_total += visible_us
			edit_worst_us = maxi(edit_worst_us, edit_us)
			visible_worst_us = maxi(visible_worst_us, visible_us)
			last_frame_us = Time.get_ticks_usec()
		edit_avg_us = edit_total / motions
		visible_avg_us = visible_total / motions
	measuring = false
	_button(Vector3(origin.x + motions, origin.y, origin.z), false)
	await _settle_tool()
	run_done = true


func _print_stroke() -> void:
	print("MEASURE stroke: mode=%s motions=%d, queue %d us, edit avg %d us worst %d us, visible avg %d us worst %d us" % [
		mode, motions, burst_us, edit_avg_us, edit_worst_us, visible_avg_us, visible_worst_us,
	])
	var sorted := stroke_us.duplicate()
	sorted.sort()
	var stroke_p50: int = sorted[sorted.size() / 2] if not sorted.is_empty() else 0
	var stroke_p95: int = sorted[mini(sorted.size() - 1, int(sorted.size() * 0.95))] if not sorted.is_empty() else 0
	print("MEASURE gap: longest frame %d ms, p50 %d us, p95 %d us over %d frames" % [
		longest_frame_us / 1000, stroke_p50, stroke_p95, frame_count,
	])
	if prof:
		print("MEASURE gap attribution: worst frame renderer share %d us, publish %d us, pending %d, jobs %d" % [
			gap_renderer_us, gap_publish_us, gap_pending, gap_jobs,
		])
	else:
		print("MEASURE gap attribution: worst frame publish %d us" % gap_publish_us)
	print("MEASURE chunks: emitted entries %d, unique %d" % [emitted_entries, unique_chunks])
	print("MEASURE publish: finish_edit worst %d us, intervals with a publication %d" % [max_publish_us, publish_intervals])
	if prof:
		var total_us: int = prof.process_us
		var worst_us: int = prof.max_process_us
		for extra_prof in extra_profs:
			total_us += extra_prof.process_us
			worst_us = maxi(worst_us, extra_prof.max_process_us)
		print("MEASURE renderer: process total %d us over %d frames, max frame %d us, peak pending %d, peak jobs %d, max installed per frame %d, peak retired %d" % [
			total_us, prof.frames, worst_us, max_pending, max_jobs, max_installed, max_retired,
		])
	else:
		print("MEASURE renderer: off")


func _print_stages() -> void:
	var use_smooth := State.document.smooth_normals
	var chunks: Array[Vector3i] = chunk_positions
	if chunks.is_empty():
		for location in frame.chunks.keys():
			chunks.append(location)
			if chunks.size() >= 8:
				break
	var signature_us := _time_repeat(func():
		for location in chunks:
			VoxelRenderer._signature(frame, location, use_smooth)
	, SIGNATURE_REPEATS)
	var copy_us := _time_repeat(func(): frame.copy_frame(), 20)
	var capture_us := _time_repeat(func(): frame.capture(), 20)
	# A dirty document rescan reads every chunk's cached bounds.
	State.document._bounds_dirty = true
	var bounds_started := Time.get_ticks_usec()
	State.document.bounds()
	var bounds_us := Time.get_ticks_usec() - bounds_started
	# A dirty chunk rescan is the worst case the batch write avoids.
	var dirty_location: Vector3i = chunks[0]
	var dirty_chunk: VoxelFrame.Chunk = frame.chunks[dirty_location]
	dirty_chunk.bounds_dirty = true
	var chunk_started := Time.get_ticks_usec()
	dirty_chunk.get_bounds()
	var chunk_bounds_us := Time.get_ticks_usec() - chunk_started
	var builder: VoxelMeshBuilder = BUILDER.new()
	builder.source_frame = frame.copy_frame()
	builder.chunk_location = dirty_location
	builder.texture_materials = true
	var build_started := Time.get_ticks_usec()
	builder.run()
	var build_us := Time.get_ticks_usec() - build_started
	var upload_us := _time_repeat(func():
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, builder.surface_arrays)
	, 5)
	var snapshot_us := _time_repeat(func(): BUILDER._snapshot(frame, dirty_location, use_smooth), 10)
	var material_us := 0
	if prof:
		var material_started := Time.get_ticks_usec()
		prof._build_material(builder)
		material_us = Time.get_ticks_usec() - material_started
	var cache_us := _measure_cache()
	# One chunk notification replayed on the live listeners. The renderer's
	# request work is timed apart from the remaining listeners, so the split is
	# visible. The replay only repeats reads and UI refreshes.
	var notify_all_us := 0
	var notify_renderer_us := 0
	var grid_us := 0
	var status_us := 0
	if prof and not chunks.is_empty():
		var renderer_callable := Callable(prof, "_update_chunks")
		State.chunks_changed.disconnect(renderer_callable)
		var extra_callables: Array[Callable] = []
		for extra_prof in extra_profs:
			var extra_callable := Callable(extra_prof, "_update_chunks")
			State.chunks_changed.disconnect(extra_callable)
			extra_callables.append(extra_callable)
		# The probe handler is not part of production, so it must not count.
		State.chunks_changed.disconnect(_on_chunks_changed)
		var notify_started := Time.get_ticks_usec()
		State.chunks_changed.emit(0, chunks)
		notify_all_us = Time.get_ticks_usec() - notify_started
		State.chunks_changed.connect(_on_chunks_changed)
		State.chunks_changed.connect(renderer_callable)
		for extra_callable in extra_callables:
			State.chunks_changed.connect(extra_callable)
		var update_started := Time.get_ticks_usec()
		prof._update_chunks(0, chunks)
		notify_renderer_us = Time.get_ticks_usec() - update_started
	# The two listeners that read the bounds and rebuild geometry or text.
	var grid_node: MeshInstance3D = viewport_scene().get_node_or_null("Grid")
	if grid_node:
		grid_node._last_bounds = AABB()
		var grid_started := Time.get_ticks_usec()
		grid_node.rebuild()
		grid_us = Time.get_ticks_usec() - grid_started
	var status: Node = main.get_node_or_null("%StatusBar")
	if status and status.has_method("_refresh_status"):
		var status_started := Time.get_ticks_usec()
		status._refresh_status()
		status_us = Time.get_ticks_usec() - status_started
	print("MEASURE stage: signature %d chunks %d us, frame copy %d us, capture %d us" % [
		chunks.size(), signature_us, copy_us, capture_us,
	])
	print("MEASURE stage: bounds rescan %d us, dirty chunk bounds %d us, snapshot %d us" % [
		bounds_us, chunk_bounds_us, snapshot_us,
	])
	print("MEASURE stage: chunk build %d us, mesh upload %d us, material %d us, cache insert %d us" % [
		build_us, upload_us, material_us, cache_us,
	])
	print("MEASURE stage: notify non-renderer %d us, renderer request %d us, grid rebuild %d us, status bar %d us" % [
		notify_all_us, notify_renderer_us, grid_us, status_us,
	])
	# Each listener on one notification, so the heavy handler is visible. The
	# listeners are called in turn with the renderers out of the list.
	var connections := State.chunks_changed.get_connections()
	var callables: Array[Callable] = []
	for connection in connections:
		var callable: Callable = connection["callable"]
		if callable.is_valid():
			callables.append(callable)
	for callable in callables:
		State.chunks_changed.disconnect(callable)
	for callable in callables:
		var listener_started := Time.get_ticks_usec()
		callable.call(0, chunks)
		print("MEASURE listener: %s %d us" % [_listener_name(callable), Time.get_ticks_usec() - listener_started])
	for callable in callables:
		State.chunks_changed.connect(callable)


func _listener_name(callable: Callable) -> String:
	var object: Object = callable.get_object()
	if object is Node:
		var node: Node = object
		var script: Script = node.get_script()
		var script_file := script.resource_path.get_file() if script else "?"
		return "%s(%s)::%s" % [script_file, node.name, callable.get_method()]
	return "?::%s" % callable.get_method()


func _measure_cache() -> int:
	var saved_bytes: int = VoxelRenderer._surface_cache_bytes
	var saved_order: Array[PackedInt64Array] = VoxelRenderer._surface_use_order.duplicate()
	var dummy_mesh := ArrayMesh.new()
	var keys: Array[PackedInt64Array] = []
	for index in 32:
		keys.append(PackedInt64Array([index + 1, 1]))
	var started := Time.get_ticks_usec()
	for key in keys:
		VoxelRenderer._cache_surface(key, dummy_mesh, 4096, null)
	var elapsed := Time.get_ticks_usec() - started
	VoxelRenderer._surface_cache_bytes = saved_bytes
	VoxelRenderer._surface_use_order = saved_order
	for key in keys:
		VoxelRenderer._surface_cache.erase(key)
	return elapsed / 32


func _settle_all() -> void:
	if prof:
		while not prof.is_settled():
			await get_tree().process_frame
	for extra in extras:
		while not extra.is_settled():
			await get_tree().process_frame


func _settle_tool() -> void:
	while tool._job or not tool._pending_centers.is_empty():
		await get_tree().process_frame


func _on_chunks_changed(_updated_frame: int, positions: Array[Vector3i]) -> void:
	emitted_entries = maxi(emitted_entries, positions.size())
	var seen := {}
	for position in positions:
		seen[position] = true
	unique_chunks = maxi(unique_chunks, seen.size())
	if chunk_positions.is_empty():
		chunk_positions = positions.duplicate()


func _time_repeat(work: Callable, repeats: int) -> int:
	# The minimum single-iteration time. A short operation is rarely preempted,
	# so the minimum is robust to the external load on this machine.
	var best := -1
	for index in repeats:
		var started_us := Time.get_ticks_usec()
		work.call()
		var elapsed := Time.get_ticks_usec() - started_us
		best = elapsed if best < 0 else mini(best, elapsed)
	return best


func _button(world: Vector3, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	tool.handle_input(event, camera_rig().unproject_position(world))


func _motion(world: Vector3) -> void:
	var event := InputEventMouseMotion.new()
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	tool.handle_input(event, camera_rig().unproject_position(world))
