extends "res://tests/test.gd"

## Checks that the editor workspace follows the document.

var _menu: Node
var _brush: BrushToolSettings
var _paint: PaintToolSettings
# The selection and transform settings have no class name.
var _selection = null
var _transform = null
var _deform: DeformToolSettings
var _terrain: TerrainToolSettings
var _play_events: Array[bool] = []


func _ready() -> void:
	timeout = 30.0
	test("tool settings and the active color follow the document", _tools_run, "tools")
	test("view, environment, and camera settings follow the document", _view_run, "view")
	test("a saved document restores its workspace", _file_run, "file")
	test("a save captures the active workspace", _save_capture_run, "save_capture")
	test("a document without workspace state keeps the current setup", _legacy_run, "legacy")
	test("workspace changes do not mark the document dirty", _dirty_run, "dirty")
	test("the frame, tag, and playback state follow the document", _switch_run, "switch")
	test("the document stores its playback state", _playback_run, "playback")
	test("a cancelled edit reports the stopped playback state", _play_cancel_run, "play_cancel")
	test("a new-version startup restores each saved workspace after the splash", _startup_workspace_run, "startup_workspace")
	test("an old brush tool id restores the brush", _legacy_tool_id_run, "legacy_tool_id")
	test("an old stamp shape without a pattern falls back to the cube", _old_stamp_shape_run, "old_stamp_shape")


func before_test() -> void:
	_menu = main.get_node("%MenuBar")
	_brush = load("res://plugins/brush/BrushSettings.tres")
	_paint = load("res://plugins/paint/PaintSettings.tres")
	_selection = load("res://plugins/selection/SelectionSettings.tres")
	_transform = load("res://plugins/Transform/TransformSettings.tres")
	_deform = load("res://plugins/Deform/DeformSettings.tres")
	_terrain = load("res://plugins/Terrain/TerrainSettings.tres")
	_reset_workspace()


func _legacy_tool_id_run() -> void:
	var workspace := main.get_node("%EditorWorkspace")
	step("Given the brush button released and the old saved active id", func():
		var button := _tool_button("brush")
		expect(button != null, "the brush tool button is registered")
		if button != null:
			button.set_pressed_no_signal(false)
		workspace.call("_apply_active_tool", "BrushPlugin/Toolbar")
	)
	step("Then the old brush id selects the brush", func():
		var button := _tool_button("brush")
		expect(button != null and button.button_pressed, "the old brush id selects the brush")
	)
	step("Then the old symmetry id maps to the stable id", func():
		var constants: Dictionary = load("res://Globals/State/EditorWorkspace.gd").get_script_constant_map()
		var aliases: Dictionary = constants.get("LEGACY_TOOL_IDS", {})
		expect(aliases.get("SymmetryPlugin/Symmetry", "") == "SymmetryPlugin/symmetry", "the old symmetry id maps")
	)


func _tool_button(tool_id: String) -> BaseButton:
	for control in main.get_node("%ToolBar").get_children():
		if control is BaseButton and str(control.get_meta("tool_id", control.name)) == tool_id:
			return control
	return null


func _on_test_play_toggled(on: bool) -> void:
	_play_events.append(on)


func _reset_workspace() -> void:
	State.stop()
	_brush.mode = BrushToolSettings.BrushMode.PENCIL
	_brush.shape = StampToolSettings.BrushShape.CUBE
	_brush.diameter = 1
	_brush.pixel_perfect = false
	_paint.tool = PaintToolSettings.Tools.PAINTBRUSH
	_paint.connected = true
	_paint.spot_diameter = 1
	_paint.spray_size = 9
	_paint.speed = 8
	_paint.diameter = 1
	_paint.shape = StampToolSettings.BrushShape.CUBE
	_paint.pixel_perfect = false
	# The selection and transform settings have no class name.
	_selection.tool = 0
	_selection.mode = 0
	_selection.connected = true
	_selection.include_empty = false
	_selection.depth_test = true
	_transform.tool = 0
	_transform.snap = false
	_transform.uniform = true
	_deform.tool = DeformToolSettings.Tools.POSE
	_deform.size = 4
	_deform.snap = false
	_deform.falloff = 0.5
	_deform.connected = false
	_terrain.tool = TerrainToolSettings.Tools.BUILD
	_terrain.radius = 4
	_terrain.strength = 1
	_terrain.falloff = 0.5
	_terrain.build_mode = TerrainToolSettings.BuildMode.ADD
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	State.slice_layers = 0
	activate_tool("Toolbar")


