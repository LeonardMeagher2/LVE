class_name ScreenSelection
extends RefCounted

# Screen selection tests each cell against a shape on the screen.
# Every cell inside the shape joins the region, including hidden voxels.
# The frame bounds limit the empty cells. A subtract also tests the selected
# cells, so empty selected cells can leave without the empty cell option.
# The mode values match SelectionToolSettings.SelectMode.

const REPLACE_MODE := 0
const SUBTRACT_MODE := 2


# The job captures the camera and the shape. It reads no scene node.
class Job extends VoxelFrame.EditJob:
	var source_frame: VoxelFrame
	var view_matrix := Transform3D()
	var projection := Projection()
	var viewport_size := Vector2.ZERO
	var rectangle := Rect2()
	var polygon := PackedVector2Array()
	var mode := REPLACE_MODE
	var previous_selection := {}
	var include_empty := false
	var empty_min := Vector3i.ZERO
	var empty_max := Vector3i(-1, -1, -1)
	var result := {}

	func empty_cell_count() -> int:
		if not include_empty:
			return 0
		return (empty_max.x - empty_min.x + 1) * (empty_max.y - empty_min.y + 1) * (empty_max.z - empty_min.z + 1)

	func run() -> void:
		var total: int = source_frame.count() + empty_cell_count()
		if mode == SUBTRACT_MODE:
			total += previous_selection.size()
		stage("Projecting voxels", estimate_work(total))
		var region := {}
		var completed := 0
		for chunk in source_frame.chunks.values():
			for cell_position in chunk.world_cells():
				if _covers(cell_position):
					region[cell_position] = true
				completed += 1
				if completed % 4096 == 0 and not checkpoint(completed):
					return
		if include_empty:
			for x in range(empty_min.x, empty_max.x + 1):
				for y in range(empty_min.y, empty_max.y + 1):
					for z in range(empty_min.z, empty_max.z + 1):
						var cell_position := Vector3i(x, y, z)
						if not source_frame.has(cell_position) and _covers(cell_position):
							region[cell_position] = true
						completed += 1
						if completed % 4096 == 0 and not checkpoint(completed):
							return
		if mode == SUBTRACT_MODE:
			for cell_position in previous_selection:
				if not region.has(cell_position) and _covers(cell_position):
					region[cell_position] = true
				completed += 1
				if completed % 4096 == 0 and not checkpoint(completed):
					return
		if edit_context:
			region = edit_context.expand(region, source_frame, false, null, self)
		if not checkpoint(completed):
			return
		stage("Applying the selection mode", region.size())
		result = {} if mode == REPLACE_MODE else previous_selection.duplicate()
		completed = 0
		for cell_position in region:
			if mode == SUBTRACT_MODE:
				result.erase(cell_position)
			else:
				result[cell_position] = true
			completed += 1
			if completed % 4096 == 0 and not checkpoint(completed):
				return

	func _covers(cell_position: Vector3i) -> bool:
		var screen_point := ScreenSelection.project(view_matrix, projection, viewport_size, Vector3(cell_position))
		if screen_point == Vector2.INF:
			return false
		if polygon.size() >= 3:
			return ScreenSelection.point_in_polygon(screen_point, polygon)
		return rectangle.has_point(screen_point)


# Return the viewport position of a world point. Return Vector2.INF behind the camera.
static func project(view_matrix: Transform3D, projection: Projection, viewport_size: Vector2, world_point: Vector3) -> Vector2:
	var view_point: Vector3 = view_matrix * world_point
	if view_point.z > 0.0:
		return Vector2.INF
	var clip := projection * Vector4(view_point.x, view_point.y, view_point.z, 1.0)
	if is_zero_approx(clip.w):
		return Vector2.INF
	var normalized := Vector3(clip.x, clip.y, clip.z) / clip.w
	return Vector2((normalized.x * 0.5 + 0.5) * viewport_size.x, (-normalized.y * 0.5 + 0.5) * viewport_size.y)


# Capture the values that the worker needs to project a cell center.
static func view_of(camera: Camera3D, viewport_size: Vector2) -> Array:
	if camera == null:
		return []
	return [camera.global_transform.affine_inverse(), camera.get_camera_projection(), viewport_size]


static func point_in_polygon(point: Vector2, polygon: PackedVector2Array) -> bool:
	var inside := false
	var previous := polygon.size() - 1
	for index in polygon.size():
		var start := polygon[index]
		var end := polygon[previous]
		if (start.y > point.y) != (end.y > point.y):
			var cross: float = (end.x - start.x) * (point.y - start.y) / (end.y - start.y) + start.x
			if point.x < cross:
				inside = not inside
		previous = index
	return inside
