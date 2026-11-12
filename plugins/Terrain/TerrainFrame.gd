class_name TerrainFrame
extends RefCounted

## An oriented surface frame for the terrain tools.
##
## The frame holds a point on the surface, an outward unit normal, and an
## in-plane basis. A surface frame follows the local voxel surface. A frame that
## without a surface falls back to the clicked face or the floor plane.
##
## The tool samples the surface along the frame normal, so a surface frame makes
## the footprint follow a slope instead of a cube face.

## A point on the surface.
var origin := Vector3.ZERO
## The outward unit normal.
var normal := Vector3.UP
## The first in-plane unit direction.
var tangent_u := Vector3.RIGHT
## The second in-plane unit direction.
var tangent_v := Vector3.FORWARD
## The dominant axis of the normal.
var axis := 1
## The sign of the normal on its dominant axis.
var sign := 1
## Whether the plane follows the local surface. A false value is a fallback.
var follows_surface := false
## Whether the plane is the floor. A floor frame sits on the outer face of the
## first buildable layer, one cell above the grid that the user sees.
var on_floor := false


## Returns the frame of a clicked face.
static func from_face(hit: Vector3i, entry: Vector3i) -> TerrainFrame:
	var frame := TerrainFrame.new()
	var use_axis := TerrainGeometry.axis_of(entry)
	if use_axis < 0:
		use_axis = 1
	var use_sign := TerrainGeometry.sign_of(entry, use_axis)
	frame.axis = use_axis
	frame.sign = use_sign
	frame.normal = _axis_vector(use_axis, use_sign)
	frame.origin = Vector3(hit) + frame.normal * 0.5
	frame._build_cardinal_basis(use_axis)
	return frame


## Returns the frame of the floor plane at a target cell. The origin sits on the
## outward boundary of the first buildable layer, so the layer is the flatten
## target and the empty-floor seed sits one half step inward.
static func from_floor(floor_axis: int, floor_sign: int, floor_level: float, target: Vector3i) -> TerrainFrame:
	var frame := TerrainFrame.new()
	frame.axis = floor_axis
	frame.sign = floor_sign
	frame.normal = _axis_vector(floor_axis, floor_sign)
	frame.origin = Vector3(target)
	frame.origin[floor_axis] = floor_level + float(floor_sign)
	frame.on_floor = true
	frame._build_cardinal_basis(floor_axis)
	return frame


## Returns a frame that follows the local surface around a hit. It falls back to
## [param fallback] when the samples are too few or the surface is degenerate.
##
## [param job] supplies the cancel checkpoints of a worker. A cancelled read
## returns the fallback, and the job publishes nothing. The result and the query
## stream are unchanged when the job is null or uncancelled.
static func from_surface(frame: VoxelFrame, hit: Vector3i, entry: Vector3i, radius: int, fallback: TerrainFrame, job: VoxelFrame.EditJob = null, context: TerrainQueryContext = null) -> TerrainFrame:
	var points := TerrainGeometry.surface_points(frame, hit, entry, radius, job, context)
	if points.size() < 3:
		return fallback
	var surface := TerrainGeometry.surface_gradient(points, fallback.normal)
	if not surface["ok"]:
		return fallback
	var result := TerrainFrame.new()
	result.normal = surface["normal"]
	var centroid: Vector3 = surface["centroid"]
	# Anchor the plane near the clicked face, so the target stays under the
	# cursor. The origin is the clicked face moved onto the surface plane.
	result.origin = centroid + result.normal * result.normal.dot(fallback.origin - centroid)
	result.axis = TerrainGeometry.dominant_axis(result.normal)
	result.sign = 1 if result.normal[result.axis] >= 0.0 else -1
	result.follows_surface = true
	result._build_normal_basis()
	return result


## Returns the plane point of one anchor cell. The anchor is a world cell and the
## plane is frozen at the press, so the same path gives the same dab points at any
## event rate and no new surface read moves them.
func plane_point(cell: Vector3i) -> Vector3:
	var point := Vector3(cell)
	return point - normal * normal.dot(point - origin)


