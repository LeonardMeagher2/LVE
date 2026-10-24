class_name SculptFrame
extends RefCounted

## An oriented surface frame for the sculpt tools.
##
## The frame holds a point on the surface, an outward unit normal, and an
## in-plane basis. A fitted frame follows the local voxel surface. A frame that
## cannot be fitted falls back to the clicked face or the floor plane.
##
## The tool samples the surface along the frame normal, so a fitted frame makes
## the footprint follow a slope instead of a cube face.

## The radius in cells of the local surface sample around a hit.
const SAMPLE_RADIUS := 3

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
## Whether the plane follows a fitted surface. A false value is a fallback.
var fitted := false


## Returns the frame of a clicked face.
static func from_face(hit: Vector3i, entry: Vector3i) -> SculptFrame:
	var frame := SculptFrame.new()
	var use_axis := SculptGeometry.axis_of(entry)
	if use_axis < 0:
		use_axis = 1
	var use_sign := SculptGeometry.sign_of(entry, use_axis)
	frame.axis = use_axis
	frame.sign = use_sign
	frame.normal = _axis_vector(use_axis, use_sign)
	frame.origin = Vector3(hit) + frame.normal * 0.5
	frame._build_cardinal_basis(use_axis)
	return frame


## Returns the frame of the floor plane at a target cell. The origin sits on the
## outward boundary of the first buildable layer, so the layer is the flatten
## target and the empty-floor seed sits one half step inward.
static func from_floor(floor_axis: int, floor_sign: int, floor_level: float, target: Vector3i) -> SculptFrame:
	var frame := SculptFrame.new()
	frame.axis = floor_axis
	frame.sign = floor_sign
	frame.normal = _axis_vector(floor_axis, floor_sign)
	frame.origin = Vector3(target)
	frame.origin[floor_axis] = floor_level + float(floor_sign)
	frame._build_cardinal_basis(floor_axis)
	return frame


## Returns a frame fitted to the local surface around a hit. It falls back to
## [param fallback] when the samples are too few or the fit is degenerate.
##
## [param job] supplies the cancel checkpoints of a worker. A cancelled fit
## returns the fallback, and the job publishes nothing. The result and the query
## stream are unchanged when the job is null or uncancelled.
static func fit(frame: VoxelFrame, hit: Vector3i, entry: Vector3i, radius: int, fallback: SculptFrame, job: VoxelFrame.EditJob = null, context: SculptQueryContext = null) -> SculptFrame:
	var points := SculptGeometry.surface_points(frame, hit, entry, radius, job, context)
	if points.size() < 3:
		return fallback
	var fit := SculptGeometry.fit_surface_gradient(points, fallback.normal)
	if not fit["ok"]:
		return fallback
	var result := SculptFrame.new()
	result.normal = fit["normal"]
	var centroid: Vector3 = fit["centroid"]
	# Anchor the plane near the clicked face, so the target stays under the
	# cursor. The origin is the clicked face projected onto the fitted plane.
	result.origin = centroid + result.normal * result.normal.dot(fallback.origin - centroid)
	result.axis = SculptGeometry.dominant_axis(result.normal)
	result.sign = 1 if result.normal[result.axis] >= 0.0 else -1
	result.fitted = true
	result._build_normal_basis()
	return result


## Returns this frame mirrored through one symmetry mask. The mask is a bit
## field of the reflected axes.
func reflected(context: VoxelFrame.EditContext, mask: int) -> SculptFrame:
	if mask == 0:
		return self
	var result := SculptFrame.new()
	result.origin = _reflect_point(origin, context.origin_twice, mask)
	result.normal = _reflect_vector(normal, mask)
	result.tangent_u = _reflect_vector(tangent_u, mask)
	result.tangent_v = _reflect_vector(tangent_v, mask)
	result.axis = axis
	result.sign = -sign if mask & (1 << axis) else sign
	result.fitted = fitted
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