func _tools_run() -> void:
	var blue := VoxelFrame.material(Color(0.2, 0.4, 0.8))
	step("Given two documents and a distinctive tool setup", func():
		var first := State.new_document()
		var second := State.new_document()
		var documents: Array[VoxelDocument] = [first, second]
		State.set_tabs(documents, 0)
		_brush.diameter = 7
		_brush.shape = StampToolSettings.BrushShape.SPHERE
		_brush.pixel_perfect = true
		_brush.mode = BrushToolSettings.BrushMode.ERASER
		_paint.tool = PaintToolSettings.Tools.SPRAY
		_paint.connected = false
		_paint.spot_diameter = 3
		_paint.spray_size = 11
		_paint.speed = 4
		_selection.tool = 2
		_selection.mode = 1
		_selection.include_empty = true
		_selection.depth_test = false
		_transform.tool = 1
		_transform.snap = true
		_transform.uniform = false
		_deform.tool = DeformToolSettings.Tools.GRAB
		_deform.size = 6
		_deform.snap = true
		_deform.falloff = 0.25
		_deform.connected = true
		_terrain.tool = TerrainToolSettings.Tools.SMOOTH
		_terrain.radius = 7
		_terrain.strength = 3
		_terrain.falloff = 0.75
		_terrain.build_mode = TerrainToolSettings.BuildMode.REMOVE
		State.symmetry_axes = 3
		State.symmetry_origin = Vector3(1.5, -0.5, 0.5)
		State.floor_axis = Vector3.Axis.AXIS_Z
		State.floor_index = 4
		State.slice_layers = 2
		State.edit_material(blue)
		activate_tool("paint")
		select_toolbar_item("paint", "Spray Can")
	)
	step("When the user changes the setup on the second document", func():
		State.activate_tab(1)
		_brush.diameter = 3
		_brush.shape = StampToolSettings.BrushShape.CUBE
		_brush.pixel_perfect = false
		_brush.mode = BrushToolSettings.BrushMode.PENCIL
		_paint.tool = PaintToolSettings.Tools.PAINTBRUSH
		State.edit_material(VoxelFrame.material(Color.RED))
		State.symmetry_axes = 0
		State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
		State.floor_axis = Vector3.Axis.AXIS_Y
		State.floor_index = 0
		State.slice_layers = 0
		activate_tool("Toolbar")
	)
	step("Then the first document restores its setup", func():
		expect(State.activate_tab(0), "the first tab activates")
		expect(_brush.diameter == 7, "the brush diameter returns")
		expect(_brush.shape == StampToolSettings.BrushShape.SPHERE, "the brush shape returns")
		expect(_brush.pixel_perfect, "the pixel-perfect flag returns")
		expect(_brush.mode == BrushToolSettings.BrushMode.ERASER, "the brush mode returns")
		expect(_paint.tool == PaintToolSettings.Tools.SPRAY, "the paint tool returns")
		expect(not _paint.connected, "the fill connection returns")
		expect(_paint.spot_diameter == 3, "the spray spot returns")
		expect(_paint.spray_size == 11, "the spray size returns")
		expect(_paint.speed == 4, "the spray speed returns")
		expect(_selection.tool == 2, "the selection tool returns")
		expect(_selection.mode == 1, "the selection mode returns")
		expect(_selection.include_empty, "the include-empty flag returns")
		expect(not _selection.depth_test, "the depth-test flag returns")
		expect(_transform.tool == 1, "the transform tool returns")
		expect(_transform.snap, "the transform snap returns")
		expect(not _transform.uniform, "the uniform scale flag returns")
		expect(_deform.tool == DeformToolSettings.Tools.GRAB, "the deform tool returns")
		expect(_deform.size == 6, "the deform size returns")
		expect(_deform.snap, "the deform snap returns")
		expect(is_equal_approx(_deform.falloff, 0.25), "the deform falloff returns")
		expect(_deform.connected, "the deform connection returns")
		expect(_terrain.tool == TerrainToolSettings.Tools.SMOOTH, "the terrain tool returns")
		expect(_terrain.radius == 7, "the terrain radius returns")
		expect(_terrain.strength == 3, "the terrain strength returns")
		expect(is_equal_approx(_terrain.falloff, 0.75), "the terrain falloff returns")
		expect(_terrain.build_mode == TerrainToolSettings.BuildMode.REMOVE, "the build mode returns")
		expect(State.symmetry_axes == 3, "the symmetry axes return")
		expect(State.symmetry_origin.is_equal_approx(Vector3(1.5, -0.5, 0.5)), "the symmetry origin returns")
		expect(State.floor_axis == Vector3.Axis.AXIS_Z, "the floor axis returns")
		expect(State.floor_index == 4, "the floor index returns")
		expect(State.slice_layers == 2, "the slice count returns")
		expect(State.current_material == blue, "the active material returns")
		var paint_button: BaseButton = plugin("PaintPlugin")._toolbar
		expect(paint_button.button_pressed, "the paint toolbar is pressed")
		expect(plugin("PaintPlugin")._tool.name == "SprayTool", "the paint plugin mounts the restored tool")
		expect(paint_button.icon == paint_button.get_popup().get_item_icon(2), "the paint icon shows the restored tool")
	)


