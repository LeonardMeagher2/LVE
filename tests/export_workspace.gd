extends "res://tests/test.gd"

var exporter: Node
var tabs: TabContainer
var original_camera: Transform3D
var original_selection: Dictionary
var original_document: VoxelDocument
var extra_tab: Control
var error: Error
var saved_revision := 0
var saved_preview: Image
var complete_frames := true
const MODEL_PATH := "user://voxel_workspace_model.glb"
const SHEET_PATH := "user://voxel_workspace_sheet.png"


func _ready() -> void:
	timeout = 45.0
	test("Export shares plugin tabs and previews both formats without changing the editor", _run)


func _run() -> void:
	step("Given two colored frames and an editor selection", func():
		exporter = plugin("ExportPlugin")
		tabs = main.get_node("%TabContainer")
		State.document = VoxelDocument.new()
		State.document.set_cell(0, Vector3i(4, 2, 1), VoxelFrame.material(Color.RED))
		State.document.add_frame()
		State.document.set_cell(1, Vector3i(5, 2, 1), VoxelFrame.material(Color.BLUE))
		State.frames_changed.emit()
		State.active_tag = State.document.add_tag("Second", 1, 1)
		State.selection.from_box(Vector3i(4, 2, 1), Vector3i(5, 2, 1))
		select_toolbar_item("Toolbar", "Eraser")
		original_document = State.document
		original_selection = State.selection.capture()
		original_camera = camera_rig().transform
	)
	step("When a plugin adds, opens, and removes another workspace", func():
		extra_tab = VBoxContainer.new()
		extra_tab.name = "Extra"
		exporter.add_tab(extra_tab)
		exporter.add_tab(extra_tab)
		expect(tabs.get_tab_count() == 3, "adding the same plugin tab keeps one workspace")
		exporter.show_tab(extra_tab)
		expect(tabs.get_current_tab_control() == extra_tab, "a plugin can open its tab")
	)
	step("Then removing the active plugin tab returns to the editor", func():
		exporter.remove_tab(extra_tab)
		expect(tabs.get_current_tab_control() == main.get_node("%Editor"), "removing the active tab restores the editor")
		expect(extra_tab.get_parent() == null, "the plugin retains ownership of the detached tab")
		extra_tab.free()
	)
	step("When the user opens Export", func():
		exporter._menu_item.get_node("ExportBtn").button_pressed = true
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then both export panels use a separate workspace", func():
		expect(tabs.get_current_tab_control() == exporter._workspace, "the export button opens its plugin tab")
		expect(not tabs.tabs_visible, "workspace navigation adds no tab header row")
		expect(not main.get_node("%Editor").can_process(), "the hidden editor stops processing input")
		expect(exporter._model_camera is EditorCameraRig, "the model preview uses the shared camera controls")
		expect(exporter._model_viewport.find_world_3d() != editor_viewport().find_world_3d(), "the preview has an independent 3D world")
		expect(not exporter._dialog.visible and not exporter._sheet_dialog.visible, "opening Export creates no save dialog")
		expect(exporter._menu_item.get_node("ExportBtn").button_pressed, "the export toggle shows the active workspace")
		expect(not exporter._workspace.has_node("Header"), "the previews use the space without a workspace heading")
		expect(exporter._workspace.get_node("Panels") is HBoxContainer, "the export panels use a fixed layout")
		expect(not exporter._model.has_node("Title") and not exporter._controls.has_node("Title"), "the previews start without redundant headings")
		expect(not exporter._workspace.has_node("Activity") and not exporter._model.has_node("Summary") and not exporter._controls.has_node("Summary"), "the workspace uses the shared bottom status bar")
	)
	step("When mouse input reaches the hidden editor viewport", func():
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = camera_rig().unproject_position(Vector3(4, 2.5, 1))
		event.pressed = true
		editor_viewport().push_input(event)
		event.pressed = false
		editor_viewport().push_input(event)
	)
	step("Then hidden editor tools leave the document unchanged", func():
		expect(State.get_voxel_frame(0).has(Vector3i(4, 2, 1)), "the hidden Eraser tool preserves the selected voxel")
		expect(not State.undo_redo.has_undo(), "export preview input adds no editor undo action")
	)
	step("When the user preserves the document origin", func():
		exporter._model.get_node("AnimationRow/Center").button_pressed = false
	)
	await get_tree().process_frame
	await get_tree().process_frame
	error = await exporter.export_gltf(MODEL_PATH)
	step("Then the preview and saved model preserve the same origin", func():
		expect(error == OK, "the model exports with its document origin")
		expect(exporter._model_renderer.transform == Transform3D.IDENTITY, "the preview preserves the document origin")
		var document := GLTFDocument.new()
		var state := GLTFState.new()
		expect(document.append_from_file(MODEL_PATH, state) == OK, "the model imports successfully")
		var meshes := state.get_meshes()
		expect(meshes.size() == 2, "the model export contains both animation frames")
		if not meshes.is_empty():
			expect(meshes[0].mesh.get_mesh().get_aabb().is_equal_approx(AABB(Vector3(3.5, 1.5, 0.5), Vector3.ONE)), "the file preserves the voxel position and size")
		expect(state.get_animations().size() == State.document.tags.size(), "the export retains the named animation clips")
	)
	step("When the user centers the exported content", func():
		exporter._model.get_node("AnimationRow/Center").button_pressed = true
	)
	await get_tree().process_frame
	error = await exporter.export_gltf(MODEL_PATH)
	step("Then all exported frames share the same centered origin", func():
		expect(error == OK, "the centered model exports successfully")
		var document := GLTFDocument.new()
		var state := GLTFState.new()
		document.append_from_file(MODEL_PATH, state)
		var meshes := state.get_meshes()
		var bounds: AABB = meshes[0].mesh.get_mesh().get_aabb().merge(meshes[1].mesh.get_mesh().get_aabb())
		expect(bounds.get_center().is_zero_approx(), "the complete animation is centered at the origin")
		expect(exporter._model_renderer.position == Vector3(-4.5, -2, -1), "the preview uses the same shared centering offset")
	)
	step("When the user plays the model preview", func():
		exporter._model_step = 0
		exporter._model.get_node("AnimationRow/Play").button_pressed = true
	)
	while exporter._model_step == 0:
		await get_tree().process_frame
	for _frame in 20:
		await get_tree().process_frame
		var visible_surface := false
		for chunk: MeshInstance3D in exporter._model_renderer._chunk_instances.values():
			visible_surface = visible_surface or (chunk.is_visible_in_tree() and chunk.mesh != null)
		complete_frames = complete_frames and visible_surface
	step("Then preview playback advances without changing the editor frame", func():
		expect(State.current_frame == 0, "preview playback leaves the editor frame in place")
		expect(complete_frames, "playback keeps a complete model visible while frames change")
		expect(exporter._model_playback.get_script() == State.playback.get_script(), "preview and editor use the same playback controller")
		exporter._model.get_node("AnimationRow/Play").button_pressed = false
	)
	step("When the user selects the Second tag", func():
		var selector: OptionButton = exporter._model.get_node("AnimationRow/Tags")
		selector.select(2)
		selector.item_selected.emit(2)
	)
	await get_tree().process_frame
	error = await exporter.export_gltf(MODEL_PATH)
	step("Then the selected tag drives preview and glTF export", func():
		expect(error == OK and exporter._model_frames.size() == 1, "the selected tag limits the preview to its frame")
		var document := GLTFDocument.new()
		var state := GLTFState.new()
		document.append_from_file(MODEL_PATH, state)
		expect(state.get_meshes().size() == 1 and state.get_animations().size() == 1, "the selected tag exports one frame and one clip")
		var selector: OptionButton = exporter._model.get_node("AnimationRow/Tags")
		selector.select(0)
		selector.item_selected.emit(0)
	)
	await get_tree().process_frame
	step("When the user plays a finite reverse tag in the preview", func():
		State.document.add_tag("Reverse preview", 0, 1, AnimationTag.LoopMode.REVERSE, 1)
		State.tag_changed.emit()
		var selector: OptionButton = exporter._model.get_node("AnimationRow/Tags")
		selector.select(3)
		selector.item_selected.emit(3)
	)
	await get_tree().process_frame
	step("Then reverse playback uses the editor tag boundaries and repeat rules", func():
		exporter._model.get_node("AnimationRow/Play").button_pressed = true
		expect(exporter._model_playback.current_frame == 1, "reverse playback starts at the tag end")
		exporter._model_playback.advance()
		expect(exporter._model_playback.current_frame == 0, "reverse playback moves to the tag start")
		exporter._model_playback.advance()
		expect(not exporter._model.get_node("AnimationRow/Play").button_pressed, "finite preview playback clears the Play toggle")
		var selector: OptionButton = exporter._model.get_node("AnimationRow/Tags")
		selector.select(0)
		selector.item_selected.emit(0)
	)
	await get_tree().process_frame
	step("When a frame build is pending in the preview", func():
		exporter._model.get_node("AnimationRow/Play").button_pressed = false
		exporter._model_playback.current_frame = 0
		exporter._model.get_node("AnimationRow/Play").button_pressed = true
		# Hold an unfinished surface and a pending frame, as a slow build does.
		exporter._model_pending_frame = 0
		exporter._model_back_renderer._pending_surface_keys[Vector3i.ZERO] = PackedInt64Array([1])
		expect(not exporter._model_back_renderer.is_settled(), "the test holds an unfinished frame build")
		# A correct playback clock applies every elapsed frame duration. With a
		# two-frame loop and a full second the frame index can wrap back to zero,
		# so count the frame changes instead of one final index.
		var frames_seen := [0]
		exporter._model_playback.frame_changed.connect(func() -> void: frames_seen[0] += 1, CONNECT_ONE_SHOT)
		exporter._process(1.0)
		expect(frames_seen[0] > 0, "the preview clock runs while a frame build is pending")
		exporter._model_back_renderer._pending_surface_keys.clear()
		exporter._model.get_node("AnimationRow/Play").button_pressed = false
	)
	step("When the editor frame changes while the preview is paused", func():
		exporter._model_playback.is_playing = false
		exporter._model_playback.current_frame = 0
		State.current_frame = 1
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the editor frame leaves the preview position alone", func():
		expect(exporter._model_playback.current_frame == 0, "an editor frame change does not move the preview")
		State.current_frame = 0
	)
	step("When the editor and the preview play the same tags", func():
		State.document.frames[0].delay_ms = 50
		State.document.frames[1].delay_ms = 250
		State.document.add_tag("Parity forward", 0, 1, AnimationTag.LoopMode.FORWARD, 0)
		State.document.add_tag("Parity ping", 0, 1, AnimationTag.LoopMode.PING_PONG, 2)
		State.tag_changed.emit()
	)
	await get_tree().process_frame
	var parity_failure := ""
	for tag_index in [1, 2, 3, 4]:
		var selector: OptionButton = exporter._model.get_node("AnimationRow/Tags")
		selector.select(tag_index + 1)
		selector.item_selected.emit(tag_index + 1)
		await get_tree().process_frame
		State.stop()
		exporter._model_playback.is_playing = false
		State.active_tag = tag_index
		var editor_steps := _clock_steps(State.playback, 0)
		var preview_steps := _clock_steps(exporter._model_playback, State.document.tags[tag_index].from)
		if editor_steps != preview_steps:
			parity_failure = "tag %d: %s vs %s" % [tag_index, editor_steps, preview_steps]
	step("Then both clocks play the same frames", func():
		expect(parity_failure.is_empty(), "editor and preview clocks play identical frames%s" % ("" if parity_failure.is_empty() else " (%s)" % parity_failure))
		State.stop()
		State.active_tag = 0
		State.current_frame = 0
	)
	await get_tree().process_frame
	if DisplayServer.get_name() != "headless":
		await _preview_behavior()
	step("When the user returns to the editor", func():
		exporter._menu_item.get_node("ExportBtn").button_pressed = false
	)
	await get_tree().process_frame
	step("Then the editor and export settings are preserved", func():
		expect(main.get_node("%Editor").can_process(), "the editor resumes input processing")
		expect(State.document == original_document and State.current_frame == 0, "preview preserves the editor document and frame")
		expect(State.selection.capture() == original_selection, "preview preserves the editor selection")
		expect(camera_rig().transform == original_camera, "preview controls preserve the editor camera")
		expect(exporter._model.get_node("AnimationRow/Center").button_pressed, "export settings survive workspace switching")
		expect(not exporter._menu_item.get_node("ExportBtn").button_pressed, "the export toggle clears when the editor is active")
	)
	step("When the user loads a model while Export is active", func():
		exporter._menu_item.get_node("ExportBtn").button_pressed = true
		var selector: OptionButton = exporter._model.get_node("AnimationRow/Tags")
		selector.select(2)
		selector.item_selected.emit(2)
		var loaded := VoxelDocument.new()
		loaded.frames[0].set_cells({Vector3i.ZERO: VoxelFrame.material(Color.GREEN), Vector3i(17, 0, 0): VoxelFrame.material(Color.BLUE)})
		State.document = loaded
	)
	await get_tree().process_frame
	await get_tree().process_frame
	var editor_renderer: VoxelRenderer = editor_viewport().get_node("ViewportScene/VoxelRenderer")
	while not editor_renderer.is_settled() or not exporter._model_renderer.is_settled():
		await get_tree().process_frame
	while exporter._model_pending_frame >= 0:
		await get_tree().process_frame
	step("Then building surfaces finishes without switching back to the editor", func():
		expect(tabs.get_current_tab_control() == exporter._workspace, "Export stays active while the new model loads")
		expect(State.get_activity() == null, "surface building releases its progress activity")
		expect(exporter._model_renderer.source_frame.count() == 2, "the preview contains the newly loaded model")
		expect(exporter._model.get_node("AnimationRow/Tags").selected == 0, "loading a document clears the previous document's tag choice")
	)
	for path in [MODEL_PATH, SHEET_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func _preview_behavior() -> void:
	step("When the user changes the sheet layout several times", func():
		exporter._sheet_settings.get_node("TurntableRow/Turntable").button_pressed = false
		exporter._sheet_settings.get_node("SizeRow/Size").value = 32
		exporter._sheet_settings.get_node("SizeRow/Size").value = 64
		exporter._sheet_settings.get_node("SizeRow/Size").value = 32
		exporter._sheet_settings.get_node("ViewRow/View").select(2)
		exporter._sheet_settings.get_node("ViewRow/View").item_selected.emit(2)
	)
	await _wait_preview()
	step("Then the live preview uses the latest settings", func():
		expect(exporter._preview_image != null and exporter._preview_image.get_size() == Vector2i(65, 32), "the live preview separates the two sprites with one pixel")
	)
	step("When the user changes only the model tag", func():
		saved_revision = exporter._preview_revision
		saved_preview = exporter._preview_image
		var selector: OptionButton = exporter._model.get_node("AnimationRow/Tags")
		selector.select(2)
		selector.item_selected.emit(2)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the independent sheet preview stays in place", func():
		expect(exporter._preview_revision == saved_revision and exporter._preview_image == saved_preview, "changing a model tag retains the preset sheet preview")
		var selector: OptionButton = exporter._model.get_node("AnimationRow/Tags")
		selector.select(0)
		selector.item_selected.emit(0)
	)
	await get_tree().process_frame
	step("When the user resets a manually changed sprite size", func():
		exporter._sheet_settings.get_node("SizeRow/Size").value = 99
		exporter._sheet_settings.get_node("SizeRow/Reset").pressed.emit()
		expect(exporter._sheet_settings.get_node("SizeRow/Size").value == 2, "Reset calculates the front-view size from the voxel bounds")
		exporter._sheet_settings.get_node("SizeRow/Size").value = 32
	)
	await _wait_preview()
	step("When the user sets the sheet zoom to one-to-one and pans", func():
		exporter._controls.get_node("ControlBar/ZoomOne").pressed.emit()
		expect(exporter._controls.get_node("ControlBar/ZoomSlider").value == 100, "one-to-one zoom displays one hundred percent")
		expect(exporter._controls.get_node("ControlBar/PanToggle").button_pressed, "the sheet starts with left-drag panning enabled")
		var motion := InputEventMouseMotion.new()
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		motion.relative = Vector2(12, 8)
		exporter._controls.get_node("Preview")._gui_input(motion)
		expect(exporter._controls.get_node("Preview")._pan == Vector2(12, 8), "the sheet pan button enables left-drag panning")
		exporter._controls.get_node("ControlBar/ZoomSlider").value = 150
		expect(exporter._controls.get_node("Preview")._zoom == 150, "the zoom slider changes the sheet magnification")
		exporter._controls.get_node("ControlBar/CenterBtn").pressed.emit()
		expect(exporter._controls.get_node("Preview")._pan == Vector2.ZERO, "the center button restores the sheet position")
	)
	error = await exporter.export_sprite_sheet(SHEET_PATH, 0, 1, 32, 2, false)
	step("Then the saved PNG matches the sheet preview", func():
		var image := Image.new()
		image.load(SHEET_PATH)
		expect(error == OK and image.get_data() == exporter._preview_image.get_data(), "preview and export contain the same PNG pixels")
		expect(not FileAccess.file_exists(SHEET_PATH.get_basename() + ".json"), "PNG-only export creates no JSON sidecar")
	)
	var default_range_error: Error = await exporter.export_sprite_sheet(SHEET_PATH, 0, -1, 32, 2, false)
	var bad_view_error: Error = await exporter.export_sprite_sheet(SHEET_PATH, 0, 1, 32, 99, false)
	step("Then the export arguments keep their defaults and limits", func():
		expect(default_range_error == OK, "a negative last frame exports to the last frame")
		expect(bad_view_error == ERR_INVALID_PARAMETER, "an unknown view index is refused")
	)
	step("When the user selects the 3D preview view and moves its camera", func():
		var yaw: float = exporter._model_camera._yaw
		var motion := InputEventMouseMotion.new()
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		motion.relative = Vector2(20, 10)
		exporter._model_viewport.push_input(motion)
		expect(exporter._model_camera._yaw != yaw, "left-drag orbits the model preview by default")
		main.get_node("%Viewport").get_node("ControlBar/PanToggle").button_pressed = true
		exporter._model.get_node("Viewport/ControlBar/RotateToggle").button_pressed = true
		exporter._sheet_settings.get_node("ViewRow/View").select(0)
		exporter._sheet_settings.get_node("ViewRow/View").item_selected.emit(0)
		exporter._model_camera.set_view("top")
		exporter._model_camera.zoom(0.5)
	)
	await _wait_preview()
	step("Then the sheet preview follows the shared camera controls", func():
		expect(exporter._preview_image != null, "the shared preview view renders a sheet")
		expect(exporter._sheet_settings.get_node("SizeRow/Size").value == 32, "camera changes retain the explicit thirty-two-pixel frame size")
		expect(camera_rig().transform == original_camera, "the preview camera controls leave the editor camera in place")
		expect(main.get_node("%Viewport").get_node("ControlBar/PanToggle").button_pressed, "preview camera modes preserve the editor camera mode")
	)
	step("When the user changes turntable settings during a preview render", func():
		exporter._sheet_settings.get_node("TurntableRow/Views").value = 4
		exporter._sheet_settings.get_node("TurntableRow/Turntable").button_pressed = true
	)
	while not exporter._preview_running:
		await get_tree().process_frame
	step("When the user changes the turntable to eight views", func():
		exporter._sheet_settings.get_node("TurntableRow/Views").value = 8
	)
	await _wait_preview()
	step("Then the live turntable uses only the latest view count", func():
		expect(exporter._preview_image.get_size() == Vector2i(131, 131), "the preview arranges every view with one-pixel gaps")
		expect(exporter._preview_viewport == null, "the completed preview releases its temporary viewport")
	)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_dir() + "/Workspace.png")


# Feed the same elapsed time to one controller. Return each displayed frame.
func _clock_steps(playback: AnimationPlayback, offset: int, ticks := 40) -> Array[int]:
	var steps: Array[int] = []
	playback.is_playing = false
	playback.is_playing = true
	for _tick in ticks:
		playback.update(0.1)
		steps.append(playback.current_frame + offset)
	playback.is_playing = false
	return steps


func _wait_preview() -> void:
	while exporter._preview_running or exporter._preview_due_ms >= 0:
		await get_tree().process_frame
