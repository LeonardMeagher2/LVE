extends VBoxContainer

const PLAY_ICON := preload("res://icons/play.svg")
const PAUSE_ICON := preload("res://icons/pause.svg")
const ANIMATION_FRAME = preload("uid://c2301xo3rbrka")

var _frame_queue:Array[WeakRef] = []

func _ready() -> void:
	State.is_playing_toggled.connect(_on_is_playing_toggled)
	State.frames_changed.connect(_rebuild_strip)
	State.cells_changed.connect(_on_cells_changed)
	_rebuild_strip()

func _queue_frame_render(frame:AnimationFrame) -> void:
	_frame_queue.append(weakref(frame))
	if _frame_queue.size() == 1:
		_process_frame_queue.call_deferred()
		
func _process_frame_queue() -> void:
	if _frame_queue.is_empty():
		return
	var animation_frame:AnimationFrame = _frame_queue.pop_front().get_ref()
	if not animation_frame:
		_process_frame_queue()
		return
	
	var voxel_renderer:VoxelRenderer = %FrameRendererViewport.get_node("%VoxelRenderer")
	voxel_renderer.frame = animation_frame.get_index()
	%FrameRendererViewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var image:Image = %FrameRendererViewport.get_texture().get_image()
	var texture := ImageTexture.create_from_image(image)
	animation_frame.texture = texture
	%FrameRendererViewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_process_frame_queue()

func _rebuild_strip() -> void:
	for frame in %FrameStrip.get_children():
		%FrameStrip.remove_child(frame)
		frame.queue_free()
	
	for i in State.document.frames.size():
		var frame: AnimationFrame = ANIMATION_FRAME.instantiate()
		%FrameStrip.add_child(frame)
		_queue_frame_render(frame)

func _on_cells_changed(frame: int, _affected: Array[Vector3i]) -> void:
	if %FrameStrip.get_child_count() <= frame:
		return
	var animation_frame:AnimationFrame = %FrameStrip.get_child(frame)
	_queue_frame_render(animation_frame)

func _on_is_playing_toggled(toggled_on: bool) -> void:
	%Play.icon = PAUSE_ICON if toggled_on else PLAY_ICON
	%Play.tooltip_text = "Pause" if toggled_on else "Play"
	%Play.set_pressed_no_signal(toggled_on)

func _on_prev_pressed() -> void:
	State.prev_frame()


func _on_next_pressed() -> void:
	State.next_frame()


func _on_to_start_pressed() -> void:
	State.to_start()


func _on_to_end_pressed() -> void:
	State.to_end()


func _on_frame_add() -> void:
	State.add_frame()


func _on_frame_dup() -> void:
	State.duplicate_frame()


func _on_frame_del() -> void:
	State.delete_frame()


func _on_play_toggled(toggled_on: bool) -> void:
	State.is_playing = toggled_on
