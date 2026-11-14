extends "./SelectTool.gd"

## The lasso selection tool.
##
## It selects the volume behind a dragged screen outline. The pointer path is
## sampled. The samples bound the polygon test. A double click selects every
## voxel in the current frame.

# The lasso tool selects the volume behind a dragged outline.
# The pointer path is sampled. The samples bound the polygon test.

## The minimum distance between two sampled pointer points in pixels.
const SCREEN_STEP := 6.0
## The maximum sampled pointer point count.
const SCREEN_POINT_LIMIT := 512

var _points := PackedVector2Array()


func _begin_shape(pos: Vector2) -> void:
	_points = PackedVector2Array([pos])
	_show_band_polygon(_points)


func _update_shape(pos: Vector2) -> void:
	_append_point(pos)
	_show_band_polygon(_points)


func _commit_shape(pos: Vector2) -> void:
	_append_point(pos)
	if _points.size() >= 3:
		_commit_screen(Rect2(), _points)
		return
	_commit_screen(_screen_rectangle(pos), PackedVector2Array())


func _double_click(_pos: Vector2) -> bool:
	_select_all()
	return true


# A lasso click stays near the press point. A path that returns to its start is
# still a drag.
func _is_click(release_pos: Vector2) -> bool:
	if not super._is_click(release_pos):
		return false
	for point in _points:
		var travel := (point - _screen_press).abs()
		if travel.x >= CLICK_SIZE or travel.y >= CLICK_SIZE:
			return false
	return true


func _reset_shape() -> void:
	_points = PackedVector2Array()


func _append_point(pos: Vector2) -> void:
	# At the limit, halve the path instead of dropping the rest. A dropped tail
	# would close the outline short of the pointer.
	if _points.size() >= SCREEN_POINT_LIMIT:
		var thinned := PackedVector2Array()
		for index in range(0, _points.size(), 2):
			thinned.append(_points[index])
		_points = thinned
	if not _points.is_empty() and _points[_points.size() - 1].distance_to(pos) < SCREEN_STEP:
		return
	_points.append(pos)
