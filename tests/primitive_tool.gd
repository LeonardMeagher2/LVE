extends "res://tests/test.gd"

## Primitive tool and shared commit path checks.

const PrimitiveField := preload("res://Globals/State/Tools/PrimitiveField.gd")

var viewport: SubViewport
var tool: Node3D
var _move_before := Vector3.ZERO
var _rotated_start_size := 0.0
var _rotated_opposite := Vector3.ZERO


func _ready() -> void:
	test("the shared build path adds a box as one undo action", _direct_box, "direct_box")
	test("a mouse drag previews and commits a box", _drag_commit, "drag_commit")
	test("a large preview builds on a worker job", _large_preview, "large_preview")
	test("the toolbar selects separate box, ellipsoid, and cone tools", _tool_selection, "tool_selection")
	test("a cone points along the surface normal", _cone_normal, "cone_normal")
	test("a cone flips when a handle crosses the base", _flip_cone, "flip_cone")
	test("Escape discards a pending primitive", _escape, "escape")
	test("a face handle changes the pending box", _handle_drag, "handle_drag")
	test("a corner handle changes two bounds", _corner_handle, "corner_handle")
	test("a roundness change updates a pending box", _pending_roundness, "pending_roundness")
	test("a second drag waits for the pending primitive to commit", _one_pending, "one_pending")
	test("subtract and intersect previews respect the selection", _selection_ops, "selection_ops")
	test("a smooth change cancels and replaces the preview job", _blend_preview_cancel, "blend_preview_cancel")
	test("two preview requests in one frame show the newest", _frame_preview, "frame_preview")
	test("the gizmo handles keep one screen size", _handle_scale, "handle_scale")
	test("a preview keeps the untouched chunk meshes", _chunk_stability, "chunk_stability")
	test("smooth blends a primitive into existing voxels", _blend_existing, "blend_existing")
	test("subtract removes cells and restores them with one undo", _subtract, "subtract")
	test("subtract clears a full voxel chunk", _subtract_full_chunk, "subtract_full_chunk")
	test("intersect keeps only the cells inside the shape", _intersect, "intersect")
	test("a no-op subtract creates no history action", _noop, "noop")
	test("the option values scale with the shape", _option_units, "option_units")
	test("the tool rotation turns the box and the cone", _rotation, "rotation")
	test("a rotate ring drag turns the pending shape", _rotate_ring, "rotate_ring")
	test("a rotated face drag keeps the opposite face still", _rotated_face, "rotated_face")
	test("the gizmo follows the shape rotation", _gizmo_rotation, "gizmo_rotation")
	test("the current material is used", _material, "material")
	test("the shape options build a cone and an ellipsoid", _shape_options, "shape_options")


func before_test() -> void:
	viewport = editor_viewport()
	viewport.get_parent().stretch = false
	viewport.size = Vector2i(800, 500)
	camera_rig().is_orthogonal = true
	camera_rig().set_view("top")
	activate_tool("primitive")
	tool = plugin("PrimitivePlugin")._active_tool
	tool.cancel_pending()
	await get_tree().process_frame


func _direct_box() -> void:
	var plugin_node := plugin("PrimitivePlugin")
	expect(plugin_node != null, "the primitive plugin exists")
	if plugin_node == null:
		return
	var request := _box_request(Vector3.ZERO, Vector3(1.5, 1.5, 1.5))
	var result: Dictionary = await plugin_node.build_shape(request)
	step("Then the box is written and reported", func():
		expect(not result.has("error"), "the box build succeeds: %s" % str(result.get("error", "")))
		expect(int(result.get("applied", 0)) == 27, "the box writes 27 cells")
		var frame := State.get_current_voxel_frame()
		expect(frame.has(Vector3i.ZERO), "the center cell exists")
		expect(frame.has(Vector3i(1, 1, 1)), "the corner cell exists")
		expect(State.undo_redo.get_history_count() == 1, "the build is one history action")
	)
	step("Then one undo restores the empty frame", func():
		State.undo_redo.undo()
		expect(State.get_current_voxel_frame().count() == 0, "the undo removes the box")
		State.undo_redo.redo()
		expect(State.get_current_voxel_frame().count() == 27, "the redo restores the box")
	)


func _drag_commit() -> void:
	step("When the user drags a four-cell box on the floor", func():
		_button(Vector3(0, 0, 0), true)
		_motion(Vector3(3, 0, 3), true)
	)
	var deadline := Time.get_ticks_msec() + 5000
	while (not tool._preview_request.is_empty() or tool._preview_job != null) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	step("Then the result frame is visible and the document is unchanged", func():
		var renderer := _preview_renderer()
		expect(State.get_current_voxel_frame().count() == 0, "the preview keeps the live document empty")
		expect(not State.undo_redo.has_undo(), "the preview creates no history")
		expect(renderer.source_frame != null, "the main renderer shows the result frame")
		expect(renderer.source_frame.count() == 64, "the result frame holds the box cells")
	)
	step("When the user releases", func():
		_button(Vector3(3, 0, 3), false)
	)
	await get_tree().process_frame
	step("Then the primitive stays pending with handles", func():
		expect(State.get_current_voxel_frame().count() == 0, "the pending shape keeps the live document empty")
		expect(_preview_renderer().source_frame != null, "the result frame stays visible")
		expect(tool.get_node("Gizmo").visible, "the face handles are visible")
		expect(plugin("PrimitivePlugin")._settings.editing, "the option bar sees the pending shape")
	)
	step("When the user presses Enter", func():
		_key(KEY_ENTER)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the box commits as one action", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 64, "the drag writes a four-cube box")
		expect(frame.has(Vector3i(0, 0, 0)), "the box starts on the pressed cell")
		expect(not frame.has(Vector3i(-1, 0, 0)), "the box does not grow behind the press")
		expect(frame.has(Vector3i(3, 3, 3)), "the box reaches the drag corner")
		expect(State.undo_redo.get_history_count() == 1, "the drag is one history action")
		expect(_preview_renderer().source_frame == null, "the result frame is cleared after the commit")
	)
	step("Then one undo restores the previous cells", func():
		State.undo_redo.undo()
		expect(State.get_current_voxel_frame().count() == 0, "the undo removes the whole box")
	)