func _view_run() -> void:
	var viewport: Node = viewport_scene()
	var rig: EditorCameraRig = camera_rig()
	var pan: Button = main.get_node("%Viewport").get_node("ControlBar/PanToggle")
	var pose := []
	var light_color := Color(0.2, 0.4, 0.6)
	var ambient_color := Color(0.1, 0.3, 0.5)
	var light_basis := Basis(Vector3.UP, 0.35)
	step("Given a document with a distinctive view", func():
		var first := State.new_document()
		var second := State.new_document()
		var documents: Array[VoxelDocument] = [first, second]
		State.set_tabs(documents, 0)
		viewport._set_grid_visible(false)
		viewport._set_wireframe(true)
		viewport._set_orthographic(true)
		pan.button_pressed = true
		viewport.get_node("%EnvironmentMenu").button_pressed = true
		viewport.get_node("%LightToggle").button_pressed = true
		viewport.get_node("%Shadows").button_pressed = false
		viewport.get_node("%LockView").button_pressed = true
		rig.orbit(Vector2(25, 10))
		rig.zoom(1.2)
		rig.pan(Vector2(8, -4))
		pose.append({"yaw": rig._yaw, "pitch": rig._pitch, "dist": rig._dist, "init": rig._init_dist, "target": rig._target})
		var lighting: Dictionary = viewport.get_lighting_settings()
		lighting.basis = light_basis
		viewport.set_lighting_settings(lighting)
		viewport.get_node("%LightColor").color_changed.emit(light_color)
		viewport.get_node("%AmbientColor").color_changed.emit(ambient_color)
	)
	step("When the user switches away and back", func():
		State.activate_tab(1)
		State.activate_tab(0)
	)
	step("Then the view returns", func():
		expect(not viewport.get_node("%Grid").visible, "the grid stays off")
		expect(editor_viewport().debug_draw == Viewport.DEBUG_DRAW_WIREFRAME, "the wireframe stays on")
		expect(rig.is_orthogonal, "the orthographic projection returns")
		expect(int(viewport.view_mode) == 3, "the light drag mode returns")
		expect(viewport.get_node("%LightToggle").button_pressed, "the light toggle returns")
		expect(viewport.get_node("%EnvironmentBar").visible, "the environment row stays open")
		expect(not viewport.get_node("%Shadows").button_pressed, "the shadow choice returns")
		expect(viewport.get_node("%LockView").button_pressed, "the view lock returns")
		var restored: Dictionary = viewport.get_lighting_settings()
		var restored_color: Color = restored.color
		var restored_ambient: Color = restored.ambient_color
		var restored_basis: Basis = restored.basis
		expect(restored_color.is_equal_approx(light_color), "the light color returns")
		expect(restored_ambient.is_equal_approx(ambient_color), "the ambient color returns")
		expect(restored_basis.is_equal_approx(light_basis), "the light direction returns")
		expect(is_equal_approx(rig._yaw, pose[0].yaw), "the camera yaw returns")
		expect(is_equal_approx(rig._pitch, pose[0].pitch), "the camera pitch returns")
		expect(is_equal_approx(rig._dist, pose[0].dist), "the camera distance returns")
		expect(is_equal_approx(rig._init_dist, pose[0].init), "the initial camera distance returns")
		expect(rig._target.is_equal_approx(pose[0].target), "the camera target returns")
	)


