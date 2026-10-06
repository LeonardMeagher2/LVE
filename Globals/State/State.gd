extends Node

signal document_changed()
signal cells_changed(frame: int, affected: Array[Vector3i])
signal chunks_changed(frame: int, affected: Array[Vector3i])
signal frames_changed()
signal frame_changed()
signal is_playing_toggled(toggled_on:bool)
signal color_changed(color: Color)
signal palette_changed()
signal default_palette_changed()
signal selection_changed()
signal floor_plane_changed()
signal tag_changed()
signal activity_changed()
signal edit_context_changing()

const WORK_SLICE_US := 3000
const DEFAULT_PALETTE_PATH := "user://default_palette.cfg"
const IMAGE_EXTENSIONS := ["bmp", "dds", "exr", "hdr", "jpg", "jpeg", "ktx", "ktx2", "png", "svg", "tga", "webp"]

var default_palette := get_builtin_palette()

class Operation extends RefCounted:
	var label := ""
	var detail := ""
	var completed := 0
	var total := -1
	var foreground := false
	var owner_ref: WeakRef

var _operations: Dictionary[int, Operation] = {}
var _next_operation_id := 1
var _activity_started_ms := 0
var _erase_job: EraseJob
var _erase_operation_id := 0
var _erase_jobs: Array[EraseJob] = []

class EraseJob extends VoxelFrame.EditJob:
	var edited_frame: VoxelFrame
	var selection_mask := {}
	var changed_chunks: Array[Vector3i] = []

	func run() -> void:
		stage("Preparing erase", selection_mask.size())
		var changes := {}
		var completed := 0
		for cell_position in selection_mask:
			changes[cell_position] = Color.TRANSPARENT
			completed += 1
			if completed % 4096 == 0 and not checkpoint(completed):
				return
		stage("Erasing selection", changes.size())
		changed_chunks = edited_frame.set_cells(changes, self)


var document: VoxiDocument : set=set_document

var current_frame := 0:
	set(value):
		value = clampi(value, 0, document.frames.size() - 1)
		if value == current_frame:
			return
		edit_context_changing.emit()
		current_frame = value
		frame_changed.emit()
		
var is_playing:bool = false: set=set_is_playing

var active_tag := 0:
	set(value):
		var new_value := clampi(value, -1, document.tags.size() - 1)
		if new_value == active_tag:
			return
		active_tag = new_value
		if is_playing:
			_init_playback()
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

var current_color := Color.BLACK
var selection := VoxelSelection.new()
var undo_redo := UndoRedo.new()
var _stroke_frame: VoxelFrame
var _stroke_start_chunks := {}
var _stroke_start_selection := {}


func _init() -> void:
	document = VoxiDocument.new()

func _ready() -> void:
	load_default_palette()
	document.palette.assign(default_palette)
	current_color = default_palette[0]
	edit_context_changing.connect(_interrupt_erase)
	cells_changed.connect(func(_frame, _affected): stop())
	chunks_changed.connect(func(_frame, _affected): stop())
	
	add_plugin(load("res://Plugins/Brush/BrushPlugin.gd").new())
	add_plugin(load("res://Plugins/Eyedropper/EyedropperPlugin.gd").new())
	add_plugin(load("res://Plugins/Fill/FillPlugin.gd").new())
	add_plugin(load("res://Plugins/Selection/SelectionPlugin.gd").new())
	add_plugin(load("res://Plugins/Transform/TransformPlugin.gd").new())
	add_plugin(load("res://Plugins/Plane/PlanePlugin.gd").new())
	add_plugin(load("res://Plugins/GLTFExport/GLTFExportPlugin.gd").new())
	add_plugin(load("res://Plugins/Clipboard/ClipboardPlugin.gd").new())
	add_plugin(load("res://Plugins/ImageImport/ImageImportPlugin.gd").new())
	


func set_document(value:VoxiDocument) -> void:
	if value == document:
		return
	edit_context_changing.emit()
	_operations.clear()
	_activity_started_ms = 0
	activity_changed.emit()
	_stroke_frame = null
	_stroke_start_chunks = {}
	_stroke_start_selection = {}
	selection.clear()
	selection_changed.emit()
	undo_redo.clear_history()
	if value is VoxiDocument:
		document = value
	else:
		document = VoxiDocument.new()
		document.palette.assign(default_palette)
		_apply_color(default_palette[0])
	if document.tags.is_empty():
		document.add_tag("Default", 0, document.frames.size() - 1)
	active_tag = 0
		
	document_changed.emit()
	palette_changed.emit()
	frames_changed.emit()
	current_frame = 0