func _large_preview() -> void:
	step("When the user drags a seven-cell box", func():
		_button(Vector3(0, 0, 0), true)
		_motion(Vector3(6, 0, 6), true)
	)
	var deadline := Time.get_ticks_msec() + 5000
	while (not tool._preview_request.is_empty() or tool._preview_job != null) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	step("Then the worker preview is visible", func():
		var renderer := _preview_renderer()
		expect(State.get_current_voxel_frame().count() == 0, "the preview keeps the live document empty")
		expect(renderer.source_frame != null, "the main renderer shows the worker result")
		expect(renderer.source_frame.count() > 0, "the worker result holds cells")
	)
	step("When the user cancels the drag", func():
		_key(KEY_ESCAPE)
	)


func _tool_selection() -> void:
	var primitive_plugin := plugin("PrimitivePlugin")
	step("When the toolbar selects the ellipsoid", func():
		select_toolbar_item("primitive", "Ellipsoid")
	)
	step("Then the ellipsoid tool is active", func():
		expect(primitive_plugin._settings.tool == PrimitiveToolSettings.Tools.ELLIPSOID, "the setting selects the ellipsoid")
		expect(primitive_plugin._active_tool == primitive_plugin._ellipsoid_tool, "the ellipsoid tool is mounted")
	)
	step("When the toolbar selects the cone", func():
		select_toolbar_item("primitive", "Cone")
	)
	step("Then the cone tool is active and the cone options are visible", func():
		expect(primitive_plugin._settings.tool == PrimitiveToolSettings.Tools.CONE, "the setting selects the cone")
		expect(primitive_plugin._active_tool == primitive_plugin._cone_tool, "the cone tool is mounted")
		expect(primitive_plugin._options.get_node("Cone").visible, "the cone options are visible")
	)
	step("When the toolbar selects the box", func():
		select_toolbar_item("primitive", "Box")
	)
	step("Then the box tool is active", func():
		expect(primitive_plugin._active_tool == primitive_plugin._box_tool, "the box tool is mounted")
	)


func _cone_normal() -> void:
	step("Given the cone tool with a point tip", func():
		select_toolbar_item("primitive", "Cone")
		plugin("PrimitivePlugin")._settings.second_radius = 0.0
		plugin("PrimitivePlugin")._settings.roundness = 0.0
	)
	step("When the user drags a cone on the floor", func():
		_button(Vector3(0, 0, 0), true)
		_motion(Vector3(4, 0, 4), true)
		_button(Vector3(4, 0, 4), false)
	)
	step("Then the axis follows the floor normal", func():
		var cone_tool = plugin("PrimitivePlugin")._active_tool
		expect(cone_tool._primitives.size() == 1, "one cone is pending")
		var primitive: Dictionary = cone_tool._primitives[0]
		var a: Vector3 = primitive["a"]
		var b: Vector3 = primitive["b"]
		expect(is_equal_approx(a.x, b.x) and is_equal_approx(a.z, b.z), "the cone axis is vertical")
		expect(not is_equal_approx(a.y, b.y), "the cone spans the height")
	)
	step("When the user commits the cone", func():
		_key(KEY_ENTER)
	)
	await _await_edit_idle()
	step("Then the cone has a base and a tip on the cell grid", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.has(Vector3i(2, 0, 2)), "the base center exists")
		expect(frame.has(Vector3i(2, 4, 2)), "the tip cell exists")
	)


func _flip_cone() -> void:
	step("Given a pending cone", func():
		select_toolbar_item("primitive", "Cone")
		tool = plugin("PrimitivePlugin")._active_tool
		plugin("PrimitivePlugin")._settings.second_radius = 0.0
		plugin("PrimitivePlugin")._settings.roundness = 0.0
		_button(Vector3(0, 0, 0), true)
		_motion(Vector3(4, 0, 4), true)
		_button(Vector3(4, 0, 4), false)
		camera_rig().set_view("front")
	)
	await get_tree().process_frame
	step("When the top handle crosses the base", func():
		var handle: Vector3 = tool.get_node("Gizmo").handle_position(1, 1)
		_button(handle, true)
		_motion(Vector3(handle.x, -3, handle.z), true)
		_button(Vector3(handle.x, -3, handle.z), false)
		expect(tool._pending_box.size.y < 0.0, "the vertical bound is negative")
		var primitive: Dictionary = tool._primitives[0]
		var a: Vector3 = primitive["a"]
		var b: Vector3 = primitive["b"]
		expect(a.y > b.y, "the wide end stays above the narrow end")
	)
	step("When the user commits the flipped cone", func():
		_key(KEY_ENTER)
	)
	await _await_edit_idle()
	step("Then the cone points down", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.has(Vector3i(2, -1, 2)), "the wide base cell exists")
		expect(frame.has(Vector3i(2, -3, 2)), "the flipped tip cell exists")
	)


