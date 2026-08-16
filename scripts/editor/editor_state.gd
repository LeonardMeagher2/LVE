class_name EditorState
extends RefCounted

enum Tool { BRUSH, ERASER, FILL, PICK }

signal frame_changed
signal color_changed(color: Color)
signal tool_changed(tool: int)
signal cells_changed

const RECENT_MAX := 12

var doc: VoxelAnimation
var current_frame := 0
var tool := Tool.BRUSH
var current_color := Color8(177, 177, 177)
var recent_colors: Array[Color] = []

var undo_stack: Array = []
var redo_stack: Array = []
var _pending: Dictionary = {}
var _stroke_changed := false


func _init() -> void:
	doc = VoxelAnimation.new()


func reset() -> void:
	doc = VoxelAnimation.new()
	current_frame = 0
	undo_stack.clear()
	redo_stack.clear()
	_pending = {}
	recent_colors.clear()
	current_color = Color8(177, 177, 177)
	color_changed.emit(current_color)
	tool_changed.emit(tool)
	frame_changed.emit()


func adopt(d: VoxelAnimation) -> void:
	doc = d
	current_frame = 0
	undo_stack.clear()
	redo_stack.clear()
	_pending = {}
	frame_changed.emit()


func set_tool(t: int) -> void:
	tool = t
	tool_changed.emit(t)


func set_color(c: Color) -> void:
	current_color = c
	color_changed.emit(c)


func begin_stroke() -> void:
	_pending = {
		"frame": current_frame,
		"cells": doc.frames[current_frame].cells.duplicate(true),
		"palette": doc.palette.duplicate(),
	}
	_stroke_changed = false


func end_stroke() -> void:
	if _pending.is_empty():
		return
	if _stroke_changed:
		undo_stack.append(_pending)
		redo_stack.clear()
	_pending = {}


func apply_tool(target: Vector3i, hit: Vector3i) -> void:
	var frame: VoxelFrame = doc.frames[current_frame]
	var changed := false
	match tool:
		Tool.BRUSH:
			if is_valid_cell(target):
				frame.cells[target] = doc.ensure_color(current_color)
				_add_recent(current_color)
				changed = true
		Tool.ERASER:
			if hit != EditorViewport.NONE and is_valid_cell(hit):
				frame.cells.erase(hit)
				changed = true
		Tool.FILL:
			if hit != EditorViewport.NONE and frame.cells.has(hit):
				changed = _flood_fill(frame, hit, frame.cells[hit])
		Tool.PICK:
			if hit != EditorViewport.NONE and frame.cells.has(hit):
				set_color(doc.color_of(frame.cells[hit]))
	if changed:
		_stroke_changed = true
		cells_changed.emit()


func _flood_fill(frame: VoxelFrame, seed: Vector3i, old_index: int) -> bool:
	var new_index := doc.ensure_color(current_color)
	if new_index == old_index:
		return false
	var stack: Array[Vector3i] = [seed]
	frame.cells[seed] = new_index
	while not stack.is_empty():
		var c: Vector3i = stack.pop_back()
		for n in _neighbors(c):
			if frame.cells.get(n, -1) == old_index:
				frame.cells[n] = new_index
				stack.append(n)
	return true


func _neighbors(c: Vector3i) -> Array[Vector3i]:
	return [
		Vector3i(c.x + 1, c.y, c.z), Vector3i(c.x - 1, c.y, c.z),
		Vector3i(c.x, c.y + 1, c.z), Vector3i(c.x, c.y - 1, c.z),
		Vector3i(c.x, c.y, c.z + 1), Vector3i(c.x, c.y, c.z - 1),
	]


func is_valid_cell(c: Vector3i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.z >= 0 \
		and c.x < doc.grid_size.x and c.y < doc.grid_size.y and c.z < doc.grid_size.z


func _add_recent(c: Color) -> void:
	if recent_colors.has(c):
		recent_colors.erase(c)
	recent_colors.push_front(c)
	while recent_colors.size() > RECENT_MAX:
		recent_colors.pop_back()


func undo() -> void:
	if undo_stack.is_empty():
		return
	redo_stack.append(_capture())
	_restore(undo_stack.pop_back())


func redo() -> void:
	if redo_stack.is_empty():
		return
	undo_stack.append(_capture())
	_restore(redo_stack.pop_back())


func _capture() -> Dictionary:
	return {
		"frame": current_frame,
		"cells": doc.frames[current_frame].cells.duplicate(true),
		"palette": doc.palette.duplicate(),
	}


func _restore(state: Dictionary) -> void:
	var i: int = state["frame"]
	if i < 0 or i >= doc.frames.size():
		i = current_frame
	doc.frames[i].cells = (state["cells"] as Dictionary).duplicate(true)
	doc.palette = (state["palette"] as PackedColorArray).duplicate()
	current_frame = i
	frame_changed.emit()
	cells_changed.emit()


func add_frame() -> void:
	doc.add_frame()
	current_frame = doc.frames.size() - 1
	frame_changed.emit()


func duplicate_frame() -> void:
	doc.duplicate_frame(current_frame)
	current_frame += 1
	frame_changed.emit()


func delete_frame() -> void:
	if doc.frames.size() <= 1:
		return
	doc.remove_frame(current_frame)
	if current_frame >= doc.frames.size():
		current_frame = doc.frames.size() - 1
	frame_changed.emit()


func select_frame(i: int) -> void:
	if i < 0 or i >= doc.frames.size() or i == current_frame:
		return
	current_frame = i
	frame_changed.emit()
