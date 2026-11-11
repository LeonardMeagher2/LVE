extends "res://tests/test.gd"

# Focused tests for the uniform solid preview.
#
# The solid preview hoists one material when every cell of the batch holds it,
# and passes it to the frame as a positional hint. A full chunk then fills in one
# write, and the loop allocates no material array per cell. The geometry, the
# cell set, and the material output must stay exactly equal to the path that lets
# the frame compare the cells itself.
#
#   godot --path . res://tests/preview_solid_uniform.tscn
#
# Each test uses its own chunk offset, so the shared preview mesh cache never
# serves a shape another test already built. Cross-step state lives on members,
# because a step lambda captures a local by value.

const PREVIEW := preload("res://Globals/Rendering/VoxelPreview.gd")
const CHUNK := VoxelFrame.CHUNK_SIZE
# The block edge of the measured batch. It spans several chunks, so a whole-run
# build is measured, not one chunk.
const BATCH := 32

var preview
var _base := 0
var _requested := {}
var _uniform_us := 0
var _varied_us := 0
var _newest_aabb := AABB()
var _interior_us := 0
var _surface_us := 0
var _interior_empty := false
var _surface_empty := false
var _normal_mesh: Mesh
var _normal_arrays: Array = []
var _normal_color := Color.BLACK
var _normal_aabb := AABB()
var _normal_cells := {}


func _ready() -> void:
	timeout = 60.0
	test("a uniform solid preview matches the frame-built reference vertex for vertex", _uniform_parity, "preview_uniform_parity")
	test("a varied solid preview matches the frame-built reference vertex for vertex", _varied_parity, "preview_varied_parity")
	test("a uniform preview reports the exact installed cells", _uniform_installed_cells, "preview_uniform_cells")
	test("a prepared payload matches show_voxels exactly and shares its cached mesh", _prepared_matches_normal, "preview_prepared_parity")
	test("a prepared payload never installs after a clear or a newer submit", _prepared_lifecycle, "preview_prepared_lifecycle")
	test("a uniform batch costs less than a varied batch on a large preview", _uniform_cost, "preview_uniform_cost")
	test("the solid build reports its per-chunk mesher phases", _mesher_phases, "preview_mesher_phases")


func before_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	# A new chunk offset keeps every test on a fresh cache key.
	_base += CHUNK


func after_test() -> void:
	if preview != null and is_instance_valid(preview):
		preview.free()
		preview = null
	_requested = {}


# One full chunk of cells in a fixed order, all one color.
func _uniform_cells() -> Dictionary:
	var cells := {}
	for z in CHUNK:
		for y in CHUNK:
			for x in CHUNK:
				cells[Vector3i(_base + x, y, z)] = Color.WHITE
	return cells


# One full chunk of cells in a fixed order, with sixteen colors.
func _varied_cells() -> Dictionary:
	var cells := {}
	for z in CHUNK:
		for y in CHUNK:
			for x in CHUNK:
				cells[Vector3i(_base + x, y, z)] = Color.from_hsv(float((x * CHUNK + y + z) % 16) / 16.0, 0.8, 0.9)
	return cells


# One large block of cells in a fixed order. A uniform fill gives every cell the
# same color. A varied fill gives the sixteen-color pattern.
func _batch_cells(varied: bool) -> Dictionary:
	var cells := {}
	for z in BATCH:
		for y in BATCH:
			for x in BATCH:
				if varied:
					cells[Vector3i(_base + x, y, z)] = Color.from_hsv(float((x * BATCH + y + z) % 16) / 16.0, 0.8, 0.9)
				else:
					cells[Vector3i(_base + x, y, z)] = Color.WHITE
	return cells


# The mesh arrays that the frame builds with no uniform hint, so the frame
# compares the cells itself. This is the pre-optimization path. The arrays are
# read back from an ArrayMesh, because the preview installs an ArrayMesh and a
# mesh may store vertex colors at a lower precision than the raw array.
func _reference_arrays(requested: Dictionary, use_voxel_colors: bool, color_key: Color) -> Array:
	var materials := {}
	for cell in requested:
		var value = requested[cell]
		if use_voxel_colors and value is PackedFloat32Array:
			materials[cell] = value
		else:
			var color: Color = value if value is Color else VoxelFrame.material_color(value)
			var wanted := (color_key if color == Color.TRANSPARENT else color) if use_voxel_colors else Color.WHITE
			materials[cell] = VoxelFrame.material(wanted)
	var frame := VoxelFrame.new()
	frame.set_cells(materials)
	var builder := VoxelMeshBuilder.new()
	builder.source_frame = frame
	builder.chunk_location = _chunk_position()
	builder.smooth_normals = false
	builder.texture_materials = false
	builder.run()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, builder.surface_arrays)
	return mesh.surface_get_arrays(0)