func _escape() -> void:
	step("When the user starts a drag and presses Escape", func():
		_button(Vector3(0, 0, 0), true)
		_motion(Vector3(2, 0, 2), true)
		_key(KEY_ESCAPE)
	)
	step("Then the preview is gone and no edit exists", func():
		expect(_preview_renderer().source_frame == null, "the result frame is cleared")
		expect(State.get_current_voxel_frame().count() == 0, "Escape writes no cells")
		expect(not State.undo_redo.has_undo(), "Escape creates no history")
		expect(State.active_edit() == null, "Escape closes the edit")
	)
	step("When the user releases a shape and presses Escape", func():
		_button(Vector3(0, 0, 0), true)
		_motion(Vector3(2, 0, 2), true)
		_button(Vector3(2, 0, 2), false)
		_key(KEY_ESCAPE)
	)
	step("Then the pending shape is discarded", func():
		expect(_preview_renderer().source_frame == null, "the result frame is cleared")
		expect(not tool.get_node("Gizmo").visible, "the handles are hidden")
		expect(not plugin("PrimitivePlugin")._settings.editing, "the option bar sees no pending shape")
		expect(State.get_current_voxel_frame().count() == 0, "the cancelled shape writes no cells")
		expect(not State.undo_redo.has_undo(), "the cancelled shape creates no history")
	)


func _handle_drag() -> void:
	step("Given a pending four-cell box", func():
		_button(Vector3(0, 0, 0), true)
		_motion(Vector3(3, 0, 3), true)
		_button(Vector3(3, 0, 3), false)
	)
	step("When the user views the box from the front", func():
		camera_rig().set_view("front")
	)
	await get_tree().process_frame
	step("Then the handle drag changes the top bound", func():
		var handle: Vector3 = tool.get_node("Gizmo").handle_position(1, 1)
		_button(handle, true)
		_motion(handle + Vector3(0, 2, 0), true)
		_button(handle + Vector3(0, 2, 0), false)
		expect(is_equal_approx(tool._pending_box.size.y, 6.0), "the box is six cells high")
	)
	step("When the user commits", func():
		_key(KEY_ENTER)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the taller box commits", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.count() == 96, "the taller box has 96 cells")
		expect(frame.has(Vector3i(3, 5, 3)), "the box reaches the moved handle")
	)


func _corner_handle() -> void:
	step("Given a pending four-cell box", func():
		_button(Vector3(0, 0, 0), true)
		_motion(Vector3(4, 0, 4), true)
		_button(Vector3(4, 0, 4), false)
		camera_rig().set_view("front")
	)
	await get_tree().process_frame
	step("When the user drags a top corner", func():
		var corner: Dictionary = {}
		for value in tool.get_node("Gizmo").handles():
			var hit: Dictionary = value
			if int(hit.get("kind", 0)) == 1 and hit.get("signs", Vector3i.ZERO) == Vector3i(1, 1, 1):
				corner = hit
				break
		var point: Vector3 = corner["position"]
		_button(point, true)
		_motion(point + Vector3(2, 2, 0), true)
		_button(point + Vector3(2, 2, 0), false)
	)
	step("Then two bounds grow", func():
		expect(is_equal_approx(tool._pending_box.size.x, 7.0), "the x bound grew by two cells")
		expect(is_equal_approx(tool._pending_box.size.y, 7.0), "the y bound grew by two cells")
	)


func _pending_roundness() -> void:
	step("Given a pending four-cell box", func():
		_button(Vector3(0, 0, 0), true)
		_motion(Vector3(4, 0, 4), true)
		_button(Vector3(4, 0, 4), false)
	)
	step("When the user sets roundness to one", func():
		plugin("PrimitivePlugin")._settings.roundness = 1.0
	)
	step("When the user commits", func():
		_key(KEY_ENTER)
	)
	await _await_edit_idle()
	step("Then the committed box is rounded", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.has(Vector3i(2, 2, 2)), "the center exists")
		expect(not frame.has(Vector3i(0, 0, 0)), "the sharp corner is gone")
	)


func _subtract_full_chunk() -> void:
	step("Given a full sixteen-cube chunk", func():
		State.undo_redo.clear_history()
	)
	await plugin("PrimitivePlugin").build_shape(_box_request(Vector3(7.5, 7.5, 7.5), Vector3(8.0, 8.0, 8.0)))
	State.undo_redo.clear_history()
	step("When the same volume is subtracted", func():
		pass
	)
	var result: Dictionary = await plugin("PrimitivePlugin").build_shape(
		_box_request(Vector3(7.5, 7.5, 7.5), Vector3(8.0, 8.0, 8.0), PrimitiveField.OP_SUBTRACT)
	)
	step("Then the chunk is empty", func():
		expect(not result.has("error"), "the subtract succeeds: %s" % str(result.get("error", "")))
		expect(State.get_current_voxel_frame().count() == 0, "the subtract removes every cell")
		expect(State.undo_redo.get_history_count() == 1, "the subtract is one history action")
		State.undo_redo.undo()
		expect(State.get_current_voxel_frame().count() == 4096, "one undo restores the chunk")
	)


