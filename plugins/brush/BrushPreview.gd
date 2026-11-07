extends "res://Globals/Rendering/VoxelPreview.gd"

## A brush cursor that mirrors its preview through the symmetry axes.
##
## The preview duplicates its mesh for each active symmetry mask.

## Whether the preview shows the symmetry mirrors.
@export var apply_edit_symmetry := false
var _mirrors: Array[MeshInstance3D] = []
# The mirror transform has a negative scale, so the mesh normal points inward.
# This copy of the lit material flips the normal back for the lighting.
var _mirror_lit_material: ShaderMaterial


func _ready() -> void:
	material_override = preload("res://plugins/cursor_material.tres").duplicate()
	super._ready()
	_mirror_lit_material = _lit_material.duplicate()
	_mirror_lit_material.set_shader_parameter("flip_normal", true)
	_mirror_lit_material.set_shader_parameter("flip_front", true)
	if apply_edit_symmetry:
		_solid_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_primitive_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		for mask in range(1, 8):
			var mirror := MeshInstance3D.new()
			mirror.name = "Mirror%s" % mask
			mirror.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mirror)
			_mirrors.append(mirror)


# Keeps the mirrored lit material in step with the main one.
func _sync_lit_material(carrier: StandardMaterial3D) -> void:
	super._sync_lit_material(carrier)
	if _mirror_lit_material != null:
		for parameter in ["cursor_color", "emission_color", "metallic", "roughness", "use_vertex_color"]:
			_mirror_lit_material.set_shader_parameter(parameter, _lit_material.get_shader_parameter(parameter))


func _process(delta: float) -> void:
	super._process(delta)
	for index in _mirrors.size():
		var mask := index + 1
		var mirror := _mirrors[index]
		mirror.visible = visible and mesh != null and (mask & ~State.symmetry_axes) == 0
		if mirror.visible:
			mirror.mesh = mesh
			mirror.material_override = _mirror_lit_material if material_override == _lit_material else material_override
			mirror.global_transform = State.symmetry_transform(mask, State.symmetry_origin) * global_transform