func add_plugin(plugin: VoxiPlugin) -> void:
	get_node("/root").add_child.call_deferred(plugin, true)
	
func remove_plugin(plugin: VoxiPlugin) -> void:
	get_node("/root").remove_child(plugin)
	plugin.queue_free()


func paint(position: Vector3i, color:Color) -> void:
	document.paint(current_frame, position, color)


func begin_operation(label: String, total: int = -1, foreground: bool = false, operation_owner: Node = null) -> int:
	var operation := Operation.new()
	operation.label = label
	operation.total = total
	operation.foreground = foreground
	if operation_owner:
		operation.owner_ref = weakref(operation_owner)
	if _operations.is_empty():
		_activity_started_ms = Time.get_ticks_msec()
	var operation_id := _next_operation_id
	_next_operation_id += 1
	_operations[operation_id] = operation
	activity_changed.emit()
	return operation_id


func update_operation(operation_id: int, completed: int, total: int = -1, label: String = "", detail: String = "") -> void:
	var operation: Operation = _operations.get(operation_id)
	if operation == null:
		return
	if operation.completed == completed and operation.total == total and operation.detail == detail and (label.is_empty() or operation.label == label):
		return
	operation.completed = completed
	operation.total = total
	operation.detail = detail
	if not label.is_empty():
		operation.label = label
	activity_changed.emit()


func finish_operation(operation_id: int) -> void:
	if not _operations.erase(operation_id):
		return
	if _operations.is_empty():
		_activity_started_ms = 0
	activity_changed.emit()


func has_operation(operation_id: int) -> bool:
	return _operations.has(operation_id)


func get_activity() -> Operation:
	var background_operation: Operation
	for operation in _operations.values():
		if operation.foreground:
			return operation
		if background_operation == null:
			background_operation = operation
	return background_operation


func activity_elapsed_ms() -> int:
	return Time.get_ticks_msec() - _activity_started_ms if not _operations.is_empty() else 0


func edit_busy(requester: Node = null) -> bool:
	for operation in _operations.values():
		if operation.foreground and (requester == null or operation.owner_ref == null or operation.owner_ref.get_ref() != requester):
			return true
	return false


func begin_stroke() -> void:
	_stroke_frame = get_current_voxel_frame()
	_stroke_start_chunks = _stroke_frame.capture()
	_stroke_start_selection = selection.capture()


func end_stroke(action: String = "Stroke") -> void:
	if _stroke_frame == null:
		return
	var stroke_end_chunks := _stroke_frame.capture()
	if not _chunks_equal(_stroke_start_chunks, stroke_end_chunks) or _stroke_start_selection != selection.all_cells():
		undo_redo.create_action(action)
		undo_redo.add_undo_method(_restore_chunks.bind(_stroke_frame, _stroke_start_chunks, _stroke_start_selection))
		undo_redo.add_do_method(_restore_chunks.bind(_stroke_frame, stroke_end_chunks, selection.capture()))
		undo_redo.commit_action(false)
	_stroke_frame = null
	_stroke_start_chunks = {}
	_stroke_start_selection = {}


func cancel_stroke() -> void:
	if _stroke_frame == null:
		return
	_restore_chunks(_stroke_frame, _stroke_start_chunks, _stroke_start_selection)
	_stroke_frame = null
	_stroke_start_chunks = {}
	_stroke_start_selection = {}


func _chunks_equal(first_chunks: Dictionary, second_chunks: Dictionary) -> bool:
	if first_chunks.size() != second_chunks.size():
		return false
	for chunk_location in first_chunks:
		if not second_chunks.has(chunk_location):
			return false
		if first_chunks[chunk_location] != second_chunks[chunk_location] and first_chunks[chunk_location].cell_colors != second_chunks[chunk_location].cell_colors:
			return false
	return true