func _selection_ops() -> void:
	step("Given a five-cell block and a selected corner", func():
		pass
	)
	await plugin("PrimitivePlugin").build_shape(_box_request(Vector3.ZERO, Vector3(2.5, 2.5, 2.5)))
	State.undo_redo.clear_history()
	State.selection.from_box(Vector3i(-2, -2, -2), Vector3i(0, 0, 0))
	State.selection_changed.emit()
	step("When a subtract preview covers the block", func():
		pass
	)
	var subtract_frame := await _tool_preview(
		{"kind": PrimitiveField.KIND_BOX, "center": Vector3.ZERO, "half_size": Vector3(2.5, 2.5, 2.5)},
		PrimitiveField.OP_SUBTRACT
	)
	step("Then only selected cells are removed", func():
		expect(subtract_frame != null, "the subtract preview has a result frame")
		expect(not subtract_frame.has(Vector3i(0, 0, 0)), "a selected cell is removed")
		expect(subtract_frame.has(Vector3i(2, 2, 2)), "an unselected cell stays")
		expect(State.get_current_voxel_frame().count() == 125, "the live frame stays unchanged")
	)
	tool.cancel_pending()
	step("When an intersect preview keeps only a small center box", func():
		pass
	)
	var intersect_frame := await _tool_preview(
		{"kind": PrimitiveField.KIND_BOX, "center": Vector3.ZERO, "half_size": Vector3(0.5, 0.5, 0.5)},
		PrimitiveField.OP_INTERSECT
	)
	step("Then selected cells outside the shape are removed", func():
		expect(intersect_frame != null, "the intersect preview has a result frame")
		expect(intersect_frame.has(Vector3i(0, 0, 0)), "the selected inside cell stays")
		expect(not intersect_frame.has(Vector3i(-1, 0, 0)), "a selected outside cell is removed")
		expect(intersect_frame.has(Vector3i(2, 2, 2)), "an unselected outside cell stays")
	)
	tool.cancel_pending()


func _blend_preview_cancel() -> void:
	step("Given a wall and a pending box near it", func():
		State.set_material(VoxelFrame.material(Color.BLUE))
		pass
	)
	await plugin("PrimitivePlugin").build_shape(_box_request(Vector3(0, 2, 0), Vector3(0.5, 2.5, 2.5)))
	step("When the preview starts flat and the smooth setting changes", func():
		State.set_material(VoxelFrame.material(Color.RED))
		plugin("PrimitivePlugin")._settings.smooth = 0
		var primitive := {
			"kind": PrimitiveField.KIND_BOX,
			"center": Vector3(8, 2, 0),
			"half_size": Vector3(6.5, 2.5, 2.5),
			"roundness": 0.0,
		}
		var primitives: Array[Dictionary] = [primitive]
		tool._primitives = primitives
		tool._active_index = 0
		tool._pending_box = AABB(Vector3(-6.5, -2.5, -2.5), Vector3(13, 5, 5))
		tool._settings.editing = true
		tool._refresh_preview()
		plugin("PrimitivePlugin")._settings.smooth = 1.0
	)
	var deadline := Time.get_ticks_msec() + 5000
	var preview: VoxelFrame = null
	while Time.get_ticks_msec() < deadline:
		preview = _preview_renderer().source_frame
		if preview != null and preview.has(Vector3i(1, 2, 0)):
			break
		await get_tree().process_frame
	step("Then the newest preview includes the smooth join", func():
		expect(preview != null, "the newest result frame is installed")
		expect(preview.has(Vector3i(1, 2, 0)), "the gap cell is filled")
		expect(preview.get_color(Vector3i(1, 2, 0)).is_equal_approx(Color.RED), "the gap uses the new material")
		expect(preview.get_color(Vector3i(0, 2, 0)).is_equal_approx(Color.BLUE), "the wall keeps its material")
	)
	tool.cancel_pending()


func _frame_preview() -> void:
	step("Given a pending box", func():
		pass
	)
	step("When two previews are requested in one frame", func():
		var first := {
			"kind": PrimitiveField.KIND_BOX,
			"center": Vector3.ZERO,
			"half_size": Vector3(0.5, 0.5, 0.5),
			"roundness": 0.0,
		}
		var first_list: Array[Dictionary] = [first]
		tool._primitives = first_list
		tool._active_index = 0
		tool._pending_box = AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
		tool._settings.editing = true
		tool._refresh_preview()
		var second := {
			"kind": PrimitiveField.KIND_BOX,
			"center": Vector3(3, 0, 0),
			"half_size": Vector3(0.5, 0.5, 0.5),
			"roundness": 0.0,
		}
		var second_list: Array[Dictionary] = [second]
		tool._primitives = second_list
		tool._pending_box = AABB(Vector3(2.5, -0.5, -0.5), Vector3.ONE)
		tool._refresh_preview()
	)
	var deadline := Time.get_ticks_msec() + 5000
	while (not tool._preview_request.is_empty() or tool._preview_job != null) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	step("Then the newest request replaces the older result", func():
		var preview := _preview_renderer().source_frame
		expect(tool._preview_request.is_empty(), "the queued request ran")
		expect(preview != null, "the result frame is installed")
		expect(preview.has(Vector3i(3, 0, 0)), "the newest box is shown")
		expect(not preview.has(Vector3i(0, 0, 0)), "the older box is replaced")
		expect(State.get_current_voxel_frame().count() == 0, "the live document stays empty")
	)
	tool.cancel_pending()


