extends VBoxContainer

## The animation timeline strip.
##
## It shows one cell per frame and a tag range row. The strip follows the frame
## list and the active tag.

const PLAY_ICON := preload("res://icons/play.svg")
const PAUSE_ICON := preload("res://icons/pause.svg")
const ANIMATION_FRAME = preload("uid://c2301xo3rbrka")
const RANGE_CELL = preload("res://ui/AnimationTimeline/RangeCell.tscn")

var _has_tag_row := false

func _ready() -> void:
	State.is_playing_toggled.connect(_on_is_playing_toggled)
	State.frames_changed.connect(_rebuild_strip)
	State.tag_changed.connect(_on_tag_changed)
	_rebuild_strip()
	_on_tag_changed()

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
