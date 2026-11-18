extends "res://plugins/paint/PaintBrushTool.gd"

## The dither painting brush.
##
## The tool recolors visible surface cells on a 4 by 4 by 4 Bayer order. The
## density runs from 0 through 1 and keeps that fraction of the surface cells in
## the brush footprint. The lowest Bayer thresholds win. The pattern starts at
## the first cell of the stroke, so a new stroke starts a fresh tile.
##
## The cursor shows only the surface cells that the stroke will write. Hidden
## cells inside the brush volume keep their material. The tool keeps the other
## paintbrush rules: a large stamp runs on the worker pool, and a stroke records
## one history action.

var _paint_settings: PaintToolSettings
var _stroke_density := 0.5
var _stroke_origin := VoxelPicking.NONE
var _stroke_origin_ready := false
var _preview_density := -1.0
var _preview_center := VoxelPicking.NONE
var _preview_frame: VoxelFrame


func _init() -> void:
	_paint_settings = preload("./PaintSettings.tres")
	_settings = _paint_settings


func open_stroke() -> VoxelEditTransaction:
	var tx := super.open_stroke()
	if tx != null:
		_stroke_density = _paint_settings.dither_density
		_stroke_origin = VoxelPicking.NONE
		_stroke_origin_ready = false
		_reset_preview_state()
	return tx


func _apply_pick(target: Vector3i, hit: Vector3i) -> void:
	if _edit != null and not _stroke_origin_ready and hit != VoxelPicking.NONE:
		_stroke_origin = hit
		_stroke_origin_ready = true
	super._apply_pick(target, hit)


func update_visual(pick: PickResult) -> void:
	var frame := _current_preview_frame()
	var density := _active_density()
	if not is_equal_approx(density, _preview_density) \
			or pick.target != _preview_center or frame != _preview_frame:
		_preview_density = density
		_preview_center = pick.target
		_preview_frame = frame
		# Rebuild the cursor for the new surface selection. A small surface
		# builds inline, so the new cells install in the same input frame.
		_cursor_axis = -1
	super.update_visual(pick)


func _cursor_pattern(pattern: Dictionary) -> Dictionary:
	var frame := _current_preview_frame()
	var origin := _current_origin()
	if pattern.is_empty() or frame == null or origin == VoxelPicking.NONE or _last_pick == null:
		return {}
	var filtered := DitherMask.filter_pattern(pattern, _last_pick.target, _active_density(), frame, origin)
	filtered.make_read_only()
	return filtered


func _cursor_cube_diameter() -> int:
	# The box mesh cannot show which cells the mask keeps.
	return 0


func _build_job() -> BrushJob:
	var job := super._build_job()
	# The density mask already keeps only exposed source cells. This tool keeps
	# its masked pattern and its mirror preview.
	job.surface_only = false
	job.dither_density = _stroke_density if _stroke_origin_ready else -1.0
	job.dither_origin = _stroke_origin if _stroke_origin_ready else Vector3i.ZERO
	return job


## Returns [code]false[/code] because the density mask shows its own mirrored
## pattern through the cursor nodes.
func _cursor_uses_world_cells() -> bool:
	return false


func _exit_tree() -> void:
	_stroke_origin = VoxelPicking.NONE
	_stroke_origin_ready = false
	_reset_preview_state()
	super._exit_tree()


func _reset_preview_state() -> void:
	_preview_density = -1.0
	_preview_center = VoxelPicking.NONE
	_preview_frame = null


func _current_origin() -> Vector3i:
	if _edit != null:
		return _stroke_origin if _stroke_origin_ready else VoxelPicking.NONE
	return _last_pick.target if _last_pick != null else VoxelPicking.NONE


func _active_density() -> float:
	return _stroke_density if _edit != null else _paint_settings.dither_density