func _handle_scale() -> void:
	var gizmo := tool.get_node("Gizmo")
	step("Given a pending box in an orthographic view", func():
		gizmo.show_box(AABB(Vector3(-2, -2, -2), Vector3(4, 4, 4)))
	)
	await get_tree().process_frame
	var rig := camera_rig()
	var viewport_height := gizmo.get_viewport().get_visible_rect().size.y
	step("Then the cross keeps one screen size", func():
		expect(viewport_height > 0.0, "the viewport has a height")
		var per_pixel := rig.size / viewport_height
		expect(is_equal_approx(gizmo._handle_half / per_pixel, 10.0), "the cross half spans ten pixels")
	)
	var before: float = gizmo._handle_half
	step("When the user zooms in four times", func():
		rig.set_zoom_percent(400.0)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the cross keeps its screen size in a smaller world size", func():
		expect(gizmo._handle_half < before, "the cross shrinks in world units")
		var per_pixel := rig.size / viewport_height
		expect(is_equal_approx(gizmo._handle_half / per_pixel, 10.0), "the zoomed cross still spans ten pixels")
	)
	gizmo.hide_box()


func _chunk_stability() -> void:
	step("Given two occupied chunks", func():
		pass
	)
	await plugin("PrimitivePlugin").build_shape(_box_request(Vector3.ZERO, Vector3(0.5, 0.5, 0.5)))
	await plugin("PrimitivePlugin").build_shape(_box_request(Vector3(40, 0, 0), Vector3(0.5, 0.5, 0.5)))
	var renderer := _preview_renderer()
	var changed_chunk := VoxelFrame.chunk_position(Vector3i.ZERO)
	var other_chunk := VoxelFrame.chunk_position(Vector3i(40, 0, 0))
	var deadline := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		if renderer._displayed_surface_keys.size() == 2:
			break
		await get_tree().process_frame
	await get_tree().process_frame
	var other_mesh: Mesh = renderer._chunk_instances[other_chunk].mesh
	var changed_mesh: Mesh = renderer._chunk_instances[changed_chunk].mesh
	step("When a preview grows the first chunk", func():
		pass
	)
	# Freeze the surface work so the swap is checked before any mesh arrives.
	renderer.set_process(false)
	await _tool_preview(
		{"kind": PrimitiveField.KIND_BOX, "center": Vector3.ZERO, "half_size": Vector3(1.5, 1.5, 1.5)},
		PrimitiveField.OP_ADD
	)
	step("Then the changed chunk keeps its old mesh visible while it rebuilds", func():
		expect(renderer._chunk_instances[changed_chunk].visible, "the changed chunk is not hidden")
		expect(renderer._chunk_instances[changed_chunk].mesh == changed_mesh, "the changed chunk keeps its old mesh")
		expect(renderer._chunk_instances[other_chunk].visible, "the untouched chunk is not hidden")
		expect(renderer._chunk_instances[other_chunk].mesh == other_mesh, "the untouched chunk keeps its mesh")
	)
	renderer.set_process(true)
	deadline = Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		if renderer._chunk_instances[changed_chunk].mesh != changed_mesh:
			break
		await get_tree().process_frame
	step("Then the changed chunk installs its new mesh", func():
		expect(renderer._chunk_instances[changed_chunk].visible, "the changed chunk stays visible")
		expect(renderer._chunk_instances[changed_chunk].mesh != changed_mesh, "the changed chunk rebuilds")
		expect(renderer._chunk_instances[other_chunk].mesh == other_mesh, "the untouched chunk keeps its mesh")
		expect(renderer._chunk_instances[other_chunk].visible, "the untouched chunk stays visible")
		expect(State.get_current_voxel_frame().count() == 2, "the live document is unchanged")
	)
	tool.cancel_pending()


func _tool_preview(primitive: Dictionary, op: int) -> VoxelFrame:
	plugin("PrimitivePlugin")._settings.op = op
	var primitives: Array[Dictionary] = [primitive]
	tool._primitives = primitives
	tool._active_index = 0
	var half: Vector3 = primitive["half_size"]
	tool._pending_box = AABB(-half, half * 2.0)
	tool._settings.editing = true
	tool._refresh_preview()
	var deadline := Time.get_ticks_msec() + 5000
	while (not tool._preview_request.is_empty() or tool._preview_job != null) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	return _preview_renderer().source_frame


func _one_pending() -> void:
	step("Given a pending primitive", func():
		_button(Vector3(0, 0, 0), true)
		_motion(Vector3(4, 0, 4), true)
		_button(Vector3(4, 0, 4), false)
		_move_before = tool._pending_center
	)
	step("When the user drags the shape body", func():
		_button(Vector3(2, 0, 2), true)
		_motion(Vector3(4, 0, 2), true)
		_button(Vector3(4, 0, 2), false)
	)
	step("Then the shape moves and no second primitive starts", func():
		expect(tool._primitives.size() == 1, "the pending request still holds one primitive")
		expect(not tool._pending_center.is_equal_approx(_move_before), "the shape moved")
		expect(plugin("PrimitivePlugin")._settings.editing, "the pending shape stays editable")
	)
	step("When the user commits and starts another shape", func():
		_key(KEY_ENTER)
	)
	await _await_edit_idle()
	_button(Vector3(8, 0, 0), true)
	_motion(Vector3(10, 0, 4), true)
	_button(Vector3(10, 0, 4), false)
	step("Then the new shape is pending", func():
		expect(tool._primitives.size() == 1, "the new request holds one primitive")
		expect(State.get_current_voxel_frame().count() == 125, "the first shape is committed")
	)


