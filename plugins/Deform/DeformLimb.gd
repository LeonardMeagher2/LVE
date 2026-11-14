extends RefCounted

## Pure geometry helpers for the Pose brush of the deform tools.
##
## The helpers find the joint of one voxel limb, capture the connected cells
## that the joint can bend, and turn them about that joint. They read one frame
## snapshot and plain values, so a worker can run them.
##
## A limb is the connected component of occupied cells at the picked cell. The
## joint is the cell where the limb enters the brush on its way to the far end of
## the limb. The joint therefore sits on an occupied cell, and the pointer is the
## tip of the bone.

## The neighbor offsets of the limb walk, in a fixed order.
const NEIGHBORS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]
## The most cells that one joint search reads. The search follows the limb, so a
## hover stays cheap on a large model.
const JOINT_CELL_LIMIT := 2048
## The completed cells between two worker cancel checks.
const CHECKPOINT := 512


## Returns the active symmetry masks of one context. A null context is one mask.
static func masks_for(context: VoxelFrame.EditContext) -> Array:
	var masks := []
	if context == null:
		masks.append(0)
		return masks
	for mask in 8:
		if (mask & ~context.axes) == 0:
			masks.append(mask)
	return masks


## Returns the joint of the limb at [param anchor].
##
## The result holds [code]pivot[/code] as a world point, [code]bone_dir[/code] as
## a unit vector that points from the joint toward the picked cell,
## [code]reach[/code] as the distance from the anchor to the pivot, and
## [code]found[/code] as whether the limb extends past the picked cell.
##
## The joint is the farthest cell of the limb within the brush radius. The search
## walks the connected cells from the picked cell one brush size out, then walks
## back to the brush radius, so the joint stays on the limb and the picked face
## has no effect.
##
## The search looks one brush radius past the joint bound. Without that lookahead
## both ends of a limb tie, and a press near a tip keeps the joint on the tip
## side. The walk also stops at [constant JOINT_CELL_LIMIT] cells.
static func joint_pivot(frame: VoxelFrame, anchor: Vector3i, size: int, context: VoxelFrame.EditContext) -> Dictionary:
	var result := {"found": false, "pivot": Vector3(anchor), "bone_dir": Vector3.ZERO, "reach": 0.0}
	if frame == null or anchor == VoxelPicking.NONE or not frame.has(anchor):
		return result
	var origin := Vector3(anchor)
	var brush_reach := float(clampi(size, 1, 32)) * 0.5
	var search := brush_reach * 2.0
	var parent := {}
	var steps := {anchor: 0}
	var queue: Array[Vector3i] = [anchor]
	var head := 0
	var far := anchor
	var far_steps := 0
	while head < queue.size() and steps.size() < JOINT_CELL_LIMIT:
		var cell: Vector3i = queue[head]
		head += 1
		var depth := int(steps[cell])
		if depth > far_steps:
			far = cell
			far_steps = depth
		for offset: Vector3i in NEIGHBORS:
			var next := cell + offset
			if steps.has(next) or not frame.has(next):
				continue
			if Vector3(next).distance_to(origin) > search:
				continue
			if context != null and not context.allows(next):
				continue
			steps[next] = depth + 1
			parent[next] = cell
			queue.append(next)
	if far_steps < 1:
		return result
	# Walk back from the far end of the limb. The first cell inside the brush is
	# the base, so the joint sits where the limb enters the brush.
	var base := far
	while parent.has(base) and Vector3(base).distance_to(origin) > brush_reach:
		base = parent[base]
	var bone := origin - Vector3(base)
	var reach := bone.length()
	if reach < 0.5:
		return result
	result["found"] = true
	result["bone_dir"] = bone / reach
	result["reach"] = reach
	result["pivot"] = Vector3(far)
	return result