## Returns a frame with the cardinal normal of the dominant axis. The ring and
## the Build step use this frame, so the cursor points along the action.
static func cardinal(frame: TerrainFrame) -> TerrainFrame:
	if frame == null:
		return null
	var result := TerrainFrame.new()
	result.axis = TerrainGeometry.dominant_axis(frame.normal)
	result.sign = 1 if frame.normal[result.axis] >= 0.0 else -1
	result.normal = _axis_vector(result.axis, result.sign)
	result.origin = frame.origin
	result.follows_surface = frame.follows_surface
	result.on_floor = frame.on_floor
	result._build_cardinal_basis(result.axis)
	return result


## Returns a frame with the same normal and basis, moved along the normal so the
## plane passes through the center of [param surface]. The move is clamped to
## [param half_height], so one step cannot teleport the ground. A missing surface
## keeps the frame as it is.
func recenter_to(surface: Vector3i, half_height: float) -> TerrainFrame:
	if surface == VoxelPicking.NONE or half_height <= 0.0:
		return self
	# The center of the cell is its center point, and its outer face is half a
	# cell along the normal. A cell corner would move the plane up to 0.87 cells
	# on a tilted normal instead of the exact half cell.
	var center := Vector3(surface) + normal * 0.5
	var offset := clampf((center - origin).dot(normal), -half_height, half_height)
	if absf(offset) <= 1e-6:
		return self
	var result := TerrainFrame.new()
	result.normal = normal
	result.tangent_u = tangent_u
	result.tangent_v = tangent_v
	result.axis = axis
	result.sign = sign
	result.follows_surface = follows_surface
	result.on_floor = on_floor
	result.origin = origin + normal * offset
	return result


## Returns this frame mirrored through one symmetry mask. The mask is a bit
## field of the reflected axes.
func reflected(context: VoxelFrame.EditContext, mask: int) -> TerrainFrame:
	if mask == 0:
		return self
	var result := TerrainFrame.new()
	result.origin = _reflect_point(origin, context.origin_twice, mask)
	result.normal = _reflect_vector(normal, mask)
	result.tangent_u = _reflect_vector(tangent_u, mask)
	result.tangent_v = _reflect_vector(tangent_v, mask)
	result.axis = axis
	result.sign = -sign if mask & (1 << axis) else sign
	result.follows_surface = follows_surface
	result.on_floor = on_floor
	return result


## Returns one world point mirrored through one symmetry mask.
static func mirror_point(point: Vector3, context: VoxelFrame.EditContext, mask: int) -> Vector3:
	return _reflect_point(point, context.origin_twice, mask)


## Returns the plane of this frame.
func to_plane() -> Plane:
	return Plane(normal, origin)


func _build_cardinal_basis(use_axis: int) -> void:
	var first := Vector3.ZERO
	var second := Vector3.ZERO
	match use_axis:
		0:
			first = Vector3.UP
			second = Vector3.BACK
		1:
			first = Vector3.RIGHT
			second = Vector3.BACK
		_:
			first = Vector3.RIGHT
			second = Vector3.UP
	tangent_u = first
	tangent_v = second


func _build_normal_basis() -> void:
	var seed := Vector3.UP if absf(normal.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	tangent_u = normal.cross(seed).normalized()
	tangent_v = normal.cross(tangent_u).normalized()


static func _axis_vector(axis: int, sign: int) -> Vector3:
	var vector := Vector3.ZERO
	vector[axis] = float(sign)
	return vector


static func _reflect_point(point: Vector3, origin_twice: Vector3i, mask: int) -> Vector3:
	var result := point
	for axis in 3:
		if mask & (1 << axis):
			result[axis] = float(origin_twice[axis]) - result[axis]
	return result


static func _reflect_vector(vector: Vector3, mask: int) -> Vector3:
	var result := vector
	for axis in 3:
		if mask & (1 << axis):
			result[axis] = -result[axis]
	return result
