extends Control

const TOOL_NAMES := ["Brush", "Eraser", "Fill", "Pick"]

@onready var _container: SubViewportContainer = $Root/ViewportContainer
@onready var _viewport: SubViewport = $Root/ViewportContainer/Viewport
@onready var _vp: EditorViewport = $Root/ViewportContainer/Viewport/Editor
@onready var _file_menu: MenuButton = $Root/MenuBar/File
@onready var _edit_menu: MenuButton = $Root/MenuBar/Edit
@onready var _view_menu: MenuButton = $Root/MenuBar/View
@onready var _brush_button: Button = $Root/ToolBar/ToolButtons/Brush
@onready var _eraser_button: Button = $Root/ToolBar/ToolButtons/Eraser
@onready var _fill_button: Button = $Root/ToolBar/ToolButtons/Fill
@onready var _pick_button: Button = $Root/ToolBar/ToolButtons/Pick
@onready var _color_picker: ColorPickerButton = $Root/ToolBar/ColorPicker
@onready var _recent_box: HBoxContainer = $Root/ToolBar/RecentColors
@onready var _play_button: Button = $Root/FrameBar/Play
@onready var _frame_box: HBoxContainer = $Root/FrameBar/FrameScroll/FrameStrip
@onready var _status_left: Label = $Root/StatusBar/StatusLeft
@onready var _status_right: Label = $Root/StatusBar/StatusRight

var state: EditorState
var _tool_buttons: Array[Button]
var _frame_buttons: Array[Button] = []
var _zoom_percent := 100.0

var playing := false
var play_time := 0.0
var _playing_frame := -1
var _shown_frame := -1

var _save_path := ""
var _file_dialog: FileDialog


func _ready() -> void:
	_tool_buttons = [_brush_button, _eraser_button, _fill_button, _pick_button]
	state = EditorState.new()
	_file_menu.get_popup().id_pressed.connect(_on_file_menu)
	_edit_menu.get_popup().id_pressed.connect(_on_edit_menu)
	_view_menu.get_popup().id_pressed.connect(_on_view_menu)
	state.tool_changed.connect(_on_tool_changed)
	state.color_changed.connect(_on_color_changed)
	state.frame_changed.connect(_on_frame_changed)
	state.cells_changed.connect(_on_cells_changed)
	_color_picker.color = state.current_color
	_vp.configure(state.doc)
	_vp.sync_to(state.doc, 0)
	_shown_frame = 0
	_update_frame_strip()
	_update_recent()
	_update_tool_buttons()
	_vp.set_ghost_color(_ghost_color())
	_update_status()


func _on_container_input(event: InputEvent) -> void:
	_vp.handle_input(event, _container.get_local_mouse_position())


func _on_viewport_resized(size: Vector2i) -> void:
	_viewport.size = size


func _process(delta: float) -> void:
	if not playing:
		return
	play_time += delta
	var n := state.doc.frames.size()
	var f := int(play_time * state.doc.fps) % n
	if f != _playing_frame:
		_playing_frame = f
		_vp.sync_to(state.doc, f)
		_shown_frame = f
		_highlight_frame(f)
		_update_status()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.is_action_pressed("tool_brush"):
		_set_tool(EditorState.Tool.BRUSH)
	elif event.is_action_pressed("tool_eraser"):
		_set_tool(EditorState.Tool.ERASER)
	elif event.is_action_pressed("tool_fill"):
		_set_tool(EditorState.Tool.FILL)
	elif event.is_action_pressed("tool_pick"):
		_set_tool(EditorState.Tool.PICK)
	elif event.is_action_pressed("undo"):
		state.undo()
	elif event.is_action_pressed("redo"):
		state.redo()
	elif event.is_action_pressed("play_pause"):
		_toggle_play()


func _set_tool(t: int) -> void:
	state.set_tool(t)


func _on_brush_pressed() -> void:
	_set_tool(EditorState.Tool.BRUSH)


func _on_eraser_pressed() -> void:
	_set_tool(EditorState.Tool.ERASER)


func _on_fill_pressed() -> void:
	_set_tool(EditorState.Tool.FILL)


func _on_pick_pressed() -> void:
	_set_tool(EditorState.Tool.PICK)


func _on_tool_changed(_t: int) -> void:
	_update_tool_buttons()
	_vp.set_ghost_color(_ghost_color())
	_update_status()


func _update_tool_buttons() -> void:
	for i in _tool_buttons.size():
		_tool_buttons[i].button_pressed = (i == state.tool)


func _ghost_color() -> Color:
	if state.tool == EditorState.Tool.ERASER:
		return Color(1.0, 0.35, 0.35, 0.4)
	return Color(state.current_color, 0.4)


func _on_color_picked(c: Color) -> void:
	state.set_color(c)


func _on_color_changed(_c: Color) -> void:
	_color_picker.color = state.current_color
	_vp.set_ghost_color(_ghost_color())
	_update_status()


func _update_recent() -> void:
	for child in _recent_box.get_children():
		child.queue_free()
	for c in state.recent_colors:
		var b := Button.new()
		b.custom_minimum_size = Vector2(22, 22)
		b.focus_mode = Control.FOCUS_NONE
		var sb := StyleBoxFlat.new()
		sb.bg_color = c
		sb.set_corner_radius_all(3)
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_stylebox_override("pressed", sb)
		b.pressed.connect(_on_recent_picked.bind(c))
		_recent_box.add_child(b)


func _on_recent_picked(c: Color) -> void:
	state.set_color(c)