## Returns the captured limb cells of one joint, keyed by cell, with their
## weight.
##
## The walk starts at [param anchor] and follows every connected occupied cell
## that the context allows. It stops where the limb crosses the joint band, so
## the cells behind the joint keep still. A limb longer than the brush therefore
## bends as a whole.
##
## [param band] is the half width of the joint blend along the bone. The walk
## stops at [param limit] cells, so a connected blob bends a bounded set instead
## of the whole model. A caller that only needs to know whether the limb holds a
## cell passes one.
static func capture_limb(frame: VoxelFrame, anchor: Vector3i, pivot: Vector3, bone_dir: Vector3, band: float, limit: int, context: VoxelFrame.EditContext, job: VoxelFrame.EditJob = null) -> Dictionary:
	var captured := {}
	if frame == null or anchor == VoxelPicking.NONE or bone_dir == Vector3.ZERO:
		return captured
	var cap := maxi(limit, 1)
	var visited := {anchor: true}
	var queue: Array[Vector3i] = [anchor]
	var head := 0
	var completed := 0
	while head < queue.size():
		if captured.size() >= cap:
			break
		var cell: Vector3i = queue[head]
		head += 1
		if context != null and not context.allows(cell):
			continue
		var along := (Vector3(cell) - pivot).dot(bone_dir)
		if along < -band:
			# The limb continues behind the joint, so this branch stops here.
			continue
		captured[cell] = limb_weight(along, band)
		for offset: Vector3i in NEIGHBORS:
			var next := cell + offset
			if visited.has(next) or not frame.has(next):
				continue
			visited[next] = true
			queue.append(next)
		completed += 1
		if job != null and completed % CHECKPOINT == 0 and not job.checkpoint(completed):
			return {}
	return captured


## Returns the pose weight of one cell from its distance along the bone.
##
## The weight runs from zero at the far side of the joint band to one at its
## near side, so a bent limb keeps a smooth neck.
static func limb_weight(along: float, band: float) -> float:
	if band <= 0.0:
		return 1.0 if along >= 0.0 else 0.0
	var t := clampf((along + band) / (2.0 * band), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## The widest half width of the joint neck, in cells. A narrow neck keeps every
## other cell rigid, so the limb turns like the rotate tool instead of shearing.
const NECK_LIMIT := 2.0


## Returns the half-width of the joint neck, in cells. The falloff sets it from
## half a cell to one brush size, and it stops at [constant NECK_LIMIT] so a
## large brush cannot smear the limb.
static func joint_band(size: int, falloff: float) -> float:
	var use_size := float(clampi(size, 1, 32))
	return minf(lerpf(0.5, use_size, clampf(falloff, 0.0, 1.0)), NECK_LIMIT)


## Returns the cell of one world point.
static func round_cell(point: Vector3) -> Vector3i:
	return Vector3i(roundi(point.x), roundi(point.y), roundi(point.z))


## Returns the turned world point of one cell around the pose joint.
##
## [param pose] holds [code]pivot[/code], the rotation [code]axis[/code], and the
## full [code]angle[/code]. [param weight] scales the turn, so the neck of the
## joint turns less than the tip. [param angle] overrides the stored angle, for a
## fit search.
static func turn_point(pose: Dictionary, cell: Vector3i, weight: float, angle := NAN) -> Vector3:
	var pivot: Vector3 = pose["pivot"]
	var use_angle: float = float(pose["angle"]) if is_nan(angle) else angle
	var axis: Vector3 = pose["axis"]
	return pivot + Basis(axis, use_angle * weight) * (Vector3(cell) - pivot)


## Returns the length of one world direction in the screen plane.
static func screen_length(direction: Vector3, right: Vector3, up: Vector3) -> float:
	return Vector2(direction.dot(right), direction.dot(up)).length()


## Returns the screen vector of one world direction, in cells.
static func screen_vector(direction: Vector3, right: Vector3, up: Vector3) -> Vector2:
	return Vector2(direction.dot(right), direction.dot(up))


## Returns [code]1.0[/code] for a mask with an even axis count, and
## [code]-1.0[/code] for an odd one. A reflection flips the handedness of a
## screen rotation, so a mirrored limb turns the other way.
static func mask_handedness(mask: int) -> float:
	var odd := 0
	for axis in 3:
		if mask & (1 << axis):
			odd ^= 1
	return -1.0 if odd == 1 else 1.0


## Returns the mirror of one world point through a symmetry mask. The origin is
## the corner between eight cells, so a point mirrors around a half-cell line.
static func mirror_point(point: Vector3, context: VoxelFrame.EditContext, mask: int) -> Vector3:
	if context == null or mask == 0:
		return point
	var origin := Vector3(context.origin_twice) * 0.5
	var mirrored := point - origin
	for axis in 3:
		if mask & (1 << axis):
			mirrored[axis] = -mirrored[axis]
	return mirrored + origin
