extends "res://tests/test.gd"

var menu_bar: Node
var exporter: Node
var imported_scene: Node
var player: AnimationPlayer
var export_error := OK
var source_document: VoxelDocument
var json_data := {}
var raw_meshes: Array[ImporterMesh] = []
const JSON_PATH := "user://voxel_export_test.gltf"
const BINARY_PATH := "user://voxel_export_test.glb"
const SOURCE_COLOR := Color(0.5, 0.25, 0.75, 0.5)
const SOURCE_EMISSION := Color(4.0, 2.0, 1.0)
const SECOND_EMISSION := Color(0.5, 0.25, 0.125)
const EMISSION_ENERGY := 4.0


func _ready() -> void:
	timeout = 30.0
	test("glTF exports voxel frames as exact flipbook clips with frame delays and baked tag repeats", _run)


func _run() -> void:
	step("Given three frames with different geometry and animation tags", func():
		State.document = VoxelDocument.new()
		source_document = State.document
		source_document.frames[0].set_cell(Vector3i(-17, 3, -1), VoxelFrame.material(SOURCE_COLOR, SOURCE_EMISSION, 0.8, 0.25))
		source_document.frames[0].delay_ms = 100
		var second := source_document.add_frame()
		second.set_cell(Vector3i(15, 0, 0), VoxelFrame.material(Color.RED, SECOND_EMISSION, 0.2, 0.7))
		second.set_cell(Vector3i(16, 0, 0), VoxelFrame.material(Color.GREEN, Color.BLACK, 0.6, 0.4))
		second.delay_ms = 250
		var third := source_document.add_frame()
		third.delay_ms = 150
		source_document.add_tag("Walk", 0, 1, AnimationTag.LoopMode.FORWARD, 2)
		source_document.add_tag("Reverse", 0, 2, AnimationTag.LoopMode.REVERSE, 1)
		source_document.add_tag("PingPong", 0, 2, AnimationTag.LoopMode.PING_PONG, 2)
		source_document.add_tag("InfinitePing", 0, 2, AnimationTag.LoopMode.PING_PONG, 0)
		source_document.add_tag("LoopOnce", 0, 1, AnimationTag.LoopMode.FORWARD, 1)
		menu_bar = main.get_node("Content/VBoxContainer/MenuBar")
		exporter = plugin("ExportPlugin")
		menu_bar.current_save_path = "user://original.tres"
	)
	step("When the user opens the Export workspace and chooses glTF", func():
		var button: Button = exporter._menu_item.get_node("ExportBtn")
		expect(button.icon != null, "the glTF export button has its own icon")
		expect(exporter._menu_item.get_parent() == menu_bar, "the export plugin adds its control to the MenuBar")
		var separator := menu_bar.get_node("Sep1")
		expect(exporter._menu_item.get_index() < separator.get_index(), "export appears before the history separator")
		expect(menu_bar.get_node("UndoBtn").get_index() == separator.get_index() + 1, "undo follows the separator")
		expect(menu_bar.get_node("RedoBtn").get_index() == separator.get_index() + 2, "redo follows undo at the end of the controls")
		button.button_pressed = true
		expect(exporter._workspace.visible, "the export button opens the Export workspace")
		expect(not exporter._dialog.visible, "opening the workspace starts with previews and settings")
		exporter._model.get_node("Export").pressed.emit()
		var dialog: FileDialog = exporter._dialog
		expect(dialog.visible, "the export button opens the export dialog")
		expect(dialog.file_mode == FileDialog.FILE_MODE_SAVE_FILE, "the export dialog saves a file")
		expect(dialog.access == FileDialog.ACCESS_FILESYSTEM, "the export dialog permits filesystem paths")
		expect(dialog.filters.size() == 2, "the export dialog offers glTF and GLB formats")
		expect(dialog.option_count == 0, "the export dialog needs no animation-method selection")
		dialog.hide()
		exporter.show_editor_tab()
	)
	export_error = await exporter.export_gltf(JSON_PATH)
	step("Then the exported file uses standard stepped scale animation", func():
		expect(export_error == OK, "the glTF file exports successfully")
		var file := FileAccess.open(JSON_PATH, FileAccess.READ)
		if file == null:
			expect(false, "the glTF file is readable")
			return
		json_data = JSON.parse_string(file.get_as_text())
		expect(json_data.asset.version == "2.0", "the file uses glTF 2.0")
		_check_json(json_data, false)
		var model_root := -1
		for node_index in json_data.nodes.size():
			if json_data.nodes[node_index].name == "LVE":
				model_root = node_index
		for node_index in json_data.nodes.size():
			var node: Dictionary = json_data.nodes[node_index]
			if not node.get("name", "").begins_with("Frame_"):
				continue
			expect(json_data.nodes[model_root].children.has(float(node_index)), "each frame is a direct child of the model root")
			expect(not node.has("children"), "frame meshes have no wrapper nodes")
		expect(json_data.animations.size() == source_document.tags.size(), "the export contains only the named tag clips")
		for animation in json_data.animations:
			expect(animation.name != "Timeline", "the export contains no additional timeline clip")
			var stepped := true
			for sampler in animation.samplers:
				stepped = stepped and sampler.interpolation == "STEP"
			expect(stepped, "%s uses step interpolation" % animation.name)
			var scale_channels := 0
			var scale_targets_valid := true
			for channel in animation.channels:
				scale_targets_valid = scale_targets_valid and channel.target.path == "scale" and not json_data.nodes[channel.target.node].has("matrix")
				scale_channels += 1
			expect(scale_targets_valid, "%s uses standard scale targets" % animation.name)
			expect(scale_channels == 3, "every frame has one scale track")
		expect(State.document == source_document, "export preserves the source document")
		expect(menu_bar.current_save_path == "user://original.tres", "export preserves the document save path")
		expect(not State.edit_busy(), "export completion releases editing")
	)
	step("When another application imports the glTF file", func():
		_import(JSON_PATH)
	)
	step("Then geometry, colors, and exact frame timing survive import", func():
		if imported_scene == null or player == null:
			return
		var first_mesh: MeshInstance3D = imported_scene.find_child("Frame_0", true, false)
		expect(first_mesh.mesh.get_aabb() == AABB(Vector3(-17, 1, -1), Vector3.ONE), "the first frame uses the shared centering offset")
		var second_mesh: MeshInstance3D = imported_scene.find_child("Frame_1", true, false)
		var combined_bounds := first_mesh.mesh.get_aabb().merge(second_mesh.mesh.get_aabb())
		expect(combined_bounds.get_center().is_zero_approx(), "the combined animation bounds are centered at the origin")
		var frame_distance := second_mesh.mesh.get_aabb().get_center() - first_mesh.mesh.get_aabb().get_center()
		expect(frame_distance.is_equal_approx(Vector3(32.5, -3, 1)), "centering preserves the relative frame positions")
		var triangle_indices := 0
		for surface_index in second_mesh.mesh.get_surface_count():
			triangle_indices += second_mesh.mesh.surface_get_arrays(surface_index)[Mesh.ARRAY_INDEX].size()
		expect(triangle_indices == 60, "the adjacent voxels retain ten seam-bounded faces across the chunk boundary")
		_check_samples()
		var default_clip := player.get_animation("Default_loop")
		expect(is_equal_approx(default_clip.length, 0.5), "the default tag retains every frame delay")
		_show("Default_loop", 0.099)
		expect(_active_frame() == 0, "the first frame holds for its full delay")
		_show("Default_loop", 0.101)
		expect(_active_frame() == 1, "the second frame starts at its delay boundary")
		expect(first_mesh.scale.is_zero_approx(), "the inactive mesh has zero scale")
		expect(second_mesh.scale.is_equal_approx(Vector3.ONE), "the active mesh has full scale")
		_show("Default_loop", 0.349)
		expect(_active_frame() == 1, "the second frame holds without a scale transition")
		_show("Default_loop", 0.351)
		expect(_active_frame() == 2, "the empty third frame starts at its delay boundary")
		expect(imported_scene.find_child("Frame_2", true, false).get_child_count() == 0, "the empty frame has no mesh")
	)
	step("Then scale changes retain one active frame at switch boundaries", func():
		if player == null:
			return
		for time in [0.1, 0.10000001, 0.1005, 0.35, 0.35000001, 0.3505]:
			_show("Default_loop", time)
			expect(_active_frame() >= 0, "the frame switch retains one full-scale frame")
	)
	step("Then tag direction and finite repeats are baked into linear clips", func():
		if player == null:
			return
		expect(is_equal_approx(player.get_animation("Walk").length, 0.7), "the forward clip contains both repeats")
		_show("Walk", 0.351)
		expect(_active_frame() == 0, "the second forward pass starts with the first frame")
		_show("Walk", 0.451)
		expect(_active_frame() == 1, "the second forward pass advances to the second frame")
		_show("Reverse", 0.01)
		expect(_active_frame() == 2, "the reverse clip starts with the last frame")
		_show("Reverse", 0.151)
		expect(_active_frame() == 1, "the reverse clip moves to the previous frame")
		expect(is_equal_approx(player.get_animation("PingPong").length, 1.6), "the ping-pong clip contains both complete passes")
		_show("PingPong", 0.501)
		expect(_active_frame() == 1, "the ping-pong clip returns from the last frame")
		_show("PingPong", 0.751)
		expect(_active_frame() == 0, "the second ping-pong pass starts at the first frame")
		_show("PingPong", 1.55)
		expect(_active_frame() == 0, "the finite ping-pong clip finishes on the first frame")
	)
	step("Then infinite tags import as loops and finite tags stay one-shot", func():
		if player == null:
			return
		expect(player.get_animation("Default_loop").loop_mode == Animation.LOOP_LINEAR, "the default tag imports with linear looping")
		expect(player.get_animation("InfinitePing_loop").loop_mode == Animation.LOOP_LINEAR, "the baked ping-pong cycle imports with linear looping")
		expect(is_equal_approx(player.get_animation("InfinitePing_loop").length, 0.75), "the infinite ping-pong tag exports one complete cycle")
		expect(player.get_animation("Walk").loop_mode == Animation.LOOP_NONE, "the finite forward repeats stay one-shot")
		expect(player.get_animation("PingPong").loop_mode == Animation.LOOP_NONE, "the finite ping-pong repeats stay one-shot")
		expect(player.get_animation("Clip_LoopOnce").loop_mode == Animation.LOOP_NONE, "a finite tag name cannot enable infinite looping")
		_show("Default_loop", 0.499)
		player.play("Default_loop")
		player.advance(0.002)
		player.pause()
		expect(_active_frame() == 0, "the infinite clip returns to its first frame after its last delay")
		expect(not player.has_animation("Timeline"), "the imported player contains no extra timeline clip")
	)
	_free_import()
	export_error = await exporter.export_gltf(BINARY_PATH)
	step("Then the binary glTF file imports with the same clips", func():
		expect(export_error == OK, "the GLB file exports successfully")
		_check_json(_read_glb_json(), true)
		_import(BINARY_PATH)
		_check_samples()
		if player:
			expect(player.has_animation("Default_loop") and player.has_animation("Walk"), "the GLB file retains its animation clips")
			expect(player.get_animation("Default_loop").loop_mode == Animation.LOOP_LINEAR, "the GLB file retains infinite looping")
			expect(not player.has_animation("Timeline"), "the GLB file contains no extra timeline clip")
			_show("Default_loop", 0.101)
			expect(_active_frame() == 1, "the GLB animation displays the correct frame")
	)
	_free_import()
	var output_paths := [JSON_PATH, BINARY_PATH]
	for buffer in json_data.get("buffers", []):
		if buffer.has("uri") and not str(buffer.uri).begins_with("data:"):
			output_paths.append(JSON_PATH.get_base_dir().path_join(buffer.uri))
	for image in json_data.get("images", []):
		if image.has("uri") and not str(image.uri).begins_with("data:"):
			output_paths.append(JSON_PATH.get_base_dir().path_join(image.uri))
	for path in output_paths:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func _import(path: String) -> void:
	raw_meshes.clear()
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var error := document.append_from_file(path, state)
	expect(error == OK, "the exported file imports successfully")
	if error != OK:
		return
	for gltf_mesh in state.get_meshes():
		raw_meshes.append(gltf_mesh.mesh)
	imported_scene = document.generate_scene(state, 1000, false, false)
	expect(imported_scene != null, "the file creates a scene")
	if imported_scene == null:
		return
	main.add_child(imported_scene)
	var previous_material: StandardMaterial3D
	var surfaces_valid := true
	var materials_valid := true
	var albedo_valid := true
	var finish_valid := true
	var emission_valid := true
	var frame_atlases_unique := true
	for frame_index in 3:
		var frame_node := imported_scene.find_child("Frame_%d" % frame_index, true, false)
		var mesh_instance := frame_node as MeshInstance3D
		if mesh_instance == null:
			continue
		surfaces_valid = mesh_instance.mesh.get_surface_count() == 1 and surfaces_valid
		for surface_index in mesh_instance.mesh.get_surface_count():
			var material := mesh_instance.get_active_material(surface_index) as StandardMaterial3D
			materials_valid = material != null and materials_valid
			if material == null:
				continue
			albedo_valid = not material.vertex_color_use_as_albedo and material.albedo_texture != null and albedo_valid
			finish_valid = material.roughness_texture != null and material.roughness_texture == material.metallic_texture and finish_valid
			finish_valid = material.roughness_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_GREEN and material.metallic_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_BLUE and finish_valid
			finish_valid = is_equal_approx(material.roughness, 1.0) and is_equal_approx(material.metallic, 1.0) and finish_valid
			emission_valid = material.emission_enabled and material.emission_texture != null and emission_valid
			emission_valid = material.emission.is_equal_approx(Color.WHITE) and material.emission_operator == BaseMaterial3D.EMISSION_OP_MULTIPLY and emission_valid
			emission_valid = is_equal_approx(material.emission_energy_multiplier, EMISSION_ENERGY if frame_index == 0 else 1.0) and emission_valid
			if previous_material:
				frame_atlases_unique = material != previous_material and material.albedo_texture != previous_material.albedo_texture and frame_atlases_unique
				frame_atlases_unique = material.roughness_texture != previous_material.roughness_texture and material.emission_texture != previous_material.emission_texture and frame_atlases_unique
			previous_material = material
	expect(surfaces_valid and materials_valid, "each nonempty frame has one surface with a standard material")
	expect(albedo_valid, "all imported materials use albedo atlases instead of vertex colors")
	expect(finish_valid, "all finish atlases share green roughness and blue metallic with unit multipliers")
	expect(emission_valid, "all emission atlases multiply white emission with each frame's restored energy")
	expect(frame_atlases_unique, "each nonempty frame owns its material and all three atlases")
	player = imported_scene.find_child("AnimationPlayer", true, false)
	expect(player != null, "the imported scene has a standard animation player")


