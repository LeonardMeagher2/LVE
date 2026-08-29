class_name VoxiDocument
extends Resource

@export var title: String = "Untitled"
@export var palette: PackedColorArray = []
@export var frames: Array[VoxelFrame] = []
@export var tags: Array[AnimationTag] = []


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
	frames.append(f)
	return f


func duplicate_frame(i: int) -> void:
	if i < 0 or i >= frames.size():
		return
	var f := VoxelFrame.new()
	f.cells = frames[i].cells.duplicate(true)
	f.delay_ms = frames[i].delay_ms
	frames.insert(i + 1, f)


func remove_frame(i: int) -> void:
	if frames.size() <= 1:
		return
	if i < 0 or i >= frames.size():
		return
	frames.remove_at(i)


func add_tag(name: String, from: int, to: int, loop_mode := AnimationTag.LoopMode.FORWARD, repeats := 0) -> AnimationTag:
	var tag := AnimationTag.new()
	tag.name = name
	tag.from = clampi(from, 0, frames.size() - 1)
	tag.to = clampi(to, tag.from, frames.size() - 1)
	tag.loop_mode = loop_mode
	tag.repeats = repeats
	tags.append(tag)
	return tag


func remove_tag(i: int) -> void:
	if i >= 0 and i < tags.size():
		tags.remove_at(i)


func bounds() -> AABB:
	var b := AABB()
	for f in frames:
		for c in f.cells:
			if not b.has_volume():
				b = AABB(Vector3(c), Vector3.ONE)
			else:
				b = b.merge(AABB(Vector3(c), Vector3.ONE))
	return b


func paint(frame: int, cell: Vector3i, color: Color) -> void:
	frames[frame].cells[cell] = color


func set_cell(frame: int, cell: Vector3i, color: Color) -> void:
	frames[frame].cells[cell] = color


func erase(frame: int, cell: Vector3i) -> void:
	frames[frame].cells.erase(cell)


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