func _blend_existing() -> void:
	step("Given a blue wall", func():
		State.set_material(VoxelFrame.material(Color.BLUE))
	)
	await plugin("PrimitivePlugin").build_shape(_box_request(Vector3(0, 2, 0), Vector3(0.5, 2.5, 2.5)))
	step("When a red smooth box is placed one cell away", func():
		State.set_material(VoxelFrame.material(Color.RED))
		plugin("PrimitivePlugin")._settings.smooth = 1.0
		State.undo_redo.clear_history()
	)
	var blend_request := _box_request(Vector3(4, 2, 0), Vector3(2.5, 2.5, 2.5))
	blend_request["smooth"] = 3.0
	await plugin("PrimitivePlugin").build_shape(blend_request)
	step("Then the blend fills the gap and keeps the wall", func():
		var frame := State.get_current_voxel_frame()
		expect(frame.has(Vector3i(1, 2, 2)), "the gap cell is filled")
		expect(frame.get_color(Vector3i(1, 2, 2)).is_equal_approx(Color.RED), "the fillet uses the new material")
		expect(frame.get_color(Vector3i(0, 2, 2)).is_equal_approx(Color.BLUE), "the existing wall keeps its material")
		expect(frame.count() > 150, "the blend adds cells beyond the two boxes")
		expect(State.undo_redo.get_history_count() == 1, "the blend is one history action")
		State.undo_redo.undo()
		expect(frame.count() == 25, "one undo restores the wall")
	)


func _subtract() -> void:
	step("Given a five-cell block", func():
		pass
	)
	await plugin("PrimitivePlugin").build_shape(_box_request(Vector3.ZERO, Vector3(2.5, 2.5, 2.5)))
	State.undo_redo.clear_history()
	step("When a smaller box is subtracted", func():
		pass
	)
	var subtract_result: Dictionary = await plugin("PrimitivePlugin").build_shape(_box_request(Vector3.ZERO, Vector3(0.5, 0.5, 0.5), PrimitiveField.OP_SUBTRACT))
	step("Then the subtraction succeeds", func():
		expect(not subtract_result.has("error"), "the subtract succeeds: %s" % str(subtract_result.get("error", "")))
	)
	step("Then the center is empty and the outer cells stay", func():
		var frame := State.get_current_voxel_frame()
		expect(not frame.has(Vector3i.ZERO), "the subtracted center is empty")
		expect(frame.has(Vector3i(2, 0, 0)), "the outer cell stays")
		expect(State.undo_redo.get_history_count() == 1, "the subtract is one history action")
		State.undo_redo.undo()
		expect(frame.has(Vector3i.ZERO), "one undo restores the center cell")
	)


func _intersect() -> void:
	step("Given a seven-cell block and a small intersect box", func():
		pass
	)
	await plugin("PrimitivePlugin").build_shape(_box_request(Vector3.ZERO, Vector3(3.5, 3.5, 3.5)))
	State.undo_redo.clear_history()
	var intersect_result: Dictionary = await plugin("PrimitivePlugin").build_shape(_box_request(Vector3.ZERO, Vector3(0.5, 0.5, 0.5), PrimitiveField.OP_INTERSECT))
	step("Then the intersect succeeds and only the inside cells remain", func():
		var frame := State.get_current_voxel_frame()
		expect(not intersect_result.has("error"), "the intersect succeeds: %s" % str(intersect_result.get("error", "")))
		expect(frame.count() == 1, "one cell remains")
		expect(frame.has(Vector3i.ZERO), "the remaining cell is the box center")
		expect(not frame.has(Vector3i(3, 3, 3)), "a cell outside the shape is removed")
		State.undo_redo.undo()
		expect(frame.count() == 343, "one undo restores the seven-cell block")
	)


func _noop() -> void:
	step("Given an empty frame", func():
		State.undo_redo.clear_history()
	)
	step("When a box is subtracted", func():
		pass
	)
	var result: Dictionary = await plugin("PrimitivePlugin").build_shape(_box_request(Vector3.ZERO, Vector3(1.0, 1.0, 1.0), PrimitiveField.OP_SUBTRACT))
	step("Then the no-op reports zero cells and no history action exists", func():
		expect(int(result.get("applied", -1)) == 0, "the no-op reports zero cells")
		expect(not State.undo_redo.has_undo(), "the no-op creates no history")
	)