func _file_run() -> void:
	var path := "user://editor_workspace_%s.lve" % Time.get_ticks_usec()
	var green := VoxelFrame.material(Color(0.1, 0.9, 0.2))
	var pose := []
	step("Given a document with a distinctive workspace", func():
		var document := State.new_document()
		State.set_tabs([document], 0)
		State.add_frame()
		State.add_tag("Walk", 0, 1)
		State.select_tag(0)
		_brush.diameter = 9
		_brush.shape = StampToolSettings.BrushShape.SPHERE
		_brush.pixel_perfect = true
		_paint.tool = PaintToolSettings.Tools.SPRAY
		_paint.spot_diameter = 4
		_terrain.radius = 8
		_terrain.build_mode = TerrainToolSettings.BuildMode.REMOVE
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3(0.5, 0.5, 0.5)
		State.floor_axis = Vector3.Axis.AXIS_X
		State.floor_index = 3
		State.slice_layers = 1
		State.edit_material(green)
		activate_tool("paint")
		select_toolbar_item("paint", "Spray Can")
		viewport_scene()._set_grid_visible(false)
		viewport_scene()._set_wireframe(true)
		viewport_scene()._set_orthographic(true)
		var pan: Button = main.get_node("%Viewport").get_node("ControlBar/PanToggle")
		pan.button_pressed = true
		viewport_scene().get_node("%Shadows").button_pressed = false
		camera_rig().orbit(Vector2(35, 12))
		camera_rig().zoom(1.35)
		camera_rig().pan(Vector2(6, -3))
		pose.append({"dist": camera_rig()._dist, "init": camera_rig()._init_dist, "target": camera_rig()._target})
		expect(_menu.save_doc(path) == OK, "the document saves")
	)
	step("When the workspace changes and the file opens", func():
		_brush.diameter = 2
		_paint.tool = PaintToolSettings.Tools.PAINTBRUSH
		State.symmetry_axes = 0
		State.edit_material(VoxelFrame.material(Color.BLACK))
		viewport_scene()._set_grid_visible(true)
		activate_tool("Toolbar")
		_menu._on_file_opened(path)
	)
	step("Then the saved workspace returns", func():
		expect(_brush.diameter == 9, "the brush diameter returns")
		expect(_brush.shape == StampToolSettings.BrushShape.SPHERE, "the brush shape returns")
		expect(_brush.pixel_perfect, "the pixel-perfect flag returns")
		expect(_paint.tool == PaintToolSettings.Tools.SPRAY, "the paint tool returns")
		expect(_paint.spot_diameter == 4, "the spray spot returns")
		expect(_terrain.radius == 8, "the terrain radius returns")
		expect(_terrain.build_mode == TerrainToolSettings.BuildMode.REMOVE, "the build mode returns")
		expect(State.symmetry_axes == 1, "the symmetry axes return")
		expect(State.symmetry_origin.is_equal_approx(Vector3(0.5, 0.5, 0.5)), "the symmetry origin returns")
		expect(State.floor_axis == Vector3.Axis.AXIS_X, "the floor axis returns")
		expect(State.floor_index == 3, "the floor index returns")
		expect(State.slice_layers == 1, "the slice count returns")
		expect(State.current_material == green, "the active material returns")
		expect(not viewport_scene().get_node("%Grid").visible, "the grid stays off")
		expect(editor_viewport().debug_draw == Viewport.DEBUG_DRAW_WIREFRAME, "the wireframe stays on")
		expect(camera_rig().is_orthogonal, "the orthographic projection returns")
		expect(not viewport_scene().get_node("%Shadows").button_pressed, "the shadow choice returns")
		expect(State.current_frame == 1, "the frame returns")
		expect(State.active_tag == 0, "the active tag returns")
		expect(plugin("PaintPlugin")._tool.name == "SprayTool", "the paint plugin mounts the restored tool")
		expect(is_equal_approx(camera_rig()._dist, pose[0].dist), "the camera distance returns")
		expect(is_equal_approx(camera_rig()._init_dist, pose[0].init), "the initial camera distance returns")
		expect(camera_rig()._target.is_equal_approx(pose[0].target), "the camera target returns")
		DirAccess.remove_absolute(path)
	)


