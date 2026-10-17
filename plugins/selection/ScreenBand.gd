extends Control

# Draw the screen selection shape over the viewport.

const BORDER_COLOR := Color(0.0, 0.0, 0.0, 0.85)
const BORDER_WIDTH := 3.0
const INNER_COLOR := Color(1.0, 1.0, 1.0, 1.0)
const INNER_WIDTH := 1.0

var _rectangle := Rect2()
var _polygon := PackedVector2Array()
var _closed := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


func show_rectangle(rectangle: Rect2) -> void:
	_rectangle = rectangle
	_polygon = PackedVector2Array()
	_closed = false
	visible = true
	queue_redraw()


func show_polygon(points: PackedVector2Array) -> void:
	_polygon = points
	_closed = true
	visible = points.size() >= 2
	queue_redraw()


func hide_band() -> void:
	_rectangle = Rect2()
	_polygon = PackedVector2Array()
	_closed = false
	visible = false
	queue_redraw()


func _draw() -> void:
	var points := _outline()
	if points.size() < 2:
		return
	draw_polyline(points, BORDER_COLOR, BORDER_WIDTH)
	draw_polyline(points, INNER_COLOR, INNER_WIDTH)


func _outline() -> PackedVector2Array:
	if _closed:
		var closed := _polygon.duplicate()
		if closed.size() >= 2:
			closed.append(closed[0])
		return closed
	if _rectangle.size.x <= 0.0 and _rectangle.size.y <= 0.0:
		return PackedVector2Array()
	var near_corner := _rectangle.position
	var far_corner := _rectangle.end
	return PackedVector2Array([
		near_corner,
		Vector2(far_corner.x, near_corner.y),
		far_corner,
		Vector2(near_corner.x, far_corner.y),
		near_corner,
	])