func _option_units() -> void:
	var settings: PrimitiveToolSettings = plugin("PrimitivePlugin")._settings
	step("Given a four-cell box and a half smooth blend", func():
		settings.smooth = 0.5
		var primitive := {
			"kind": PrimitiveField.KIND_BOX,
			"center": Vector3.ZERO,
			"half_size": Vector3(2, 2, 2),
			"roundness": 0.0,
		}
		var primitives: Array[Dictionary] = [primitive]
		tool._primitives = primitives
		tool._active_index = 0
		tool._pending_box = AABB(Vector3(-2, -2, -2), Vector3(4, 4, 4))
	)
	step("Then the blend becomes half of the largest blend", func():
		var request: Dictionary = tool._build_request(false)
		expect(is_equal_approx(float(request["smooth"]), 1.0), "half of a four-cell extent blends one cell")
	)
	step("Given a cone with a half narrow radius", func():
		settings.second_radius = 0.5
		tool.shape = PrimitiveField.KIND_CONE
		var cone_box := AABB(Vector3(-2, -2, -4), Vector3(4, 4, 8))
		var cone: Dictionary = tool._build_primitive(cone_box, 2)
		expect(is_equal_approx(float(cone["r1"]), 2.0), "the base radius is two cells")
		expect(is_equal_approx(float(cone["r2"]), 1.0), "half the base radius is one cell")
		tool.shape = PrimitiveField.KIND_BOX
	)


func _rotation() -> void:
	step("When the pending shape turns a quarter turn around Y", func():
		tool._pending_rotation = Quaternion(Vector3.UP, deg_to_rad(90.0))
		var box := AABB(Vector3(-2.5, -0.5, -0.5), Vector3(5, 1, 1))
		tool._pending_center = box.get_center()
		var primitive: Dictionary = tool._build_primitive(box, 2)
		expect(primitive.has("rotation"), "the box carries a rotation")
		expect(PrimitiveField.primitive_distance(primitive, Vector3(0, 0, 2)) <= 0.0, "a z cell is inside the rotated box")
		expect(PrimitiveField.primitive_distance(primitive, Vector3(2, 0, 0)) > 0.0, "an x cell is outside the rotated box")
	)
	step("When the pending shape turns a cone around Z", func():
		plugin("PrimitivePlugin")._settings.second_radius = 1.0
		tool._pending_rotation = Quaternion(Vector3(0, 0, 1), deg_to_rad(90.0))
		tool.shape = PrimitiveField.KIND_CONE
		var box := AABB(Vector3(-0.5, -2.5, -0.5), Vector3(1, 5, 1))
		tool._pending_center = box.get_center()
		var cone: Dictionary = tool._build_primitive(box, 1)
		var a: Vector3 = cone["a"]
		var b: Vector3 = cone["b"]
		expect(is_equal_approx(absf(b.x - a.x), 5.0), "the cone axis turns toward x")
		expect(is_equal_approx(absf(b.y - a.y), 0.0), "the cone no longer lies along y")
		tool.shape = PrimitiveField.KIND_BOX
		tool._pending_rotation = Quaternion.IDENTITY
	)


func _rotate_ring() -> void:
	var gizmo := tool.get_node("Gizmo")
	var camera := camera_rig()
	var center: Vector3 = camera._target
	step("Given a pending box and its rotate rings", func():
		gizmo.show_box(AABB(center - Vector3.ONE * 2, Vector3.ONE * 4), Quaternion.IDENTITY)
	)
	var ring := {}
	for value in gizmo.rotation_rings():
		if int(value["axis"]) == 1:
			ring = value
	step("When the pointer turns a quarter around the Y ring", func():
		expect(not ring.is_empty(), "the y ring exists")
		var radius: float = ring["radius"]
		var start := camera.unproject_position(center + Vector3.RIGHT * radius)
		var finish := camera.unproject_position(center + Vector3.BACK * radius)
		tool._begin_ring_drag(ring, camera.project_ray_origin(start), camera.project_ray_normal(start))
		tool._update_ring(camera.project_ray_origin(finish), camera.project_ray_normal(finish))
	)
	step("Then the pending shape turns a quarter turn", func():
		var turned: Quaternion = tool._pending_rotation
		expect(is_equal_approx(absf(turned.get_angle()), deg_to_rad(90.0)), "the drag turns a quarter turn")
		expect(absf(turned.get_axis().dot(Vector3.UP)) > 0.999, "the turn uses the ring axis")
	)
	tool._pending_rotation = Quaternion.IDENTITY
	gizmo.hide_box()


func _gizmo_rotation() -> void:
	var gizmo := tool.get_node("Gizmo")
	var rotation := Quaternion(Vector3.UP, deg_to_rad(90.0))
	step("Given a box rotated a quarter turn around Y", func():
		gizmo.show_box(AABB(Vector3(-2, -1, -0.5), Vector3(4, 2, 1)), rotation)
	)
	step("Then the x face handle sits on the rotated side", func():
		var hit: Dictionary = gizmo.handles()[0]
		expect((hit["position"] as Vector3).is_equal_approx(Vector3(0, 0, 2)), "the handle follows the rotation")
		expect((hit["axis_direction"] as Vector3).is_equal_approx(Vector3(0, 0, -1)), "the face drags along its rotated axis")
	)
	step("Then a world drag point maps back to the box frame", func():
		tool._handle_start_box = AABB(Vector3(-2, -1, -0.5), Vector3(4, 2, 1))
		tool._handle_start_center = Vector3.ZERO
		tool._handle_rotation = rotation
		expect(tool._handle_local(Vector3(0, 0, 2)).is_equal_approx(Vector3(-2, 0, 0)), "the drag uses the local axis")
	)
	gizmo.hide_box()


