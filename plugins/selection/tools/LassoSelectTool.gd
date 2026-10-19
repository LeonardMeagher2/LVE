extends "./SelectTool.gd"

# The lasso tool selects the volume behind a dragged outline.
# The pointer path is sampled. The samples bound the polygon test.

const SCREEN_STEP := 6.0
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


func _append_point(pos: Vector2) -> void:
	if _points.size() >= SCREEN_POINT_LIMIT:
		return
	if not _points.is_empty() and _points[_points.size() - 1].distance_to(pos) < SCREEN_STEP:
		return
	_points.append(pos)
