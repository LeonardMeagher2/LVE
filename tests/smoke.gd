extends "res://tests/test.gd"

var _inst: Node = null


func _initialize() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	_inst = scene.instantiate()
	root.add_child(_inst)
	test("exercise editor state, viewport input, and camera controls", _smoke)


func _smoke() -> void:
	for i in 2:
		await process_frame
	var st: EditorState = _inst.state
	expect(st != null, "editor state is null")
	st.current_color = Color8(200, 60, 60)
	st.apply_tool(Vector3i(8, 0, 8), EditorViewport.NONE)
	st.begin_stroke()
	st.apply_tool(Vector3i(9, 0, 8), EditorViewport.NONE)
	st.end_stroke()
	st.undo()
	st.redo()
	st.add_frame()
	expect(st.doc.frames.size() == 2, "expected 2 frames")
	expect(st.doc.frames[0].cells.has(Vector3i(8, 0, 8)), "brush voxel missing")
	expect(st.doc.frames[0].cells.has(Vector3i(9, 0, 8)), "stroke voxel missing")
	var file_menu: MenuButton = _inst.get_node("Root/MenuBar/File")
	expect(file_menu != null and file_menu.get_popup().get_item_count() == 5, "file menu items missing")
	expect(file_menu.get_popup().get_item_text(2) == "Save", "file menu item text wrong")
	var vp: EditorViewport = _inst.get_node("Root/ViewportContainer/Viewport/Editor")
	var svp := vp.get_viewport()
	var vsize: Vector2i = svp.size
	if vsize.x <= 0 or vsize.y <= 0:
		svp.size = Vector2i(800, 500)
		vsize = svp.size
	var center := Vector2(vsize.x * 0.5, vsize.y * 0.5)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = center
	vp.handle_input(click, center)
	click.pressed = false
	vp.handle_input(click, center)
	expect(not st.doc.frames[1].cells.is_empty(), "synthetic viewport click painted nothing")
	var yaw_before: float = vp._yaw
	var orbit_press := InputEventMouseButton.new()
	orbit_press.button_index = MOUSE_BUTTON_RIGHT
	orbit_press.pressed = true
	vp.handle_input(orbit_press, center)
	var orbit_move := InputEventMouseMotion.new()
	orbit_move.relative = Vector2(30, 20)
	orbit_move.button_mask = MOUSE_BUTTON_MASK_RIGHT
	vp.handle_input(orbit_move, center)
	var orbit_release := InputEventMouseButton.new()
	orbit_release.button_index = MOUSE_BUTTON_RIGHT
	orbit_release.pressed = false
	vp.handle_input(orbit_release, center)
	expect(vp._yaw != yaw_before, "right-drag did not orbit")
	var target_before: Vector3 = vp._target
	var pan_press := InputEventMouseButton.new()
	pan_press.button_index = MOUSE_BUTTON_MIDDLE
	pan_press.pressed = true
	vp.handle_input(pan_press, center)
	var pan_move := InputEventMouseMotion.new()
	pan_move.relative = Vector2(40, -20)
	pan_move.button_mask = MOUSE_BUTTON_MASK_MIDDLE
	vp.handle_input(pan_move, center)
	var pan_release := InputEventMouseButton.new()
	pan_release.button_index = MOUSE_BUTTON_MIDDLE
	pan_release.pressed = false
	vp.handle_input(pan_release, center)
	expect(vp._target != target_before, "middle-drag did not pan")
