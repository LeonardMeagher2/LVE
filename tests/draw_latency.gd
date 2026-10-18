extends "res://tests/test.gd"

# Measures where drawing time goes. Prints one line per measurement.

const MATERIAL_COUNT := 64
const MOTIONS := 16
const DIAMETER := 9
const MAX_DIAMETER := 64
const MAX_MOTIONS := 4
const LARGE_MODEL := 64
const STAMP_CENTERS := 4
const REGION := preload("res://Globals/Rendering/VoxelPlanarRegion.gd")
const BrushScript := preload("res://plugins/brush/BrushTool.gd")

var frame: VoxelFrame
var tool: Node
var renderer: VoxelRenderer
var measuring := false
var last_frame_us := 0
var longest_frame_us := 0
var large_model_us := 0
var large_centers := 0
var large_chunks := 0
var large_pending := 0
var large_burst_us := 0
var large_edit_us := 0
var large_settle_us := 0
var large_done := false
var stamp_us := 0
var stamp_cells := 0
var cursor_us := 0
var cursor_vertices := 0
var cursor_box := false
var cursor_done := false
var limit_rows: Array[String] = []
var limits_done := false


func _ready() -> void:
	timeout = 120.0
	test("drawing latency attribution", _run)


func _process(_delta: float) -> void:
	if not measuring:
		return
	var now := Time.get_ticks_usec()
	longest_frame_us = maxi(longest_frame_us, now - last_frame_us)
	last_frame_us = now


