class_name VoxiDocument
extends Resource

@export var title: String = "Untitled"
@export var palette: Array[Color] = []
@export var frames: Array[VoxelFrame] = []
@export var tags: Array[AnimationTag] = []

var _bounds: AABB
var _bounds_dirty := true


func _init() -> void:
	if frames.is_empty():
		frames.append(VoxelFrame.new())


func add_frame(from_frame: int = -1) -> VoxelFrame:
	var f := VoxelFrame.new()
	if from_frame >= 0 and from_frame < frames.size():
		f.cells = frames[from_frame].cells.duplicate(true)
		f.delay_ms = frames[from_frame].delay_ms
	elif not frames.is_empty():
		f.delay_ms = frames.back().delay_ms
	var old_last := frames.size() - 1
	frames.append(f)
	_extend_end_tags(old_last)
	return f


func duplicate_frame(i: int) -> void:
	if i < 0 or i >= frames.size():
		return
	var f := VoxelFrame.new()
	f.cells = frames[i].cells.duplicate(true)
	f.delay_ms = frames[i].delay_ms
	frames.insert(i + 1, f)
	_extend_end_tags(frames.size() - 2)


func _extend_end_tags(old_last: int) -> void:
	var new_last := frames.size() - 1
	if new_last <= old_last:
		return
	for tag in tags:
		if tag.to >= old_last:
			tag.to = new_last


func remove_frame(i: int) -> void:
	if frames.size() <= 1:
		return
	if i < 0 or i >= frames.size():
		return
	frames.remove_at(i)
	_shift_tags_after_remove(i)
	_bounds_dirty = true


func _shift_tags_after_remove(i: int) -> void:
	var last := frames.size() - 1
	for tag in tags:
		if tag.from > i:
			tag.from -= 1
		if tag.to >= i:
			tag.to -= 1
		tag.from = clampi(tag.from, 0, last)
		tag.to = clampi(tag.to, 0, last)
		if tag.from > tag.to:
			tag.to = tag.from


func move_frame(from: int, to: int) -> void:
	if from < 0 or from >= frames.size() or to < 0 or to >= frames.size():
		return
	if from == to:
		return
	var frame := frames[from]
	frames.remove_at(from)
	frames.insert(to, frame)
	_bounds_dirty = true


func add_tag(name: String, from: int, to: int, loop_mode := AnimationTag.LoopMode.FORWARD, repeats := 0) -> int:
	var tag := AnimationTag.new()
	tag.name = name
	tag.from = clampi(from, 0, frames.size() - 1)
	tag.to = clampi(to, tag.from, frames.size() - 1)
	tag.loop_mode = loop_mode
	tag.repeats = repeats
	tags.append(tag)
	return tags.size() - 1

func get_tag(i:int) -> AnimationTag:
	if i >= 0 and i < tags.size():
		return tags[i]
	return null

func remove_tag(i: int) -> void:
	if i >= 0 and i < tags.size():
		tags.remove_at(i)


func bounds() -> AABB:
	if _bounds_dirty:
		_rescan_bounds()
	return _bounds


func _rescan_bounds() -> void:
	var b := AABB()
	var half = Vector3.ONE * 0.5
	for f in frames:
		for c in f.cells:
			if not b.has_volume():
				b = AABB(Vector3(c) - half, Vector3.ONE)
			else:
				b = b.merge(AABB(Vector3(c) - half, Vector3.ONE))
	
	_bounds = b
	_bounds_dirty = false


func _grow_bounds(cell: Vector3i) -> void:
	var half = Vector3.ONE * 0.5
	if not _bounds.has_volume():
		_bounds = AABB(Vector3(cell) - half, Vector3.ONE)
	else:
		_bounds = _bounds.merge(AABB(Vector3(cell) - half, Vector3.ONE))


func _may_shrink_bounds(frame: int, cell: Vector3i) -> void:
	if _bounds_dirty or not _bounds.has_volume():
		_bounds_dirty = true
		return
	var lo := Vector3i(_bounds.position + Vector3.ONE * 0.5)
	var hi := Vector3i(_bounds.position + _bounds.size - Vector3.ONE * 0.5)
	var cells: Dictionary = frames[frame].cells
	if (cell.x == lo.x and not _face_has_cells(cells, 0, lo.x, lo, hi)) or \
			(cell.x == hi.x and not _face_has_cells(cells, 0, hi.x, lo, hi)) or \
			(cell.y == lo.y and not _face_has_cells(cells, 1, lo.y, lo, hi)) or \
			(cell.y == hi.y and not _face_has_cells(cells, 1, hi.y, lo, hi)) or \
			(cell.z == lo.z and not _face_has_cells(cells, 2, lo.z, lo, hi)) or \
			(cell.z == hi.z and not _face_has_cells(cells, 2, hi.z, lo, hi)):
		_bounds_dirty = true


func _face_has_cells(cells: Dictionary, axis: int, value: int, lo: Vector3i, hi: Vector3i) -> bool:
	var a := (axis + 1) % 3
	var b := (axis + 2) % 3
	for i in range(lo[a], hi[a] + 1):
		for j in range(lo[b], hi[b] + 1):
			var p := Vector3i.ZERO
			p[axis] = value
			p[a] = i
			p[b] = j
			if cells.has(p):
				return true
	return false


func paint(frame: int, cell: Vector3i, color: Color) -> void:
	set_cell(frame, cell, color)


func set_cell(frame: int, cell: Vector3i, color: Color) -> void:
	frames[frame].cells[cell] = color
	_grow_bounds(cell)


func erase(frame: int, cell: Vector3i) -> void:
	if not frames[frame].cells.has(cell):
		return
	frames[frame].cells.erase(cell)
	_may_shrink_bounds(frame, cell)


func replace_cells(frame: int, cells: Dictionary) -> void:
	frames[frame].cells = cells
	_bounds_dirty = true


func get_color_at(frame: int, cell: Vector3i) -> Color:
	if frames[frame].cells.has(cell):
		return frames[frame].cells[cell]
	return Color.TRANSPARENT


func has_cell(frame: int, cell: Vector3i) -> bool:
	return frames[frame].cells.has(cell)


func add_color(color: Color) -> bool:
	if palette.has(color):
		return false
	palette.append(color)
	return true


func get_color(index: int) -> Color:
	if index >= 0 and index < palette.size():
		return palette[index]
	return Color.MAGENTA


func remove_color(color: Color) -> bool:
	var index = palette.find(color)
	if index == -1:
		return false
	palette.remove_at(index)
	return true
