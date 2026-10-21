extends "res://plugins/brush/BrushPreview.gd"

## A test-only probe for the spray latency benchmark.
##
## It counts the cursor requests, the visible mesh installs, and the completed
## results that the latest-only request policy discards. It changes no behavior.
##
## A discard is a result the worker finished and the main thread threw away
## because a newer request arrived first. A high discard count with a low install
## count is the visible starvation of the cursor.

## The cursor requests since the last reset.
var request_calls := 0
## The visible mesh installs since the last reset.
var installs := 0
## The completed results that a newer request superseded.
var discards := 0
## The microseconds of the last request.
var request_us := 0
## The microseconds of the last brush material update.
var material_us := 0
## The microseconds of the last show_voxels call, including its request.
var show_us := 0
## The microseconds of the last install or discard.
var finish_us := 0
## The microseconds of the longest install.
var install_max_us := 0


## Clears the counters. It does not change the cursor state.
func reset_probe() -> void:
	request_calls = 0
	installs = 0
	discards = 0
	request_us = 0
	material_us = 0
	show_us = 0
	finish_us = 0
	install_max_us = 0


func set_brush_material(cell_material: PackedFloat32Array) -> void:
	var started := Time.get_ticks_usec()
	super.set_brush_material(cell_material)
	material_us = Time.get_ticks_usec() - started


func show_voxels(colors: Dictionary, color: Color, outline: bool = false, cube_diameter: int = 0, use_voxel_colors: bool = true) -> void:
	var started := Time.get_ticks_usec()
	super.show_voxels(colors, color, outline, cube_diameter, use_voxel_colors)
	show_us = Time.get_ticks_usec() - started


func _request(cells: Dictionary, style: PreviewStyle, use_voxel_colors: bool = false, color_key: Color = Color.WHITE) -> void:
	var started := Time.get_ticks_usec()
	super._request(cells, style, use_voxel_colors, color_key)
	request_us = Time.get_ticks_usec() - started
	request_calls += 1


func _finish_preview() -> void:
	var before := mesh_id()
	var started := Time.get_ticks_usec()
	super._finish_preview()
	finish_us = Time.get_ticks_usec() - started
	if mesh_id() != before:
		installs += 1
		install_max_us = maxi(install_max_us, finish_us)
	else:
		discards += 1


## Returns the instance id of the shown mesh, or zero when the cursor is empty.
func mesh_id() -> int:
	if mesh == null:
		return 0
	return mesh.get_instance_id()
