extends Control


const LIGHT_SHADER := preload("res://plugins/Export/preview_light.gdshader")

signal zoom_changed(percent: float)

var texture: Texture2D:
	set(value):
		texture = value
		if texture and _fitted:
			fit()
		queue_redraw()
var pan_mode := false
var _animation_rects: Array[Rect2i] = []
var _animation_delays := PackedInt32Array()
var _animation_index := 0
var _animation_elapsed := 0.0
var _zoom := 100.0
var _pan := Vector2.ZERO
var _fitted := true
var _light_enabled := false
var _pointer_inside := false
var _pointer := Vector2.ZERO
var _normal_texture: Texture2D
var _specular_texture: Texture2D
var _specular_intensity := 1.0
var _light_material: ShaderMaterial
@onready var _light: PointLight2D = $Light


func _ready() -> void:
	resized.connect(_on_resized)
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	_light_material = ShaderMaterial.new()
	_light_material.shader = LIGHT_SHADER
	_light_material.set_shader_parameter("ambient", 0.65)
	_light.enabled = false


func _on_resized() -> void:
	if _fitted:
		fit()
	queue_redraw()


func set_animation(rects: Array[Rect2i], delays: PackedInt32Array) -> void:
	_animation_rects = rects
	_animation_delays = delays
	_animation_index = 0
	_animation_elapsed = 0.0
	set_process(not _animation_rects.is_empty())
	if _fitted:
		fit()
	queue_redraw()


func clear_animation() -> void:
	if _animation_rects.is_empty():
		return
	_animation_rects.clear()
	_animation_delays.clear()
	_animation_index = 0
	_animation_elapsed = 0.0
	set_process(false)
	if _fitted:
		fit()
	queue_redraw()


func is_animating() -> bool:
	return not _animation_rects.is_empty()


func fit() -> void:
	_fitted = true
	_pan = Vector2.ZERO
	if texture:
		var image_size := _source_size()
		_zoom = maxf(1.0, minf(size.x / image_size.x, size.y / image_size.y) * 100.0)
		zoom_changed.emit(_zoom)
	queue_redraw()


func _process(delta: float) -> void:
	if _animation_rects.is_empty() or texture == null:
		return
	_animation_elapsed += delta * 1000.0
	if _animation_elapsed < _current_delay():
		return
	_animation_elapsed -= _current_delay()
	_animation_index = (_animation_index + 1) % _animation_rects.size()
	queue_redraw()


func _current_delay() -> float:
	if _animation_delays.is_empty():
		return 100.0
	return maxf(float(_animation_delays[_animation_index % _animation_delays.size()]), 1.0)


func _source_size() -> Vector2:
	if not _animation_rects.is_empty():
		return Vector2(_animation_rects[_animation_index].size)
	if texture:
		return texture.get_size()
	return Vector2.ONE


func set_pan_mode(enabled: bool) -> void:
	pan_mode = enabled


func set_light_enabled(enabled: bool) -> void:
	_light_enabled = enabled
	_update_light()


func set_normal_map(texture: Texture2D) -> void:
	_normal_texture = texture
	_light_material.set_shader_parameter("has_normal", texture != null)
	_light_material.set_shader_parameter("normal_map", texture)
	_update_light()
	queue_redraw()


func set_specular_map(texture: Texture2D) -> void:
	_specular_texture = texture
	_light_material.set_shader_parameter("has_specular", texture != null)
	_light_material.set_shader_parameter("specular_map", texture)
	_update_light()
	queue_redraw()


func set_specular_intensity(value: float) -> void:
	_specular_intensity = clampf(value, 0.0, 1.0)
	_light_material.set_shader_parameter("specular_intensity", _specular_intensity)
	queue_redraw()


func _on_mouse_entered() -> void:
	_pointer_inside = true
	_pointer = get_local_mouse_position()
	_update_light()


func _on_mouse_exited() -> void:
	_pointer_inside = false
	_update_light()


func _update_light() -> void:
	var shaded := _light_enabled and _pointer_inside and _normal_texture != null
	if shaded != (material != null):
		material = _light_material if shaded else null
		queue_redraw()
	_light.enabled = shaded
	_light.position = _pointer


func set_zoom_percent(percent: float) -> void:
	_fitted = false
	_zoom = clampf(percent, 1.0, 100000.0)
	zoom_changed.emit(_zoom)
	queue_redraw()


func zoom(factor: float) -> void:
	set_zoom_percent(_zoom * factor)


func _draw() -> void:
	if texture:
		var source_rect := Rect2(Vector2.ZERO, texture.get_size())
		if not _animation_rects.is_empty():
			source_rect = Rect2(_animation_rects[_animation_index])
		var scale_factor := _zoom / 100.0
		var display_size := source_rect.size * scale_factor
		draw_texture_rect_region(texture, Rect2((size - display_size) * 0.5 + _pan, display_size), source_rect)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_pointer = event.position
		_update_light()
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom(1.2 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.2)
			accept_event()
	elif event is InputEventMouseMotion and (event.button_mask & (MOUSE_BUTTON_MASK_MIDDLE | MOUSE_BUTTON_MASK_RIGHT) or (pan_mode and event.button_mask & MOUSE_BUTTON_MASK_LEFT)):
		_fitted = false
		_pan += event.relative
		queue_redraw()
		accept_event()