func _save_capture_run() -> void:
	var path := "user://editor_workspace_save_%s.lve" % Time.get_ticks_usec()
	var inherited := VoxelFrame.material(Color(0.3, 0.7, 0.4))
	var pose := []
	step("Given a document that inherits the active workspace", func():
		var first := State.new_document()
		var second := State.new_document()
		State.set_tabs([first], 0)
		_brush.diameter = 6
		_brush.shape = StampToolSettings.BrushShape.SPHERE
		State.edit_material(inherited)
		viewport_scene()._set_grid_visible(false)
		viewport_scene()._set_wireframe(true)
		State.open_tab(second)
		expect(second.tool_settings.is_empty(), "the new document starts without tool state")
		expect(second.view_settings.is_empty(), "the new document starts without view state")
		pose.append({"yaw": camera_rig()._yaw, "pitch": camera_rig()._pitch, "dist": camera_rig()._dist, "target": camera_rig()._target})
		expect(_menu.save_doc(path) == OK, "the inherited workspace saves")
		expect(second.tool_settings.get("BrushPlugin", {}).get("diameter", 0) == 6, "the save captures the tools")
		expect(second.tool_settings.has("material"), "the save captures the material")
		expect(second.view_settings.get("grid", true) == false, "the save captures the view")
		expect(second.lighting_settings.has("shadows"), "the save captures the lighting")
		expect(not second.edit_camera.is_empty(), "the save captures the camera")
	)
	step("When the first workspace changes and the file opens", func():
		State.activate_tab(0)
		_brush.diameter = 2
		_brush.shape = StampToolSettings.BrushShape.CUBE
		State.edit_material(VoxelFrame.material(Color.BLACK))
		viewport_scene()._set_grid_visible(true)
		viewport_scene()._set_wireframe(false)
		camera_rig().orbit(Vector2(-30, -10))
		_menu._on_file_opened(path)
	)
	step("Then the saved workspace returns", func():
		expect(_brush.diameter == 6, "the saved brush diameter returns")
		expect(_brush.shape == StampToolSettings.BrushShape.SPHERE, "the saved brush shape returns")
		expect(State.current_material == inherited, "the saved material returns")
		expect(not viewport_scene().get_node("%Grid").visible, "the saved grid choice returns")
		expect(editor_viewport().debug_draw == Viewport.DEBUG_DRAW_WIREFRAME, "the saved wireframe returns")
		expect(not State.document.edit_camera.is_empty(), "the opened document keeps its camera")
		expect(is_equal_approx(camera_rig()._yaw, pose[0].yaw), "the saved camera yaw returns")
		expect(is_equal_approx(camera_rig()._dist, pose[0].dist), "the saved camera distance returns")
		expect(camera_rig()._target.is_equal_approx(pose[0].target), "the saved camera target returns")
		DirAccess.remove_absolute(path)
	)


