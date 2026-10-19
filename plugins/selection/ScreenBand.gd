extends Line2D

# Draw the screen selection shape over the viewport with marching ants.
# The ants material marches the dashes along UV.x, which runs along the line.

func _ready() -> void:
	visible = false


func show_rectangle(rectangle: Rect2) -> void:
	points = PackedVector2Array([
		rectangle.position,
		Vector2(rectangle.end.x, rectangle.position.y),
		rectangle.end,
		Vector2(rectangle.position.x, rectangle.end.y),
	])
	closed = true
	visible = true


func show_polygon(sampled: PackedVector2Array) -> void:
	points = sampled
	closed = true
	visible = sampled.size() >= 2


func hide_band() -> void:
	points = PackedVector2Array()
	closed = false
	visible = false
