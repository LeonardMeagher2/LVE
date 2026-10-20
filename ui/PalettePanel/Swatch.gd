extends Button

## One palette swatch.
##
## It shows a rounded material thumbnail and selects that palette entry. A
## drag moves the entry to another swatch.

## The drag data type that marks one palette material drag.
const DRAG_TYPE := "voxel_palette_material"
const ThumbnailRenderer := preload("./MaterialThumbnails.gd")

## The material of this swatch. A write also updates the style and the tooltip.
var cell_material: PackedFloat32Array = VoxelFrame.material(Color.BLACK):
	set(value):
		if value.size() != VoxelFrame.MATERIAL_STRIDE:
			return
		cell_material = value.duplicate()
		for style in ["normal", "pressed", "hover"]:
			(get_theme_stylebox(style) as StyleBoxFlat).bg_color = color
		tooltip_text = "Color: #%s\nRGBA: %.2f, %.2f, %.2f, %.2f\nEmission RGB: %.2f, %.2f, %.2f\nMetallic: %.2f\nRoughness: %.2f" % [color.to_html(true), value[0], value[1], value[2], value[3], value[4], value[5], value[6], value[7], value[8]]
		_refresh_thumbnail()

## The palette index of this swatch, or -1.
var palette_index: int = -1
## The color of [member cell_material]. A write keeps the other material values.
var color: Color:
	get:
		return Color(cell_material[0], cell_material[1], cell_material[2], cell_material[3])
	set(value):
		var material := cell_material.duplicate()
		material[0] = value.r
		material[1] = value.g
		material[2] = value.b
		material[3] = value.a
		cell_material = material

## The shared thumbnail renderer. A write reconnects its signal.
var thumbnail_renderer: ThumbnailRenderer:
	set(value):
		_disconnect_renderer()
		thumbnail_renderer = value
		if is_inside_tree():
			_connect_renderer()
		_refresh_thumbnail()

## The current thumbnail texture, or null while it renders.
var thumbnail_texture: Texture2D
var _thumbnail_key := ""


func _enter_tree() -> void:
	_connect_renderer()
	get_viewport().size_changed.connect(_refresh_thumbnail)
	_refresh_thumbnail.call_deferred()


func _ready() -> void:
	cell_material = cell_material
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)
	toggled.connect(func(_pressed: bool): queue_redraw())
	resized.connect(_refresh_thumbnail)


func _exit_tree() -> void:
	_disconnect_renderer()
	get_viewport().size_changed.disconnect(_refresh_thumbnail)


func _connect_renderer() -> void:
	if is_instance_valid(thumbnail_renderer) and not thumbnail_renderer.thumbnail_ready.is_connected(_on_thumbnail_ready):
		thumbnail_renderer.thumbnail_ready.connect(_on_thumbnail_ready)


func _disconnect_renderer() -> void:
	if is_instance_valid(thumbnail_renderer) and thumbnail_renderer.thumbnail_ready.is_connected(_on_thumbnail_ready):
		thumbnail_renderer.thumbnail_ready.disconnect(_on_thumbnail_ready)


func _refresh_thumbnail() -> void:
	thumbnail_texture = null
	if is_inside_tree() and is_instance_valid(thumbnail_renderer):
		var screen_transform := get_viewport().get_stretch_transform() * get_global_transform_with_canvas()
		var display_scale := screen_transform.x.length() * minf(size.x, size.y) / 32.0
		_thumbnail_key = thumbnail_renderer.thumbnail_key(cell_material, display_scale)
		thumbnail_texture = thumbnail_renderer.request_thumbnail(cell_material, display_scale)
	queue_redraw()


func _on_thumbnail_ready(key: String, texture: Texture2D) -> void:
	if key == _thumbnail_key:
		thumbnail_texture = texture
		queue_redraw()


func _draw() -> void:
	var side := minf(size.x, size.y)
	var rect := Rect2((size - Vector2.ONE * side) * 0.5, Vector2.ONE * side)
	var surface := rect.grow(-2.0 if button_pressed else -1.0)
	if thumbnail_texture:
		draw_texture_rect(thumbnail_texture, surface, false)
	if has_focus():
		draw_style_box(get_theme_stylebox("focus"), rect)


func _get_drag_data(_at_position: Vector2) -> Variant:
	if State.edit_busy() or palette_index < 0:
		return null
	var data := {"type": DRAG_TYPE, "from": palette_index, "material": cell_material.duplicate(), "document": State.document}
	if get_viewport() and get_viewport().gui_is_dragging():
		var preview: Control
		if thumbnail_texture:
			var tile := TextureRect.new()
			tile.texture = thumbnail_texture
			tile.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tile.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			preview = tile
		else:
			var placeholder := ColorRect.new()
			placeholder.color = color
			preview = placeholder
		preview.size = size
		set_drag_preview(preview)
	return data


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if State.edit_busy() or not data is Dictionary or data.get("type", "") != DRAG_TYPE or data.get("document") != State.document:
		return false
	if not data.get("from") is int or not data.get("material") is PackedFloat32Array:
		return false
	var from_index: int = data["from"]
	var palette := State.get_palette()
	return palette_index >= 0 and palette_index < palette.size() and from_index >= 0 and from_index < palette.size() and palette[from_index] == data["material"]


func _drop_data(at_position: Vector2, data: Variant) -> void:
	if _can_drop_data(at_position, data):
		State.move_palette_entry(data["from"], palette_index)
