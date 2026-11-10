extends "res://tests/test.gd"

# Chunk material storage and the per-chunk atlas bake. The atlas case moved here
# from `chunk_atlas`, so one process covers both.

const DOCUMENT_PATH := "user://chunk_materials_test.lve"
const LEGACY_PATH := "user://chunk_materials_legacy.lve"
const ATLAS_MATERIAL := {"emission": Color(2.0, 1.0, 0.5), "metallic": 0.8, "roughness": 0.25}
const MESH_SAMPLES := preload("res://tests/helpers/mesh_samples.gd")

var frame: VoxelFrame
var loaded: VoxelFrame
var scene_renderer: VoxelRenderer
var chunk_position := Vector3i.ZERO
var scope_frame: VoxelFrame
var scope_renderer: VoxelRenderer
var scope_material := VoxelFrame.material(Color.RED)
var scope_reported: Array[Vector3i] = []
var storage_original: VoxelFrame
var storage_duplicate: VoxelFrame
var storage_restored: VoxelFrame
var storage_data := PackedByteArray()
var storage_undo_us := 0
var storage_redo_us := 0
var publish_frame: VoxelFrame
var publish_snapshot := {}
var publish_written := {}


func _ready() -> void:
	timeout = 30.0
	test("Cell materials survive saving and loading, and older documents keep their voxels", _run, "materials")
	timeout = 20.0
	test("voxel materials bake into one atlas for each chunk", _atlas_run, "chunk_atlas")
	timeout = 20.0
	test("an edit reports only the chunks whose mesher input changed", _rebuild_scope_run, "chunk_rebuild_scope")
	timeout = 30.0
	test("large edits restore chunk versions and save uniform regions as compact octrees", _storage_run, "chunk_storage")
	timeout = 10.0
	test("a published job keeps every snapshot chunk frozen", _publish_run, "chunk_publish")


func _publish_run() -> void:
	step("Given two neighboring chunks and an undo snapshot", func():
		publish_frame = State.get_current_voxel_frame()
		publish_frame.set_cell(Vector3i(15, 0, 0), VoxelFrame.material(Color.RED))
		publish_frame.set_cell(Vector3i(16, 0, 0), VoxelFrame.material(Color.GREEN))
		publish_snapshot = publish_frame.capture()
		expect(publish_frame.chunks.size() == 2, "the fixture holds two chunks")
	)
	step("When a job writes the face cell and publishes its changed chunks", func():
		var job := publish_frame.copy_frame()
		var changed := job.set_cells({Vector3i(15, 0, 0): VoxelFrame.material(Color.BLUE)})
		expect(changed.has(Vector3i.ZERO), "the changed list holds the written chunk")
		expect(changed.has(Vector3i(1, 0, 0)), "the changed list holds the neighbor that meshes across the face")
		publish_frame.apply_published(changed, job)
		publish_written[Vector3i.ZERO] = publish_frame.chunks[Vector3i.ZERO]
	)
	step("Then the neighbor still belongs to the snapshot, and the written chunk belongs to the frame", func():
		expect(publish_frame.get_color(Vector3i(15, 0, 0)) == Color.BLUE, "the published cell is live")
		expect(publish_frame.chunks[Vector3i(1, 0, 0)] == publish_snapshot[Vector3i(1, 0, 0)], "the neighbor keeps the snapshot object")
	)
	step("When the user writes the neighbor and writes the published chunk again", func():
		publish_frame.set_cell(Vector3i(16, 1, 0), VoxelFrame.material(Color.YELLOW))
		publish_frame.set_cell(Vector3i(15, 1, 0), VoxelFrame.material(Color.BLUE))
	)
	step("Then the snapshot chunk is unchanged and the published chunk is reused", func():
		var frozen: VoxelFrame.Chunk = publish_snapshot[Vector3i(1, 0, 0)]
		expect(not frozen.has(Vector3i(16, 1, 0)), "the snapshot chunk keeps no new cell")
		expect(frozen.get_color(Vector3i(16, 0, 0)) == Color.GREEN, "the snapshot chunk keeps its color")
		expect(publish_frame.chunks[Vector3i.ZERO] == publish_written[Vector3i.ZERO], "the written chunk is reused, not copied again")
	)