func _legacy_run() -> void:
	var green := VoxelFrame.material(Color.GREEN)
	step("Given a document with a current workspace", func():
		var current := State.new_document()
		State.set_tabs([current], 0)
		_brush.diameter = 6
		State.edit_material(green)
		viewport_scene()._set_grid_visible(false)
		activate_tool("Toolbar")
	)
	step("When a document without workspace state opens", func():
		var legacy := VoxelDocument.new()
		State.document = legacy
		expect(legacy.tool_settings.is_empty(), "the replacement has no tool state")
		expect(legacy.view_settings.is_empty(), "the replacement has no view state")
	)
	step("Then the current workspace stays", func():
		expect(_brush.diameter == 6, "the brush diameter stays")
		expect(State.current_material == green, "the active material stays")
		expect(not viewport_scene().get_node("%Grid").visible, "the grid stays off")
		expect(plugin("BrushPlugin")._toolbar.button_pressed, "the active tool stays")
	)


func _old_stamp_shape_run() -> void:
	step("Given a document saved with the old stamp shape and no pattern", func():
		var document := State.new_document()
		document.tool_settings = {"BrushPlugin": {"shape": int(StampToolSettings.BrushShape.STAMP), "diameter": 4}}
		State.set_tabs([document], 0)
	)
	step("Then the brush shape falls back to the cube", func():
		expect(_brush.shape == StampToolSettings.BrushShape.CUBE, "the brush uses the cube shape")
		expect(_brush.diameter == 4, "the brush keeps its saved diameter")
		var stored: Dictionary = State.document.tool_settings.get("BrushPlugin", {})
		expect(int(stored.get("shape", -1)) == int(StampToolSettings.BrushShape.CUBE), "the stored shape records the fallback")
	)


func _dirty_run() -> void:
	step("Given a clean document", func():
		State.set_tabs([State.new_document()], 0)
		expect(not State.document.edit_dirty, "the new document starts clean")
	)
	step("When the user changes the workspace", func():
		_brush.diameter = 8
		viewport_scene()._set_grid_visible(false)
		camera_rig().orbit(Vector2(10, 5))
		viewport_scene().get_node("%Shadows").button_pressed = false
		State.edit_material(VoxelFrame.material(Color.BLUE))
	)
	step("Then the document stays clean", func():
		expect(not State.document.edit_dirty, "workspace changes do not mark the document edited")
	)
	step("When a cell notification arrives", func():
		sync_viewport()
	)
	step("Then the document is edited", func():
		expect(State.document.edit_dirty, "a cell change marks the document edited")
	)


func _switch_run() -> void:
	step("Given two documents with different frames and tags", func():
		var first := State.new_document()
		var second := State.new_document()
		var documents: Array[VoxelDocument] = [first, second]
		State.set_tabs(documents, 0)
		State.add_frame()
		State.add_tag("Walk", 0, 1)
		State.current_frame = 1
		State.select_tag(1)
		State.activate_tab(1)
		State.deselect_tag()
	)
	step("Then each document keeps its own frame and tag", func():
		expect(State.current_frame == 0, "the second document keeps frame zero")
		expect(State.active_tag == -1, "the second document keeps no active tag")
		State.activate_tab(0)
		expect(State.current_frame == 1, "the first document keeps frame one")
		expect(State.active_tag == 1, "the first document keeps its active tag")
	)
	step("When the first document plays and the user switches away", func():
		State.is_playing = true
		expect(State.is_playing, "the first document plays")
		State.activate_tab(1)
	)
	step("Then the second document stays paused", func():
		expect(not State.is_playing, "the second document does not play")
		State.activate_tab(0)
	)
	step("Then the first document plays again", func():
		expect(State.is_playing, "the first document resumes")
		State.stop()
	)


func _play_cancel_run() -> void:
	var tx: VoxelEditTransaction
	step("Given an edited frame with an open edit", func():
		State.set_tabs([State.new_document()], 0)
		State.add_frame()
		State.add_tag("Walk", 0, 1)
		State.current_frame = 1
		tx = State.begin_edit()
		expect(tx != null, "the edit opens")
		if tx != null:
			State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		_play_events.clear()
		if not State.is_playing_toggled.is_connected(_on_test_play_toggled):
			State.is_playing_toggled.connect(_on_test_play_toggled)
		# The restart changes the frame. The open edit cancels, and its restore
		# emits cells_changed, which stops playback.
		State.edit_context_changing.connect(func():
			if tx != null:
				State.cancel_edit(tx)
		, CONNECT_ONE_SHOT)
	)
	step("When playback starts", func():
		State.is_playing = true
	)
	step("Then the cancel stops playback and the last signal says so", func():
		expect(not State.is_playing, "the cancel stops playback")
		expect(not _play_events.is_empty(), "the toggle signal fires")
		expect(_play_events[_play_events.size() - 1] == false, "the last toggle reports stopped")
		if State.is_playing_toggled.is_connected(_on_test_play_toggled):
			State.is_playing_toggled.disconnect(_on_test_play_toggled)
	)


