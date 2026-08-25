extends Node

const NONE := Vector3i(Vector3.INF)

signal document_changed()
signal frames_changed()
signal frame_changed()
signal color_changed(color: Color)
signal tool_changed(tool: ToolInfo)
signal tool_option_changed(group: String, id: String, value: Variant)
signal cells_changed()
signal selection_changed()
signal view_mode_changed(mode: ViewMode)
signal floor_plane_changed()

enum ViewMode {
	NONE,
	PAN,
	ROTATE,
}

var document: VoxiDocument
var current_frame := 0:
	set(value):
		if value == current_frame:
			return
		current_frame = value
		frame_changed.emit()
var view_mode: ViewMode = ViewMode.NONE:
	set(value):
		if value == view_mode:
			return
		view_mode = value
		view_mode_changed.emit(value)
var floor_axis := Vector3.Axis.AXIS_Y:
	set(value):
		if value == floor_axis or value < Vector3.Axis.AXIS_X or value > Vector3.Axis.AXIS_Z:
			return
		floor_axis = value
		floor_plane_changed.emit()
var floor_index := 0:
	set(value):
		if value == floor_index:
			return
		floor_index = value
		floor_plane_changed.emit()
var tools := {}
var tool: ToolInfo = null
var current_color := Color.from_rgba8(20, 20, 20)
var selection := VoxelSelection.new()
var undo_redo := UndoRedo.new()
var playback := Playback.new()
var _option_values := {}


func _init() -> void:
	document = VoxiDocument.new()


func _ready() -> void:
	cells_changed.connect(_stop_playback)
	add_tool(load("res://tools/pencil.tres"))
	add_tool(load("res://tools/paint_brush.tres"))
	add_tool(load("res://tools/eyedropper.tres"))
	add_tool(load("res://tools/eraser.tres"))
	add_tool(load("res://tools/fill.tres"))
	add_tool(load("res://tools/select.tres"))
	add_tool(load("res://tools/wand_select.tres"))
	add_tool(load("res://tools/lasso.tres"))
	add_tool(load("res://tools/move.tres"))
	add_tool(load("res://tools/plane.tres"))
	tool = tools["pencil"]


func add_tool(info: ToolInfo) -> void:
	tools[info.id] = info


func reset() -> void:
	document = VoxiDocument.new()
	current_frame = 0
	undo_redo.clear_history()
	current_color = Color.from_rgba8(20, 20, 20)
	selection.clear()
	color_changed.emit(current_color)
	tool_changed.emit(tool)
	document_changed.emit()
	frames_changed.emit()
	selection_changed.emit()


func load_document(d: VoxiDocument) -> void:
	document = d
	current_frame = 0
	undo_redo.clear_history()
	selection.clear()
	document_changed.emit()
	frames_changed.emit()
	selection_changed.emit()


func set_tool(t: ToolInfo) -> void:
	tool = t
	tool_changed.emit(t)


func set_color(c: Color) -> void:
	current_color = c
	color_changed.emit(c)


func set_tool_option(group: String, id: String, value: Variant) -> void:
	if not _option_values.has(group):
		_option_values[group] = {}
	if _option_values[group].get(id) == value:
		return
	_option_values[group][id] = value
	tool_option_changed.emit(group, id, value)


func get_tool_option(info: ToolInfo, id: String) -> Variant:
	for opt in info.options:
		if opt.id == id:
			var vals: Dictionary = _option_values.get(info.group, {})
			return vals.get(id, opt.default)
	return null


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


func _stop_playback() -> void:
	playback.set_playing(false)


func notify_restored() -> void:
	frame_changed.emit()
	cells_changed.emit()
	selection_changed.emit()