# Each case starts from a clean document, history, and playback state. The cases
# shared one process, so no case may inherit another case's document or undo.
func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.undo_redo.clear_history()
	State.clear_selection()
	State.symmetry_axes = 0



func _run() -> void:
	step("Given a plain voxel and a glowing metal voxel", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		frame.set_cell(Vector3i(3, 0, 0), VoxelFrame.material(Color.BLUE, Color(1, 0.5, 0.25), 1.0, 0.25))
		expect(frame.get_metallic(Vector3i(3, 0, 0)) == 1.0, "the metal voxel stores its metallic")
		expect(frame.chunks[Vector3i.ZERO].materials.size() == 2 * VoxelFrame.MATERIAL_STRIDE, "each voxel stores nine material values")
	)
	step("When the document saves and loads", func():
		var document := VoxelDocument.new()
		document.frames.assign([frame])
		expect(document.save_file(DOCUMENT_PATH) == OK, "the document saves")
		var opened := VoxelDocument.load_file(DOCUMENT_PATH)
		loaded = opened.frames[0] if opened else null
		expect(loaded != null, "the document loads")
	)
	step("Then every voxel keeps its color and material", func():
		expect(loaded.get_color(Vector3i(3, 0, 0)) == Color.BLUE, "the metal voxel keeps its color")
		expect(loaded.get_emission(Vector3i(3, 0, 0)) == Color(1, 0.5, 0.25), "the metal voxel keeps its emission color")
		expect(loaded.get_metallic(Vector3i(3, 0, 0)) == 1.0 and loaded.get_roughness(Vector3i(3, 0, 0)) == 0.25, "the metal voxel keeps its metallic and roughness")
		expect(loaded.get_color(Vector3i.ZERO) == Color.RED, "the plain voxel keeps its color")
		expect(loaded.get_emission(Vector3i.ZERO) == Color.BLACK and loaded.get_metallic(Vector3i.ZERO) == 0.0 and loaded.get_roughness(Vector3i.ZERO) == 1.0, "the plain voxel uses the default values")
	)
	step("Then the chunk stores one table for all material values", func():
		var record: Array = loaded.storage_data()[1][0]
		var materials: PackedFloat32Array = record[1]
		expect(loaded.storage_data()[0] == VoxelFrame.STORAGE_VERSION, "the storage uses the current version")
		expect(materials.size() == 3 * VoxelFrame.MATERIAL_STRIDE, "the table holds the empty material and both voxel materials")
		expect(record.size() == 3 and record[2] is PackedInt32Array, "the chunk holds one material table and one octree")
	)
	step("When the user erases the metal voxel", func():
		frame.set_cell(Vector3i(3, 0, 0), VoxelFrame.material(Color.TRANSPARENT))
		expect(not frame.has(Vector3i(3, 0, 0)), "erasing removes the voxel")
		expect(frame.get_color(Vector3i.ZERO) == Color.RED, "the plain voxel keeps its color")
	)
	step("Given a version 1 document with a solid red chunk", func():
		expect(_write_legacy(LEGACY_PATH) == OK, "the version 1 document writes")
	)
	step("When the version 1 document loads", func():
		var opened := VoxelDocument.load_file(LEGACY_PATH)
		loaded = opened.frames[0] if opened else null
		expect(loaded != null, "the version 1 document loads")
		expect(loaded.get_color(Vector3i.ZERO) == Color.RED, "the version 1 voxel keeps its color")
		expect(loaded.get_emission(Vector3i.ZERO) == Color.BLACK and loaded.get_metallic(Vector3i.ZERO) == 0.0 and loaded.get_roughness(Vector3i.ZERO) == 1.0, "the version 1 voxel uses the default values")
	)
	step("Then saving the version 1 frame writes the current version", func():
		expect(loaded.storage_data()[0] == VoxelFrame.STORAGE_VERSION, "the upgraded storage uses the current version")
		expect(VoxelFrame.validate_storage(loaded.storage_data()) == 4096, "the upgraded chunk stores all voxels in the current format")
	)
	step("Given a version 2 frame with a glowing metal chunk", func():
		var chunks := [[Vector3i.ZERO, PackedColorArray([Color.TRANSPARENT, Color.BLUE]), PackedColorArray([Color.RED]), PackedColorArray([Color(0.5, 0.25, 0, 0)]), PackedInt32Array([3])]]
		var storage := [2, chunks]
		expect(VoxelFrame.validate_storage(storage) == 4096, "the version 2 storage is valid")
		loaded = VoxelFrame.new()
		loaded.restore_storage(storage)
		expect(loaded.get_color(Vector3i.ZERO) == Color.BLUE, "the version 2 voxel keeps its color")
		expect(loaded.get_emission(Vector3i.ZERO) == Color.RED and loaded.get_metallic(Vector3i.ZERO) == 0.5 and loaded.get_roughness(Vector3i.ZERO) == 0.25, "the version 2 voxel keeps its material values")
		expect(VoxelFrame.validate_storage(loaded.storage_data()) == 4096, "the version 2 frame saves in the current format")
	)
	step("When erases compact a copied chunk", func():
		frame = VoxelFrame.new()
		for x in 10:
			frame.set_cell(Vector3i(x, 0, 0), VoxelFrame.material(Color.BLUE, Color.RED, x / 10.0, 0.25))
		var copy := frame.copy_frame()
		for x in 7:
			copy.set_cell(Vector3i(x, 0, 0), VoxelFrame.material(Color.TRANSPARENT))
		expect(copy.count() == 3 and frame.count() == 10, "compaction preserves the source frame")
		for x in range(7, 10):
			expect(is_equal_approx(copy.get_metallic(Vector3i(x, 0, 0)), x / 10.0), "each remaining voxel keeps its metallic")
		expect(copy.chunks[Vector3i.ZERO].materials.size() <= 6 * VoxelFrame.MATERIAL_STRIDE, "compaction bounds the unused material space")
	)
	step("When a stroke restores the same voxels with different slots", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		var material := VoxelFrame.material(Color.RED, Color(0.2, 0.4, 0.6), 0.2, 0.4)
		frame.set_cell(Vector3i.ZERO, material)
		frame.set_cell(Vector3i.RIGHT, material)
		State.undo_redo.clear_history()
		var tx := State.begin_edit()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.TRANSPARENT))
		frame.set_cell(Vector3i.ZERO, material)
		State.finish_edit(tx)
		expect(not State.undo_redo.has_undo(), "equal voxel materials create no undo action")
		var revision: int = frame.chunks[Vector3i.ZERO].voxel_revision
		var changed := frame.set_cells({Vector3i.ZERO: material})
		expect(changed.is_empty() and frame.chunks[Vector3i.ZERO].voxel_revision == revision, "a repeated material write preserves the chunk revision")
		expect(is_equal_approx(frame.get_metallic(Vector3i.ZERO), 0.2), "the metallic retains float32 precision")
	)
	step("Then invalid material tables are rejected before loading", func():
		var valid := VoxelFrame.material(Color.TRANSPARENT)
		valid.append_array(VoxelFrame.material(Color.RED))
		var nodes := PackedInt32Array([1])
		var short := valid.slice(0, valid.size() - 1)
		expect(VoxelFrame.validate_storage([3, [[Vector3i.ZERO, short, nodes]]]) == -1, "a material table must contain complete materials")
		var invalid := valid.duplicate()
		invalid[VoxelFrame.MATERIAL_STRIDE + VoxelFrame.MATERIAL_METALLIC] = NAN
		expect(VoxelFrame.validate_storage([3, [[Vector3i.ZERO, invalid, nodes]]]) == -1, "all material values must be finite")
		invalid[VoxelFrame.MATERIAL_STRIDE + VoxelFrame.MATERIAL_METALLIC] = 2.0
		expect(VoxelFrame.validate_storage([3, [[Vector3i.ZERO, invalid, nodes]]]) == -1, "material values must stay within zero and one")
		expect(VoxelFrame.validate_storage([3, [[Vector3i.ZERO, valid, PackedInt32Array([2])]]]) == -1, "every octree material id must exist")
	)
	DirAccess.remove_absolute(DOCUMENT_PATH)
	DirAccess.remove_absolute(LEGACY_PATH)


