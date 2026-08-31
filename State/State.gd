extends Node

signal document_changed()
signal cells_changed()
signal frames_changed()
signal frame_changed()
signal is_playing_toggled(toggled_on:bool)
signal color_changed(color: Color)
signal palette_changed()
signal selection_changed()
signal floor_plane_changed()


var document: VoxiDocument : set=set_document

var current_frame := 0:
	set(value):
		if value == current_frame:
			return
		current_frame = value
		frame_changed.emit()
		
var is_playing:bool = false: set=set_is_playing

var floor_axis:Vector3.Axis = Vector3.Axis.AXIS_Y:
	set(value):
		if value == floor_axis:
			return
		floor_axis = value
		floor_plane_changed.emit()

var floor_index := 0:
	set(value):
		if value == floor_index:
			return
		floor_index = value
		floor_plane_changed.emit()

var current_color := Color.from_rgba8(20, 20, 20) : set=set_color
var selection := VoxelSelection.new()
var undo_redo := UndoRedo.new()


func _init() -> void:
	document = VoxiDocument.new()

func _ready() -> void:
	cells_changed.connect(stop)
	
	add_plugin(load("res://Plugins/Brush/BrushPlugin.gd").new())
	add_plugin(load("res://Plugins/Eyedropper/EyedropperPlugin.gd").new())
	add_plugin(load("res://Plugins/Eraser/EraserPlugin.gd").new())
	add_plugin(load("res://Plugins/Fill/FillPlugin.gd").new())
	add_plugin(load("res://Plugins/Selection/SelectionPlugin.gd").new())
	add_plugin(load("res://Plugins/Plane/PlanePlugin.gd").new())
	


func set_document(value:VoxiDocument) -> void:
	if value == document:
		return
	selection.clear()
	selection_changed.emit()
	undo_redo.clear_history()
	if value is VoxiDocument:
		document = value
	else:
		document = VoxiDocument.new()
		
	document_changed.emit()
	palette_changed.emit()
	frames_changed.emit()
	current_frame = 0


func add_plugin(plugin: VoxiPlugin) -> void:
	get_node("/root").add_child.call_deferred(plugin, true)
	
func remove_plugin(plugin: VoxiPlugin) -> void:
	get_node("/root").remove_child(plugin)


func paint(position: Vector3i, color:Color) -> void:
	document.paint(current_frame, position, color)

func has_cell(position: Vector3i) -> bool:
	return document.has_cell(current_frame, position)

func set_is_playing(value:bool) -> void:
	if value == is_playing:
		return
	is_playing = value
	is_playing_toggled.emit(is_playing)

func play():
	is_playing = true

func stop():
	is_playing = false

func set_color(color: Color) -> void:
	current_color = color
	color_changed.emit(color)

func add_color(color: Color = current_color) -> void:
	if document.add_color(color):
		palette_changed.emit()

func get_color(index: int) -> Color:
	return document.get_color(index)
	
func get_color_at(position: Vector3i) -> Color:
	return document.get_color_at(current_frame, position)

func remove_color(color: Color = current_color) -> void:
	if document.remove_color(color):
		palette_changed.emit()

func get_palette() -> PackedColorArray:
	return document.palette

func can_edit(cell: Vector3i) -> bool:
	if selection.is_empty():
		return true
	return selection.contains(cell)


func clear_selection() -> void:
	if selection.is_empty():
		return
	selection.clear()
	selection_changed.emit()


func erase_selection() -> void:
	if selection.is_empty():
		return
	var i := current_frame
	var removed := {}
	var cells: Dictionary = document.frames[i].cells
	for c in selection.cells:
		if cells.has(c):
			removed[c] = cells[c]
			cells.erase(c)
	if removed.is_empty():
		return
	cells_changed.emit()
	undo_redo.create_action("Erase Selection")
	undo_redo.add_undo_method(_restore_cells.bind(i, removed))
	undo_redo.add_do_method(_erase_cells.bind(i, removed.keys()))
	undo_redo.commit_action(false)


func _restore_cells(i: int, cells: Dictionary) -> void:
	if i < 0 or i >= document.frames.size():
		return
	for c in cells:
		document.frames[i].cells[c] = cells[c]
	cells_changed.emit()


func _erase_cells(i: int, keys: Array) -> void:
	if i < 0 or i >= document.frames.size():
		return
	for c in keys:
		document.frames[i].cells.erase(c)
	cells_changed.emit()


func next_frame() -> void:
	var n := document.frames.size()
	current_frame = (current_frame + 1) % n


func prev_frame() -> void:
	var n := document.frames.size()
	current_frame = (current_frame - 1) % n

func get_frame_count() -> int:
	return document.frames.size()
	
func get_current_voxel_frame() -> VoxelFrame:
	return document.frames[current_frame]


func add_frame() -> void:
	is_playing = false
	document.add_frame()
	current_frame = document.frames.size() - 1
	frames_changed.emit()


func duplicate_frame() -> void:
	is_playing = false
	document.duplicate_frame(current_frame)
	current_frame += 1
	frames_changed.emit()
	
func delete_frame() -> void:
	if document.frames.size() <= 1:
		return
	is_playing = false
	document.remove_frame(current_frame)
	if current_frame >= document.frames.size():
		current_frame = document.frames.size() - 1
	frames_changed.emit()
	
func to_start() -> void:
	current_frame = 0

func to_end() -> void:
	current_frame = document.frames.size() - 1

func notify_restored() -> void:
	frame_changed.emit()
	cells_changed.emit()
	selection_changed.emit()
