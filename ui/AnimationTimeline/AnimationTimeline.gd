extends VBoxContainer


const PLAY_ICON := preload("res://icons/play.svg")
const PAUSE_ICON := preload("res://icons/pause.svg")
const ANIMATION_FRAME = preload("uid://c2301xo3rbrka")
const RANGE_CELL = preload("res://ui/AnimationTimeline/RangeCell.tscn")
const CEL_CELL = preload("res://ui/AnimationTimeline/CelCell.tscn")
const LAYER_HEADER = preload("res://ui/AnimationTimeline/LayerHeaderCell.tscn")

var _has_tag_row := false
var _frame_cells: Array[AnimationFrame] = []
var _cel_cells := {}
var _layer_headers := {}
var _active_cel_key := Vector2i(-1, -1)
var _active_layer := -1
var _rename_layer_index := -1
var _syncing_scroll := false

@export var playback_bottom := false

func _ready() -> void:
	if playback_bottom:
		_place_playback_bottom()
	%LayerRenameDialog.about_to_popup.connect(_on_layer_rename_about_to_popup)
	%LayerToolbar.rename_requested.connect(_open_layer_rename)
	%LayerScroll.get_v_scroll_bar().value_changed.connect(_sync_from_layer_scroll)
	%CelScroll.get_v_scroll_bar().value_changed.connect(_sync_from_cel_scroll)
	%CelScroll.get_h_scroll_bar().value_changed.connect(_sync_from_cel_horizontal)
	%HeaderScroll.get_h_scroll_bar().value_changed.connect(_sync_from_header_scroll)
	State.is_playing_toggled.connect(_on_is_playing_toggled)
	State.frames_changed.connect(_rebuild_strip)
	State.layers_changed.connect(_rebuild_strip)
	State.document_changed.connect(_rebuild_strip)
	State.active_layer_changed.connect(_sync_active_cel)
	State.frame_changed.connect(_sync_active_cel)
	State.cells_changed.connect(_on_cells_changed)
	State.chunks_changed.connect(_on_cells_changed)
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
	var horizontal: int = %CelScroll.scroll_horizontal
	var vertical: int = %CelScroll.scroll_vertical
	_clear_children(%FrameGrid)
	_clear_children(%LayerColumn)
	_clear_children(%CelGrid)
	_frame_cells.clear()
	_cel_cells.clear()
	_layer_headers.clear()
	_active_cel_key = Vector2i(-1, -1)
	_active_layer = -1
	var n := State.get_frame_count()
	%FrameGrid.columns = n
	%CelGrid.columns = n
	_has_tag_row = State.get_active_tag() != null
	if _has_tag_row:
		for i in n:
			var range_cell := RANGE_CELL.instantiate()
			range_cell.set_column_index(i)
			range_cell.column_offset = 0
			range_cell.grid = %FrameGrid
			%FrameGrid.add_child(range_cell)
	for i in n:
		var frame: AnimationFrame = ANIMATION_FRAME.instantiate()
		frame.frame_index = i
		%FrameGrid.add_child(frame)
		_frame_cells.append(frame)
	var layer_group := ButtonGroup.new()
	var cel_group := ButtonGroup.new()
	for row in range(State.document.layers.size() - 1, -1, -1):
		var layer: VoxelLayer = State.document.layers[row]
		var header: LayerHeaderCell = LAYER_HEADER.instantiate()
		header.rename_requested.connect(_open_layer_rename)
		%LayerColumn.add_child(header)
		header.setup(row, layer, layer_group)
		_layer_headers[row] = header
		for i in n:
			var cel: CelCell = CEL_CELL.instantiate()
			%CelGrid.add_child(cel)
			cel.setup(row, i, layer.name, cel_group)
			if not layer.visible:
				cel.modulate = Color(1, 1, 1, 0.55)
			_cel_cells[Vector2i(row, i)] = cel
	_sync_active_cel()
	_restore_scroll.call_deferred(horizontal, vertical)


func _clear_children(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _open_layer_rename(index: int) -> void:
	if index < 0 or index >= State.document.layers.size():
		return
	_rename_layer_index = index
	%LayerRenameDialog.popup_centered()


func _on_layer_rename_about_to_popup() -> void:
	if _rename_layer_index < 0 or _rename_layer_index >= State.document.layers.size():
		return
	%LayerRenameInput.text = State.document.layers[_rename_layer_index].name
	%LayerRenameInput.select_all()


func _on_layer_rename_confirmed() -> void:
	var index := _rename_layer_index
	_rename_layer_index = -1
	if index < 0 or index >= State.document.layers.size():
		return
	var new_name: String = %LayerRenameInput.text.strip_edges()
	if new_name.is_empty():
		return
	State.rename_layer(index, new_name)


func _restore_scroll(horizontal: int, vertical: int) -> void:
	_syncing_scroll = true
	%CelScroll.scroll_horizontal = horizontal
	%CelScroll.scroll_vertical = vertical
	%HeaderScroll.scroll_horizontal = horizontal
	%LayerScroll.scroll_vertical = vertical
	_syncing_scroll = false


func _sync_from_layer_scroll(value: float) -> void:
	if _syncing_scroll:
		return
	_syncing_scroll = true
	%CelScroll.scroll_vertical = int(value)
	_syncing_scroll = false


func _sync_from_cel_scroll(value: float) -> void:
	if _syncing_scroll:
		return
	_syncing_scroll = true
	%LayerScroll.scroll_vertical = int(value)
	_syncing_scroll = false


func _sync_from_cel_horizontal(value: float) -> void:
	if _syncing_scroll:
		return
	_syncing_scroll = true
	%HeaderScroll.scroll_horizontal = int(value)
	_syncing_scroll = false


func _sync_from_header_scroll(value: float) -> void:
	if _syncing_scroll:
		return
	_syncing_scroll = true
	%CelScroll.scroll_horizontal = int(value)
	_syncing_scroll = false


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

func _on_cells_changed(layer: int, frame: int, affected: Array[Vector3i]) -> void:
	if affected.is_empty():
		for key: Vector2i in _cel_cells:
			if key.y == frame:
				_cel_cells[key].refresh_filled()
		return
	var key := Vector2i(layer, frame)
	if _cel_cells.has(key):
		_cel_cells[key].refresh_filled()


func _sync_active_cel() -> void:
	var next := Vector2i(State.active_layer_index, State.current_frame)
	if next != _active_cel_key:
		if _cel_cells.has(_active_cel_key):
			_cel_cells[_active_cel_key].set_active(false)
		_active_cel_key = next
		if _cel_cells.has(next):
			_cel_cells[next].set_active(true)
	if State.active_layer_index != _active_layer:
		if _layer_headers.has(_active_layer):
			_layer_headers[_active_layer].set_active(false)
		_active_layer = State.active_layer_index
		if _layer_headers.has(_active_layer):
			_layer_headers[_active_layer].set_active(true)


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
	if State.current_frame < 0 or State.current_frame >= _frame_cells.size():
		return
	var cell := _frame_cells[State.current_frame]
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
