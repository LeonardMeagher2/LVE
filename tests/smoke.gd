extends SceneTree

var _frames := 0
var _inst: Node = null
var _checked := false


func _initialize() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	_inst = scene.instantiate()
	root.add_child(_inst)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 3 and not _checked:
		_checked = true
		var st: EditorState = _inst.state
		if st == null:
			push_error("VOXI SMOKE FAIL: editor state is null")
			quit(1)
			return true
		st.current_color = Color8(200, 60, 60)
		st.apply_tool(Vector3i(8, 0, 8), EditorViewport.NONE)
		st.begin_stroke()
		st.apply_tool(Vector3i(9, 0, 8), EditorViewport.NONE)
		st.end_stroke()
		st.undo()
		st.redo()
		st.add_frame()
		if st.doc.frames.size() != 2:
			push_error("VOXI SMOKE FAIL: expected 2 frames")
			quit(1)
			return true
		if not st.doc.frames[0].cells.has(Vector3i(8, 0, 8)):
			push_error("VOXI SMOKE FAIL: brush voxel missing")
			quit(1)
			return true
		if not st.doc.frames[0].cells.has(Vector3i(9, 0, 8)):
			push_error("VOXI SMOKE FAIL: stroke voxel missing")
			quit(1)
			return true
		var file_menu: MenuButton = _inst.get_node("Root/MenuBar/File")
		if file_menu == null or file_menu.get_popup().get_item_count() != 5:
			push_error("VOXI SMOKE FAIL: file menu items missing")
			quit(1)
			return true
		if file_menu.get_popup().get_item_text(2) != "Save":
			push_error("VOXI SMOKE FAIL: file menu item text wrong")
			quit(1)
			return true
		print("VOXI SMOKE OK")
	if _frames >= 6:
		quit(0)
	return false