func _check_json(data: Dictionary, embedded: bool) -> void:
	var materials: Array = data.get("materials", [])
	var meshes: Array = data.get("meshes", [])
	expect(materials.size() == 2 and meshes.size() == 2, "only the two nonempty frames have glTF meshes and materials")
	var used_materials := {}
	var primitives_valid := true
	var attributes_valid := true
	var material_bindings_valid := true
	for mesh in meshes:
		var primitives: Array = mesh.get("primitives", [])
		primitives_valid = primitives.size() == 1 and primitives_valid
		for primitive in primitives:
			var attributes: Dictionary = primitive.get("attributes", {})
			attributes_valid = not attributes.has("COLOR_0") and attributes.has("TEXCOORD_0") and attributes_valid
			var material_index := int(primitive.get("material", -1))
			material_bindings_valid = material_index >= 0 and material_index < materials.size() and material_bindings_valid
			used_materials[material_index] = true
	expect(primitives_valid, "each nonempty frame has one glTF primitive")
	expect(attributes_valid, "all primitives use atlas UVs instead of vertex colors")
	expect(material_bindings_valid and used_materials.size() == 2, "all primitives bind distinct valid frame materials")
	var texture_owners := {}
	var strengths: Array[float] = []
	var texture_bindings_valid := true
	var image_bindings_valid := true
	var samplers_valid := true
	var emission_factors_valid := true
	for material_index in materials.size():
		var material: Dictionary = materials[material_index]
		var pbr: Dictionary = material.get("pbrMetallicRoughness", {})
		var textures: Array = data.get("textures", [])
		var images: Array = data.get("images", [])
		var samplers: Array = data.get("samplers", [])
		for binding in [pbr.get("baseColorTexture", {}), pbr.get("metallicRoughnessTexture", {}), material.get("emissiveTexture", {})]:
			var texture_index := int(binding.get("index", -1))
			texture_bindings_valid = texture_index >= 0 and texture_index < textures.size() and texture_bindings_valid
			if texture_index < 0 or texture_index >= textures.size():
				continue
			texture_bindings_valid = (not texture_owners.has(texture_index) or texture_owners[texture_index] == material_index) and texture_bindings_valid
			texture_owners[texture_index] = material_index
			var texture: Dictionary = textures[texture_index]
			var image_index := int(texture.get("source", -1))
			image_bindings_valid = image_index >= 0 and image_index < images.size() and image_bindings_valid
			var sampler_index := int(texture.get("sampler", -1))
			samplers_valid = sampler_index >= 0 and sampler_index < samplers.size() and samplers_valid
			if sampler_index >= 0 and sampler_index < samplers.size():
				var sampler: Dictionary = samplers[sampler_index]
				samplers_valid = sampler.get("magFilter", -1) == 9728 and sampler.get("minFilter", -1) == 9728 and samplers_valid
		var strength: Dictionary = material.get("extensions", {}).get("KHR_materials_emissive_strength", {})
		strengths.append(float(strength.get("emissiveStrength", 1.0)))
		var factor: Array = material.get("emissiveFactor", [])
		emission_factors_valid = factor == [1.0, 1.0, 1.0] and emission_factors_valid
	strengths.sort()
	expect(texture_bindings_valid, "all PBR channels bind valid textures owned by one frame")
	expect(image_bindings_valid, "all atlas textures bind valid images")
	expect(samplers_valid, "all atlas textures bind valid nearest-filter samplers")
	expect(emission_factors_valid and strengths == [1.0, EMISSION_ENERGY] and data.get("extensionsUsed", []).has("KHR_materials_emissive_strength"), "all emission factors and declared strengths preserve each frame's normalized energy")
	if embedded:
		var images: Array = data.get("images", [])
		var images_embedded := not images.is_empty()
		for image in images:
			var view_index := int(image.get("bufferView", -1))
			images_embedded = not image.has("uri") and view_index >= 0 and view_index < data.get("bufferViews", []).size() and images_embedded
		expect(images_embedded, "the GLB contains atlas images embedded in valid buffer views")