func _restore_chunks(edited_frame: VoxelFrame, chunk_snapshot: Dictionary, selection_snapshot: Dictionary) -> void:
	var frame_index := document.frames.find(edited_frame)
	if frame_index == -1:
		return
	var cells_restored := edited_frame.chunks != chunk_snapshot
	edited_frame.restore(chunk_snapshot)
	document._bounds_dirty = true
	selection.restore(selection_snapshot)
	if cells_restored:
		var affected_cells: Array[Vector3i] = []
		cells_changed.emit(frame_index, affected_cells)
	selection_changed.emit()

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
	for operation_id in _operations.keys():
		var operation: Operation = _operations[operation_id]
		if operation.owner_ref and operation.owner_ref.get_ref() == null:
			finish_operation(operation_id)
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
	current_frame = _play_hi() if _play_mode() in [AnimationTag.LoopMode.REVERSE, AnimationTag.LoopMode.PING_PONG_REVERSE] else _play_lo()
	if _play_mode() == AnimationTag.LoopMode.PING_PONG_REVERSE:
		_play_dir = -1


func _play_lo() -> int:
	var tag := get_active_tag()
	if tag:
		return clampi(mini(tag.from, tag.to), 0, document.frames.size() - 1)
	return 0


func _play_hi() -> int:
	var tag := get_active_tag()
	if tag:
		return clampi(maxi(tag.from, tag.to), 0, document.frames.size() - 1)
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
	if current_frame < _play_lo() or current_frame > _play_hi():
		_init_playback()
		return
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
					if _play_mode() == AnimationTag.LoopMode.PING_PONG_REVERSE:
						_play_passes += 1
						if _finished():
							stop()
							return
					current_frame = _play_hi() - 1
					_play_dir = -1
				else:
					current_frame += 1
			else:
				if current_frame == _play_lo():
					if _play_mode() != AnimationTag.LoopMode.PING_PONG_REVERSE:
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
	if color == current_color:
		return
	undo_redo.create_action("Set Color", UndoRedo.MERGE_ENDS)
	undo_redo.add_undo_method(_apply_color.bind(current_color))
	undo_redo.add_do_method(_apply_color.bind(color))
	undo_redo.commit_action(false)
	_apply_color(color)


func _apply_color(color: Color) -> void:
	current_color = color
	color_changed.emit(color)

func add_color(color: Color = current_color) -> void:
	if not document.add_color(color):
		return
	undo_redo.create_action("Add Palette Color")
	undo_redo.add_undo_method(_remove_palette_color.bind(color))
	undo_redo.add_do_method(_add_palette_color.bind(color))
	undo_redo.commit_action(false)
	palette_changed.emit()


func _add_palette_color(color: Color) -> void:
	document.add_color(color)
	palette_changed.emit()


func _remove_palette_color(color: Color) -> void:
	document.remove_color(color)
	palette_changed.emit()

func get_color(index: int) -> Color:
	return document.get_color(index)
	
func get_color_at(position: Vector3i) -> Color:
	return document.get_color_at(current_frame, position)

func remove_color(color: Color = current_color) -> void:
	var index := document.palette.find(color)
	if index == -1:
		return
	undo_redo.create_action("Remove Palette Color")
	undo_redo.add_undo_method(_insert_palette_color.bind(index, color))
	undo_redo.add_do_method(_remove_palette_color.bind(color))
	undo_redo.commit_action(false)
	document.remove_color(color)
	palette_changed.emit()


func _insert_palette_color(index: int, color: Color) -> void:
	if not document.palette.has(color):
		document.palette.insert(index, color)
	palette_changed.emit()

func get_palette() -> PackedColorArray:
	return document.palette


func set_palette(colors: PackedColorArray, action_name: String = "Replace Palette") -> void:
	if edit_busy() or get_palette() == colors:
		return
	undo_redo.create_action(action_name)
	undo_redo.add_undo_method(_apply_palette.bind(get_palette()))
	undo_redo.add_do_method(_apply_palette.bind(colors))
	undo_redo.commit_action()


func _apply_palette(colors: PackedColorArray) -> void:
	document.palette.assign(colors)
	palette_changed.emit()


func move_palette_color(from_index: int, to_index: int) -> void:
	var colors := get_palette()
	if edit_busy() or from_index == to_index or from_index < 0 or to_index < 0 or from_index >= colors.size() or to_index >= colors.size():
		return
	var color := colors[from_index]
	colors.remove_at(from_index)
	colors.insert(to_index, color)
	set_palette(colors, "Move Palette Color")