func _playback_run() -> void:
	var path := "user://editor_workspace_play_%s.lve" % Time.get_ticks_usec()
	step("Given a playing document", func():
		State.set_tabs([State.new_document()], 0)
		State.add_frame()
		State.add_tag("Walk", 0, 1)
		State.is_playing = true
		expect(State.document.edit_playing, "the document records the play state")
		var decoded := VoxelDocument.decode_document(State.document.encode_document())
		expect(decoded != null and decoded.edit_playing, "the encoding stores the play state")
		expect(_menu.save_doc(path) == OK, "the playing document saves")
	)
	step("When the user stops and reopens the file", func():
		State.stop()
		expect(not State.document.edit_playing, "stopping clears the play state")
		_menu._on_file_opened(path)
	)
	step("Then the document plays", func():
		expect(State.is_playing, "the opened document plays")
		var play_button: Button = main.find_child("BottomDock", true, false).get_node("%Play")
		expect(play_button.button_pressed, "the Play button shows the playing state")
		State.stop()
		DirAccess.remove_absolute(path)
	)


func _startup_workspace_run() -> void:
	var stamp := Time.get_ticks_usec()
	var config_path := "user://workspace_startup_%s.cfg" % stamp
	var first_path := "user://workspace_first_%s.lve" % stamp
	var second_path := "user://workspace_second_%s.lve" % stamp
	var previous_settings := str(main.get("settings_path"))
	var first := VoxelDocument.new()
	first.add_frame()
	first.tool_settings = {"BrushPlugin": {"diameter": 7}, "PaintPlugin": {"diameter": 5}, "active": "BrushPlugin/Toolbar"}
	var second := VoxelDocument.new()
	second.add_frame()
	second.tool_settings = {"BrushPlugin": {"diameter": 9}, "PaintPlugin": {"diameter": 11}, "active": "PaintPlugin/Toolbar"}
	step("Given two saved documents with different workspaces and a new version", func():
		expect(first.save_file(first_path, null, first.encode_document()) == OK, "the first copy saves")
		expect(second.save_file(second_path, null, second.encode_document()) == OK, "the second copy saves")
		var settings := ConfigFile.new()
		settings.set_value("application", "version", "0.0")
		settings.set_value("files", "tabs", PackedStringArray([first_path, second_path]))
		settings.set_value("files", "active", 1)
		expect(settings.save(config_path) == OK, "the settings file saves")
		main.set("settings_path", config_path)
	)
	step("When the editor starts with a new version", func():
		main._restore_startup_document(true, config_path)
	)
	step("Then the splash is active and inherits the restored setup", func():
		expect(State.active_tab == 0, "the splash is the active tab")
		expect(State.document.file_path == "res://splash.lve", "the splash is the active document")
		expect(_brush.diameter == 9, "the splash keeps the restored active setup")
	)
	step("When the user opens the first saved tab", func():
		expect(State.activate_tab(1), "the first saved tab activates")
	)
	step("Then the first saved workspace restores", func():
		expect(_brush.diameter == 7, "the first brush diameter returns")
		expect(_paint.diameter == 5, "the first paint diameter returns")
	)
	step("When the user opens the second saved tab", func():
		expect(State.activate_tab(2), "the second saved tab activates")
	)
	step("Then the second saved workspace restores", func():
		expect(_brush.diameter == 9, "the second brush diameter returns")
		expect(_paint.diameter == 11, "the second paint diameter returns")
	)
	step("Then the temporary files are removed", func():
		main.set("settings_path", previous_settings)
		for path in [config_path, first_path, second_path]:
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	)
