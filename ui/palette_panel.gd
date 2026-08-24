class_name PalettePanel
extends VBoxContainer

const SWATCH := preload("res://ui/swatch.tres")

var _swatches: Array[Button] = []

@onready var _swatch_grid: HFlowContainer = %SwatchGrid
@onready var _color_picker: ColorPicker = %ColorPicker
@onready var _color_picker_button: ColorPickerButton = %ColorPickerButton


@onready var _add_color_btn: Button = %AddColorBtn


func _ready() -> void:
	State.color_changed.connect(_on_color_changed)
	State.cells_changed.connect(_rebuild_swatches)
	State.frame_changed.connect(_rebuild_swatches)
	_add_color_btn.pressed.connect(_add_current_color)
	_color_picker.color = State.current_color
	_color_picker_button.color = State.current_color
	_rebuild_swatches()


func _on_color_changed(c: Color) -> void:
	_color_picker.color = c
	_color_picker_button.color = c
	_mark_current()


func _rebuild_swatches() -> void:
	for b in _swatches:
		b.queue_free()
	_swatches.clear()
	var palette := State.document.palette
	for i in palette.size():
		var b := Button.new()
		b.custom_minimum_size = Vector2(36, 36)
		b.tooltip_text = State.document.color_of(i).to_html(true)
		var sb := (SWATCH as StyleBoxFlat).duplicate() as StyleBoxFlat
		sb.bg_color = palette[i]
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_stylebox_override("hover", sb)
		b.add_theme_stylebox_override("pressed", sb)
		b.pressed.connect(_pick_swatch.bind(i))
		b.gui_input.connect(_on_swatch_input.bind(i))
		_swatch_grid.add_child(b)
		_swatches.append(b)
	_mark_current()


func _pick_swatch(i: int) -> void:
	State.set_color(State.document.color_of(i))

func _on_picker_color_changed(c: Color) -> void:
	State.set_color(c)

func _on_swatch_input(event: InputEvent, i: int) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_RIGHT:
		if State.document.remove_color(i):
			_rebuild_swatches()


func _add_current_color() -> void:
	State.document.ensure_color(State.current_color)
	_rebuild_swatches()


func _mark_current() -> void:
	for i in _swatches.size():
		var sb := (SWATCH as StyleBoxFlat).duplicate() as StyleBoxFlat
		sb.bg_color = State.document.color_of(i)
		if State.document.color_of(i) == State.current_color:
			sb.set_border_width_all(2)
			sb.border_color = Color.WHITE
		_swatches[i].add_theme_stylebox_override("normal", sb)


