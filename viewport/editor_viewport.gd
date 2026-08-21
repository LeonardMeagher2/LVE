class_name EditorViewport
extends Node3D

signal zoom_changed(percent: float)
signal grid_changed(visible: bool)
signal frame_displayed(index: int)

var _tool: VoxelTool
var _tools := {}

@onready var camera_rig: EditorCameraRig = $CameraRig
@onready var _grid: GridRenderer = $GridRoot
@onready var _voxels: VoxelRenderer = $Voxels
@onready var _selection: SelectionOverlay = $SelectionLayer
@onready var _playback: PlaybackAnimator = $Playback
@onready var _tool_layer: Node3D = $ToolLayer

var frame_index := 0:
	set(value):
		frame_index = value
		if State.document != null and value >= 0 and value < State.document.frames.size():
			sync_to(value)
			frame_displayed.emit(value)


func _ready() -> void:
	($Light as DirectionalLight3D).rotation_degrees = Vector3(-50.0, -35.0, 0.0)
	camera_rig.zoom_changed.connect(zoom_changed.emit)


func set_tool(t: ToolInfo) -> void:
	if _tool != null:
		_tool.visible = false
		_tool.on_deactivated()
	if t == null or t.scene.is_empty():
		_tool = null
		return
	_tool = _tools.get(t.id)
	if _tool == null:
		var scene := load(t.scene)
		if scene == null:
			_tool = null
			return
		_tool = scene.instantiate()
		_tool.info = t
		_tool_layer.add_child(_tool)
		_tools[t.id] = _tool
	_tool.visible = true
	_tool.on_activated()


func configure() -> void:
	camera_rig.configure()
	_grid.rebuild()


func reset_view() -> void:
	camera_rig.reset_view()


func set_view(name: String) -> void:
	camera_rig.set_view(name)


func set_zoom_percent(percent: float) -> void:
	camera_rig.set_zoom_percent(percent)


func set_grid_visible(v: bool) -> void:
	_grid.visible = v
	grid_changed.emit(v)


func toggle_grid() -> void:
	set_grid_visible(not _grid.visible)


func sync_to(frame_index: int) -> void:
	_voxels.sync_to(frame_index)


func play_preview() -> void:
	_playback.play_preview()


func stop_preview() -> void:
	_playback.stop_preview()
	frame_index = State.current_frame


func is_playing() -> bool:
	return _playback.is_playing()


func pick_request(pos: Vector2) -> PickRequest:
	var req := PickRequest.new()
	var d := State.document
	var cam := camera_rig.camera()
	if cam == null or d == null:
		return req
	var fi := clampi(frame_index, 0, d.frames.size() - 1)
	req.origin = cam.project_ray_origin(pos)
	req.dir = cam.project_ray_normal(pos)
	req.cells = d.frames[fi].cells
	return req


func sync_selection(selection: VoxelSelection) -> void:
	_selection.sync_selection(selection)
