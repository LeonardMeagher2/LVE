class_name PalettePanel
extends VBoxContainer

const Swatch := preload("./Swatch.tscn")
const SwatchButtonGroup := preload("./SwatchButtonGroup.tres")

@onready var _swatch_grid: HFlowContainer = %SwatchGrid
@onready var _color_picker: ColorPicker = %ColorPicker
@onready var _color_picker_button: ColorPickerButton = %ColorPickerButton


func _ready() -> void:
	State.document_changed.connect(_rebuild_swatches)
	State.color_changed.connect(_on_color_changed)
	State.palette_changed.connect(_rebuild_swatches)
	
	_on_color_changed(State.current_color)
	_rebuild_swatches()


func _on_color_changed(color: Color) -> void:
	_color_picker.color = color
	_color_picker_button.color = color
	_select_current()


func _rebuild_swatches() -> void:
	for swatch in _swatch_grid.get_children():
		_swatch_grid.remove_child(swatch)
		swatch.queue_free()
	
	var palette := State.get_palette()
	for i in palette.size():
		var swatch = Swatch.instantiate()
		swatch.color = palette[i]
		swatch.toggled.connect(_pick_swatch.bind(palette[i]))
		_swatch_grid.add_child(swatch)
	_select_current()


func _pick_swatch(toggled_on:bool, color:Color) -> void:
	if toggled_on:
		State.current_color = color

func _on_picker_color_changed(color: Color) -> void:
	State.current_color = color


func _select_current() -> void:
	for swatch in _swatch_grid.get_children():
		if swatch.color == State.current_color:
			(swatch as Button).set_pressed_no_signal(true)
			return


func _on_add_btn_pressed() -> void:
	State.add_color()


func _on_remove_btn_pressed() -> void:
	State.remove_color()
	
