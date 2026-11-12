extends ConfirmationDialog

## Edits the document settings.
##
## The modal holds the normals mode and the centered document size.
## A size of zero on an axis means that axis is infinite. Changes preview live
## and commit as one history action when the user confirms.

@onready var _flat: Button = $Margin/Layout/NormalsRow/Flat
@onready var _smooth: Button = $Margin/Layout/NormalsRow/Smooth
@onready var _ao = $Margin/Layout/AoRow/AO
@onready var _size_x: SpinBox = $Margin/Layout/SizeRow/SizeX
@onready var _size_y: SpinBox = $Margin/Layout/SizeRow/SizeY
@onready var _size_z: SpinBox = $Margin/Layout/SizeRow/SizeZ
@onready var _fit: Button = $Margin/Layout/SizeRow/Fit

var _before_smooth := false
var _before_ao := 1.0
var _before_size := Vector3i.ZERO
var _syncing := false


func _ready() -> void:
	_flat.toggled.connect(_on_normals_toggled)
	_smooth.toggled.connect(_on_normals_toggled)
	_ao.value_changed.connect(_on_ao_changed)
	_size_x.value_changed.connect(_on_size_changed)
	_size_y.value_changed.connect(_on_size_changed)
	_size_z.value_changed.connect(_on_size_changed)
	_fit.pressed.connect(_on_fit_pressed)
	confirmed.connect(_on_confirmed)
	canceled.connect(_on_canceled)


## Shows the modal with the current values.
func open(current_size: Vector3i, smooth_normals: bool, ao_strength := 1.0) -> void:
	_before_smooth = smooth_normals
	_before_ao = ao_strength
	_before_size = current_size
	_syncing = true
	_flat.set_pressed_no_signal(not smooth_normals)
	_smooth.set_pressed_no_signal(smooth_normals)
	_ao.set_value_no_signal(ao_strength)
	_size_x.set_value_no_signal(current_size.x)
	_size_y.set_value_no_signal(current_size.y)
	_size_z.set_value_no_signal(current_size.z)
	_syncing = false
	_fit.disabled = not State.document.bounds().has_volume()
	popup_centered()


func _on_normals_toggled(_pressed: bool) -> void:
	_apply_preview()


func _on_ao_changed(_value: float) -> void:
	_apply_preview()


func _on_size_changed(_value: float) -> void:
	_apply_preview()


func _apply_preview() -> void:
	if _syncing:
		return
	State.set_document_properties(_smooth.button_pressed, _current_size(), false)
	State.set_ao_strength(_ao.value, false)


func _on_confirmed() -> void:
	State.commit_document_settings(_before_smooth, _before_size, _before_ao)


func _on_canceled() -> void:
	_syncing = true
	State.set_document_properties(_before_smooth, _before_size, false)
	State.set_ao_strength(_before_ao, false)
	_syncing = false


func _on_fit_pressed() -> void:
	var size := _fitted_size()
	if size == Vector3i.ZERO:
		return
	_syncing = true
	_size_x.set_value_no_signal(size.x)
	_size_y.set_value_no_signal(size.y)
	_size_z.set_value_no_signal(size.z)
	_syncing = false
	_apply_preview()


func _fitted_size() -> Vector3i:
	var bounds := State.document.bounds()
	if not bounds.has_volume():
		return Vector3i.ZERO
	var min_cell := Vector3i(bounds.position + Vector3.ONE * 0.5)
	var max_cell := Vector3i(bounds.end + Vector3.ONE * 0.5)
	var size := Vector3i.ZERO
	for axis in 3:
		var low := maxi(0, -min_cell[axis])
		var high := maxi(0, max_cell[axis])
		size[axis] = mini(VoxelDocument.MAX_DOCUMENT_SIZE, maxi(low * 2, high * 2 - 1))
	return size


func _current_size() -> Vector3i:
	return Vector3i(roundi(_size_x.value), roundi(_size_y.value), roundi(_size_z.value))