func _run() -> void:
	step("Given a 32-cube model with 64 materials", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		var palette: Array[PackedFloat32Array] = []
		for index in MATERIAL_COUNT:
			palette.append(VoxelFrame.material(Color.from_rgba8(index * 3, 255 - index * 3, index * 2), Color.BLACK, 0.2, 0.4))
		for z in 32:
			for y in 32:
				for x in 32:
					frame.set_cell(Vector3i(x, y, z), palette[(x + y + z) % MATERIAL_COUNT])
		State.floor_axis = Vector3.Axis.AXIS_Y
		camera_rig().set_view("top")
		camera_rig().is_orthogonal = true
		expect(frame.count() == 32768, "the model holds 32768 voxels")
	)

	step("When one chunk surface is rebuilt", func():
		var plain := _time_mesh(false)
		var textured := _time_mesh(true)
		print("MEASURE chunk mesh: greedy %d us, with cleanup and atlas %d us" % [plain[0], textured[0]])
		print("MEASURE chunk atlas: size %s, surfaces %d" % [textured[1], textured[2]])
	)

	step("When one smooth chunk surface is rebuilt", func():
		var greedy := _time_mesh(false, null, true)
		var merged := _time_mesh(true, null, true)
		print("MEASURE smooth chunk: greedy %d us, with cleanup and atlas %d us" % [greedy[0], merged[0]])
	)

	step("When one plain-color chunk surface is rebuilt", func():
		var plain_frame := _plain_frame()
		var flat := _time_mesh(true, plain_frame)
		var smooth := _time_mesh(true, plain_frame, true)
		print("MEASURE one-color chunk: flat greedy %d us total %d us, smooth greedy %d us total %d us" % [
			flat[3], flat[0], smooth[3], smooth[0],
		])
	)

	step("When one blocky-material chunk surface is rebuilt", func():
		var blocky := _blocky_frame()
		var textured := _time_mesh(true, blocky)
		print("MEASURE blocky chunk: greedy %d us, with cleanup and atlas %d us" % [textured[3], textured[0]])
	)

	step("When one hollow-model chunk surface is rebuilt", func():
		var hollow := _hollow_frame()
		var textured := _time_mesh(true, hollow)
		print("MEASURE hollow chunk: greedy %d us, with cleanup and atlas %d us" % [textured[3], textured[0]])
	)

	step("When the cleanup stages are timed apart", func():
		var stages := _time_stages()
		print("MEASURE cleanup stages: regions %d us, atlas bake %d us, uvs %d us" % [stages[0], stages[1], stages[2]])
	)

	step("When the cleanup is split into its parts", func():
		var parts := _time_substages()
		print("MEASURE cleanup parts: grouping %d us, protect %d us, triangulate %d us, emit %d us" % [
			parts[0], parts[1], parts[2], parts[3],
		])
	)

	step("When one planar region is triangulated", func():
		var cells := {}
		for y in 16:
			for x in 16:
				cells[Vector2i(x, y)] = true
		var contours := _time_repeat(func(): REGION.contours(cells), 20)
		var triangulate := _time_repeat(func(): REGION.triangulate(cells), 20)
		print("MEASURE region 16x16: contours %d us, triangulate %d us" % [contours, triangulate])
	)

	step("When the frame is copied and its bounds are rescanned", func():
		var copy_us := _time_copy()
		var bounds_us := _time_bounds()
		print("MEASURE frame copy: %d us, bounds rescan: %d us" % [copy_us, bounds_us])
	)

	step("Given the pencil with a cube brush of nine", func():
		select_toolbar_item("Toolbar", "Pencil")
		tool = plugin("BrushPlugin")._brush_tool
		renderer = viewport_scene().get_node("VoxelRenderer")
		plugin("BrushPlugin")._options.get_node("Diameter").value = DIAMETER
		expect(tool._settings.diameter == DIAMETER, "the brush uses a diameter of nine")
	)

	step("When the user drags the large brush across the model", func():
		_drag("large brush", Vector3(8, 16, 32))
	)
	await _settle_renderer()
	step("Then every large stroke step completes", func():
		expect(frame.count() > 32768, "the drag painted voxels")
		print("MEASURE large drag: %d motions, longest frame gap %d ms" % [MOTIONS, longest_frame_us / 1000])
	)

	step("Given the pencil with a single cell brush", func():
		plugin("BrushPlugin")._options.get_node("Diameter").value = 1
		expect(tool._settings.diameter == 1, "the brush uses a single cell")
	)

	step("When the user drags the single cell brush across the model", func():
		_drag("single cell", Vector3(2, 16, 32))
	)
	await _settle_renderer()
	step("Then every small stroke step completes", func():
		print("MEASURE small drag: %d motions, longest frame gap %d ms" % [MOTIONS, longest_frame_us / 1000])
	)

	step("Given a 64-cube model and the largest brush", func():
		_build_large_model()
		# The document is replaced before the frame is filled, so frame the model now.
		camera_rig().configure()
		camera_rig().set_view("top")
		plugin("BrushPlugin")._options.get_node("Diameter").value = MAX_DIAMETER
		expect(tool._settings.diameter == MAX_DIAMETER, "the brush uses the largest diameter")
	)

	step("When the user drags the largest brush across the large model", func():
		_measure_large_stroke()
	)
	while not large_done:
		await get_tree().process_frame
	step("Then the largest stroke reports its stamp and rebuild cost", func():
		print("MEASURE max diameter: model %d cells in %d chunks, %d us to build" % [
			State.get_current_voxel_frame().count(), State.get_current_voxel_frame().chunks.size(), large_model_us,
		])
		print("MEASURE max diameter: %d motions, peak %d centers, %d emitted chunk entries, peak %d pending surfaces" % [
			MAX_MOTIONS, large_centers, large_chunks, large_pending,
		])
		print("MEASURE max diameter: burst %d us to queue, %d us to settle, longest frame gap %d ms" % [
			large_burst_us, large_settle_us, longest_frame_us / 1000,
		])
		print("MEASURE max diameter edit completion: %d us" % large_edit_us)
	)

	step("When one largest-diameter motion stamps and writes on its own", func():
		_measure_stamp()
	)
	step("Then the stamp reports its own cost", func():
		print("MEASURE stamp: diameter %d, %d centers, %d cells, %d us" % [
			MAX_DIAMETER, STAMP_CENTERS, stamp_cells, stamp_us,
		])
	)

	step("Given the largest sphere brush", func():
		tool._settings.shape = BrushToolSettings.BrushShape.SPHERE
		tool._settings._cached_pattern = {}
		expect(tool._settings.shape == BrushToolSettings.BrushShape.SPHERE, "the brush uses the sphere shape")
	)

	step("When the cursor shows the largest sphere brush", func():
		_measure_cursor()
	)
	while not cursor_done:
		await get_tree().process_frame
	step("Then the cursor reports its preview cost", func():
		print("MEASURE max cursor: pattern %d cells, %d us to settle, %d vertices, box=%s" % [
			tool._settings.pattern().size(), cursor_us, cursor_vertices, str(cursor_box),
		])
	)

	step("When the number of in-flight surface jobs changes", func():
		_measure_job_limits()
	)
	while not limits_done:
		await get_tree().process_frame
	step("Then each limit reports its settle time and its frame gap", func():
		for row in limit_rows:
			print(row)
	)


