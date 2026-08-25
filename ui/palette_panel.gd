class_name PalettePanel
extends VBoxContainer

const SWATCH := preload("res://ui/swatch.tscn")

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
	for swatch in _swatch_grid.get_children():
		swatch.queue_free()
	
	var palette := State.document.palette
	
	for i in palette.size():
		var swatch:Swatch = SWATCH.instantiate()
		swatch.color = palette[i]
		swatch.toggled.connect(_pick_swatch.bind(i))
		_swatch_grid.add_child(swatch)
	_mark_current()


func _pick_swatch(toggled_on:bool, i: int) -> void:
	if toggled_on:
		_selected_swatch_index = i
		State.set_color(State.document.color_of(i))


func _on_picker_color_changed(c: Color) -> void:
	State.set_color(c)


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
	for swatch in _swatch_grid.get_children():
		var hit: bool = swatch.color == State.current_color
		swatch.button_pressed = hit
		if hit and _selected_swatch_index < 0:
			_selected_swatch_index = swatch.get_index()
