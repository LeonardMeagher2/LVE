class_name LayerToolbarCell
extends HBoxContainer


signal rename_requested(index: int)

const ACTION_RENAME := 0
const ACTION_MERGE := 1
const ACTION_MOVE_BASE := 100

var _targets := {}

@onready var _delete: Button = %Delete
@onready var _more: MenuButton = %More
@onready var _menu: PopupMenu = _more.get_popup()


func _ready() -> void:
	%Add.pressed.connect(_on_add)
	%Duplicate.pressed.connect(_on_duplicate)
	_delete.pressed.connect(_on_delete)
	_menu.about_to_popup.connect(_rebuild_menu)
	_menu.id_pressed.connect(_on_menu)
	State.active_layer_changed.connect(_sync)
	_sync()


func _sync() -> void:
	var active := State.document.active_layer()
	_delete.disabled = State.document.layers.size() <= 1 or (active != null and active.locked)


func _on_add() -> void:
	State.add_layer()


func _on_duplicate() -> void:
	State.duplicate_layer(State.active_layer_index)


func _on_delete() -> void:
	State.delete_layer(State.active_layer_index)


func _rebuild_menu() -> void:
	_menu.clear()
	_targets.clear()
	var active_index := State.active_layer_index
	var active := State.document.active_layer()
	_menu.add_item("Rename Layer", ACTION_RENAME)
	_menu.add_item("Merge Down", ACTION_MERGE)
	var merge_disabled := active_index <= 0 or active == null or active.locked or State.document.layers[active_index - 1].locked
	_menu.set_item_disabled(_menu.get_item_index(ACTION_MERGE), merge_disabled)
	_menu.add_separator()
	var can_move := active != null and active.visible and not active.locked
	var next_id := ACTION_MOVE_BASE
	for index in State.document.layers.size():
		if index == active_index:
			continue
		var layer: VoxelLayer = State.document.layers[index]
		if not layer.visible:
			continue
		_menu.add_item("Move Selection to %s" % layer.name, next_id)
		var item := _menu.get_item_index(next_id)
		_menu.set_item_disabled(item, not can_move or layer.locked)
		_targets[next_id] = index
		next_id += 1
	if _targets.is_empty():
		_menu.add_item("No other layer", ACTION_MOVE_BASE)
		_menu.set_item_disabled(_menu.get_item_index(ACTION_MOVE_BASE), true)


func _on_menu(id: int) -> void:
	match id:
		ACTION_RENAME:
			rename_requested.emit(State.active_layer_index)
		ACTION_MERGE:
			State.merge_layer_down(State.active_layer_index)
		_:
			if _targets.has(id):
				State.move_selection_to_layer(_targets[id])
