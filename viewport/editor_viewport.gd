class_name EditorViewport
extends Node3D

signal zoom_changed(percent: float)
signal grid_changed(visible: bool)

var _tool: VoxelTool
var _tools := {}

@onready var camera_rig: EditorCameraRig = %CameraRig
@onready var _grid: GridRenderer = %Grid
@onready var _voxels: VoxelRenderer = %Voxels
@onready var _playback: PlaybackAnimator = %Playback
@onready var _tool_layer: Node3D = %ToolLayer


func _ready() -> void:
	($Light as DirectionalLight3D).rotation_degrees = Vector3(-50.0, -35.0, 0.0)
	camera_rig.zoom_changed.connect(zoom_changed.emit)


func set_tool(t: ToolInfo) -> void:
	if _tool != null:
		_tool.visible = false
		_tool.on_deactivated()
	if t == null or t.tool_scene.is_empty():
		_tool = null
		return
	_tool = _tools.get(t.id)
	if _tool == null:
		var scene := load(t.tool_scene)
		if scene == null:
			_tool = null
			return
		_tool = scene.instantiate()
		_tool.info = t
		_tool_layer.add_child(_tool)
		_tools[t.id] = _tool
	_tool.visible = true
	_tool.on_activated()

func center_content() -> void:
	camera_rig.center_on(_focus_box())


func _focus_box() -> AABB:
	if not State.selection.is_empty():
		var b := AABB()
		for c in State.selection.cells:
			var cb := AABB(Vector3(c), Vector3.ONE)
			b = cb if not b.has_volume() else b.merge(cb)
		return b
	return State.document.bounds()


@warning_ignore("shadowed_variable_base_class")
func set_view(name: String) -> void:
	camera_rig.set_view(name)


func set_projection(orthogonal: bool) -> void:
	camera_rig.set_projection(orthogonal)


func is_orthogonal() -> bool:
	return camera_rig.is_orthogonal()


func set_unshaded(on: bool) -> void:
	var vp: SubViewport = %Viewport
	vp.debug_draw = Viewport.DEBUG_DRAW_UNSHADED if on else Viewport.DEBUG_DRAW_DISABLED


func is_unshaded() -> bool:
	var vp: SubViewport = %Viewport
	return vp.debug_draw == Viewport.DEBUG_DRAW_UNSHADED


func set_zoom_percent(percent: float) -> void:
	camera_rig.set_zoom_percent(percent)


func set_grid_visible(v: bool) -> void:
	_grid.visible = v
	grid_changed.emit(v)


func toggle_grid() -> void:
	set_grid_visible(not _grid.visible)


func sync_to(frame: int) -> void:
	_voxels.sync_to(frame)


func play_preview() -> void:
	_playback.play_preview()


func stop_preview() -> void:
	_playback.stop_preview()


func is_playing() -> bool:
	return _playback.is_playing()


func pick_request(pos: Vector2) -> PickRequest:
	var req := PickRequest.new()
	var d := State.document
	var cam := camera_rig.camera()
	if cam == null or d == null:
		return req
	var fi := clampi(State.current_frame, 0, d.frames.size() - 1)
	req.origin = cam.project_ray_origin(pos)
	req.dir = cam.project_ray_normal(pos)
	req.cells = d.frames[fi].cells
	req.forward = -cam.basis.z
	return req