static func get_builtin_palette() -> PackedColorArray:
	# Keep grayscale first, then vivid hues, cooler shadows, and warmer highlights.
	return PackedColorArray([
		Color.BLACK, Color("808080"), Color.WHITE,
		Color("ff0000"), Color("ff8000"), Color("ffff00"), Color("80ff00"), Color("00ff00"), Color("00ff80"),
		Color("00ffff"), Color("0080ff"), Color("0000ff"), Color("8000ff"), Color("ff00ff"), Color("ff0080"),
		Color("800020"), Color("608000"), Color("008020"), Color("006080"), Color("200080"), Color("600080"),
		Color("ffb399"), Color("fffbef"), Color("bfffaa"), Color("b3ffec"), Color("b3c6ff"), Color("ffb3ec"),
	])


func load_default_palette(path: String = DEFAULT_PALETTE_PATH) -> void:
	default_palette = get_builtin_palette()
	var config := ConfigFile.new()
	if config.load(path) == OK:
		var colors: Variant = config.get_value("palette", "colors", PackedColorArray())
		if colors is PackedColorArray and not colors.is_empty():
			default_palette = colors
	default_palette_changed.emit()


func save_default_palette(path: String = DEFAULT_PALETTE_PATH) -> Error:
	if edit_busy():
		return ERR_BUSY
	var colors := get_palette()
	if colors.is_empty():
		return ERR_INVALID_DATA
	var config := ConfigFile.new()
	config.set_value("palette", "colors", colors)
	var error := config.save(path)
	if error == OK:
		default_palette = colors
		default_palette_changed.emit()
	return error


func reset_default_palette(path: String = DEFAULT_PALETTE_PATH) -> Error:
	if edit_busy():
		return ERR_BUSY
	if FileAccess.file_exists(path):
		var error := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		if error != OK:
			return error
	default_palette = get_builtin_palette()
	default_palette_changed.emit()
	return OK


static func get_image_file_filter() -> String:
	var patterns := PackedStringArray()
	for extension in IMAGE_EXTENSIONS:
		patterns.append("*." + extension)
	return ", ".join(patterns) + " ; Images"


static func load_image(path: String, image: Image) -> Error:
	var extension := path.get_extension().to_lower()
	var error: Error = OK
	if extension in ["dds", "ktx", "ktx2"]:
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			return FileAccess.get_open_error()
		var bytes := file.get_buffer(file.get_length())
		file.close()
		error = image.load_dds_from_buffer(bytes) if extension == "dds" else image.load_ktx_from_buffer(bytes)
	else:
		error = image.load(path)
	if error != OK:
		return error
	if image.is_compressed():
		return image.decompress()
	return OK

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
	if selection.is_empty() or edit_busy():
		return
	var edited_document := document
	var edited_frame := get_current_voxel_frame()
	begin_stroke()
	var job := EraseJob.new()
	job.edited_frame = edited_frame.copy_frame()
	job.selection_mask = selection.capture()
	_erase_job = job
	var operation_id := begin_operation("Erasing selection", selection.count(), true, self)
	_erase_operation_id = operation_id
	if selection.count() <= 4096:
		job.run()
	else:
		job.worker_task_id = WorkerThreadPool.add_task(job.run, true, "Erase selection")
		_erase_jobs.append(job)
		while not WorkerThreadPool.is_task_completed(job.worker_task_id):
			var progress := job.progress()
			update_operation(operation_id, progress[1], progress[2], progress[0])
			await get_tree().process_frame
		WorkerThreadPool.wait_for_task_completion(job.worker_task_id)
		_erase_jobs.erase(job)
	if _erase_job != job:
		return
	if document != edited_document or get_current_voxel_frame() != edited_frame:
		_interrupt_erase()
		return
	edited_frame.restore(job.edited_frame.capture())
	document._bounds_dirty = true
	end_stroke("Erase Selection")
	if not job.changed_chunks.is_empty():
		chunks_changed.emit(current_frame, job.changed_chunks)
	_erase_job = null
	finish_operation(operation_id)
	_erase_operation_id = 0


func _interrupt_erase() -> void:
	if _erase_job == null:
		return
	_erase_job.cancel()
	_erase_job = null
	cancel_stroke()
	finish_operation(_erase_operation_id)
	_erase_operation_id = 0


