extends "res://tests/test.gd"

var camera_menu_btn: MenuButton


func _ready() -> void:
	test("shading and wireframe are independent view options", _run)


func after_test() -> void:
	if camera_menu_btn == null:
		camera_menu_btn = camera_menu()
	if _checked("wireframe"):
		_pick("wireframe")
	if _checked("orthographic"):
		_pick("orthographic")
	_shaded().button_pressed = true


func _renderer() -> VoxelRenderer:
	return viewport_scene().get_node("VoxelRenderer")


func _debug_draw() -> int:
	return (editor_viewport() as SubViewport).debug_draw


func _shaded() -> Button:
	return viewport_scene().get_node("%Shaded")


func _pick(text: String) -> void:
	var popup := camera_menu_btn.get_popup()
	for i in popup.item_count:
		if popup.get_item_text(i).to_lower() == text:
			popup.index_pressed.emit(i)
			return


func _checked(text: String) -> bool:
	var popup := camera_menu_btn.get_popup()
	for i in popup.item_count:
		if popup.get_item_text(i).to_lower() == text:
			return popup.is_item_checked(i)
	return false


func _settle() -> void:
	var renderer := _renderer()
	while not renderer.is_settled():
		await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame


# Returns true when every displayed chunk material uses the expected shading.
func _all_materials(expected: int) -> bool:
	var modes: Array[int] = []
	for instance: MeshInstance3D in _renderer()._chunk_instances.values():
		var material := instance.material_override as BaseMaterial3D
		if material:
			modes.append(material.shading_mode)
	if modes.is_empty():
		return false
	for mode in modes:
		if mode != expected:
			return false
	return true


func _run() -> void:
	State.document.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color.RED))
	State.frames_changed.emit()
	await _settle()

	step("Given an editor viewport with shaded voxels", func():
		camera_menu_btn = camera_menu()
		expect(not _renderer().unshaded, "the renderer is not unshaded")
		expect(_all_materials(BaseMaterial3D.SHADING_MODE_PER_PIXEL), "the chunk materials shade with the light")
		expect(_shaded().button_pressed, "the Shaded button starts pressed")
		expect(_debug_draw() == Viewport.DEBUG_DRAW_DISABLED, "the viewport starts without a debug mode")
	)

	step("When the user disables shading", func():
		_shaded().button_pressed = false
	)
	step("Then the chunk materials draw unshaded and the viewport debug mode stays off", func():
		expect(_all_materials(BaseMaterial3D.SHADING_MODE_UNSHADED), "the chunk materials ignore the light")
		expect(not _shaded().button_pressed, "the Shaded button shows unpressed")
		expect(_debug_draw() == Viewport.DEBUG_DRAW_DISABLED, "the viewport keeps its debug mode off")
		expect(viewport_scene().get_node("%Shadows").disabled, "the other lighting controls disable")
	)

	step("When the user enables the wireframe checkbox while unshaded", func():
		_pick("wireframe")
	)
	step("Then wireframe and unshaded apply together", func():
		expect(_debug_draw() == Viewport.DEBUG_DRAW_WIREFRAME, "the viewport draws wireframe")
		expect(_checked("wireframe"), "the wireframe item shows checked")
		expect(_all_materials(BaseMaterial3D.SHADING_MODE_UNSHADED), "the chunk materials stay unshaded")
		expect(not _shaded().button_pressed, "the Shaded button stays unpressed")
	)

	step("When the user enables shading while wireframe is on", func():
		_shaded().button_pressed = true
	)
	step("Then the materials shade and wireframe stays checked", func():
		expect(_all_materials(BaseMaterial3D.SHADING_MODE_PER_PIXEL), "the chunk materials shade again")
		expect(_debug_draw() == Viewport.DEBUG_DRAW_WIREFRAME, "the viewport still draws wireframe")
		expect(_checked("wireframe"), "the wireframe item stays checked")
		expect(not viewport_scene().get_node("%Shadows").disabled, "the other lighting controls enable")
	)

	step("When the user unchecks wireframe", func():
		_pick("wireframe")
	)
	step("Then the viewport returns to the shaded solid view", func():
		expect(_debug_draw() == Viewport.DEBUG_DRAW_DISABLED, "the viewport leaves wireframe")
		expect(not _checked("wireframe"), "the wireframe item shows unchecked")
		expect(_all_materials(BaseMaterial3D.SHADING_MODE_PER_PIXEL), "the chunk materials stay shaded")
	)

	step("When the user enables orthographic projection and disables shading", func():
		_pick("orthographic")
		_shaded().button_pressed = false
	)
	step("Then the projection stays independent", func():
		expect(camera_rig().is_orthogonal, "the camera stays orthographic")
		expect(_checked("orthographic"), "the orthographic item stays checked")
		expect(_all_materials(BaseMaterial3D.SHADING_MODE_UNSHADED), "the chunk materials draw unshaded")
	)