# A 64-cube model. The 32-cube model holds eight chunks, so a brush of the
# largest diameter cannot show how the cost scales with the footprint.
func _build_large_model() -> void:
	var started_us := Time.get_ticks_usec()
	State.document = VoxelDocument.new()
	var cells := {}
	var cell_material := VoxelFrame.material(Color.RED)
	for z in LARGE_MODEL:
		for y in LARGE_MODEL:
			for x in LARGE_MODEL:
				cells[Vector3i(x, y, z)] = cell_material
	State.get_current_voxel_frame().set_cells(cells)
	# A direct frame write does not dirty the document bounds. The brush tool
	# sets the same flag after it restores an edited frame.
	State.document._bounds_dirty = true
	large_model_us = Time.get_ticks_usec() - started_us


# The stamp cost is the accumulated center count times the brush volume, and
# every changed chunk rebuilds. A real drag delivers motions faster than a
# maximum-diameter stamp completes, so queue the whole burst before waiting.
func _measure_large_stroke(job_limit := 0) -> void:
	var origin := Vector3(16, 32, 32)
	VoxelRenderer._surface_job_limit = job_limit
	large_centers = 0
	large_chunks = 0
	large_pending = 0
	large_burst_us = 0
	large_edit_us = 0
	large_settle_us = 0
	State.chunks_changed.connect(_on_chunks_changed)
	longest_frame_us = 0
	measuring = true
	_button(origin, true)
	# The gap measures the interval between frames. Reset the mark here, or the
	# first frame also counts the idle time since the last measured frame.
	last_frame_us = Time.get_ticks_usec()
	var burst_started_us := Time.get_ticks_usec()
	for step_index in MAX_MOTIONS:
		_motion(Vector3(origin.x + step_index + 1, origin.y, origin.z))
		large_centers = maxi(large_centers, tool._pending_centers.size())
	large_burst_us = Time.get_ticks_usec() - burst_started_us
	await _settle_tool()
	large_edit_us = Time.get_ticks_usec() - burst_started_us - large_burst_us
	await _settle_large()
	# Visible completion includes the surfaces, not only the edit worker.
	large_settle_us = Time.get_ticks_usec() - burst_started_us - large_burst_us
	measuring = false
	_button(Vector3(origin.x + MAX_MOTIONS, origin.y, origin.z), false)
	await _settle_tool()
	State.chunks_changed.disconnect(_on_chunks_changed)
	large_done = true


# One largest-diameter motion, stamped and written with the renderer out of the
# picture. The result is the job cost alone, which the settle time hides.
func _measure_stamp() -> void:
	var pattern: Dictionary = tool._settings.pattern()
	if pattern.is_empty():
		pattern = BrushToolSettings.build_pattern(MAX_DIAMETER, tool._settings.shape)
	var job := BrushScript.BrushJob.new()
	for index in STAMP_CENTERS:
		job.centers.append(Vector3i(16 + index, 32, 32))
	job.pattern = pattern
	job.offsets = pattern.keys()
	job.diameter = MAX_DIAMETER
	job.shape = tool._settings.shape
	job.material = State.current_material
	# The tool declares a uniform batch for a shape brush, so mirror that here or
	# the line measures a path the brush no longer takes.
	job.applied_uniform = State.current_material
	job.edited_frame = State.get_current_voxel_frame().copy_frame()
	var started_us := Time.get_ticks_usec()
	job.run()
	stamp_us = Time.get_ticks_usec() - started_us
	stamp_cells = job.cell_materials.size()


func _settle_large() -> void:
	while not renderer.is_settled():
		large_pending = maxi(large_pending, renderer._pending_surface_keys.size())
		await get_tree().process_frame


# The cursor preview is a second cost of a large brush. Above a diameter of 16
# the pattern is not cached, so the hover builds it first and then builds the
# preview. Measure both together.
func _measure_cursor() -> void:
	var cursor: MeshInstance3D = tool.get_node("Cursor")
	var started_us := Time.get_ticks_usec()
	tool._cursor_axis = -1
	tool._show_brush_shape(0)
	while tool._hover_job != null or not cursor.is_settled():
		await get_tree().process_frame
	cursor_us = Time.get_ticks_usec() - started_us
	cursor_box = cursor.mesh is BoxMesh
	cursor_vertices = 0
	if cursor.mesh is ArrayMesh:
		var surface: ArrayMesh = cursor.mesh
		for index in surface.get_surface_count():
			cursor_vertices += surface.surface_get_arrays(index)[Mesh.ARRAY_VERTEX].size()
	cursor_done = true