func _chunk_position() -> Vector3i:
	return VoxelFrame.chunk_position(Vector3i(_base, 0, 0))


# The chunk origin of the fixture. The preview moves the chunk vertices to world
# space, and a single-chunk builder leaves them local.
func _reference_positions(requested: Dictionary, use_voxel_colors: bool, color_key: Color) -> PackedVector3Array:
	var reference := _reference_arrays(requested, use_voxel_colors, color_key)
	var positions: PackedVector3Array = reference[Mesh.ARRAY_VERTEX]
	var origin := Vector3(_chunk_position() * CHUNK)
	for index in positions.size():
		positions[index] += origin
	return positions


func _same_positions(mesh: Mesh, reference: PackedVector3Array) -> bool:
	var positions: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	if positions.size() != reference.size():
		return false
	for index in positions.size():
		if not positions[index].is_equal_approx(reference[index]):
			return false
	return true


func _same_indices(mesh: Mesh, reference: Array) -> bool:
	var indices: PackedInt32Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	var expected: PackedInt32Array = reference[Mesh.ARRAY_INDEX]
	return indices == expected


func _same_colors(mesh: Mesh, reference: Array) -> bool:
	var colors: PackedColorArray = mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var expected: PackedColorArray = reference[Mesh.ARRAY_COLOR]
	return colors == expected


func _await_settled(instance) -> void:
	var deadline := Time.get_ticks_msec() + 20000
	while not instance.is_settled() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _uniform_parity() -> void:
	step("Given a full uniform chunk", func():
		preview = PREVIEW.new()
		add_child(preview)
		_requested = _uniform_cells()
	)
	step("When the preview builds the uniform chunk", func():
		preview.show_voxels(_requested, Color.RED, false, 0, false)
	)
	await _await_settled(preview)
	step("Then the preview matches the frame-built reference", func():
		var reference := _reference_arrays(_requested, false, Color.WHITE)
		expect(preview.visible, "the uniform preview is visible")
		expect(preview.mesh.get_surface_count() == 1, "the uniform preview holds one surface")
		expect(_same_positions(preview.mesh, _reference_positions(_requested, false, Color.WHITE)), "the uniform preview keeps the reference positions")
		expect(_same_indices(preview.mesh, reference), "the uniform preview keeps the reference indices")
		expect(_same_colors(preview.mesh, reference), "the uniform preview keeps the reference vertex colors")
		expect(preview.mesh.get_aabb().size == Vector3.ONE * CHUNK, "the uniform preview spans the whole chunk")
	)


func _varied_parity() -> void:
	step("Given a full varied chunk", func():
		preview = PREVIEW.new()
		add_child(preview)
		_requested = _varied_cells()
	)
	step("When the preview builds the varied chunk", func():
		preview.show_voxels(_requested, Color.WHITE, false, 0, true)
	)
	await _await_settled(preview)
	step("Then the preview matches the frame-built reference", func():
		var reference := _reference_arrays(_requested, true, Color.WHITE)
		expect(preview.visible, "the varied preview is visible")
		expect(preview.mesh.get_surface_count() == 1, "the varied preview holds one surface")
		expect(_same_positions(preview.mesh, _reference_positions(_requested, true, Color.WHITE)), "the varied preview keeps the reference positions")
		expect(_same_indices(preview.mesh, reference), "the varied preview keeps the reference indices")
		expect(_same_colors(preview.mesh, reference), "the varied preview keeps the reference vertex colors")
	)