func _read_glb_json() -> Dictionary:
	var file := FileAccess.open(BINARY_PATH, FileAccess.READ)
	expect(file != null, "the GLB header is readable")
	if file == null or file.get_length() < 20:
		return {}
	var magic := file.get_32()
	var version := file.get_32()
	var length := file.get_32()
	expect(magic == 0x46546c67 and version == 2 and length == file.get_length(), "the GLB has a valid version-two header")
	var json_length := file.get_32()
	var chunk_type := file.get_32()
	expect(chunk_type == 0x4e4f534a and json_length <= file.get_length() - 20, "the GLB starts with a complete JSON chunk")
	if chunk_type != 0x4e4f534a or json_length > file.get_length() - 20:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_buffer(json_length).get_string_from_utf8())
	expect(parsed is Dictionary, "the GLB JSON chunk is readable")
	return parsed if parsed is Dictionary else {}


func _check_samples() -> void:
	expect(raw_meshes.size() == 2, "both nonempty frames retain raw import meshes")
	if raw_meshes.size() != 2 or imported_scene == null:
		return
	var surfaces_valid := true
	var arrays_valid := true
	var materials_valid := true
	var images_valid := true
	var uvs_valid := true
	var albedo_valid := true
	var finish_valid := true
	var emission_valid := true
	for frame_index in 2:
		var mesh := raw_meshes[frame_index]
		surfaces_valid = mesh.get_surface_count() == 1 and surfaces_valid
		if mesh.get_surface_count() != 1:
			continue
		var arrays := mesh.get_surface_arrays(0)
		arrays_valid = arrays[Mesh.ARRAY_COLOR] == null and arrays[Mesh.ARRAY_TEX_UV] is PackedVector2Array and arrays_valid
		var material := mesh.get_surface_material(0) as StandardMaterial3D
		materials_valid = material != null and materials_valid
		if material == null or material.albedo_texture == null or material.roughness_texture == null or material.emission_texture == null:
			continue
		var albedo := material.albedo_texture.get_image()
		var finish := material.roughness_texture.get_image()
		var emission := material.emission_texture.get_image()
		images_valid = albedo != null and finish != null and emission != null and images_valid
		if albedo == null or finish == null or emission == null:
			continue
		images_valid = albedo.get_format() == Image.FORMAT_RGBA8 and images_valid
		var frame_node := imported_scene.find_child("Frame_%d" % frame_index, true, false) as MeshInstance3D
		if frame_node == null:
			continue
		var bounds := frame_node.mesh.get_aabb()
		for cell in (1 if frame_index == 0 else 2):
			var point := bounds.get_center()
			point.y = bounds.end.y
			point.x = bounds.position.x + cell + 0.5
			var uv: Variant = _uv_at(arrays, point)
			uvs_valid = uv is Vector2 and uvs_valid
			if not uv is Vector2:
				continue
			var color := SOURCE_COLOR if frame_index == 0 else (Color.RED if cell == 0 else Color.GREEN)
			var glow := SOURCE_EMISSION if frame_index == 0 else (SECOND_EMISSION if cell == 0 else Color.BLACK)
			var metallic := 0.8 if frame_index == 0 else (0.2 if cell == 0 else 0.6)
			var roughness := 0.25 if frame_index == 0 else (0.7 if cell == 0 else 0.4)
			albedo_valid = _color_close(_texel(albedo, uv), color) and albedo_valid
			var packed := _texel(finish, uv)
			finish_valid = absf(packed.g - roughness) < 0.005 and absf(packed.b - metallic) < 0.005 and finish_valid
			var energy := EMISSION_ENERGY if frame_index == 0 else 1.0
			var normalized := Color(glow.r / energy, glow.g / energy, glow.b / energy).linear_to_srgb()
			emission_valid = _color_close(_texel(emission, uv), normalized, false) and emission_valid
	expect(surfaces_valid, "both raw frames have one surface")
	expect(arrays_valid, "both raw meshes use atlas UV arrays instead of color arrays")
	expect(materials_valid, "both raw meshes have standard materials")
	expect(images_valid, "all atlas images are readable and albedo uses RGBA8")
	expect(uvs_valid, "all sampled face interiors have interpolated atlas UVs")
	expect(albedo_valid, "all sampled faces preserve sRGB albedo and original alpha")
	expect(finish_valid, "all sampled faces preserve roughness and metallic values")
	expect(emission_valid, "all sampled faces preserve normalized sRGB emission across frames")


