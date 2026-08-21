extends Node

const NONE := Vector3i(-1000000, -1000000, -1000000)

signal document_changed()
signal frame_changed()
signal color_changed(color: Color)
signal tool_changed(tool: ToolInfo)
signal cells_changed()
signal selection_changed()
signal pixel_perfect_changed(enabled: bool)

var document: VoxiDocument
var current_frame := 0
var tools := {}
var tool: ToolInfo = null
var current_color := Color8(177, 177, 177)
var pixel_perfect := false
var selection := VoxelSelection.new()
var undo_redo := UndoRedo.new()
var playback := Playback.new()


func _init() -> void:
	document = VoxiDocument.new()


func _ready() -> void:
	cells_changed.connect(_stop_playback)
	frame_changed.connect(_stop_playback)
	add_tool(load("res://tools/brush.tres"))
	add_tool(load("res://tools/brush_paint.tres"))
	add_tool(load("res://tools/eraser.tres"))
	add_tool(load("res://tools/fill.tres"))
	add_tool(load("res://tools/pick.tres"))
	add_tool(load("res://tools/select.tres"))
	add_tool(load("res://tools/move.tres"))
	tool = tools["brush"]


func add_tool(info: ToolInfo) -> void:
	tools[info.id] = info


func reset() -> void:
	document = VoxiDocument.new()
	current_frame = 0
	undo_redo.clear_history()
	current_color = Color8(177, 177, 177)
	selection.clear()
	color_changed.emit(current_color)
	tool_changed.emit(tool)
	frame_changed.emit()
	selection_changed.emit()


func load_document(d: VoxiDocument) -> void:
	document = d
	current_frame = 0
	undo_redo.clear_history()
	selection.clear()
	frame_changed.emit()
	selection_changed.emit()


func set_tool(t: ToolInfo) -> void:
	tool = t
	tool_changed.emit(t)


func set_color(c: Color) -> void:
	current_color = c
	color_changed.emit(c)


func set_pixel_perfect(v: bool) -> void:
	if pixel_perfect == v:
		return
	pixel_perfect = v
	pixel_perfect_changed.emit(v)


func _stop_playback() -> void:
	playback.set_playing(false)


func notify_restored() -> void:
	frame_changed.emit()
	cells_changed.emit()
	selection_changed.emit()
