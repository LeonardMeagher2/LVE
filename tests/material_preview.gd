extends "res://tests/test.gd"

const BrushScript := preload("res://plugins/brush/BrushTool.gd")
const MESH_SAMPLES := preload("res://tests/helpers/mesh_samples.gd")

var tool: Node3D
var cursor: MeshInstance3D
var settings: BrushToolSettings
var shape_mesh: Mesh
var display_material: ShaderMaterial
var revision := 0
var other: MeshInstance3D
var line: Node3D
var paste: Node3D
var colors := {Vector3i.ZERO: Color.BLUE, Vector3i.RIGHT: Color.RED, Vector3i(16, 0, 0): Color.RED, Vector3i(32, 0, 0): Color.BLUE}
var materials := {}


func _ready() -> void:
	timeout = 30.0
	test("painting previews display full materials and reuse cached geometry", _run)


func _run() -> void:
	step("Given a cube cursor with an emitting metallic material", func():
		main.set_ui_scale(1.0, false)
		State.document = VoxelDocument.new()
		activate_tool("Toolbar")
		tool = plugin("BrushPlugin")._tool
		settings = tool._settings
		settings.diameter = 5
		settings.shape = BrushToolSettings.BrushShape.CUBE
		State.current_material = VoxelFrame.material(Color.RED, Color(0.8, 0.5, 0.25), 0.8, 0.2)
		expect(State.current_material == VoxelFrame.material(Color.RED, Color(0.8, 0.5, 0.25), 0.8, 0.2), "the selected material includes the requested parameters")
		tool._show_brush_shape(1)
		tool.visible = true
		tool.position = Vector3.ZERO
		camera_rig().center_on(AABB(Vector3.ONE * -3, Vector3.ONE * 6))
		cursor = tool.get_node("Cursor")
		shape_mesh = cursor.mesh
		display_material = cursor.material_override
		expect(shape_mesh is BoxMesh, "the cube cursor keeps its box mesh")
		_expect_uniform(cursor, State.current_material)
	)
	await _capture("cube_material.png")
	step("When only the cube material parameters change", func():
		State.current_material = VoxelFrame.material(Color.RED, Color(0.25, 0.75, 0.5), 0.3, 0.7)
		tool._show_brush_shape(1)
		expect(cursor.mesh == shape_mesh, "the cube reuses its geometry")
		expect(cursor.material_override == display_material, "the cube reuses its display material")
		_expect_uniform(cursor, State.current_material)
		settings.shape = BrushToolSettings.BrushShape.SPHERE
		tool._show_brush_shape(1)
	)
	await _settle(cursor)
	step("Then the meshed sphere displays the same full material", func():
		shape_mesh = cursor.mesh
		display_material = cursor.material_override
		revision = cursor._request_revision
		expect(shape_mesh is ArrayMesh, "the sphere uses generated voxel geometry")
		_expect_uniform(cursor, State.current_material)
	)
	for parameter in [VoxelFrame.MATERIAL_EMISSION, VoxelFrame.MATERIAL_METALLIC, VoxelFrame.MATERIAL_ROUGHNESS, 2]:
		step("When sphere material parameter %d changes" % parameter, func():
			var value := State.current_material
			value[parameter] += 0.1
			State.current_material = value
			tool._show_brush_shape(1)
			expect(cursor.mesh == shape_mesh and cursor.is_settled(), "the material change reuses the completed sphere immediately")
			expect(cursor._request_revision == revision, "the material change starts no geometry request")
			expect(cursor.material_override == display_material, "the sphere reuses its display material")
			_expect_uniform(cursor, value)
		)
	await _capture("sphere_material.png")
	step("When another preview requests the same sphere", func():
		other = MeshInstance3D.new()
		other.set_script(load("res://plugins/brush/BrushPreview.gd"))
		main.add_child(other)
		other.set_brush_material(VoxelFrame.material(Color.GREEN, Color.BLUE, 0.1, 0.9))
		other.show_voxels(settings.pattern(), Color.GREEN, false, 0, false)
		expect(other.mesh == shape_mesh and other.is_settled(), "the second preview shares the cached sphere")
		expect(other.material_override != display_material, "the previews keep independent display materials")
		_expect_uniform(other, VoxelFrame.material(Color.GREEN, Color.BLUE, 0.1, 0.9))
		_expect_uniform(cursor, State.current_material)
	)
	step("When the selected material returns to the default values", func():
		State.current_material = VoxelFrame.material(Color.RED)
		tool._show_brush_shape(1)
		_expect_uniform(cursor, State.current_material)
		expect(cursor.mesh == shape_mesh and cursor.is_settled(), "clearing the material parameters reuses the sphere")
		cursor.show_voxels(settings.pattern(), Color.RED, true)
	)
	await _settle(cursor)
	step("Then the eraser outline stays separate from the display material", func():
		expect(cursor.material_override == cursor._outline_material, "the outline retains its original material")
		expect(cursor.mesh.surface_get_primitive_type(0) == Mesh.PRIMITIVE_LINES, "the eraser keeps line geometry")
		tool._show_brush_shape(1)
		expect(cursor.mesh == shape_mesh and cursor.is_settled(), "the solid sphere returns from the cache immediately")
	)
	step("Given a voxel brush with different materials across three chunks", func():
		materials = {
			Vector3i.ZERO: VoxelFrame.material(Color.BLUE),
			Vector3i.RIGHT: VoxelFrame.material(Color.RED, Color.GREEN, 0.8, 0.2),
			Vector3i(16, 0, 0): VoxelFrame.material(Color.RED, Color.BLUE, 0.3, 0.7),
			Vector3i(32, 0, 0): VoxelFrame.material(Color.BLUE),
		}
		settings.use_selection(colors, materials)
		tool._show_brush_shape(1)
	)
	await _settle(cursor)
	step("Then each chunk surface displays the copied material values", func():
		shape_mesh = cursor.mesh
		_expect_atlas(cursor)
		expect(shape_mesh.get_aabb().size == Vector3(33, 1, 1), "the chunk surfaces retain their voxel positions")
		tool._show_brush_shape(1)
		expect(cursor.mesh == shape_mesh and cursor.is_settled(), "the voxel brush reuses its cached material surfaces")
	)
	step("When Line and Paste display the same copied materials", func():
		line = load("res://plugins/brush/LineTool.tscn").instantiate()
		main.add_child(line)
		line._stroke_shape = BrushToolSettings.BrushShape.SELECTION
		var job := BrushScript.BrushJob.new()
		job.applied_cells = materials
		line._show_preview(job)
		paste = load("res://plugins/Clipboard/PasteTool.tscn").instantiate()
		main.add_child(paste)
		paste.begin_paste(colors, colors, Vector3i(4, 0, 0), materials)
	)
	await _settle(line.get_node("Cursor"))
	await _settle(paste.get_node("Cursor"))
	step("Then Line and Paste reuse the material preview surfaces", func():
		_expect_atlas(line.get_node("Cursor"))
		_expect_atlas(paste.get_node("Cursor"))
		expect(line.get_node("Cursor").mesh == shape_mesh, "Line reuses the cached full-material geometry")
		expect(paste.get_node("Cursor").mesh == shape_mesh, "Paste reuses its local full-material geometry")
		expect(paste.position == Vector3(4, 0, 0), "Paste retains its placement offset")
		paste._update_endpoint(Vector3i(8, 0, 0))
		expect(paste.get_node("Cursor").mesh == shape_mesh, "moving Paste reuses its local material geometry")
	)
	step("When a copied material changes without a color change", func():
		materials[Vector3i.RIGHT] = VoxelFrame.material(Color.RED, Color.YELLOW, 0.5, 0.4)
		other.show_voxels(materials, Color.WHITE)
		materials[Vector3i.RIGHT][VoxelFrame.MATERIAL_EMISSION] = 0.0
	)
	await _settle(other)
	step("Then the material change replaces the cached surface", func():
		expect(other.mesh != shape_mesh, "different full materials use different cached surfaces")
		var holds_snapshot := false
		for surface in other.mesh.get_surface_count():
			var surface_material: StandardMaterial3D = other.mesh.surface_get_material(surface)
			if surface_material.emission_texture != null:
				holds_snapshot = holds_snapshot or _holds_color(surface_material.emission_texture, Color.YELLOW)
		expect(holds_snapshot, "the new atlas retains the requested emission snapshot")
	)
	line.free()
	paste.free()
	other.free()


