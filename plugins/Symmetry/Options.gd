extends HBoxContainer

## The symmetry option bar.
##
## It toggles the mirror axes and edits the symmetry origin. The controls are
## disabled while an edit is busy.

func _ready() -> void:
	for axis in 3:
		get_node(["X", "Y", "Z"][axis]).toggled.connect(_on_axis_toggled.bind(axis))
		get_node(["OriginX", "OriginY", "OriginZ"][axis]).value_changed.connect(_on_origin_changed.bind(axis))
	State.symmetry_changed.connect(_sync)
	State.activity_changed.connect(_sync)
	$Center.pressed.connect(_center_origin)
	_sync()


func _sync() -> void:
	var busy := State.edit_busy()
	for axis in 3:
		var button: Button = get_node(["X", "Y", "Z"][axis])
		button.set_pressed_no_signal(bool(State.symmetry_axes & (1 << axis)))
		button.disabled = busy
		var control: SpinBox = get_node(["OriginX", "OriginY", "OriginZ"][axis])
		control.set_value_no_signal(State.symmetry_origin[axis])
		control.editable = not busy
	$Center.disabled = busy


func _on_axis_toggled(on: bool, axis: int) -> void:
	if on:
		State.symmetry_axes |= 1 << axis
	else:
		State.symmetry_axes &= ~(1 << axis)


func _on_origin_changed(value: float, axis: int) -> void:
	var origin := State.symmetry_origin
	origin[axis] = value
	State.symmetry_origin = origin


## Places the origin at the selection center, or the model center when the
## selection is empty.
func _center_origin() -> void:
	var bounds := _selection_bounds()
	if not bounds.has_volume():
		bounds = State.document.bounds()
	if not bounds.has_volume():
		bounds = State.document.workspace_bounds()
	State.symmetry_origin = bounds.get_center()


## Returns the box of the selected cells. An empty selection has no volume.
func _selection_bounds() -> AABB:
	var bounds := AABB()
	for cell in State.selection.all_cells():
		var cell_bounds := AABB(Vector3(cell) - Vector3.ONE * 0.5, Vector3.ONE)
		bounds = cell_bounds if not bounds.has_volume() else bounds.merge(cell_bounds)
	return bounds