func _on_frame_changed() -> void:
	_stop_play()
	_update_frame_strip()
	_vp.sync_to(state.doc, state.current_frame)
	_shown_frame = state.current_frame
	_update_status()


func _on_cells_changed() -> void:
	if not playing:
		_vp.sync_to(state.doc, state.current_frame)
	_shown_frame = state.current_frame
	_update_status()


func _update_frame_strip() -> void:
	for b in _frame_buttons:
		b.queue_free()
	_frame_buttons.clear()
	var group := ButtonGroup.new()
	for i in state.doc.frames.size():
		var b := Button.new()
		b.text = str(i + 1)
		b.custom_minimum_size = Vector2(34, 30)
		b.toggle_mode = true
		b.button_group = group
		b.pressed.connect(_select_frame.bind(i))
		_frame_box.add_child(b)
		_frame_buttons.append(b)
	_highlight_frame(state.current_frame)


func _select_frame(i: int) -> void:
	state.select_frame(i)


func _highlight_frame(i: int) -> void:
	for j in _frame_buttons.size():
		_frame_buttons[j].button_pressed = (j == i)
		if j == i:
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0.28, 0.42, 0.62)
			sb.set_corner_radius_all(3)
			_frame_buttons[j].add_theme_stylebox_override("normal", sb)
		else:
			_frame_buttons[j].remove_theme_stylebox_override("normal")


func _on_frame_add() -> void:
	state.add_frame()


func _on_frame_dup() -> void:
	state.duplicate_frame()


func _on_frame_del() -> void:
	state.delete_frame()


func _on_tool_pressed(target: Vector3i, hit: Vector3i, is_drag: bool) -> void:
	if playing:
		_toggle_play()
	if not is_drag:
		state.begin_stroke()
	state.apply_tool(target, hit)


func _on_tool_released() -> void:
	state.end_stroke()


func _on_zoom_changed(p: float) -> void:
	_zoom_percent = p
	_update_status()


func _on_play_pressed() -> void:
	_toggle_play()


func _on_prev_pressed() -> void:
	_step_frame(-1)


func _on_next_pressed() -> void:
	_step_frame(1)


func _toggle_play() -> void:
	if playing:
		_stop_play()
	else:
		playing = true
		_play_button.text = "Pause"
		_playing_frame = state.current_frame
		play_time = float(state.current_frame) / maxf(state.doc.fps, 0.1)
		_highlight_frame(state.current_frame)


func _stop_play() -> void:
	playing = false
	_play_button.text = "Play"
	_vp.sync_to(state.doc, state.current_frame)
	_shown_frame = state.current_frame
	_highlight_frame(state.current_frame)
	_update_status()


func _step_frame(dir: int) -> void:
	_stop_play()
	var n := state.doc.frames.size()
	state.select_frame((state.current_frame + dir) % n)


func _update_status() -> void:
	_status_left.text = "%s  %s" % [TOOL_NAMES[state.tool], state.current_color.to_html(true)]
	_status_right.text = "Frame %d/%d   Zoom %d%%   Grid %s" % [
		state.current_frame + 1, state.doc.frames.size(),
		int(_zoom_percent), str(state.doc.grid_size)
	]


func _on_file_menu(index: int) -> void:
	match index:
		0: _new_document()
		1: _open_file()
		2: _save_file()
		3: _save_file_as()
		4: get_tree().quit()


func _on_edit_menu(index: int) -> void:
	match index:
		0: state.undo()
		1: state.redo()


func _on_view_menu(index: int) -> void:
	match index:
		0: _vp.reset_view()
		1: _vp.toggle_grid()


func _new_document() -> void:
	state.reset()
	_save_path = ""
	_vp.configure(state.doc)
	_vp.sync_to(state.doc, 0)
	_update_recent()
	_update_tool_buttons()
	_vp.set_ghost_color(_ghost_color())


func _make_file_dialog() -> FileDialog:
	if _file_dialog:
		return _file_dialog
	var d := FileDialog.new()
	d.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	d.current_dir = OS.get_user_data_dir()
	add_child(d)
	_file_dialog = d
	return d


func _open_file() -> void:
	var d := _make_file_dialog()
	d.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	d.clear_filters()
	d.add_filter("*.tres ; Voxel animation")
	d.file_selected.connect(_on_file_opened, CONNECT_ONE_SHOT)
	d.popup_centered(Vector2i(600, 400))


func _on_file_opened(path: String) -> void:
	var res: Resource = ResourceLoader.load(path)
	if res is VoxelAnimation:
		state.adopt(res)
		_save_path = path
		_vp.configure(state.doc)
		_vp.sync_to(state.doc, state.current_frame)
		_shown_frame = state.current_frame
		_update_recent()
		_update_status()
	else:
		push_warning("Voxi: not a VoxelAnimation resource: " + path)


func _save_file() -> void:
	if _save_path.is_empty():
		_save_file_as()
		return
	_save_doc()


func _save_file_as() -> void:
	var d := _make_file_dialog()
	d.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	d.clear_filters()
	d.add_filter("*.tres ; Voxel animation")
	d.file_selected.connect(_on_file_saved, CONNECT_ONE_SHOT)
	d.popup_centered(Vector2i(600, 400))


func _on_file_saved(path: String) -> void:
	_save_path = path
	_save_doc()


func _save_doc() -> void:
	var err := ResourceSaver.save(state.doc, _save_path)
	if err != OK:
		push_error("Voxi: save failed: %s" % error_string(err))