func _on_chunks_changed(_updated_frame: int, chunk_positions: Array[Vector3i]) -> void:
	large_chunks = maxi(large_chunks, chunk_positions.size())


# Phase 7 step 0. The same maximum-diameter stroke under different numbers of
# in-flight surface jobs. The 64-cube model is rebuilt each time so every limit
# meets the same conditions.
func _measure_job_limits() -> void:
	for limit: int in [2, 4, 6, 8]:
		_build_large_model()
		camera_rig().configure()
		camera_rig().set_view("top")
		await _settle_renderer()
		await _measure_large_stroke(limit)
		limit_rows.append("MEASURE job limit %d: burst %d us, edit %d us, settle %d us, gap %d ms, peak %d pending surfaces" % [
			limit, large_burst_us, large_edit_us, large_settle_us, longest_frame_us / 1000, large_pending,
		])
	VoxelRenderer._surface_job_limit = 0
	limits_done = true


func _drag(label: String, origin: Vector3) -> void:
	var edit_total_us := 0
	var visible_total_us := 0
	var worst_edit_us := 0
	var worst_visible_us := 0
	longest_frame_us = 0
	measuring = true
	_button(origin, true)
	last_frame_us = Time.get_ticks_usec()
	for step_index in MOTIONS:
		var target := Vector3(origin.x + step_index + 1, origin.y, origin.z)
		var started_us := Time.get_ticks_usec()
		_motion(target)
		await _settle_tool()
		var edit_us := Time.get_ticks_usec() - started_us
		await _settle_renderer()
		var visible_us := Time.get_ticks_usec() - started_us
		edit_total_us += edit_us
		visible_total_us += visible_us
		worst_edit_us = maxi(worst_edit_us, edit_us)
		worst_visible_us = maxi(worst_visible_us, visible_us)
		last_frame_us = Time.get_ticks_usec()
	measuring = false
	_button(Vector3(origin.x + MOTIONS, origin.y, origin.z), false)
	await _settle_tool()
	print("MEASURE %s per motion: edit avg %d us worst %d us, visible avg %d us worst %d us" % [
		label, edit_total_us / MOTIONS, worst_edit_us, visible_total_us / MOTIONS, worst_visible_us
	])


func _plain_frame() -> VoxelFrame:
	var plain := VoxelFrame.new()
	var cell_material := VoxelFrame.material(Color.RED)
	for z in 32:
		for y in 32:
			for x in 32:
				plain.set_cell(Vector3i(x, y, z), cell_material)
	return plain


# A hollow 32-cube shell, like most voxel art, instead of a solid block.
func _hollow_frame() -> VoxelFrame:
	var hollow := VoxelFrame.new()
	var cell_material := VoxelFrame.material(Color.RED)
	for z in 32:
		for y in 32:
			for x in 32:
				if x == 0 or y == 0 or z == 0 or x == 31 or y == 31 or z == 31:
					hollow.set_cell(Vector3i(x, y, z), cell_material)
	return hollow


# Eight uniform material blocks, like a painted model rather than a test pattern.
func _blocky_frame() -> VoxelFrame:
	var blocky := VoxelFrame.new()
	var palette: Array[PackedFloat32Array] = []
	for index in 8:
		palette.append(VoxelFrame.material(Color.from_rgba8(index * 30, 120, 255 - index * 30)))
	for z in 32:
		for y in 32:
			for x in 32:
				var block := (x / 16) + (y / 16) * 2 + (z / 16) * 4
				blocky.set_cell(Vector3i(x, y, z), palette[block % 8])
	return blocky