func _uv_at(arrays: Array, point: Vector3) -> Variant:
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if not arrays[Mesh.ARRAY_TEX_UV] is PackedVector2Array:
		return null
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	if uvs.size() != positions.size():
		return null
	for index in range(0, indices.size(), 3):
		var a := positions[indices[index]]
		var ab := positions[indices[index + 1]] - a
		var ac := positions[indices[index + 2]] - a
		var normal := ab.cross(ac)
		if normal.length_squared() < 0.000001 or absf(normal.normalized().dot(point - a)) > 0.001:
			continue
		var denominator := ab.dot(ab) * ac.dot(ac) - ab.dot(ac) * ab.dot(ac)
		var v := (ac.dot(ac) * (point - a).dot(ab) - ab.dot(ac) * (point - a).dot(ac)) / denominator
		var w := (ab.dot(ab) * (point - a).dot(ac) - ab.dot(ac) * (point - a).dot(ab)) / denominator
		if v >= -0.00001 and w >= -0.00001 and v + w <= 1.00001:
			return uvs[indices[index]] * (1.0 - v - w) + uvs[indices[index + 1]] * v + uvs[indices[index + 2]] * w
	return null


func _texel(image: Image, uv: Vector2) -> Color:
	return image.get_pixel(clampi(floori(uv.x * image.get_width()), 0, image.get_width() - 1), clampi(floori(uv.y * image.get_height()), 0, image.get_height() - 1))


func _color_close(actual: Color, expected: Color, alpha: bool = true) -> bool:
	return absf(actual.r - expected.r) < 0.005 and absf(actual.g - expected.g) < 0.005 and absf(actual.b - expected.b) < 0.005 and (not alpha or absf(actual.a - expected.a) < 0.005)


func _show(clip: String, time: float) -> void:
	player.play(clip)
	player.seek(time, true)
	player.pause()


func _active_frame() -> int:
	var active := -1
	for frame_index in 3:
		var frame_node: Node3D = imported_scene.find_child("Frame_%d" % frame_index, true, false)
		if frame_node.scale.is_equal_approx(Vector3.ONE):
			if active >= 0:
				return -2
			active = frame_index
		elif not frame_node.scale.is_zero_approx():
			return -2
	return active


func _free_import() -> void:
	if imported_scene:
		imported_scene.free()
	imported_scene = null
	player = null