func _uniform_installed_cells() -> void:
	step("Given a full uniform chunk", func():
		preview = PREVIEW.new()
		add_child(preview)
		_requested = _uniform_cells()
		preview.show_voxels(_requested, Color.RED, false, 0, false)
	)
	await _await_settled(preview)
	step("Then the preview reports exactly the requested cells", func():
		expect(preview.installed_cells().is_read_only(), "the installed cells are immutable")
		expect(preview.installed_cells().size() == CHUNK * CHUNK * CHUNK, "the installed cells hold the whole chunk")
		expect(preview.installed_cells() == _requested, "the installed cells are the requested cells")
	)


func _uniform_cost() -> void:
	step("When one large uniform batch and one large varied batch build on this thread", func():
		_uniform_us = _build_us(_batch_cells(false), false)
		_varied_us = _build_us(_batch_cells(true), true)
	)
	step("Then both build the whole batch and the uniform batch is not slower", func():
		print("MEASURE preview_solid_uniform cost: cells=%d uniform_us=%d varied_us=%d" % [
			BATCH * BATCH * BATCH, _uniform_us, _varied_us,
		])
		expect(_uniform_us > 0 and _varied_us > 0, "both batches measured a build")
		# The varied path allocates one material array per cell and lets the frame
		# compare every cell, so the uniform path must not cost more.
		expect(_uniform_us <= _varied_us, "the uniform batch costs no more than the varied batch")
	)


# The prepared payload must produce the exact surface of `show_voxels`. The two
# paths share the mesh cache key, so the second install must reuse the first
# ArrayMesh object. That proves the key, the cells, the material, and the bounds
# agree without a rebuild.
func _prepared_matches_normal() -> void:
	step("Given a uniform chunk shown the normal way", func():
		preview = PREVIEW.new()
		add_child(preview)
		_requested = _uniform_cells()
		preview.show_voxels(_requested, Color.GREEN, false, 0, false)
	)
	await _await_settled(preview)
	step("When the same cells are submitted as a prepared payload", func():
		_normal_mesh = preview.mesh
		_normal_arrays = preview.mesh.surface_get_arrays(0).duplicate()
		_normal_color = preview.material_override.get_shader_parameter("cursor_color")
		_normal_aabb = preview.mesh.get_aabb()
		_normal_cells = preview.installed_cells()
		var keys: Array[Vector3i] = []
		keys.assign(_requested.keys())
		var payload = PREVIEW.build_solid_payload(keys, Color.GREEN)
		expect(payload.cell_count == _requested.size(), "the payload holds every cell")
		expect(payload.spots.is_read_only(), "the payload dictionary is read-only")
		preview.show_selection(null)
		preview.submit_prepared(payload)
	)
	await _await_settled(preview)
	step("Then the prepared surface is the exact normal surface", func():
		expect(preview.visible, "the prepared preview is visible")
		expect(preview.mesh == _normal_mesh, "the prepared submit reuses the exact cached mesh")
		expect((preview.material_override.get_shader_parameter("cursor_color") as Color) == (_normal_color as Color), "the prepared submit keeps the display color")
		expect(preview.mesh.get_aabb() == _normal_aabb, "the prepared submit keeps the bounds")
		expect(preview.installed_cells() == _normal_cells, "the prepared submit installs the exact cells")
		expect(preview.mesh.surface_get_arrays(0) == _normal_arrays, "the prepared submit keeps the vertex arrays")
	)


# A prepared submit follows the same clear and supersede rules as a normal one.
func _prepared_lifecycle() -> void:
	step("Given a preview with a prepared payload released", func():
		preview = PREVIEW.new()
		add_child(preview)
		_requested = _uniform_cells()
		var keys: Array[Vector3i] = []
		keys.assign(_requested.keys())
		preview.submit_prepared(PREVIEW.build_solid_payload(keys, Color.BLUE))
	)
	await _await_settled(preview)
	step("Then the prepared payload installed", func():
		expect(preview.visible and not preview.installed_cells().is_empty(), "the prepared payload installed its cells")
	)
	step("When the preview is cleared", func():
		preview.show_selection(null)
	)
	await _await_settled(preview)
	step("Then the clear hides the prepared surface and no worker resurrects it", func():
		expect(not preview.visible, "the cleared preview stays hidden")
		expect(preview.installed_cells().is_empty(), "the clear empties the installed cells")
	)
	step("When a prepared payload supersedes another", func():
		var keys: Array[Vector3i] = []
		keys.assign(_requested.keys())
		preview.submit_prepared(PREVIEW.build_solid_payload(keys, Color.BLUE))
		var moved: Array[Vector3i] = []
		for key in keys:
			moved.append(key + Vector3i(1, 0, 0))
		preview.submit_prepared(PREVIEW.build_solid_payload(moved, Color.BLUE))
		_newest_aabb = _aabb_of_dict(moved)
	)
	await _await_settled(preview)
	step("Then the newest prepared payload owns the surface", func():
		expect(preview.visible, "the newest prepared payload is visible")
		expect(preview.mesh.get_aabb().position.is_equal_approx(_newest_aabb.position), "the newest prepared payload sits on its cells")
	)