func _time_mesh(textured: bool, model: VoxelFrame = null, smooth := false) -> Array:
	var source: VoxelFrame = model if model else frame
	var greedy := VoxelMeshBuilder.new()
	greedy.source_frame = source.copy_frame()
	greedy.chunk_location = Vector3i(1, 1, 1)
	greedy.smooth_normals = smooth
	greedy.texture_materials = false
	var started_us := Time.get_ticks_usec()
	greedy.run()
	var greedy_us := Time.get_ticks_usec() - started_us
	if not textured:
		return [greedy_us, greedy.atlas_size, greedy.surface_arrays[Mesh.ARRAY_VERTEX].size(), greedy_us]
	var job := VoxelMeshBuilder.new()
	job.source_frame = source.copy_frame()
	job.chunk_location = Vector3i(1, 1, 1)
	job.smooth_normals = smooth
	job.texture_materials = true
	started_us = Time.get_ticks_usec()
	job.run()
	var elapsed_us := Time.get_ticks_usec() - started_us
	return [elapsed_us, job.atlas_size, job.surface_arrays[Mesh.ARRAY_VERTEX].size(), greedy_us]


func _time_repeat(work: Callable, repeats: int) -> int:
	var started_us := Time.get_ticks_usec()
	for index in repeats:
		work.call()
	return (Time.get_ticks_usec() - started_us) / repeats


func _time_stages() -> Array:
	var surface := load("res://Globals/Rendering/VoxelSurface.gd")
	var atlas := load("res://Globals/Rendering/VoxelAtlas.gd")
	var greedy := VoxelMeshBuilder.new()
	greedy.source_frame = frame.copy_frame()
	greedy.chunk_location = Vector3i(1, 1, 1)
	greedy.texture_materials = false
	greedy.run()
	var source_arrays := greedy.surface_arrays
	var bake: RefCounted = atlas.new()
	var always := func(_progress: int) -> bool: return true
	var started_us := Time.get_ticks_usec()
	var built: Array = surface._build(source_arrays, frame, Vector3.ZERO, bake, always, false)
	var regions_us := Time.get_ticks_usec() - started_us
	started_us = Time.get_ticks_usec()
	bake.bake(always)
	var bake_us := Time.get_ticks_usec() - started_us
	started_us = Time.get_ticks_usec()
	surface._finish_uvs(built, bake, always)
	var uvs_us := Time.get_ticks_usec() - started_us
	return [regions_us, bake_us, uvs_us]


# The cleanup in parts, on the real functions. The protection and the
# triangulation feed each other, so they are timed on their own group set, and
# the emission is the remainder of `_finish`.
func _time_substages() -> Array:
	var surface := load("res://Globals/Rendering/VoxelSurface.gd")
	var atlas := load("res://Globals/Rendering/VoxelAtlas.gd")
	var always := func(_progress: int) -> bool: return true
	var greedy := VoxelMeshBuilder.new()
	greedy.source_frame = frame.copy_frame()
	greedy.chunk_location = Vector3i(1, 1, 1)
	greedy.texture_materials = false
	greedy.run()
	var started_us := Time.get_ticks_usec()
	var groups: Dictionary = surface._groups_from_arrays(greedy.surface_arrays, frame, Vector3.ZERO, always, false)
	var grouping_us := Time.get_ticks_usec() - started_us
	var alone: Dictionary = surface._groups_from_arrays(greedy.surface_arrays, frame, Vector3.ZERO, always, false)
	started_us = Time.get_ticks_usec()
	var protected: Dictionary = surface._protect_groups(alone, always)
	var protect_us := Time.get_ticks_usec() - started_us
	started_us = Time.get_ticks_usec()
	surface._triangulate_groups(alone, protected, always)
	var triangulate_us := Time.get_ticks_usec() - started_us
	var bake: RefCounted = atlas.new()
	started_us = Time.get_ticks_usec()
	surface._finish(groups, frame, Vector3.ZERO, bake, always, false)
	var finish_us := Time.get_ticks_usec() - started_us
	return [grouping_us, protect_us, triangulate_us, finish_us - protect_us - triangulate_us]


func _time_copy() -> int:
	var started_us := Time.get_ticks_usec()
	var copy := frame.copy_frame()
	var elapsed_us := Time.get_ticks_usec() - started_us
	expect(copy.chunks.size() == frame.chunks.size(), "the copy holds every chunk")
	return elapsed_us


func _time_bounds() -> int:
	State.document._bounds_dirty = true
	var started_us := Time.get_ticks_usec()
	State.document.bounds()
	return Time.get_ticks_usec() - started_us


func _settle_tool() -> void:
	while tool._job or not tool._pending_centers.is_empty():
		await get_tree().process_frame


func _settle_renderer() -> void:
	while not renderer.is_settled():
		await get_tree().process_frame


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
