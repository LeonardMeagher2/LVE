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
signal symmetry_changed()
signal tag_changed()
signal activity_changed()
signal edit_context_changing()
signal model_settings_changed()

const WORK_SLICE_US := 3000
const DEFAULT_PALETTE_PATH := "user://default_palette.cfg"
const SESSION_PATH := "user://session.cfg"
const DEFAULT_SYMMETRY_ORIGIN := Vector3(-0.5, -0.5, -0.5)
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


var playback := AnimationPlayback.new()
var document: VoxelDocument : set=set_document

var current_frame: int:
	get:
		return playback.current_frame
	set(value):
		playback.current_frame = value

var is_playing: bool:
	get:
		return playback.is_playing
	set(value):
		playback.is_playing = value

var active_tag: int:
	get:
		return playback.active_tag
	set(value):
		playback.active_tag = value

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

var symmetry_axes := 0:
	set(value):
		value &= 7
		if value == symmetry_axes:
			return
		symmetry_axes = value
		symmetry_changed.emit()

var symmetry_origin := DEFAULT_SYMMETRY_ORIGIN:
	set(value):
		value = value.snapped(Vector3.ONE * 0.5)
		if value == symmetry_origin:
			return
		symmetry_origin = value
		symmetry_changed.emit()

var current_color := Color.BLACK
var selection := VoxelSelection.new()
var undo_redo := UndoRedo.new()
var _stroke_frame: VoxelFrame
var _stroke_start_chunks := {}
var _stroke_start_selection := {}
var _stroke_edit_context: VoxelFrame.EditContext


func _init() -> void:
	playback.frame_changing.connect(edit_context_changing.emit)
	playback.frame_changed.connect(frame_changed.emit)
	playback.is_playing_toggled.connect(is_playing_toggled.emit)
	playback.tag_changed.connect(tag_changed.emit)
	document = VoxelDocument.new()

func _ready() -> void:
	load_default_palette()
	document.palette.assign(default_palette)
	current_color = default_palette[0]
	edit_context_changing.connect(_interrupt_erase)
	cells_changed.connect(func(_frame, _affected): stop())
	chunks_changed.connect(func(_frame, _affected): stop())
	
	add_plugin(load("res://plugins/brush/BrushPlugin.gd").new())
	add_plugin(load("res://plugins/Eyedropper/EyedropperPlugin.gd").new())
	add_plugin(load("res://plugins/Fill/FillPlugin.gd").new())
	add_plugin(load("res://plugins/selection/SelectionPlugin.gd").new())
	add_plugin(load("res://plugins/Transform/TransformPlugin.gd").new())
	add_plugin(load("res://plugins/Symmetry/SymmetryPlugin.gd").new())
	add_plugin(load("res://plugins/Plane/PlanePlugin.gd").new())
	add_plugin(load("res://plugins/Export/ExportPlugin.gd").new())
	add_plugin(load("res://plugins/Clipboard/ClipboardPlugin.gd").new())
	add_plugin(load("res://plugins/ImageImport/ImageImportPlugin.gd").new())
	


func set_document(value:VoxelDocument) -> void:
	if value == document:
		return
	edit_context_changing.emit()
	_operations.clear()
	_activity_started_ms = 0
	activity_changed.emit()
	_stroke_frame = null
	_stroke_start_chunks = {}
	_stroke_start_selection = {}
	_stroke_edit_context = null
	selection.clear()
	selection_changed.emit()
	undo_redo.clear_history()
	if value is VoxelDocument:
		document = value
	else:
		document = VoxelDocument.new()
		document.palette.assign(default_palette)
		_apply_color(default_palette[0])
	if document.tags.is_empty():
		document.add_tag("Default", 0, document.frames.size() - 1)
	playback.document = document
	active_tag = 0
		
	document_changed.emit()
	palette_changed.emit()
	frames_changed.emit()
	current_frame = 0


func add_plugin(plugin: VoxelPlugin) -> void:
	get_node("/root").add_child.call_deferred(plugin, true)
	
func remove_plugin(plugin: VoxelPlugin) -> void:
	get_node("/root").remove_child(plugin)
	plugin.queue_free()


func paint(position: Vector3i, color:Color) -> void:
	if symmetry_axes == 0 and _stroke_edit_context == null:
		document.paint(current_frame, position, color)
		return
	var context := drawing_context()
	var changes := context.expand({position: color}, get_current_voxel_frame(), false, null)
	get_current_voxel_frame().set_cells(changes)
	document._bounds_dirty = true


func drawing_context() -> VoxelFrame.EditContext:
	if _stroke_edit_context:
		return _stroke_edit_context
	var context := VoxelFrame.EditContext.new()
	context.axes = symmetry_axes
	context.origin_twice = Vector3i(symmetry_origin * 2.0)
	context.selection = selection.capture()
	context.selection.make_read_only()
	return context


func symmetry_transform(mask: int, origin: Vector3) -> Transform3D:
	var reflection := Vector3.ONE
	for axis in 3:
		if mask & (1 << axis):
			reflection[axis] = -1.0
	return Transform3D(Basis.from_scale(reflection), origin - origin * reflection)


func selection_context() -> VoxelFrame.EditContext:
	var drawing := drawing_context()
	var context := VoxelFrame.EditContext.new()
	context.axes = drawing.axes
	context.origin_twice = drawing.origin_twice
	return context


