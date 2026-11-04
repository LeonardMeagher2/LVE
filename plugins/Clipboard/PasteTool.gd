extends "res://plugins/brush/LineTool.gd"

## The paste tool.
##
## It places a copied pattern at the pointer and commits one paste. Enter
## commits. Escape cancels. It emits [signal finished] when it stops.

## Emitted when the paste tool stops.
signal finished()

var _active := false
var _placement_operation_id := 0
var _selection_pattern := {}
var _material_pattern := {}
var _preview_pattern := {}


## One cancellable paste job.
##
## It writes the pattern and builds the pasted selection.
## [method BrushTool.BrushJob.run] is the base worker body.
class PasteJob extends BrushJob:
	## The selection offsets relative to the pattern center.
	var selection_pattern := {}
	## The pasted selection cells, keyed by cell position.
	var pasted_selection := {}

	## Writes the pattern and the pasted selection. This is the worker body.
	func run() -> void:
		super.run()
		if not checkpoint(0):
			return
		stage("Preparing pasted selection", selection_pattern.size())
		for offset: Vector3i in selection_pattern:
			pasted_selection[centers[0] + offset] = true
			if pasted_selection.size() % 4096 == 0 and not checkpoint(pasted_selection.size()):
				return


## Starts one paste placement. [param pattern] maps an offset to a color.
## [param material_pattern] maps an offset to a full material. [param center] is
## the pattern center.
func begin_paste(pattern: Dictionary, selection_pattern: Dictionary, center: Vector3i, material_pattern := {}) -> void:
	_active = true
	_source_document = State.document
	_source_frame = State.get_current_voxel_frame()
	_line_snapshot = _source_frame.copy_frame()
	_anchor = center
	_endpoint = VoxelPicking.NONE
	_stroke_pattern = pattern
	_stroke_offsets = pattern.keys()
	_selection_pattern = selection_pattern
	_material_pattern = material_pattern
	_preview_pattern = pattern
	if not material_pattern.is_empty():
		if material_pattern.size() == pattern.size():
			_preview_pattern = material_pattern
		else:
			_preview_pattern = pattern.duplicate()
			for cell in pattern:
				_preview_pattern[cell] = material_pattern.get(cell, VoxelFrame.material(pattern[cell]))
			_preview_pattern.make_read_only()
	_stroke_shape = _settings.BrushShape.SELECTION
	_stroke_pattern_size = maxi(pattern.size(), selection_pattern.size())
	_selection_mask = {}
	_placement_operation_id = State.begin_operation("Placing pasted voxels", -1, true, self)
	_update_endpoint(center)


## Handles one input event. A pointer move places the pattern. A click or Enter
## commits the paste. Escape cancels it.
func handle_input(event: InputEvent, pos: Vector2) -> bool:
	if not _active:
		return false
	if event.is_action_pressed("ui_cancel"):
		_cancel_edit()
		return true
	if event.is_action_pressed("ui_accept"):
		_request_commit()
		return true
	if event is InputEventMouseMotion or (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed):
		if _commit_requested:
			return true
		var ray := _ray(pos)
		var pick := _pick_start(ray[0], ray[1])
		if pick.target != VoxelPicking.NONE:
			_update_endpoint(pick.target)
			if event is InputEventMouseButton:
				_request_commit()
		return true
	return event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT


func _preview_centers() -> Array[Vector3i]:
	return [_endpoint]


func _show_preview(_built_job: BrushJob) -> void:
	position = Vector3(_endpoint)
	$Cursor.show_voxels(_preview_pattern, Color.WHITE)


func _create_preview_job() -> BrushJob:
	var job := PasteJob.new()
	job.selection_pattern = _selection_pattern
	job.material_pattern = _material_pattern
	job.replace_materials = true
	return job


## Returns the placement operation, so the placement and the preview share one
## status entry and one cancel path.
func _begin_preview_operation(_work: int) -> int:
	return _placement_operation_id


## Keeps the placement operation open until the paste stops.
func _finish_preview_operation(_id: int) -> void:
	pass


func _commit_line() -> void:
	if _preview_result == null:
		return
	var job := _preview_result as PasteJob
	var frame := _source_frame
	var context_valid := State.document == _source_document and State.get_current_voxel_frame() == frame
	_cancel_edit()
	if not context_valid:
		return
	var tx := State.begin_edit()
	if tx == null:
		return
	# Publish the cells the paste preview wrote. The snapshot is unchanged, so
	# an unchanged chunk stays as it is.
	frame.apply_published(job.changed_chunks, job.edited_frame)
	State.document._bounds_dirty = true
	State.selection.restore(job.pasted_selection)
	State.finish_edit(tx, "Paste")
	if not job.changed_chunks.is_empty():
		State.chunks_changed.emit(State.current_frame, job.changed_chunks)
	State.selection_changed.emit()


func _cancel_edit() -> void:
	var was_active := _active
	_active = false
	State.finish_operation(_placement_operation_id)
	_placement_operation_id = 0
	super._cancel_edit()
	if was_active:
		finished.emit()


# A removal without a cancel still releases the placement operation, so the
# status bar cannot keep a finished paste.
func _exit_tree() -> void:
	State.finish_operation(_placement_operation_id)
	_placement_operation_id = 0
	super._exit_tree()


func _on_settings_changed() -> void:
	pass
