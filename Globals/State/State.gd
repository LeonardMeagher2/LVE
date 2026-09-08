extends Node

signal document_changed()
signal cells_changed(frame: int, affected: Array[Vector3i])
signal frames_changed()
signal frame_changed()
signal is_playing_toggled(toggled_on:bool)
signal color_changed(color: Color)
signal palette_changed()
signal selection_changed()
signal floor_plane_changed()
signal tag_changed()
signal edit_mode_changed()


var document: VoxiDocument : set=set_document

var current_frame := 0:
	set(value):
		if value == current_frame:
			return
		current_frame = value
		frame_changed.emit()
		
var is_playing:bool = false: set=set_is_playing

var edit_mode := false:
	set(value):
		if value == edit_mode:
			return
		edit_mode = value
		edit_mode_changed.emit()

var active_tag := -1:
	set(value):
		var new_value := clampi(value, -1, document.tags.size() - 1)
		if new_value == active_tag:
			return
		active_tag = new_value
		tag_changed.emit()

var _play_dir := 1
var _play_passes := 0
var _play_elapsed := 0.0

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
	cells_changed.connect(func(_frame, _affected): stop())
	
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
	active_tag = -1
		
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
	if is_playing:
		_init_playback()
	is_playing_toggled.emit(is_playing)

func play():
	is_playing = true

func play_tag(i: int) -> void:
	active_tag = i
	is_playing = true

func stop():
	is_playing = false

func select_tag(i: int) -> void:
	active_tag = i

func deselect_tag() -> void:
	active_tag = -1


func _process(delta: float) -> void:
	if not is_playing:
		return
	_play_elapsed += delta
	if _play_elapsed >= _current_delay():
		_play_elapsed = 0.0
		_advance_playback()


func _init_playback() -> void:
	_play_elapsed = 0.0
	_play_passes = 0
	_play_dir = 1
	current_frame = clampi(current_frame, _play_lo(), _play_hi())


func _play_lo() -> int:
	var tag := get_active_tag()
	if tag:
		return mini(tag.from, tag.to)
	return 0


func _play_hi() -> int:
	var tag := get_active_tag()
	if tag:
		return maxi(tag.from, tag.to)
	return document.frames.size() - 1


func _play_mode() -> AnimationTag.LoopMode:
	var tag := get_active_tag()
	if tag:
		return tag.loop_mode
	return AnimationTag.LoopMode.FORWARD


func _play_repeats() -> int:
	var tag := get_active_tag()
	if tag:
		return tag.repeats
	return 0


func _advance_playback() -> void:
	if _play_lo() == _play_hi():
		return
	match _play_mode():
		AnimationTag.LoopMode.FORWARD:
			if current_frame == _play_hi():
				_play_passes += 1
				if _finished():
					stop()
					return
				current_frame = _play_lo()
			else:
				current_frame += 1
		AnimationTag.LoopMode.REVERSE:
			if current_frame == _play_lo():
				_play_passes += 1
				if _finished():
					stop()
					return
				current_frame = _play_hi()
			else:
				current_frame -= 1
		_:
			if _play_dir == 1:
				if current_frame == _play_hi():
					current_frame = _play_hi() - 1
					_play_dir = -1
				else:
					current_frame += 1
			else:
				if current_frame == _play_lo():
					_play_passes += 1
					if _finished():
						stop()
						return
					current_frame = _play_lo() + 1
					_play_dir = 1
				else:
					current_frame -= 1
					
	if current_frame >= document.frames.size():
		current_frame = 0
	elif current_frame < 0:
		current_frame = document.frames.size() - 1


func _finished() -> bool:
	return _play_repeats() > 0 and _play_passes >= _play_repeats()


func _current_delay() -> float:
	var current_voxel_frame := get_current_voxel_frame()
	if not current_voxel_frame:
		return 1.0
	return maxf(current_voxel_frame.delay_ms, 1.0) / 1000.0

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
			document.erase(i, c)
	if removed.is_empty():
		return
	cells_changed.emit(i, _vec3i_array(removed.keys()))
	undo_redo.create_action("Erase Selection")
	undo_redo.add_undo_method(_restore_cells.bind(i, removed))
	undo_redo.add_do_method(_erase_cells.bind(i, removed.keys()))
	undo_redo.commit_action(false)


func _restore_cells(i: int, cells: Dictionary) -> void:
	if i < 0 or i >= document.frames.size():
		return
	for c in cells:
		document.set_cell(i, c, cells[c])
	cells_changed.emit(i, _vec3i_array(cells.keys()))


func _erase_cells(i: int, keys: Array) -> void:
	if i < 0 or i >= document.frames.size():
		return
	for c in keys:
		document.erase(i, c)
	cells_changed.emit(i, _vec3i_array(keys))


func next_frame() -> void:
	var n := document.frames.size()
	current_frame = (current_frame + 1) % n


func prev_frame() -> void:
	var n := document.frames.size()
	current_frame = (current_frame - 1) % n

func get_frame_count() -> int:
	return document.frames.size()

func get_voxel_frame(frame:int) -> VoxelFrame:
	if frame < 0 or frame >= document.frames.size():
		return null
	return document.frames[frame]

func get_current_voxel_frame() -> VoxelFrame:
	if current_frame < 0 or current_frame >= document.frames.size():
		return null
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

func move_frame(from: int, to: int) -> void:
	var f := clampi(from, 0, document.frames.size() - 1)
	var t := clampi(to, 0, document.frames.size() - 1)
	if f == t:
		return
	document.move_frame(f, t)
	if current_frame == f:
		current_frame = t
	elif f < current_frame and current_frame <= t:
		current_frame -= 1
	elif t <= current_frame and current_frame < f:
		current_frame += 1
	frames_changed.emit()

func add_tag(name: String, from: int = 0, to: int = -1) -> void:
	var end := to
	if to < 0:
		end = document.frames.size() - 1
	active_tag = document.add_tag(name, from, end)
	frames_changed.emit()

func get_active_tag() -> AnimationTag:
	return document.get_tag(active_tag)
	
func get_tag(i: int) -> AnimationTag:
	return document.get_tag(i)

func remove_tag() -> void:
	document.remove_tag(active_tag)
	active_tag = clampi(active_tag, -1, document.tags.size() -1)
	tag_changed.emit()
	frames_changed.emit()

func set_tag_range(from: int, to: int) -> void:
	var tag := get_active_tag()
	if tag == null:
		return
	var last := document.frames.size() - 1
	var new_from := clampi(from, 0, last)
	var new_to := clampi(to, new_from, last)
	if tag.from == new_from and tag.to == new_to:
		return
	tag.from = new_from
	tag.to = new_to
	if is_playing:
		current_frame = clampi(current_frame, _play_lo(), _play_hi())
	tag_changed.emit()
	
func to_start() -> void:
	var tag := get_active_tag()
	if tag:
		current_frame = maxi(tag.from, 0)
	else:
		current_frame = 0

func to_end() -> void:
	var tag = get_active_tag()
	if tag:
		current_frame = mini(tag.to, document.frames.size() - 1)
	else:
		current_frame = document.frames.size() - 1

func notify_restored() -> void:
	frame_changed.emit()
	cells_changed.emit(current_frame, _vec3i_array([]))
	selection_changed.emit()


func _vec3i_array(keys: Array) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for k in keys:
		out.append(k)
	return out
