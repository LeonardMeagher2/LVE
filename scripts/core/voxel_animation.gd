class_name VoxelAnimation
extends Resource

@export var title: String = "Untitled"
@export var fps: float = 10.0
@export var grid_size: Vector3i = Vector3i(16, 16, 16)
@export var palette: PackedColorArray = []
@export var frames: Array[VoxelFrame] = []


func _init() -> void:
	if frames.is_empty():
		frames.append(VoxelFrame.new())


func add_frame(from_frame: int = -1) -> VoxelFrame:
	var f := VoxelFrame.new()
	if from_frame >= 0 and from_frame < frames.size():
		f.cells = frames[from_frame].cells.duplicate(true)
	frames.append(f)
	return f


func duplicate_frame(i: int) -> void:
	if i < 0 or i >= frames.size():
		return
	var f := VoxelFrame.new()
	f.cells = frames[i].cells.duplicate(true)
	frames.insert(i + 1, f)


func remove_frame(i: int) -> void:
	if frames.size() <= 1:
		return
	if i < 0 or i >= frames.size():
		return
	frames.remove_at(i)


func color_of(palette_index: int) -> Color:
	if palette_index >= 0 and palette_index < palette.size():
		return palette[palette_index]
	return Color.MAGENTA


func ensure_color(c: Color) -> int:
	for i in palette.size():
		if palette[i] == c:
			return i
	palette.append(c)
	return palette.size() - 1