# The bounds of a cell list, for the supersede check.
func _aabb_of_dict(cells: Array[Vector3i]) -> AABB:
	var min_corner := Vector3(INF, INF, INF)
	var max_corner := Vector3(-INF, -INF, -INF)
	for cell in cells:
		min_corner = min_corner.min(Vector3(cell) - Vector3(0.5, 0.5, 0.5))
		max_corner = max_corner.max(Vector3(cell) + Vector3(0.5, 0.5, 0.5))
	return AABB(min_corner, max_corner - min_corner)


# The preview reports the mesher phases of a large solid build, and a fully
# surrounded chunk is built to an empty mesh. That measures the cost an exact
# no-exposed-face early cull would skip.
func _mesher_phases() -> void:
	var job := PREVIEW.PreviewJob.new()
	step("Given a three-cube block of full chunks", func():
		var frame := VoxelFrame.new()
		var cells := {}
		var material := VoxelFrame.material(Color.WHITE)
		for x in CHUNK * 3:
			for y in CHUNK * 3:
				for z in CHUNK * 3:
					cells[Vector3i(x, y, z)] = material
		frame.set_cells(cells)
		expect(frame.chunks.size() == 27, "the block holds twenty-seven chunks")
		var interior := VoxelMeshBuilder.new()
		interior.source_frame = frame.copy_frame()
		interior.chunk_location = Vector3i(1, 1, 1)
		interior.smooth_normals = false
		interior.texture_materials = false
		var started := Time.get_ticks_usec()
		interior.run()
		_interior_us = Time.get_ticks_usec() - started
		_interior_empty = interior.surface_arrays[Mesh.ARRAY_VERTEX].is_empty()
		var surface := VoxelMeshBuilder.new()
		surface.source_frame = frame.copy_frame()
		surface.chunk_location = Vector3i(0, 0, 0)
		surface.smooth_normals = false
		surface.texture_materials = false
		started = Time.get_ticks_usec()
		surface.run()
		_surface_us = Time.get_ticks_usec() - started
		_surface_empty = surface.surface_arrays[Mesh.ARRAY_VERTEX].is_empty()
	)
	step("When a large uniform batch builds its solid preview", func():
		job.cells = _batch_cells(false)
		job.style = PREVIEW.PreviewStyle.SOLID
		job.use_voxel_colors = false
		job.smooth_normals = false
		job.color_key = Color.WHITE
		job.run()
	)
	step("Then the phases are reported and the interior chunk is empty", func():
		print("MEASURE preview_mesher_phases: interior_us=%d interior_empty=%s surface_us=%d surface_empty=%s batch_chunks=%d batch_empty=%d batch_culled=%d build_us=%d merge_us=%d" % [
			_interior_us, str(_interior_empty), _surface_us, str(_surface_empty),
			job.chunk_count, job.empty_chunks, job.culled_chunks, job.build_us, job.merge_us,
		])
		expect(_interior_empty, "the fully surrounded chunk emits no vertex")
		expect(not _surface_empty, "the corner chunk emits its exposed faces")
		expect(job.chunk_count > 0, "the batch built its chunks")
		expect(job.build_us > 0 and job.merge_us >= 0, "the mesher phases are measured")
	)


# Runs one solid preview build on this thread and returns its microseconds.
func _build_us(cells: Dictionary, use_voxel_colors: bool) -> int:
	var job := PREVIEW.PreviewJob.new()
	job.cells = cells
	job.style = PREVIEW.PreviewStyle.SOLID
	job.use_voxel_colors = use_voxel_colors
	job.smooth_normals = false
	job.color_key = Color.WHITE
	var started := Time.get_ticks_usec()
	job.run()
	return Time.get_ticks_usec() - started
