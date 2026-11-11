extends "res://tests/test.gd"

# A heavy GLB export runs its mesh worker across several frames, so the status
# cancel button and Escape can cancel it while the job is still running. The test
# uses the real plugin call and a real GUI input, not a fake callback.

const FRAMES := 96
const CANCEL_PATH := "user://voxel_gltf_cancel_test.glb"

var exporter: Node
var viewport: SubViewport
var widget: Node
var _result: Error = OK
var _done := false
var _op_id := 0


func _ready() -> void:
	timeout = 30.0
	test("the status cancel button cancels a running GLB export", _cancel_with_button, "gltf_cancel_button")
	test("Escape cancels a running GLB export", _cancel_with_escape, "gltf_cancel_escape")


func before_test() -> void:
	_result = OK
	_done = false
	_op_id = 0
	viewport = null
	widget = null
	exporter = plugin("ExportPlugin")
	_remove_file(CANCEL_PATH)
	_build_heavy_document()
	# The real flow opens the export workspace before a GLB save.
	exporter._menu_item.get_node("ExportBtn").button_pressed = true


func after_test() -> void:
	# Own the job on every path, so a failed step leaves no worker or operation.
	if is_instance_valid(exporter) and exporter._gltf != null and exporter._gltf._export_job != null:
		exporter._gltf.cancel()
	if is_instance_valid(exporter) and exporter._menu_item != null:
		exporter._menu_item.get_node("ExportBtn").button_pressed = false
		exporter.show_editor_tab()
	var guard := 0
	while State.get_activity() != null and guard < 240:
		State.finish_operation(State.get_activity().id)
		await get_tree().process_frame
		guard += 1
	if is_instance_valid(viewport):
		viewport.queue_free()
	viewport = null
	widget = null
	_remove_file(CANCEL_PATH)
	State.document = VoxelDocument.new()
	await get_tree().process_frame


func _cancel_with_button() -> void:
	step("Given a running GLB export and a status widget that shows work at once", func():
		_start_export()
		_op_id = State.get_activity().id if State.get_activity() != null else 0
		expect(_op_id != 0 and State.get_activity().foreground, "the export owns a foreground operation")
		expect(State.get_activity().owner_ref.get_ref() == exporter, "the export operation belongs to the export plugin")
		expect(State.get_activity().can_cancel(), "the export operation registers a cancel action")
		# The widget helper needs its own sized viewport for a real GUI hit test.
		viewport = SubViewport.new()
		viewport.size = Vector2i(360, 40)
		viewport.gui_disable_input = false
		main.add_child(viewport)
		widget = load("res://ui/JobStatus/job_status.tscn").instantiate()
		widget.delay_ms = 0
		viewport.add_child(widget)
		widget.size = Vector2(360, 40)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("When the user presses and releases the cancel button", func():
		expect(widget.visible, "the status widget shows the export")
		var cancel: Button = widget.get_node("Cancel")
		expect(cancel.visible, "the status widget shows the cancel button")
		expect(cancel.size.x > 0.0, "the cancel button has a laid-out rectangle")
		_click_cancel()
	)
	step("Then the cancel removes the export operation once", func():
		expect(not State.has_operation(_op_id), "the cancel removes the export operation")
		expect(not State.cancel_operation(_op_id), "a repeat cancel request is refused")
	)
	await _await_export()
	step("Then the cancelled GLB export writes nothing and releases its job", func():
		_expect_cancelled()
	)


func _cancel_with_escape() -> void:
	step("Given a running GLB export", func():
		_start_export()
		_op_id = State.get_activity().id if State.get_activity() != null else 0
		expect(_op_id != 0 and State.get_activity().foreground, "the export owns a foreground operation")
		expect(State.get_activity().owner_ref.get_ref() == exporter, "the export operation belongs to the export plugin")
		expect(State.get_activity().can_cancel(), "the export operation registers a cancel action")
	)
	step("When the user presses Escape", func():
		_key(KEY_ESCAPE)
	)
	step("Then the cancel removes the export operation once", func():
		expect(not State.has_operation(_op_id), "the cancel removes the export operation")
		expect(not State.cancel_operation(_op_id), "a repeat cancel request is refused")
	)
	await _await_export()
	step("Then the cancelled GLB export writes nothing and releases its job", func():
		_expect_cancelled()
	)


func _start_export() -> void:
	_run_export()


func _run_export() -> void:
	_result = await exporter.export_gltf(CANCEL_PATH)
	_done = true


func _await_export() -> void:
	var guard := 0
	while not _done and guard < 600:
		await get_tree().process_frame
		guard += 1
	expect(_done, "the cancelled export finishes")


func _expect_cancelled() -> void:
	expect(_result == ERR_UNAVAILABLE, "the cancelled export reports cancellation")
	expect(not FileAccess.file_exists(CANCEL_PATH), "the cancelled export writes no GLB file")
	expect(not State.edit_busy(), "the cancelled export releases editing")
	expect(exporter._gltf._export_job == null, "the cancelled export drops its job")
	expect(exporter._gltf._export_operation_id == 0, "the cancelled export clears its operation id")
	expect(exporter._gltf._export_root == null, "the cancelled export frees its scene root")


func _build_heavy_document() -> void:
	State.document = VoxelDocument.new()
	var material := VoxelFrame.material(Color.RED)
	var cells := {}
	for x in 8:
		for y in 8:
			for z in 8:
				cells[Vector3i(x, y, z)] = material
	State.get_current_voxel_frame().set_cells(cells)
	for index in FRAMES - 1:
		State.document.add_frame(0)
	State.document._bounds_dirty = true
	State.frames_changed.emit()
	State.undo_redo.clear_history()


func _click_cancel() -> void:
	var cancel: Button = widget.get_node("Cancel")
	var center := cancel.get_global_rect().get_center()
	_push_button(center, true)
	_push_button(center, false)


func _push_button(position: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.position = position
	event.global_position = position
	viewport.push_input(event, true)


func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	get_tree().root.push_input(event)
	event = InputEventKey.new()
	event.keycode = code
	event.pressed = false
	get_tree().root.push_input(event)


func _remove_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
