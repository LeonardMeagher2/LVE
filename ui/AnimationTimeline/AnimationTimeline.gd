extends VBoxContainer


const PLAY_ICON := preload("res://icons/play.svg")
const PAUSE_ICON := preload("res://icons/pause.svg")
const ANIMATION_FRAME = preload("uid://c2301xo3rbrka")
const RANGE_CELL = preload("res://ui/AnimationTimeline/RangeCell.tscn")

var _has_tag_row := false

@export var playback_bottom := false

func _ready() -> void:
	if playback_bottom:
		_place_playback_bottom()
	State.is_playing_toggled.connect(_on_is_playing_toggled)
	State.frames_changed.connect(_rebuild_strip)
	State.tag_changed.connect(_on_tag_changed)
	_rebuild_strip()
	_on_tag_changed()

func _place_playback_bottom() -> void:
	var bar: HBoxContainer = $HBoxContainer
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	var spacer: Control = bar.get_node("VSeparator2")
	spacer.hide()
	var row := HBoxContainer.new()
	row.name = "PlaybackRow"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(row)
	bar.get_node("Playback").reparent(row)
	var playback: Control = row.get_node("Playback")
	playback.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for child in playback.get_children():
		if child is Control:
			(child as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tag_row: Control = bar.get_node("TagRow")
	tag_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _rebuild_strip() -> void:
	for cell in %FrameGrid.get_children():
		%FrameGrid.remove_child(cell)
		cell.queue_free()
	var n := State.document.frames.size()
	%FrameGrid.columns = n
	_has_tag_row = State.get_active_tag() != null
	if _has_tag_row:
		for i in n:
			var range_cell = RANGE_CELL.instantiate()
			range_cell.set_column_index(i)
			range_cell.grid = %FrameGrid
			%FrameGrid.add_child(range_cell)
	for i in n:
		var frame: AnimationFrame = ANIMATION_FRAME.instantiate()
		frame.frame_index = i
		%FrameGrid.add_child(frame)

func _on_is_playing_toggled(toggled_on: bool) -> void:
	%Play.icon = PAUSE_ICON if toggled_on else PLAY_ICON
	%Play.tooltip_text = "Pause" if toggled_on else "Play"
	%Play.set_pressed_no_signal(toggled_on)

func _on_tag_changed() -> void:
	_sync_range_row()

func _sync_range_row() -> void:
	var has_row := State.get_active_tag() != null
	if has_row != _has_tag_row:
		_rebuild_strip()

func _on_prev_pressed() -> void:
	State.prev_frame()
	_focus_current_frame()


func _on_next_pressed() -> void:
	State.next_frame()
	_focus_current_frame()


func _on_to_start_pressed() -> void:
	State.to_start()
	_focus_current_frame()


func _on_to_end_pressed() -> void:
	State.to_end()
	_focus_current_frame()


func _focus_current_frame() -> void:
	var offset := State.document.frames.size() if _has_tag_row else 0
	var index := offset + State.current_frame
	if index < 0 or index >= %FrameGrid.get_child_count():
		return
	var cell := %FrameGrid.get_child(index) as AnimationFrame
	if cell:
		cell.get_node("%Button").grab_focus()


func _on_frame_add() -> void:
	State.add_frame()


func _on_frame_dup() -> void:
	State.duplicate_frame()


func _on_frame_del() -> void:
	State.delete_frame()


func _on_play_toggled(toggled_on: bool) -> void:
	State.is_playing = toggled_on
