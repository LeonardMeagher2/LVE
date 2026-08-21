extends Control

@onready var _menu_bar: EditorMenuBar = $Content/Root/MenuBar
@onready var _option_bar: OptionBar = $Content/Root/Body/CenterPane/OptionBar
@onready var _viewport_panel: EditorViewportPanel = $Content/Root/Body/CenterPane/ViewportContainer
@onready var _control_bar: ControlBar = $Content/Root/Body/CenterPane/ControlBar
@onready var _bottom_dock: EditorBottomDock = $Content/Root/BottomDock
@onready var _status_bar: EditorStatusBar = $Content/Root/StatusBar

var _zoom_percent := 100.0

var _save_path := ""
var _file_dialog: FileDialog


func _ready() -> void:
	State.tool_changed.connect(_on_tool_changed)
	State.color_changed.connect(_on_color_changed)
	State.frame_changed.connect(_on_frame_changed)
	State.cells_changed.connect(_on_cells_changed)
	State.selection_changed.connect(_on_selection_changed)
	State.playback.playback_changed.connect(_on_playback_changed)
	_menu_bar.new_document.connect(_new_document)
	_menu_bar.open_file.connect(_open_file)
	_menu_bar.save_file.connect(_save_file)
	_menu_bar.save_file_as.connect(_save_file_as)
	_menu_bar.quit.connect(func() -> void: get_tree().quit())
	_menu_bar.undo.connect(State.undo_redo.undo)
	_menu_bar.redo.connect(State.undo_redo.redo)
	_menu_bar.reset_view.connect(_viewport_panel.reset_view)
	_menu_bar.toggle_grid.connect(_viewport_panel.toggle_grid)
	_bottom_dock.play_toggled.connect(_toggle_play)
	_bottom_dock.prev.connect(_step_frame.bind(-1))
	_bottom_dock.next.connect(_step_frame.bind(1))
	_bottom_dock.to_start.connect(_to_start)
	_bottom_dock.to_end.connect(_to_end)
	_bottom_dock.frame_add.connect(State.playback.add_frame)
	_bottom_dock.frame_dup.connect(State.playback.duplicate_frame)
	_bottom_dock.frame_del.connect(State.playback.delete_frame)
	_bottom_dock.frame_selected.connect(State.playback.select_frame)
	_bottom_dock.delay_changed.connect(_update_status)
	_viewport_panel.frame_displayed.connect(_on_frame_displayed)
	_viewport_panel.zoom_changed.connect(_on_zoom_changed)
	_viewport_panel.grid_changed.connect(_control_bar.set_grid_visible)
	_option_bar.view_requested.connect(_viewport_panel.set_view)
	_control_bar.zoom_requested.connect(_viewport_panel.set_zoom_percent)
	_control_bar.grid_toggled.connect(_viewport_panel.set_grid_visible)
	_viewport_panel.set_tool(State.tool)
	_viewport_panel.configure()
	_viewport_panel.sync_to(State.current_frame)
	_viewport_panel.sync_selection(State.selection)
	_update_status()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.is_action_pressed("tool_brush"):
		State.set_tool(State.tools.brush)
	elif event.is_action_pressed("tool_eraser"):
		State.set_tool(State.tools.eraser)
	elif event.is_action_pressed("tool_fill"):
		State.set_tool(State.tools.fill)
	elif event.is_action_pressed("tool_pick"):
		State.set_tool(State.tools.pick)
	elif event.is_action_pressed("undo"):
		State.undo_redo.undo()
	elif event.is_action_pressed("redo"):
		State.undo_redo.redo()
	elif event.is_action_pressed("play_pause"):
		_toggle_play()


func _on_tool_changed(_t: ToolInfo) -> void:
	_viewport_panel.set_tool(State.tool)
	_update_status()


func _on_color_changed(_c: Color) -> void:
	_update_status()


func _on_frame_changed() -> void:
	_viewport_panel.sync_to(State.current_frame)
	_update_status()


func _on_cells_changed() -> void:
	if not State.playback.playing:
		_viewport_panel.sync_to(State.current_frame)
	_update_status()


func _on_selection_changed() -> void:
	_viewport_panel.sync_selection(State.selection)


func _on_playback_changed() -> void:
	if State.playback.playing:
		_viewport_panel.play_preview()
	else:
		_viewport_panel.stop_preview()
	_bottom_dock.set_playing(State.playback.playing)


func _on_frame_displayed(i: int) -> void:
	_bottom_dock.highlight_frame(i)
	_update_status()


func _on_zoom_changed(p: float) -> void:
	_zoom_percent = p
	_control_bar.set_zoom(p)
	_update_status()


func _toggle_play() -> void:
	State.playback.set_playing(not State.playback.playing)


func _stop_play() -> void:
	State.playback.set_playing(false)


func _step_frame(dir: int) -> void:
	_stop_play()
	var n := State.document.frames.size()
	State.playback.select_frame((State.current_frame + dir) % n)


func _to_start() -> void:
	_stop_play()
	State.playback.select_frame(0)


func _to_end() -> void:
	_stop_play()
	State.playback.select_frame(State.document.frames.size() - 1)


func _update_status() -> void:
	var total := 0
	for f in State.document.frames:
		total += f.delay_ms
	_status_bar.set_status(
		State.tool.display_name, State.current_color.to_html(false),
		State.document.frames[State.current_frame].delay_ms, total,
		State.current_frame, State.document.frames.size(),
		int(_zoom_percent), State.document.grid_size)


func _new_document() -> void:
	State.reset()
	_save_path = ""
	_viewport_panel.configure()
	_viewport_panel.sync_to(0)


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
	if res is VoxiDocument:
		State.load_document(res)
		_save_path = path
		_viewport_panel.configure()
		_viewport_panel.sync_to(State.current_frame)
		_update_status()
	else:
		push_warning("Voxi: not a VoxiDocument resource: " + path)


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
	var err := ResourceSaver.save(State.document, _save_path)
	if err != OK:
		push_error("Voxi: save failed: %s" % error_string(err))