func _rotated_face() -> void:
	step("Given a pending box turned a quarter around Y", func():
		_button(Vector3(0, 0, 0), true)
		_motion(Vector3(3, 0, 3), true)
		_button(Vector3(3, 0, 3), false)
		tool._pending_rotation = Quaternion(Vector3.UP, deg_to_rad(90.0))
		tool._primitives[0] = tool._build_primitive(tool._pending_box)
		tool._refresh_gizmo()
	)
	await get_tree().process_frame
	step("Then the opposite face starts at its world point", func():
		_rotated_opposite = tool.get_node("Gizmo").handle_position(0, -1)
		_rotated_start_size = tool._pending_box.size.x
	)
	step("When the user drags the x face along its rotated axis", func():
		var gizmo := tool.get_node("Gizmo")
		var handle: Vector3 = gizmo.handle_position(0, 1)
		var axis: Vector3 = tool._pending_rotation * Vector3.RIGHT
		_button(handle, true)
		_motion(handle + axis * 2.0, true)
		_button(handle + axis * 2.0, false)
	)
	step("Then the box grows on one side and the opposite face stays", func():
		var gizmo := tool.get_node("Gizmo")
		expect(is_equal_approx(tool._pending_box.size.x, _rotated_start_size + 2.0), "the x size grows by two")
		expect(gizmo.handle_position(0, -1).is_equal_approx(_rotated_opposite), "the opposite face stays in place")
	)
	step("Then the rotate rings sit on the shape center", func():
		var gizmo := tool.get_node("Gizmo")
		var ring: Dictionary = gizmo.rotation_rings()[0]
		var expected: Vector3 = ring["center"] + (ring["u"] as Vector3) * float(ring["radius"])
		var vertices: PackedVector3Array = gizmo.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var found := false
		for value in vertices:
			if value.is_equal_approx(expected):
				found = true
				break
		expect(found, "a drawn ring point sits on the world ring")
	)
	tool.cancel_pending()


func _material() -> void:
	step("Given a red current material", func():
		State.set_material(VoxelFrame.material(Color.RED))
	)
	step("When a box is built", func():
		pass
	)
	var request := _box_request(Vector3.ZERO, Vector3(0.5, 0.5, 0.5))
	request["material"] = State.current_material.duplicate()
	await plugin("PrimitivePlugin").build_shape(request)
	step("Then the cell is red", func():
		expect(State.get_current_voxel_frame().get_color(Vector3i.ZERO).is_equal_approx(Color.RED), "the cell uses the current material")
	)


func _shape_options() -> void:
	var settings: PrimitiveToolSettings = plugin("PrimitivePlugin")._settings
	step("When the options select a cone with a narrow radius", func():
		settings.tool = PrimitiveToolSettings.Tools.CONE
		settings.second_radius = 0.0
		settings.roundness = 0.0
	)
	var cone_request := {
		"primitives": [{"kind": PrimitiveField.KIND_CONE, "a": Vector3(0, 0, 0), "b": Vector3(0, 4, 0), "r1": 1.5, "r2": 0.0, "roundness": 0.0}],
		"op": PrimitiveField.OP_ADD,
		"smooth": 0.0,
		"shell": 0.0,
		"step": 1,
		"material": State.current_material.duplicate(),
	}
	var cone_result: Dictionary = await plugin("PrimitivePlugin").build_shape(cone_request)
	step("Then the cone tip cell exists", func():
		expect(not cone_result.has("error"), "the cone build succeeds: %s" % str(cone_result.get("error", "")))
		expect(State.get_current_voxel_frame().has(Vector3i(0, 4, 0)), "the cone tip cell exists")
	)
	step("When the options select an ellipsoid", func():
		State.document = VoxelDocument.new()
	)
	var ellipsoid_request := {
		"primitives": [{"kind": PrimitiveField.KIND_ELLIPSOID, "center": Vector3.ZERO, "radii": Vector3(2, 1, 1)}],
		"op": PrimitiveField.OP_ADD,
		"smooth": 0.0,
		"shell": 0.0,
		"step": 1,
		"material": State.current_material.duplicate(),
	}
	var ellipsoid_result: Dictionary = await plugin("PrimitivePlugin").build_shape(ellipsoid_request)
	step("Then the ellipsoid has a radius cell and no corner", func():
		expect(not ellipsoid_result.has("error"), "the ellipsoid build succeeds: %s" % str(ellipsoid_result.get("error", "")))
		expect(State.get_current_voxel_frame().has(Vector3i(1, 0, 0)), "the ellipsoid radius cell exists")
		expect(not State.get_current_voxel_frame().has(Vector3i(2, 2, 2)), "the ellipsoid corner is outside")
	)


func _await_edit_idle() -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while (State.edit_busy() or State.active_edit() != null) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame


func _preview_renderer() -> VoxelRenderer:
	return State.context.viewport_scene.get_node_or_null("VoxelRenderer") as VoxelRenderer


func _box_request(center: Vector3, half_size: Vector3, op := PrimitiveField.OP_ADD) -> Dictionary:
	return {
		"primitives": [{"kind": PrimitiveField.KIND_BOX, "center": center, "half_size": half_size}],
		"op": op,
		"smooth": 0.0,
		"shell": 0.0,
		"step": 1,
		"material": State.current_material.duplicate(),
	}


func _button(world: Vector3, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = camera_rig().unproject_position(world)
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	viewport.push_input(event)


func _motion(world: Vector3, pressed := false) -> void:
	var event := InputEventMouseMotion.new()
	event.position = camera_rig().unproject_position(world)
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	viewport.push_input(event)


func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	viewport.push_input(event)
