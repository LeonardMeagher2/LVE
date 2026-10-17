extends "res://tests/test.gd"

var panel: PalettePanel
var renderer: Node
var matte := VoxelFrame.material(Color("b88648"), Color.BLACK, 0.0, 0.8)
var polished := VoxelFrame.material(Color("b88648"), Color.BLACK, 1.0, 0.05)
var rough := VoxelFrame.material(Color("b88648"), Color.BLACK, 1.0, 0.8)
var textures: Array[Texture2D] = []


func _ready() -> void:
	timeout = 30.0
	test("Square material thumbnails retain the rounded swatch style and reuse rendered textures", _run)


func _run() -> void:
	step("Given three same-color swatches with different material values", func():
		panel = main.find_child("PalettePanel", true, false)
		renderer = panel.get_node("%MaterialThumbnails")
		main.set_ui_scale(1.0, false)
		State.set_palette([matte, polished, rough])
		State.select_palette_entry(1)
	)
	await _settle()
	step("Then each square tile has its own material image", func():
		var grid := panel.get_node("%SwatchGrid")
		for swatch in grid.get_children():
			var texture: Texture2D = swatch.thumbnail_texture
			textures.append(texture)
			expect(texture != null and texture.get_width() == texture.get_height(), "the material image stays square")
			var style: StyleBoxFlat = swatch.get_theme_stylebox("normal")
			expect(style.corner_radius_top_left == 3 and style.border_width_left == 1, "the swatch keeps its original rounded border")
			expect(panel.get_node("%Scroll").get_global_rect().encloses(swatch.get_global_rect()), "the complete swatch fits inside the palette grid")
			expect(swatch.focus_mode != Control.FOCUS_NONE, "the swatch retains keyboard focus")
		expect(textures[0] != textures[1] and textures[1] != textures[2], "same-color variants have separate cached textures")
		expect(renderer.get_node("SubViewport").render_target_update_mode == SubViewport.UPDATE_DISABLED, "the shared viewport stops after rendering")
		if DisplayServer.get_name() != "headless":
			expect(textures[0].get_image().get_data() != textures[1].get_image().get_data(), "the thumbnail shows the metallic difference")
			expect(textures[1].get_image().get_data() != textures[2].get_image().get_data(), "the thumbnail shows the roughness difference")
			expect(textures[0].get_image().get_pixel(0, 0).a < 1.0, "the image follows the rounded swatch corners")
	)
	step("When a selected swatch is focused and requested again", func():
		var swatch := panel.get_node("%SwatchGrid").get_child(1)
		swatch.grab_focus()
		var cached: Texture2D = renderer.request_thumbnail(polished, 1.0)
		expect(cached == textures[1], "an unchanged material reuses its cached texture")
		expect(swatch.has_focus() and swatch.button_pressed, "focus and selection remain separate from the material image")
		var drag: Dictionary = swatch._get_drag_data(Vector2.ZERO)
		expect(drag.material == polished and drag.from == 1, "dragging carries the full indexed material")
		State.document.lighting_settings = {"color": Color.RED, "ambient_color": Color.BLUE}
		expect(renderer.request_thumbnail(polished, 1.0) == cached, "document lighting does not change the thumbnail")
	)
	await _capture("swatches_100.png")
	step("When the user doubles the display scale", func():
		main.set_ui_scale(2.0, false)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	await _settle()
	step("Then thumbnails use more pixels without changing their logical squares", func():
		var grid := panel.get_node("%SwatchGrid")
		for index in grid.get_child_count():
			var swatch := grid.get_child(index)
			expect(swatch.thumbnail_texture.get_width() > textures[index].get_width(), "the thumbnail uses the increased display scale")
			expect(swatch.size.x == swatch.size.y, "the scaled swatch remains square")
		expect(renderer.get_node("SubViewport").render_target_update_mode == SubViewport.UPDATE_DISABLED, "scaling does not leave a viewport rendering")
	)
	await _capture("swatches_200.png")
	main.set_ui_scale(1.0, false)


func _settle() -> void:
	await get_tree().process_frame
	while renderer._rendering or not renderer._pending.is_empty():
		await get_tree().process_frame


func _capture(filename: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	get_tree().root.get_texture().get_image().save_png(_dir() + "/" + filename)
