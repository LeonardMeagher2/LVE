extends VoxelPlugin

const ALPHA_CLIP := 0.5

var _import_job: ImportJob

class ImportJob extends VoxelFrame.EditJob:
	var path := ""
	var plane_axis := Vector3.Axis.AXIS_Y
	var error: Error = OK
	var imported_document := VoxelDocument.new()
	var _patterns: Array[Dictionary] = []
	var _occupied_bounds := AABB()
	var _palette_colors := {}

	func run() -> void:
		stage("Reading image", -1)
		var image := Image.new()
		error = State.load_image(path, image)
		if error != OK or not checkpoint(0):
			return
		imported_document.file_path = path
		imported_document.frames.clear()
		var descriptors: Array = []
		var metadata := {}
		var sidecar_path := path.get_basename() + ".json"
		if FileAccess.file_exists(sidecar_path):
			var parser := JSON.new()
			error = parser.parse(FileAccess.get_file_as_string(sidecar_path))
			if error != OK:
				return
			var data = parser.data
			if not data is Dictionary:
				error = ERR_INVALID_DATA
				return
			var frame_data = data.get("frames")
			if frame_data is Array:
				descriptors = frame_data
			elif frame_data is Dictionary:
				descriptors = frame_data.values()
			else:
				error = ERR_INVALID_DATA
				return
			metadata = data.get("meta", {})
			if descriptors.is_empty():
				error = ERR_INVALID_DATA
				return
		else:
			descriptors = [{"frame": {"x": 0, "y": 0, "w": image.get_width(), "h": image.get_height()}}]
		for descriptor in descriptors:
			if not checkpoint(0) or not _read_frame(image, descriptor):
				return
		var center := Vector3i((_occupied_bounds.get_center() + Vector3.ONE * 0.5).floor())
		for frame_index in _patterns.size():
			var centered_colors := {}
			stage("Centering image voxels", _patterns[frame_index].size())
			for cell_position: Vector3i in _patterns[frame_index]:
				centered_colors[cell_position - center] = VoxelFrame.material(_patterns[frame_index][cell_position])
				if centered_colors.size() % 4096 == 0 and not checkpoint(centered_colors.size()):
					return
			stage("Building image voxels", centered_colors.size())
			imported_document.frames[frame_index].set_cells(centered_colors, self)
			if not checkpoint(centered_colors.size()):
				return
		_read_tags(metadata)

	func _read_frame(image: Image, descriptor: Variant) -> bool:
		if not descriptor is Dictionary or not descriptor.get("frame") is Dictionary:
			error = ERR_INVALID_DATA
			return false
		var rect_data: Dictionary = descriptor.frame
		var rect := Rect2i(int(rect_data.get("x", 0)), int(rect_data.get("y", 0)), int(rect_data.get("w", 0)), int(rect_data.get("h", 0)))
		if rect.size.x <= 0 or rect.size.y <= 0 or not Rect2i(Vector2i.ZERO, image.get_size()).encloses(rect):
			error = ERR_INVALID_DATA
			return false
		if descriptor.get("rotated", false):
			error = ERR_UNAVAILABLE
			return false
		var source_size: Dictionary = descriptor.get("sourceSize", {"w": rect.size.x, "h": rect.size.y})
		var source_rect: Dictionary = descriptor.get("spriteSourceSize", {"x": 0, "y": 0})
		var horizontal := Vector3i.BACK if plane_axis == Vector3.Axis.AXIS_X else Vector3i.RIGHT
		var vertical := Vector3i.FORWARD if plane_axis == Vector3.Axis.AXIS_Y else Vector3i.UP
		var first_x := int(source_rect.get("x", 0)) - floori(int(source_size.w) * 0.5)
		var top_y := floori((int(source_size.h) - 1) * 0.5) - int(source_rect.get("y", 0))
		var pattern := {}
		stage("Importing image frame %s" % (imported_document.frames.size() + 1), rect.size.x * rect.size.y)
		var completed := 0
		for y in rect.size.y:
			for x in rect.size.x:
				var color := image.get_pixel(rect.position.x + x, rect.position.y + y)
				if color.a >= ALPHA_CLIP:
					color.a = 1.0
					var cell_position := horizontal * (x + first_x) + vertical * (top_y - y)
					pattern[cell_position] = color
					var bounds := AABB(Vector3(cell_position) - Vector3.ONE * 0.5, Vector3.ONE)
					_occupied_bounds = _occupied_bounds.merge(bounds) if _occupied_bounds.has_volume() else bounds
					if not _palette_colors.has(color):
						_palette_colors[color] = true
						imported_document.palette.append(VoxelFrame.material(color))
				completed += 1
				if completed % 4096 == 0 and not checkpoint(completed):
					return false
		var frame := VoxelFrame.new()
		frame.delay_ms = maxi(1, int(descriptor.get("duration", 100)))
		imported_document.frames.append(frame)
		_patterns.append(pattern)
		return true

	func _read_tags(metadata: Dictionary) -> void:
		for tag_data in metadata.get("frameTags", []):
			if not tag_data is Dictionary:
				continue
			var mode := AnimationTag.LoopMode.FORWARD
			match tag_data.get("direction", "forward"):
				"reverse": mode = AnimationTag.LoopMode.REVERSE
				"pingpong": mode = AnimationTag.LoopMode.PING_PONG
				"pingpong_reverse": mode = AnimationTag.LoopMode.PING_PONG_REVERSE
			var repeats := maxi(0, int(tag_data.get("repeat", 0)))
			if tag_data.get("data", "") == "no_loop":
				repeats = 1
			imported_document.add_tag(str(tag_data.get("name", "Tag")), int(tag_data.get("from", 0)), int(tag_data.get("to", 0)), mode, repeats)


func _ready() -> void:
	name = "ImageImportPlugin"


func import_image(path: String) -> Error:
	if State.edit_busy() or _import_job:
		return ERR_BUSY
	State.edit_context_changing.emit()
	State.stop()
	var document := State.document
	var frame := State.get_current_voxel_frame()
	var job := ImportJob.new()
	job.path = path
	job.plane_axis = State.floor_axis
	_import_job = job
	var operation_id := State.begin_operation("Importing image", -1, true, self)
	job.worker_task_id = WorkerThreadPool.add_task(job.run, true, "Image import")
	while not WorkerThreadPool.is_task_completed(job.worker_task_id):
		if State.document != document or State.get_current_voxel_frame() != frame:
			job.cancel()
		var progress := job.progress()
		State.update_operation(operation_id, progress[1], progress[2], progress[0])
		await State.get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(job.worker_task_id)
	_import_job = null
	State.finish_operation(operation_id)
	if State.document != document or State.get_current_voxel_frame() != frame or not job.checkpoint(0):
		return ERR_BUSY
	if job.error != OK:
		return job.error
	State.document = job.imported_document
	return OK


func _exit_tree() -> void:
	if _import_job:
		_import_job.cancel()
		WorkerThreadPool.wait_for_task_completion(_import_job.worker_task_id)
