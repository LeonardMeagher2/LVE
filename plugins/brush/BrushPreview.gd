extends "res://plugins/selection/SelectionPreview.gd"

@export var apply_edit_symmetry := false
var _mirrors: Array[MeshInstance3D] = []


func _ready() -> void:
	material_override = preload("res://plugins/cursor_material.tres").duplicate()
	super._ready()
	if apply_edit_symmetry:
		_solid_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_box_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		for mask in range(1, 8):
			var mirror := MeshInstance3D.new()
			mirror.name = "Mirror%s" % mask
			mirror.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mirror)
			_mirrors.append(mirror)


func _process(delta: float) -> void:
	super._process(delta)
	for index in _mirrors.size():
		var mask := index + 1
		var mirror := _mirrors[index]
		mirror.visible = visible and mesh != null and (mask & ~State.symmetry_axes) == 0
		if mirror.visible:
			mirror.mesh = mesh
			mirror.material_override = material_override
			mirror.global_transform = State.symmetry_transform(mask, State.symmetry_origin) * global_transform
