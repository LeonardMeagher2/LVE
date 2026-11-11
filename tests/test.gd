extends "res://addons/test_kit/test_case.gd"

# The LVE test adapter. The shared test kit owns the test lifecycle. This file
# owns the editor fixture and the helpers that drive the real LVE interface.
# Every LVE test scene inherits `res://tests/test_base.tscn` and puts one of
# these scripts on its root node.

const BRUSH_SETTINGS_PATH := "res://plugins/brush/settings.tres"
const PAINT_SETTINGS_PATH := "res://plugins/paint/settings.tres"
const SELECTION_SETTINGS_PATH := "res://plugins/selection/settings.tres"
const TRANSFORM_SETTINGS_PATH := "res://plugins/Transform/settings.tres"

var main: Node
var _brush_settings_resource: BrushToolSettings
var _paint_settings_resource: PaintToolSettings
var _selection_settings_resource = null
var _transform_settings_resource = null


func _enter_tree() -> void:
	main = get_node_or_null("Main")
	if main == null or main.get_node_or_null("%Viewport") == null:
		push_error("LVE test scene must inherit res://tests/test_base.tscn")
	settle_frames = 2
	_brush_settings_resource = load(BRUSH_SETTINGS_PATH)
	_paint_settings_resource = load(PAINT_SETTINGS_PATH)
	_selection_settings_resource = load(SELECTION_SETTINGS_PATH)
	_transform_settings_resource = load(TRANSFORM_SETTINGS_PATH)


# The shared editor state survives a scene change. Reset the parts that every
# suite assumes at startup: one tab, the first palette entry, no slice or
# symmetry, no selection, the default brush, and the brush tool.
func reset_environment() -> void:
	State.stop()
	State.set_tabs([State.new_document()], 0)
	State.select_palette_entry(0)
	State.slice_layers = 0
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	State.symmetry_axes = 0
	State.clear_selection()
	_brush_settings_resource.mode = BrushToolSettings.BrushMode.PENCIL
	_brush_settings_resource.shape = StampToolSettings.BrushShape.CUBE
	_brush_settings_resource.diameter = 1
	_brush_settings_resource.pixel_perfect = false
	_paint_settings_resource.tool = PaintToolSettings.Tools.PAINTBRUSH
	_paint_settings_resource.connected = true
	_paint_settings_resource.spot_diameter = 1
	_paint_settings_resource.spray_size = 9
	_paint_settings_resource.diameter = 1
	_paint_settings_resource.shape = StampToolSettings.BrushShape.CUBE
	_paint_settings_resource.pixel_perfect = false
	# The selection settings have no class name. BOX and REPLACE are both zero.
	_selection_settings_resource.tool = 0
	_selection_settings_resource.mode = 0
	_selection_settings_resource.connected = true
	_selection_settings_resource.include_empty = false
	_selection_settings_resource.depth_test = true
	# TransformToolSettings.Tools.MOVE is zero.
	_transform_settings_resource.tool = 0
	_transform_settings_resource.snap = true
	_transform_settings_resource.uniform = true
	activate_tool("Toolbar")


func before_scene_free() -> void:
	# The next scene starts in the same process. Let a fill or a wand finish
	# before the plugins and their preview workers are removed.
	var deadline := Time.get_ticks_msec() + 5000
	while State.edit_busy() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	State.clear_plugins()
	await get_tree().process_frame


func editor_viewport() -> SubViewport:
	return main.get_node("%Viewport").get_node("PanelContainer/SubViewportContainer/Viewport")

func camera_rig() -> EditorCameraRig:
	return editor_viewport().get_node("ViewportScene/CameraRig")

func viewport_scene() -> Node:
	return editor_viewport().get_node("ViewportScene")

func camera_menu() -> MenuButton:
	return main.get_node("%Viewport").get_node("ControlBar/CameraMenu")

func pick_request(pos: Vector2) -> PickRequest:
	var cam := camera_rig()
	var req := PickRequest.new()
	req.origin = cam.project_ray_origin(pos)
	req.dir = cam.project_ray_normal(pos)
	req.frame = State.get_current_voxel_frame()
	req.forward = -cam.basis.z
	return req

func aim(pos: Vector2) -> PickResult:
	var req := pick_request(pos)
	return VoxelPicking.start_pick(req.origin, req.dir, req.frame, req.forward)

func drag(pos: Vector2, plane: StrokePlane) -> PickResult:
	var req := pick_request(pos)
	return VoxelPicking.drag_pick(req.origin, req.dir, req.frame, plane)

func activate_tool(button_name: String) -> void:
	for b in main.get_node("%ToolBar").get_children():
		if b.name == button_name:
			b.button_pressed = true
			return

func select_toolbar_item(button_name: String, item_text: String) -> void:
	for b in main.get_node("%ToolBar").get_children():
		if b is MenuButton and b.name == button_name:
			var popup: PopupMenu = b.get_popup()
			for i in popup.item_count:
				if popup.get_item_text(i) == item_text:
					popup.index_pressed.emit(i)
					return

func press_option(tooltip: String) -> void:
	var b := _find_option_button(tooltip)
	if b != null:
		b.button_pressed = not b.button_pressed

func _find_option_button(tooltip: String) -> BaseButton:
	var option_bar := main.get_node("%OptionBar")
	for container in option_bar.get_children():
		var b := _find_button_by_tooltip(container, tooltip)
		if b != null:
			return b
	return null

func _find_button_by_tooltip(node: Node, tooltip: String) -> BaseButton:
	for c in node.get_children():
		if c is BaseButton and c.tooltip_text == tooltip:
			return c
		var found := _find_button_by_tooltip(c, tooltip)
		if found != null:
			return found
	return null

func plugin(plugin_name: String) -> Node:
	return get_tree().root.get_node_or_null(plugin_name)

func sync_viewport() -> void:
	State.document._bounds_dirty = true
	var affected: Array[Vector3i] = []
	State.cells_changed.emit(State.current_frame, affected)

func active_tool_node(plugin_name: String) -> Node3D:
	var p := plugin(plugin_name)
	if p == null:
		return null
	return p._tool