func _settle(preview: MeshInstance3D) -> void:
	while not preview.is_settled():
		await get_tree().process_frame


func _expect_uniform(preview: MeshInstance3D, value: PackedFloat32Array) -> void:
	var material: ShaderMaterial = preview.material_override
	var cursor_color: Color = material.get_shader_parameter("cursor_color")
	expect(cursor_color.is_equal_approx(VoxelFrame.material_color(value)), "the cursor displays the selected color")
	var emission_color: Color = material.get_shader_parameter("emission_color")
	expect(emission_color.is_equal_approx(Color(value[4], value[5], value[6])), "the cursor displays the full emission RGB")
	expect(is_equal_approx(material.get_shader_parameter("metallic"), value[7]), "the cursor displays the selected metallic value")
	expect(is_equal_approx(material.get_shader_parameter("roughness"), value[8]), "the cursor displays the selected roughness value")


func _expect_atlas(preview: MeshInstance3D) -> void:
	expect(preview.material_override == null, "the preview uses its per-surface materials")
	expect(preview.mesh.get_surface_count() == 3, "the preview keeps one atlas surface for each chunk")
	if preview.mesh.get_surface_count() != 3:
		return
	var matches := true
	var face_samples := {}
	var chunks := [Vector3i.ZERO, Vector3i(1, 0, 0), Vector3i(2, 0, 0)]
	for surface in preview.mesh.get_surface_count():
		var arrays := preview.mesh.surface_get_arrays(surface)
		var material: StandardMaterial3D = preview.mesh.surface_get_material(surface)
		matches = matches and material.cull_mode == BaseMaterial3D.CULL_DISABLED
		var colors: Variant = arrays[Mesh.ARRAY_COLOR]
		var has_ao: bool = colors is PackedColorArray and colors.size() == arrays[Mesh.ARRAY_VERTEX].size()
		expect(has_ao, "the material surface carries one ambient occlusion color for each vertex")
		matches = matches and has_ao and material.vertex_color_use_as_albedo and not material.vertex_color_is_srgb
		expect(material.albedo_texture != null and material.emission_texture != null and material.roughness_texture != null, "every chunk retains all atlas textures")
		if material.albedo_texture == null or material.emission_texture == null or material.roughness_texture == null:
			matches = false
			continue
		var emission := material.emission_texture.get_image()
		var albedo := material.albedo_texture.get_image()
		var material_values := material.roughness_texture.get_image()
		var energy := 1.0
		for cell: Vector3i in materials:
			if VoxelFrame.chunk_position(cell) == chunks[surface]:
				for component in 3:
					energy = maxf(energy, materials[cell][VoxelFrame.MATERIAL_EMISSION + component])
		matches = matches and albedo.get_format() == Image.FORMAT_RGBA8
		matches = matches and material_values.get_format() == Image.FORMAT_RGB8
		matches = matches and emission.get_format() == Image.FORMAT_RGB8
		matches = matches and material.emission == Color.WHITE
		matches = matches and material.emission_operator == BaseMaterial3D.EMISSION_OP_MULTIPLY
		matches = matches and is_equal_approx(material.emission_energy_multiplier, energy)
		matches = matches and material.metallic_texture == material.roughness_texture
		matches = matches and material.metallic_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_BLUE
		matches = matches and material.roughness_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	# Interpolate the triangle UVs at each exposed voxel face center.
	for cell: Vector3i in materials:
		for direction: Vector3i in [Vector3i.LEFT, Vector3i.RIGHT, Vector3i.DOWN, Vector3i.UP, Vector3i.FORWARD, Vector3i.BACK]:
			if materials.has(cell + direction):
				continue
			var found := false
			for surface in preview.mesh.get_surface_count():
				var arrays := preview.mesh.surface_get_arrays(surface)
				var uv: Variant = MESH_SAMPLES.uv_at(arrays, Vector3(cell) + Vector3(direction) * 0.5, Vector3(direction))
				if uv == null:
					continue
				found = true
				matches = matches and VoxelFrame.chunk_position(cell) == chunks[surface]
				var material: StandardMaterial3D = preview.mesh.surface_get_material(surface)
				if material.albedo_texture == null or material.emission_texture == null or material.roughness_texture == null:
					matches = false
					break
				face_samples[cell] = face_samples.get(cell, 0) + 1
				var expected: PackedFloat32Array = materials[cell]
				var emission := material.emission_texture.get_image()
				var albedo := material.albedo_texture.get_image()
				var material_values := material.roughness_texture.get_image()
				var texel := Vector2i(uv * Vector2(emission.get_size()))
				var glow := emission.get_pixelv(texel)
				var values := material_values.get_pixelv(texel)
				var expected_glow := (Color(expected[4], expected[5], expected[6]) / material.emission_energy_multiplier).linear_to_srgb()
				matches = matches and _colors_match(albedo.get_pixelv(texel), VoxelFrame.material_color(expected))
				matches = matches and _colors_match(glow, Color(expected_glow, 1.0))
				matches = matches and absf(values.b - expected[7]) <= 1.0 / 255.0
				matches = matches and absf(values.g - expected[8]) <= 1.0 / 255.0
				break
			matches = matches and found
	expect(face_samples == {Vector3i.ZERO: 5, Vector3i.RIGHT: 5, Vector3i(16, 0, 0): 6, Vector3i(32, 0, 0): 6}, "all twenty-two exposed voxel faces receive interior samples")
	expect(matches, "every atlas face interior samples its own color, emission, metallic, and roughness")


func _colors_match(actual: Color, expected: Color) -> bool:
	return absf(actual.r - expected.r) <= 1.0 / 255.0 and absf(actual.g - expected.g) <= 1.0 / 255.0 and absf(actual.b - expected.b) <= 1.0 / 255.0 and absf(actual.a - expected.a) <= 1.0 / 255.0


func _holds_color(texture: Texture2D, color: Color) -> bool:
	var image := texture.get_image()
	for y in image.get_height():
		for x in image.get_width():
			if image.get_pixel(x, y).is_equal_approx(color):
				return true
	return false


func _capture(filename: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	get_tree().root.get_texture().get_image().save_png(_dir() + "/" + filename)
