extends "res://tests/test.gd"

var menu_bar: Node
var exporter: Node
var imported_scene: Node
var player: AnimationPlayer
var export_error := OK
var source_document: VoxiDocument
var json_data := {}
const JSON_PATH := "user://voxi_export_test.gltf"
const BINARY_PATH := "user://voxi_export_test.glb"
const SOURCE_COLOR := Color(0.5, 0.25, 0.75, 0.5)


func _ready() -> void:
	timeout = 30.0
	test("glTF exports voxel frames as exact flipbook clips with frame delays and baked tag repeats", _run)


func _run() -> void:
	step("Given three frames with different geometry and animation tags", func():
		State.document = VoxiDocument.new()
		source_document = State.document
		source_document.frames[0].set_cell(Vector3i(-17, 3, -1), SOURCE_COLOR)
		source_document.frames[0].delay_ms = 100
		var second := source_document.add_frame()
		second.set_cell(Vector3i(15, 0, 0), Color.RED)
		second.set_cell(Vector3i(16, 0, 0), Color.GREEN)
		second.delay_ms = 250
		var third := source_document.add_frame()
		third.delay_ms = 150
		source_document.add_tag("Walk", 0, 1, AnimationTag.LoopMode.FORWARD, 2)
		source_document.add_tag("Reverse", 0, 2, AnimationTag.LoopMode.REVERSE, 1)
		source_document.add_tag("PingPong", 0, 2, AnimationTag.LoopMode.PING_PONG, 2)
		source_document.add_tag("InfinitePing", 0, 2, AnimationTag.LoopMode.PING_PONG, 0)
		source_document.add_tag("LoopOnce", 0, 1, AnimationTag.LoopMode.FORWARD, 1)
		menu_bar = main.get_node("Content/VBoxContainer/MenuBar")
		exporter = plugin("GLTFExportPlugin")
		menu_bar.current_save_path = "user://original.tres"
	)
	step("When the user opens the glTF export dialog", func():
		var button: Button = exporter._menu_item.get_node("ExportGLTFBtn")
		expect(button.icon != null, "the glTF export button has its own icon")
		expect(exporter._menu_item.get_parent() == menu_bar, "the export plugin adds its control to the MenuBar")
		var separator := menu_bar.get_node("Sep1")
		expect(exporter._menu_item.get_index() < separator.get_index(), "export appears before the history separator")
		expect(menu_bar.get_node("UndoBtn").get_index() == separator.get_index() + 1, "undo follows the separator")
		expect(menu_bar.get_node("RedoBtn").get_index() == separator.get_index() + 2, "redo follows undo at the end of the controls")
		button.pressed.emit()
		var dialog: FileDialog = exporter._dialog
		expect(dialog.visible, "the export button opens the export dialog")
		expect(dialog.file_mode == FileDialog.FILE_MODE_SAVE_FILE, "the export dialog saves a file")
		expect(dialog.access == FileDialog.ACCESS_FILESYSTEM, "the export dialog permits filesystem paths")
		expect(dialog.filters.size() == 2, "the export dialog offers glTF and GLB formats")
		expect(dialog.option_count == 0, "the export dialog needs no animation-method selection")
		dialog.hide()
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
		expect(json_data.materials.size() == 1, "all exported frames share one vertex-color material")
		expect(json_data.get("extensionsRequired", []).is_empty(), "the flipbook requires no custom extensions")
		expect(json_data.get("extensionsUsed", []).is_empty(), "the export uses only core glTF features")
		var model_root := -1
		for node_index in json_data.nodes.size():
			if json_data.nodes[node_index].name == "Voxi":
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
		var colors: PackedColorArray = first_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
		var expected_color := SOURCE_COLOR.srgb_to_linear()
		expect(absf(colors[0].r - expected_color.r) < 0.005, "vertex colors retain their linear red value")
		expect(absf(colors[0].a - SOURCE_COLOR.a) < 0.005, "vertex colors retain their alpha")
		var second_mesh: MeshInstance3D = imported_scene.find_child("Frame_1", true, false)
		var combined_bounds := first_mesh.mesh.get_aabb().merge(second_mesh.mesh.get_aabb())
		expect(combined_bounds.get_center().is_zero_approx(), "the combined animation bounds are centered at the origin")
		var frame_distance := second_mesh.mesh.get_aabb().get_center() - first_mesh.mesh.get_aabb().get_center()
		expect(frame_distance.is_equal_approx(Vector3(32.5, -3, 1)), "centering preserves the relative frame positions")
		var triangle_indices := 0
		for surface_index in second_mesh.mesh.get_surface_count():
			triangle_indices += second_mesh.mesh.surface_get_arrays(surface_index)[Mesh.ARRAY_INDEX].size()
		expect(triangle_indices == 60, "adjacent chunk voxels export only their exposed faces")
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
		_import(BINARY_PATH)
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
		if buffer.has("uri"):
			output_paths.append(JSON_PATH.get_base_dir().path_join(buffer.uri))
	for path in output_paths:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func _import(path: String) -> void:
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var error := document.append_from_file(path, state)
	expect(error == OK, "the exported file imports successfully")
	if error != OK:
		return
	imported_scene = document.generate_scene(state, 1000, false, false)
	expect(imported_scene != null, "the file creates a scene")
	if imported_scene == null:
		return
	main.add_child(imported_scene)
	var shared_material: BaseMaterial3D
	for frame_index in 3:
		var frame_node := imported_scene.find_child("Frame_%d" % frame_index, true, false)
		var mesh_instance := frame_node as MeshInstance3D
		if mesh_instance == null:
			continue
		for surface_index in mesh_instance.mesh.get_surface_count():
			var material := mesh_instance.get_active_material(surface_index) as BaseMaterial3D
			expect(material != null, "the imported frame has a standard material")
			if material == null:
				continue
			expect(material.vertex_color_use_as_albedo, "the imported material uses vertex colors as albedo")
			expect(not material.vertex_color_is_srgb, "the imported material uses the exported linear vertex colors")
			if shared_material:
				expect(material == shared_material, "the imported surfaces and frames share their vertex-color material")
			shared_material = material
	player = imported_scene.find_child("AnimationPlayer", true, false)
	expect(player != null, "the imported scene has a standard animation player")


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