func _input(event: InputEvent) -> void:
	if _erase_job and event.is_action_pressed("ui_cancel"):
		_interrupt_erase()
		get_viewport().set_input_as_handled()


func _exit_tree() -> void:
	for job in _erase_jobs:
		job.cancel()
		WorkerThreadPool.wait_for_task_completion(job.worker_task_id)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		undo_redo.free()


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
	edit_context_changing.emit()
	is_playing = false
	var before := _frame_snapshot()
	document.add_frame()
	current_frame = document.frames.size() - 1
	_record_frame_action("Add Frame", before, _frame_snapshot())


func duplicate_frame() -> void:
	edit_context_changing.emit()
	is_playing = false
	var before := _frame_snapshot()
	document.duplicate_frame(current_frame)
	current_frame += 1
	_record_frame_action("Duplicate Frame", before, _frame_snapshot())


func delete_frame() -> void:
	if document.frames.size() <= 1:
		return
	edit_context_changing.emit()
	is_playing = false
	var before := _frame_snapshot()
	document.remove_frame(current_frame)
	if current_frame >= document.frames.size():
		current_frame = document.frames.size() - 1
	_record_frame_action("Delete Frame", before, _frame_snapshot())


func move_frame(from: int, to: int) -> void:
	var f := clampi(from, 0, document.frames.size() - 1)
	var t := clampi(to, 0, document.frames.size() - 1)
	if f == t:
		return
	edit_context_changing.emit()
	var before := _frame_snapshot()
	document.move_frame(f, t)
	if current_frame == f:
		current_frame = t
	elif f < current_frame and current_frame <= t:
		current_frame -= 1
	elif t <= current_frame and current_frame < f:
		current_frame += 1
	_record_frame_action("Move Frame", before, _frame_snapshot())


func _frame_snapshot() -> Dictionary:
	return {
		"frames": document.frames.duplicate(),
		"ranges": _tag_ranges(),
		"current": current_frame,
	}


@warning_ignore("shadowed_variable_base_class")
func _record_frame_action(name: String, before: Dictionary, after: Dictionary) -> void:
	undo_redo.create_action(name)
	undo_redo.add_undo_method(_restore_frame_layout.bind(before["frames"], before["ranges"], before["current"]))
	undo_redo.add_do_method(_restore_frame_layout.bind(after["frames"], after["ranges"], after["current"]))
	undo_redo.commit_action(false)
	_restore_frame_layout(after["frames"], after["ranges"], after["current"])


func _restore_frame_layout(frames: Array[VoxelFrame], ranges: Array[Vector2i], current: int) -> void:
	edit_context_changing.emit()
	document.frames = frames
	_set_tag_ranges(ranges)
	document._bounds_dirty = true
	current_frame = clampi(current, 0, frames.size() - 1)
	frames_changed.emit()


func _tag_ranges() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for tag in document.tags:
		out.append(Vector2i(tag.from, tag.to))
	return out


func _set_tag_ranges(ranges: Array[Vector2i]) -> void:
	for i in mini(ranges.size(), document.tags.size()):
		var tag := document.tags[i]
		tag.from = ranges[i].x
		tag.to = ranges[i].y


func set_frame_delay(index: int, ms: int) -> void:
	if index < 0 or index >= document.frames.size():
		return
	var frame := document.frames[index]
	if frame.delay_ms == ms:
		return
	undo_redo.create_action("Set Frame Delay")
	undo_redo.add_undo_method(_apply_frame_delay.bind(index, frame.delay_ms))
	undo_redo.add_do_method(_apply_frame_delay.bind(index, ms))
	undo_redo.commit_action(false)
	_apply_frame_delay(index, ms)


func _apply_frame_delay(index: int, ms: int) -> void:
	if index < 0 or index >= document.frames.size():
		return
	document.frames[index].delay_ms = ms
	frame_changed.emit()


@warning_ignore("shadowed_variable_base_class")
func add_tag(name: String, from: int = 0, to: int = -1) -> void:
	var end := to
	if to < 0:
		end = document.frames.size() - 1
	var index := document.tags.size()
	var tag := AnimationTag.new()
	tag.name = name
	tag.from = clampi(from, 0, document.frames.size() - 1)
	tag.to = clampi(end, tag.from, document.frames.size() - 1)
	var prev_active := active_tag
	undo_redo.create_action("Add Tag")
	undo_redo.add_undo_method(_apply_tag_removed.bind(index, prev_active))
	undo_redo.add_do_method(_apply_tag_inserted.bind(index, tag, index))
	undo_redo.commit_action(false)
	_apply_tag_inserted(index, tag, index)


