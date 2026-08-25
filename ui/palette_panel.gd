class_name PalettePanel
extends VBoxContainer

const SWATCH := preload("res://ui/swatch.tres")

var _swatches: Array[Button] = []
var _selected_swatch_index: int = -1

@onready var _swatch_grid: HFlowContainer = %SwatchGrid
@onready var _color_picker: ColorPicker = %ColorPicker
@onready var _color_picker_button: ColorPickerButton = %ColorPickerButton


func _ready() -> void:
	State.color_changed.connect(_on_color_changed)
	State.document_changed.connect(_rebuild_swatches)
	State.cells_changed.connect(_rebuild_swatches)
	State.frame_changed.connect(_rebuild_swatches)
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
	State.document.add_color(State.current_color)
	_rebuild_swatches()


func _duplicate_selected_color() -> void:
	if _selected_swatch_index >= 0:
		var color := State.document.color_of(_selected_swatch_index)
		State.document.add_color(color)
		_rebuild_swatches()


func _remove_selected_color() -> void:
	if _selected_swatch_index >= 0:
		if State.document.remove_color(_selected_swatch_index):
			_selected_swatch_index = -1
			_rebuild_swatches()


func _mark_current() -> void:
	_selected_swatch_index = -1
	for i in State.document.palette.size():
		if State.document.palette[i] == State.current_color:
			_selected_swatch_index = i
			break
	for i in _swatches.size():
		var sb := (SWATCH as StyleBoxFlat).duplicate() as StyleBoxFlat
		sb.bg_color = State.document.color_of(i)
		if i == _selected_swatch_index:
			sb.set_border_width_all(2)
			sb.border_color = Color.WHITE
		_swatches[i].add_theme_stylebox_override("normal", sb)