func selection_region(region: VoxelSelection) -> VoxelSelection:
	var result := VoxelSelection.new()
	result.restore(selection_context().expand(region.capture(), get_current_voxel_frame(), false, null))
	return result


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
	var background_operation: Operation = null
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
	_stroke_edit_context = null
	_stroke_edit_context = drawing_context()
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
	_stroke_edit_context = null


func cancel_stroke() -> void:
	if _stroke_frame == null:
		return
	_restore_chunks(_stroke_frame, _stroke_start_chunks, _stroke_start_selection)
	_stroke_frame = null
	_stroke_start_chunks = {}
	_stroke_start_selection = {}
	_stroke_edit_context = null


func _chunks_equal(first_chunks: Dictionary, second_chunks: Dictionary) -> bool:
	if first_chunks.size() != second_chunks.size():
		return false
	for chunk_location in first_chunks:
		if not second_chunks.has(chunk_location):
			return false
		var first_chunk: VoxelFrame.Chunk = first_chunks[chunk_location]
		var second_chunk: VoxelFrame.Chunk = second_chunks[chunk_location]
		if first_chunk != second_chunk and (first_chunk.cell_colors != second_chunk.cell_colors or first_chunk.cell_materials != second_chunk.cell_materials):
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
	playback.update(delta)

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


func get_builtin_palette() -> PackedColorArray:
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


func remember_document(path: String, config_path: String = SESSION_PATH) -> void:
	var config := ConfigFile.new()
	config.load(config_path)
	config.set_value("files", "last_document", path)
	config.save(config_path)


func forget_document(config_path: String = SESSION_PATH) -> void:
	var config := ConfigFile.new()
	if config.load(config_path) != OK:
		return
	if config.has_section_key("files", "last_document"):
		config.erase_section_key("files", "last_document")
	config.save(config_path)


func last_document_path(config_path: String = SESSION_PATH) -> String:
	var config := ConfigFile.new()
	if config.load(config_path) != OK:
		return ""
	var path: Variant = config.get_value("files", "last_document", "")
	return path if path is String else ""


func is_app_session() -> bool:
	var tree := get_tree()
	return tree != null and tree.current_scene == tree.root.get_node_or_null("Main")


func get_image_file_filter() -> String:
	var patterns := PackedStringArray()
	for extension in IMAGE_EXTENSIONS:
		patterns.append("*." + extension)
	return ", ".join(patterns) + " ; Images"


func load_image(path: String, image: Image) -> Error:
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


func set_smooth_normals(value: bool) -> void:
	if edit_busy() or value == document.smooth_normals:
		return
	undo_redo.create_action("Set Smooth Normals")
	undo_redo.add_undo_method(_apply_smooth_normals.bind(document.smooth_normals))
	undo_redo.add_do_method(_apply_smooth_normals.bind(value))
	undo_redo.commit_action(false)
	_apply_smooth_normals(value)


func _apply_smooth_normals(value: bool) -> void:
	document.smooth_normals = value
	model_settings_changed.emit()


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


func _record_frame_action(action_name: String, before: Dictionary, after: Dictionary) -> void:
	undo_redo.create_action(action_name)
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


func add_tag(tag_name: String, from: int = 0, to: int = -1) -> void:
	var end := to
	if to < 0:
		end = document.frames.size() - 1
	var index := document.tags.size()
	var tag := AnimationTag.new()
	tag.name = tag_name
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

func set_tag_range(from: int, to: int, record_history: bool = true) -> void:
	var tag := get_active_tag()
	if tag == null:
		return
	var last := document.frames.size() - 1
	var new_from := clampi(from, 0, last)
	var new_to := clampi(to, new_from, last)
	if tag.from == new_from and tag.to == new_to:
		return
	var index := active_tag
	var previous_range := Vector2i(tag.from, tag.to)
	_apply_tag_range(index, new_from, new_to)
	if record_history:
		commit_tag_range(index, previous_range)


func commit_tag_range(index: int, previous_range: Vector2i) -> void:
	var tag := document.get_tag(index)
	if tag == null or previous_range == Vector2i(tag.from, tag.to):
		return
	undo_redo.create_action("Set Tag Range")
	undo_redo.add_undo_method(_apply_tag_range.bind(index, previous_range.x, previous_range.y))
	undo_redo.add_do_method(_apply_tag_range.bind(index, tag.from, tag.to))
	undo_redo.commit_action(false)


func _apply_tag_range(index: int, from: int, to: int) -> void:
	var tag := document.get_tag(index)
	if tag == null:
		return
	tag.from = from
	tag.to = to
	if is_playing:
		current_frame = clampi(current_frame, playback.first_frame(), playback.last_frame())
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
	tag.loop_mode = mode as AnimationTag.LoopMode
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


func set_tag_name(index: int, tag_name: String) -> void:
	var tag := document.get_tag(index)
	if tag == null or tag.name == tag_name:
		return
	undo_redo.create_action("Set Tag Name")
	undo_redo.add_undo_method(_apply_tag_name.bind(index, tag.name))
	undo_redo.add_do_method(_apply_tag_name.bind(index, tag_name))
	undo_redo.commit_action(false)
	_apply_tag_name(index, tag_name)


func _apply_tag_name(index: int, tag_name: String) -> void:
	var tag := document.get_tag(index)
	if tag == null:
		return
	tag.name = tag_name
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
