extends ColorRect

## Darkens the scene outside the document size.
##
## The viewport projects the eight box corners and sends their convex hull to
## the shader. The shader rejects the pixels inside that hull. The mask follows
## the box in every view and needs no depth texture.

## The low corner of the document box.
var box_min := Vector3.ZERO
## The high corner of the document box.
var box_max := Vector3.ZERO
## The projected box hull in viewport UV space.
var hull := PackedVector2Array()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	refresh()


func _process(_delta: float) -> void:
	refresh()


## Updates the shader uniforms from the live camera and document size.
func refresh() -> void:
	var camera := get_viewport().get_camera_3d()
	var document := State.document
	visible = camera != null and document != null and document.has_size()
	if not visible:
		return
	var bounds := document.workspace_bounds()
	if bounds.has_point(camera.global_position):
		# The camera is inside the box, so the whole view is inside.
		visible = false
		return
	box_min = bounds.position
	box_max = bounds.end
	hull = _projected_hull(camera, bounds)
	var shader_material := material as ShaderMaterial
	if shader_material == null:
		return
	var points := PackedVector2Array()
	points.resize(8)
	for index in hull.size():
		points[index] = hull[index]
	shader_material.set_shader_parameter("hull", points)
	shader_material.set_shader_parameter("hull_count", hull.size())


func _projected_hull(camera: Camera3D, bounds: AABB) -> PackedVector2Array:
	if bounds.has_point(camera.global_position):
		return PackedVector2Array()
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return PackedVector2Array()
	var points: Array[Vector2] = []
	for index in 8:
		var corner := bounds.position + Vector3(
			bounds.size.x if index & 1 else 0.0,
			bounds.size.y if index & 2 else 0.0,
			bounds.size.z if index & 4 else 0.0,
		)
		if camera.is_position_behind(corner):
			continue
		var screen := camera.unproject_position(corner)
		points.append(Vector2(screen.x / viewport_size.x, screen.y / viewport_size.y))
	return _convex_hull(points)


static func _convex_hull(points: Array[Vector2]) -> PackedVector2Array:
	if points.size() < 3:
		return PackedVector2Array()
	points.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		return a.x < b.x if a.x != b.x else a.y < b.y
	)
	var lower := PackedVector2Array()
	for point in points:
		while lower.size() >= 2 and _cross(lower[lower.size() - 2], lower[lower.size() - 1], point) <= 0.0:
			lower.remove_at(lower.size() - 1)
		lower.append(point)
	var upper := PackedVector2Array()
	for index in range(points.size() - 1, -1, -1):
		var point: Vector2 = points[index]
		while upper.size() >= 2 and _cross(upper[upper.size() - 2], upper[upper.size() - 1], point) <= 0.0:
			upper.remove_at(upper.size() - 1)
		upper.append(point)
	lower.remove_at(lower.size() - 1)
	upper.remove_at(upper.size() - 1)
	lower.append_array(upper)
	return lower


static func _cross(a: Vector2, b: Vector2, c: Vector2) -> float:
	return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