func _apply_tag_inserted(index: int, tag: AnimationTag, active: int) -> void:
	document.tags.insert(index, tag)
	active_tag = active
	frames_changed.emit()


func _apply_tag_removed(index: int, active: int) -> void:
	document.tags.remove_at(index)
	active_tag = active
	frames_changed.emit()


func get_active_tag() -> AnimationTag:
	return document.get_tag(active_tag)
	
func get_tag(i: int) -> AnimationTag:
	return document.get_tag(i)

func remove_tag() -> void:
	if document.tags.size() <= 1:
		return
	var index := active_tag
	var tag := document.get_tag(index)
	var new_active := clampi(index, -1, document.tags.size() - 2)
	undo_redo.create_action("Remove Tag")
	undo_redo.add_undo_method(_apply_tag_inserted.bind(index, tag, index))
	undo_redo.add_do_method(_apply_tag_removed.bind(index, new_active))
	undo_redo.commit_action(false)
	_apply_tag_removed(index, new_active)

func set_tag_range(from: int, to: int) -> void:
	var tag := get_active_tag()
	if tag == null:
		return
	var last := document.frames.size() - 1
	var new_from := clampi(from, 0, last)
	var new_to := clampi(to, new_from, last)
	if tag.from == new_from and tag.to == new_to:
		return
	var index := active_tag
	var old_from := tag.from
	var old_to := tag.to
	undo_redo.create_action("Set Tag Range", UndoRedo.MERGE_ENDS)
	undo_redo.add_undo_method(_apply_tag_range.bind(index, old_from, old_to))
	undo_redo.add_do_method(_apply_tag_range.bind(index, new_from, new_to))
	undo_redo.commit_action(false)
	_apply_tag_range(index, new_from, new_to)


func _apply_tag_range(index: int, from: int, to: int) -> void:
	var tag := document.get_tag(index)
	if tag == null:
		return
	tag.from = from
	tag.to = to
	if is_playing:
		current_frame = clampi(current_frame, _play_lo(), _play_hi())
	tag_changed.emit()


func set_tag_loop_mode(index: int, mode: int) -> void:
	var tag := document.get_tag(index)
	if tag == null or tag.loop_mode == mode:
		return
	undo_redo.create_action("Set Loop Mode")
	undo_redo.add_undo_method(_apply_tag_loop_mode.bind(index, tag.loop_mode))
	undo_redo.add_do_method(_apply_tag_loop_mode.bind(index, mode))
	undo_redo.commit_action(false)
	_apply_tag_loop_mode(index, mode)


func _apply_tag_loop_mode(index: int, mode: int) -> void:
	var tag := document.get_tag(index)
	if tag == null:
		return
	@warning_ignore("int_as_enum_without_cast")
	tag.loop_mode = mode
	tag_changed.emit()


func set_tag_repeats(index: int, value: int) -> void:
	var tag := document.get_tag(index)
	if tag == null or tag.repeats == value:
		return
	undo_redo.create_action("Set Repeats")
	undo_redo.add_undo_method(_apply_tag_repeats.bind(index, tag.repeats))
	undo_redo.add_do_method(_apply_tag_repeats.bind(index, value))
	undo_redo.commit_action(false)
	_apply_tag_repeats(index, value)


func _apply_tag_repeats(index: int, value: int) -> void:
	var tag := document.get_tag(index)
	if tag == null:
		return
	tag.repeats = value
	tag_changed.emit()


@warning_ignore("shadowed_variable_base_class")
func set_tag_name(index: int, name: String) -> void:
	var tag := document.get_tag(index)
	if tag == null or tag.name == name:
		return
	undo_redo.create_action("Set Tag Name")
	undo_redo.add_undo_method(_apply_tag_name.bind(index, tag.name))
	undo_redo.add_do_method(_apply_tag_name.bind(index, name))
	undo_redo.commit_action(false)
	_apply_tag_name(index, name)


@warning_ignore("shadowed_variable_base_class")
func _apply_tag_name(index: int, name: String) -> void:
	var tag := document.get_tag(index)
	if tag == null:
		return
	tag.name = name
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