func _write_legacy(path: String) -> Error:
	var chunks := [[Vector3i.ZERO, PackedColorArray([Color.TRANSPARENT, Color.RED]), PackedInt32Array([1])]]
	var fields := {"palette": PackedColorArray(), "frames": [{"delay_ms": 100, "voxels": [1, chunks]}], "tags": [], "smooth_normals": false, "lighting": {}, "export": {}}
	var payload := var_to_bytes(fields)
	var result := PackedByteArray(VoxelDocument.FILE_SIGNATURE)
	result.resize(16)
	result.encode_u32(4, 1)
	result.encode_u32(8, payload.size())
	result.encode_u32(12, VoxelDocument._crc32(payload))
	result.append_array(payload)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(result)
	file.close()
	return OK


func _atlas_run() -> void:
	step("Given a chunk with a metallic voxel and a plain voxel", func():
		State.document = VoxelDocument.new()
		State.paint(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.paint(Vector3i(1, 0, 0), VoxelFrame.material(Color.BLUE))
		State.get_current_voxel_frame().set_cells({Vector3i(1, 0, 0): VoxelFrame.material(Color.BLUE, ATLAS_MATERIAL.emission, ATLAS_MATERIAL.metallic, ATLAS_MATERIAL.roughness)})
		scene_renderer = load("res://ui/Viewport/VoxelRenderer.tscn").instantiate()
		main.add_child(scene_renderer)
	)
	await _atlas_settle()
	step("Then the chunk material bakes all voxel values", func():
		var material: StandardMaterial3D = _chunk_material()
		expect(material != null, "the material chunk uses its own material")
		if material == null:
			return
		var surface: ArrayMesh = scene_renderer._surface_cache[_displayed_key()].surface
		expect(surface.get_surface_count() == 1, "the chunk uses one surface for all materials")
		expect(material.albedo_texture != null, "the material holds an albedo texture")
		expect(material.roughness_texture != null, "the material holds a metallic and roughness texture")
		expect(material.roughness_texture == material.metallic_texture, "one texture serves the metallic and the roughness")
		expect(material.roughness_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_GREEN, "the roughness reads the green channel")
		expect(material.metallic_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_BLUE, "the metallic reads the blue channel")
		expect(material.emission_texture != null, "the material holds an emission texture")
		expect(material.emission_enabled, "the material emits the baked light")
		expect(material.emission == Color.WHITE, "the emission color preserves the texture values")
		expect(material.emission_operator == BaseMaterial3D.EMISSION_OP_MULTIPLY, "the emission texture multiplies the white emission color")
		var energy := maxf(1.0, maxf(ATLAS_MATERIAL.emission.r, maxf(ATLAS_MATERIAL.emission.g, ATLAS_MATERIAL.emission.b)))
		expect(is_equal_approx(material.emission_energy_multiplier, energy), "the emission energy retains the HDR strength")
		expect(material.vertex_color_use_as_albedo and not material.vertex_color_is_srgb, "the atlas multiplies the baked ambient occlusion")
		expect(material.albedo_texture.get_image().get_format() == Image.FORMAT_RGBA8, "the albedo atlas retains alpha")
		expect(material.roughness_texture.get_image().get_format() == Image.FORMAT_RGB8, "the finish atlas uses three channels")
		expect(material.metallic == 1.0 and material.roughness == 1.0, "the textures supply the metallic and roughness values")
		expect(_holds_color(material.albedo_texture, Color.BLUE), "the atlas holds the plain voxel color")
		expect(_holds_finish(material.roughness_texture, ATLAS_MATERIAL), "the atlas holds the metallic and the roughness")
		expect(_holds_color(material.emission_texture, (ATLAS_MATERIAL.emission / energy).linear_to_srgb()), "the atlas holds the normalized sRGB emission color")
		var template: StandardMaterial3D = scene_renderer.mesh.surface_get_material(0)
		expect(material.cull_mode == template.cull_mode, "the atlas retains the template cull mode")
		expect(material.rim_enabled == template.rim_enabled and is_equal_approx(material.rim, template.rim) and is_equal_approx(material.rim_tint, template.rim_tint), "the atlas retains the template rim settings")
		expect(material.stencil_flags == template.stencil_flags and material.stencil_color == template.stencil_color and is_equal_approx(material.stencil_outline_thickness, template.stencil_outline_thickness), "the atlas retains the template stencil settings")
	)
	step("When the user clears the material of the chunk", func():
		State.get_current_voxel_frame().set_cells({Vector3i(1, 0, 0): VoxelFrame.material(Color.BLUE)})
		var affected_chunks: Array[Vector3i] = [chunk_position]
		State.chunks_changed.emit(0, affected_chunks)
	)
	await _atlas_settle()
	step("Then the plain chunk retains its spatial atlas", func():
		var material := _chunk_material()
		expect(material != null and material.albedo_texture != null, "a plain chunk keeps its own atlas material")
		if material != null:
			expect(_holds_color(material.albedo_texture, Color.RED), "the plain atlas retains the red voxel")
			expect(_holds_color(material.albedo_texture, Color.BLUE), "the plain atlas retains the blue voxel")
			expect(is_equal_approx(material.emission_energy_multiplier, 1.0), "the plain atlas uses the minimum emission energy")
		expect(scene_renderer._surface_cache[_displayed_key()].bytes > 0, "the cached surface reports its size")
	)
	step("Given adjacent red voxels with two different materials", func():
		var atlas_frame := VoxelFrame.new()
		atlas_frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var metal := VoxelFrame.material(Color.RED, Color.GREEN, 0.75, 0.25)
		atlas_frame.set_cell(Vector3i.RIGHT, metal)
		atlas_frame.set_cell(Vector3i.RIGHT * 2, metal)
		var job := VoxelMeshBuilder.new()
		job.source_frame = atlas_frame
		job.run()
		var vertices: PackedVector3Array = job.surface_arrays[Mesh.ARRAY_VERTEX]
		expect(vertices.size() == 40, "ten material-bounded faces retain their flat vertices")
		expect(job.surface_arrays[Mesh.ARRAY_INDEX].size() == 60, "ten material-bounded faces produce twenty triangles")
		expect(job.surface_arrays[Mesh.ARRAY_COLOR] == null, "the atlas mesh omits vertex colors")
		expect(job.atlas_size.x > 0 and job.atlas_size.y > 0, "the face rectangles fit in an atlas")
		expect(job.geometry_bytes == vertices.size() * 32 + job.surface_arrays[Mesh.ARRAY_INDEX].size() * 4, "the surface size includes positions, normals, and UVs")
		var albedo := Image.create_from_data(job.atlas_size.x, job.atlas_size.y, false, Image.FORMAT_RGBA8, job.atlas_albedo)
		var emission := Image.create_from_data(job.atlas_size.x, job.atlas_size.y, false, Image.FORMAT_RGB8, job.atlas_emission)
		var orm := Image.create_from_data(job.atlas_size.x, job.atlas_size.y, false, Image.FORMAT_RGB8, job.atlas_orm)
		var samples_match := true
		var face_samples := [0, 0, 0]
		# Sample each exposed voxel face, not at the atlas gutter.
		for cell: Vector3i in atlas_frame.positions():
			for direction: Vector3i in [Vector3i.LEFT, Vector3i.RIGHT, Vector3i.DOWN, Vector3i.UP, Vector3i.FORWARD, Vector3i.BACK]:
				if atlas_frame.has(cell + direction):
					continue
				var uv: Variant = MESH_SAMPLES.uv_at(job.surface_arrays, Vector3(cell) + Vector3(direction) * 0.5, Vector3(direction))
				if uv == null:
					samples_match = false
					continue
				var texel := Vector2i(uv * Vector2(job.atlas_size))
				var is_metal := cell.x > 0
				face_samples[cell.x] += 1
				var glow := emission.get_pixelv(texel)
				var values := orm.get_pixelv(texel)
				samples_match = samples_match and albedo.get_pixelv(texel).is_equal_approx(Color.RED)
				samples_match = samples_match and glow.is_equal_approx(Color.GREEN if is_metal else Color.BLACK)
				samples_match = samples_match and absi(roundi(values.b * 255) - (191 if is_metal else 0)) <= 1
				samples_match = samples_match and absi(roundi(values.g * 255) - (64 if is_metal else 255)) <= 1
		expect(face_samples == [5, 4, 5], "all fourteen exposed voxel faces receive interior samples")
		expect(samples_match, "every voxel face interior samples its own material")
	)
	step("When an erased material leaves an unused slot", func():
		var slot_frame := VoxelFrame.new()
		slot_frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		slot_frame.set_cell(Vector3i.RIGHT, VoxelFrame.material(Color.BLUE, Color.GREEN, 1.0, 0.25))
		slot_frame.set_cell(Vector3i.RIGHT, VoxelFrame.material(Color.TRANSPARENT))
		var job := VoxelMeshBuilder.new()
		job.source_frame = slot_frame
		job.run()
		expect(job.atlas_size == Vector2i(3, 3), "one remaining material uses one texel with a gutter")
		expect(job.atlas_albedo.size() == 3 * 3 * 4, "the uniform atlas retains its RGBA texels")
	)
	scene_renderer.queue_free()


func _atlas_settle() -> void:
	while not scene_renderer.is_settled():
		await get_tree().process_frame


func _displayed_key() -> PackedInt64Array:
	return scene_renderer._displayed_surface_keys[chunk_position]


func _chunk_material() -> StandardMaterial3D:
	return VoxelRenderer._surface_cache[_displayed_key()].material


func _holds_color(texture: Texture2D, color: Color) -> bool:
	var expected := Vector3i(roundi(color.r * 255.0), roundi(color.g * 255.0), roundi(color.b * 255.0))
	var image: Image = texture.get_image()
	for y in image.get_height():
		for x in image.get_width():
			var texel := image.get_pixel(x, y)
			if absi(roundi(texel.r * 255.0) - expected.x) <= 1 and absi(roundi(texel.g * 255.0) - expected.y) <= 1 and absi(roundi(texel.b * 255.0) - expected.z) <= 1:
				return true
	return false


# The packed finish texture holds roughness in green and metallic in blue.
func _holds_finish(texture: Texture2D, material: Dictionary) -> bool:
	var expected := Vector2i(roundi(material.roughness * 255.0), roundi(material.metallic * 255.0))
	var image: Image = texture.get_image()
	for y in image.get_height():
		for x in image.get_width():
			var texel := image.get_pixel(x, y)
			if absi(roundi(texel.g * 255.0) - expected.x) <= 1 and absi(roundi(texel.b * 255.0) - expected.y) <= 1:
				return true
	return false


func _rebuild_scope_run() -> void:
	step("Given a settled solid 32-cube", func():
		scope_frame = State.get_current_voxel_frame()
		var cells := {}
		for z in 32:
			for y in 32:
				for x in 32:
					cells[Vector3i(x, y, z)] = scope_material
		scope_frame.set_cells(cells)
		scope_renderer = viewport_scene().get_node("VoxelRenderer")
		sync_viewport()
	)
	await _scope_settle()
	step("Then every chunk of the block is drawn", func():
		expect(scope_renderer.is_settled(), "the renderer finished the initial surfaces")
		expect(scope_renderer._chunk_instances.size() == 8, "the block covers eight chunks")
	)

	step("When an interior cell changes material", func():
		scope_reported = _scope_edit(Vector3i(8, 8, 8))
	)
	step("Then only the owning chunk is rebuilt", func():
		expect(scope_reported == [Vector3i.ZERO], "an interior cell rebuilds only its own chunk")
		expect(_scope_pending() == [Vector3i.ZERO], "the renderer requests only that chunk")
	)
	await _scope_settle()

	step("When a cell on the positive x face changes material", func():
		scope_reported = _scope_edit(Vector3i(15, 8, 8))
	)
	step("Then the owning chunk and its face neighbor are rebuilt", func():
		expect(scope_reported == [Vector3i.ZERO, Vector3i(1, 0, 0)], "a face cell also rebuilds the neighbor across that face")
		expect(_scope_pending() == [Vector3i.ZERO, Vector3i(1, 0, 0)], "the renderer requests the chunk and its face neighbor")
	)
	await _scope_settle()

	step("When the corner cell at 15,15,15 changes material", func():
		scope_reported = _scope_edit(Vector3i(15, 15, 15))
	)
	step("Then every chunk that reads that corner is rebuilt", func():
		var corners: Array[Vector3i] = []
		for z in range(0, 2):
			for y in range(0, 2):
				for x in range(0, 2):
					corners.append(Vector3i(x, y, z))
		corners.sort()
		var sorted_reported := scope_reported.duplicate()
		sorted_reported.sort()
		expect(sorted_reported == corners, "a corner cell reports all eight corner chunks")
		var requested := _scope_pending()
		var within_reported := true
		for chunk_location in requested:
			within_reported = within_reported and scope_reported.has(chunk_location)
		expect(within_reported, "the renderer requests no chunk outside the reported set")
	)
	await _scope_settle()

	step("When the same material is written again", func():
		scope_reported = _scope_edit(Vector3i(8, 8, 8))
	)
	step("Then no surface is rebuilt", func():
		expect(scope_reported.is_empty(), "a repeated material write reports no chunk")
		expect(scope_renderer.is_settled(), "the renderer stays idle after a repeated write")
	)


func _scope_edit(cell_position: Vector3i) -> Array[Vector3i]:
	var changed := scope_frame.set_cells({cell_position: VoxelFrame.material(Color.BLUE)})
	State.chunks_changed.emit(State.current_frame, changed)
	return changed


func _scope_pending() -> Array[Vector3i]:
	var pending: Array[Vector3i] = []
	pending.assign(scope_renderer._pending_surface_keys.keys())
	pending.sort()
	return pending


func _scope_settle() -> void:
	while not scope_renderer.is_settled():
		await get_tree().process_frame


func _storage_run() -> void:
	step("Given a chunk size that matches the chunk-position shift", func():
		# `chunk_position` shifts instead of dividing, so the two constants must
		# agree. This fails loudly if either one moves.
		expect(VoxelFrame.CHUNK_SIZE == 1 << VoxelFrame.CHUNK_SHIFT, "the chunk shift is the base-two logarithm of the chunk size")
		expect(VoxelFrame.chunk_position(Vector3i(-1, -17, 15)) == Vector3i(-1, -2, 0), "the chunk position floors toward negative infinity")
	)
	step("Given a solid chunk and a separate negative-coordinate voxel", func():
		storage_original = State.get_current_voxel_frame()
		for z in 16:
			for y in 16:
				for x in 16:
					State.paint(Vector3i(x, y, z), VoxelFrame.material(Color.RED))
		State.paint(Vector3i(-17, 3, -1), VoxelFrame.material(Color(0.25, 0.5, 0.75, 0.5)))
		storage_data = storage_original.voxel_data
		State.duplicate_frame()
		storage_duplicate = State.get_current_voxel_frame()
		State.undo_redo.clear_history()
	)
	step("When the user edits the duplicate and undoes the edit from another frame", func():
		var tx := State.begin_edit()
		var replacement_colors := {}
		for z in 16:
			for y in 16:
				for x in 16:
					replacement_colors[Vector3i(x, y, z)] = VoxelFrame.material(Color.BLUE)
		storage_duplicate.set_cells(replacement_colors)
		State.finish_edit(tx)
		State.current_frame = 0
		var started := Time.get_ticks_usec()
		State.undo_redo.undo()
		storage_undo_us = Time.get_ticks_usec() - started
	)
	step("Then the original and the restored duplicate share the original voxel version", func():
		expect(storage_original.get_color(Vector3i.ZERO) == Color.RED, "the original keeps its red voxel")
		expect(storage_duplicate.get_color(Vector3i.ZERO) == Color.RED, "undo restores the duplicate's red voxel")
		expect(storage_original.chunks[Vector3i.ZERO] == storage_duplicate.chunks[Vector3i.ZERO], "undo restores the shared chunk")
	)
	step("When the user redoes the edit and saves the duplicate", func():
		var started := Time.get_ticks_usec()
		State.undo_redo.redo()
		storage_redo_us = Time.get_ticks_usec() - started
		storage_data = storage_duplicate.voxel_data
		var document := VoxelDocument.new()
		document.frames.assign([storage_duplicate])
		var error := document.save_file("user://chunk_storage_test.lve")
		expect(error == OK, "the compact document saves")
		var storage_loaded := VoxelDocument.load_file("user://chunk_storage_test.lve")
		storage_restored = storage_loaded.frames[0] if storage_loaded else null
		DirAccess.remove_absolute("user://chunk_storage_test.lve")
	)
	step("Then the compact file preserves every voxel and color", func():
		expect(storage_data.size() < 2048, "the uniform chunk uses less than two kilobytes")
		expect(storage_restored != null, "the compact document loads")
		if storage_restored:
			expect(storage_restored.count() == 4097, "the file restores all occupied cells")
			expect(storage_restored.get_color(Vector3i(15, 15, 15)) == Color.BLUE, "the solid region keeps its blue color")
			expect(storage_restored.get_color(Vector3i(-17, 3, -1)) == Color(0.25, 0.5, 0.75, 0.5), "the sparse voxel keeps its position and alpha")
		expect(storage_original.get_color(Vector3i.ZERO) == Color.RED, "redo leaves the original frame red")
		print("Chunk history: undo %s us, redo %s us, storage %s bytes" % [storage_undo_us, storage_redo_us, storage_data.size()])
	)
	step("When the user paints a transparent color and cancels", func():
		State.current_frame = 1
		var tx := State.begin_edit()
		State.paint(Vector3i.ZERO, VoxelFrame.material(Color.TRANSPARENT))
		expect(not storage_duplicate.has(Vector3i.ZERO), "transparent paint erases the voxel")
		State.cancel_edit(tx)
		expect(storage_duplicate.get_color(Vector3i.ZERO) == Color.BLUE, "cancel restores the blue voxel")
	)
	step("When the user erases voxels across chunk boundaries and cancels", func():
		var tx := State.begin_edit()
		storage_duplicate.set_cells({Vector3i.ZERO: VoxelFrame.material(Color.TRANSPARENT), Vector3i(-17, 3, -1): VoxelFrame.material(Color.TRANSPARENT)})
		expect(storage_duplicate.count() == 4095, "the batch erases both occupied voxels")
		expect(storage_duplicate.get_bounds() == AABB(Vector3.ONE * -0.5, Vector3.ONE * 16), "the batch updates the occupied bounds")
		State.cancel_edit(tx)
		expect(storage_duplicate.count() == 4097, "cancel restores both erased voxels")
		expect(storage_duplicate.get_bounds() == storage_original.get_bounds(), "cancel restores the original bounds")
	)
	step("When a chunk that one fill wrote is repainted cell by cell", func():
		State.document = VoxelDocument.new()
		var storage_frame := State.get_current_voxel_frame()
		var storage_material := VoxelFrame.material(Color.RED)
		var batch := {}
		for z in 16:
			for y in 16:
				for x in 16:
					batch[Vector3i(x, y, z)] = storage_material
		storage_frame.set_cells(batch)
		var filled: VoxelFrame.Chunk = storage_frame.chunks[Vector3i.ZERO]
		expect(filled.materials.size() / VoxelFrame.MATERIAL_STRIDE == 1, "the fill leaves one material entry for the whole chunk")
		# A repaint gives each edited cell its own entry. A repaint-only workload
		# never erases, so the reclamation has to run on the write path or the table
		# grows with every edit.
		var blue := VoxelFrame.material(Color.BLUE)
		for index in 100:
			var repaint := {}
			for repaint_step in 100:
				repaint[Vector3i((index * 100 + repaint_step) % 16, (index * 100 + repaint_step) / 16 % 16, index % 16)] = blue
			storage_frame.set_cells(repaint)
		var repainted: VoxelFrame.Chunk = storage_frame.chunks[Vector3i.ZERO]
		expect(repainted.materials.size() / VoxelFrame.MATERIAL_STRIDE <= repainted.occupied_count * 2, "repeated repaints keep the material table bounded")
	)
