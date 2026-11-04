extends RefCounted

## The surface-projected brush boundary ring.
##
## The helper builds the outer boundary of one brush footprint as a line list on
## the voxel surface. It gives the terrain tools their "terrain circle": one
## opaque rim that follows the faces that the user sees. It does not draw the
## boundary of a voxel set, so no upper, lower, or riser edge of a thin slab
## appears.
##
## The helper is pure geometry. It reads a frame snapshot, one oriented surface
## frame, and plain values. It never reads the editor state and never touches a
## node, a material, or a resource. A caller can run it on a worker.
##
## The rim is a continuous parametric circle in the brush plane. Every rim
## sample finds the surface cell along the operation normal, and then the exact
## rim line meets the box of that cell. The result keeps the true circle on flat
## ground, and it lands on the real front face of a step, a slope, or a wall.
##
## A height step is drawn as a riser plus the two treads of that step. It is
## never one diagonal chord. A missing surface or a refused sample ends the run,
## so a hole shows an open arc and no wrong segment.
##
## The result is a line list for [constant Mesh.PRIMITIVE_LINES], so a break is
## an omitted pair. The mesh build belongs to the main thread.

const BrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")

## The outward offset of every vertex along the operation normal, in cells. It
## keeps the depth-tested line off the surface plane.
const LIFT := 0.02
## The fewest rim segments of one mask.
const MIN_SEGMENTS := 16
## The most rim segments of one mask.
const MAX_SEGMENTS := 256
## The most bisections that resolve one height step.
const SPLIT_DEPTH := 12
## The angular width below which one step boundary counts as resolved, in radians.
const SPLIT_ANGLE := 0.001
## The completed samples between two worker cancel checks. It matches the surface read
## checkpoint of [TerrainGeometry].
const CHECKPOINT := 32
## The tolerance that accepts a grazing line on one cell box face.
const SLAB_EPSILON := 1e-6
## The tolerance that treats two cell front faces as one plane.
const PLANE_EPSILON := 1e-4


## Returns the rim segment count of one size.
##
## The count follows the circumference of the physical radius, so one segment is
## about one cell of arc at every size. The sagitta of the chord on a flat plane
## stays below 0.004 cells at the largest size, so the circle reads as smooth.
static func segments_for(size: int) -> int:
	var use_size := BrushSize.clamp_size(size)
	return clampi(int(ceil(PI * float(use_size))), MIN_SEGMENTS, MAX_SEGMENTS)


## Returns the bounded surface search depth of one size, in cells.
##
## The value bounds every rim query, so no rim sample walks an unbounded
## distance to a far or a disconnected surface. It matches the footprint depth of
## the terrain hover, so the ring and the footprint read one surface.
static func depth_for(size: int) -> int:
	return clampi(BrushSize.clamp_size(size), 8, 64)


## Returns true when a tool seeds an empty floor, so a plain plane ring applies.
##
## The rule mirrors the seed rule of the terrain preview: Build Add and Flatten
## seed the captured floor plane, and Build Remove and Smooth seed nothing.
static func floor_ring_applies(tool: int, build_mode: int) -> bool:
	if tool == TerrainToolSettings.Tools.FLATTEN:
		return true
	return tool == TerrainToolSettings.Tools.BUILD and build_mode == TerrainToolSettings.BuildMode.ADD


## Returns the surface ring of one brush, with its counts.
##
## The result holds [code]vertices[/code] as a line list, [code]segments[/code]
## as the emitted segment count, [code]breaks[/code] as the open-arc count,
## [code]queries[/code] as the exact surface query count, [code]samples[/code] as
## the base rim sample count, and [code]masks[/code] as the baked mask count.
##
## Every active symmetry mask of [param context] is baked into one line list. The
## whole pattern reflects, not the center alone, so an even size keeps its half
## cell bias on the mirrored side.
##
## [param tester] is an optional exact eligibility rule, called as
## [code]tester.call(cell, normal, point)[/code]. It must be pure. A false result
## ends the run, so the ring clips to the real editable region. The caller
## supplies the tool rule of its own operation. For Build Add the rule tests the
## destination cell, not the support cell.
##
## [param job] supplies the worker cancel checkpoints. [param query] is an
## optional exact read-only column index of the same frame snapshot. A cancelled
## job returns no vertices.
static func surface_ring_data(frame: VoxelFrame, surface_frame: TerrainFrame, center_point: Vector3, size: int, context: VoxelFrame.EditContext, tester := Callable(), job: VoxelFrame.EditJob = null, query: TerrainQueryContext = null, lift := LIFT) -> Dictionary:
	var result := {
		"vertices": PackedVector3Array(), "segments": 0, "breaks": 0,
		"queries": 0, "samples": 0, "masks": 0,
	}
	if surface_frame == null:
		return result
	var use_size := BrushSize.clamp_size(size)
	var radius := BrushSize.radius(use_size)
	var offset := BrushSize.center_offset(use_size)
	var sample_count := segments_for(use_size)
	var depth := depth_for(use_size)
	var vertices := PackedVector3Array()
	var queries := 0
	var breaks := 0
	var completed := 0
	var cancelled := false
	var masks := _masks_for(context)
	var no_changes := {}
	for mask: int in masks:
		var axis_frame := surface_frame
		var center := center_point
		if context != null and mask != 0:
			axis_frame = surface_frame.reflected(context, mask)
			center = TerrainFrame.mirror_point(center_point, context, mask)
		var normal := axis_frame.normal.normalized()
		if normal == Vector3.ZERO:
			continue
		var first := axis_frame.tangent_u.normalized()
		var second := axis_frame.tangent_v.normalized()
		if first == Vector3.ZERO or second == Vector3.ZERO:
			continue
		# The offset belongs to the local basis of this mask, so a mirrored
		# pattern keeps its own half cell bias.
		var local_center := center + offset * (first + second)
		var cells: Array[Vector3i] = []
		var faces: Array = []
		cells.resize(sample_count)
		faces.resize(sample_count)
		for index in sample_count:
			var angle := TAU * float(index) / float(sample_count)
			var rim := _rim_point(local_center, radius, angle, first, second)
			var cell := _probe(frame, rim, normal, depth, query, tester, no_changes)
			queries += 1
			completed += 1
			cells[index] = cell
			faces[index] = _front_face(cell, rim, normal)
			if job != null and completed % CHECKPOINT == 0 and not job.checkpoint(completed):
				cancelled = true
				break
		if cancelled:
			break
		var traced := _trace(frame, vertices, cells, faces, sample_count, local_center, radius, first, second, normal, depth, query, tester, no_changes, lift)
		vertices = traced["vertices"]
		breaks += int(traced["breaks"])
	result["samples"] = sample_count
	result["masks"] = masks.size()
	result["queries"] = queries
	result["breaks"] = breaks
	result["segments"] = vertices.size() / 2
	result["vertices"] = PackedVector3Array() if cancelled else vertices
	return result


## Returns the surface ring of one brush as a line list. See
## [method surface_ring_data] for the exact contract.
static func surface_ring(frame: VoxelFrame, surface_frame: TerrainFrame, center_point: Vector3, size: int, context: VoxelFrame.EditContext, tester := Callable(), job: VoxelFrame.EditJob = null, query: TerrainQueryContext = null, lift := LIFT) -> PackedVector3Array:
	var data := surface_ring_data(frame, surface_frame, center_point, size, context, tester, job, query, lift)
	return data["vertices"]


## Returns the rim circle of one empty floor as a line list.
##
## The call reads no surface, so it is cheap. It applies when the tool seeds an
## empty floor. See [method floor_ring_applies].
static func plane_ring(surface_frame: TerrainFrame, center_point: Vector3, size: int, context: VoxelFrame.EditContext, lift := LIFT) -> PackedVector3Array:
	var vertices := PackedVector3Array()
	if surface_frame == null:
		return vertices
	var use_size := BrushSize.clamp_size(size)
	var radius := BrushSize.radius(use_size)
	var offset := BrushSize.center_offset(use_size)
	var sample_count := segments_for(use_size)
	for mask: int in _masks_for(context):
		var axis_frame := surface_frame
		var center := center_point
		if context != null and mask != 0:
			axis_frame = surface_frame.reflected(context, mask)
			center = TerrainFrame.mirror_point(center_point, context, mask)
		var normal := axis_frame.normal.normalized()
		if normal == Vector3.ZERO:
			continue
		var first := axis_frame.tangent_u.normalized()
		var second := axis_frame.tangent_v.normalized()
		if first == Vector3.ZERO or second == Vector3.ZERO:
			continue
		var local_center := center + offset * (first + second) + normal * lift
		for index in sample_count:
			var angle := TAU * float(index) / float(sample_count)
			var next_angle := TAU * float(index + 1) / float(sample_count)
			vertices.append(_rim_point(local_center, radius, angle, first, second))
			vertices.append(_rim_point(local_center, radius, next_angle, first, second))
	return vertices


## Returns one legacy brush outline in the local XY plane at z = 0.
##
## The outline is a stepped voxelized circle. It is the boundary of the disk of
## cells whose centers are within radius + 0.5 of the local origin. Every cell
## of the disk whose neighbor is not in the disk emits the shared edge as one
## axis aligned unit segment. The outline is centered on the origin and keeps
## fourfold symmetry, so a caller poses it on the brush cell center. The result
## is a line list for [constant Mesh.PRIMITIVE_LINES]. It reads no frame and
## runs no terrain query.
static func legacy_plane_ring(size: int) -> PackedVector3Array:
	var use_size := clampi(size, 1, 64)
	var cells := {}
	for entry in BrushSize.disk_offsets(use_size):
		cells[Vector2i(entry["u"], entry["v"])] = true
	var vertices := PackedVector3Array()
	var edges := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for key in cells:
		for edge in edges:
			if cells.has(key + edge):
				continue
			# The cell (i, j) is centered on its integer coordinates, so the
			# shared edge sits half a cell away from the center.
			var mid := Vector3(key.x + 0.5 * edge.x, key.y + 0.5 * edge.y, 0.0)
			var half := Vector3(-0.5 * edge.y, 0.5 * edge.x, 0.0)
			vertices.append(mid - half)
			vertices.append(mid + half)
	return vertices


## Returns a line mesh for one line list. Call it on the main thread only.
##
## The mesh carries no surface material, so a caller owns the material choice and
## no shared resource is touched.
static func build_mesh(vertices: PackedVector3Array) -> ArrayMesh:
	var surface := ArrayMesh.new()
	if vertices.is_empty():
		return surface
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	surface.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return surface


# Walks one rim in order and emits its segments.
#
# A run of whole samples becomes one tread. A sample whose front face is the
# plane of the previous sample continues that tread, so a flat floor stays one
# smooth circle. A sample whose front face is another plane becomes a riser
# between the two cell faces, so a height step is drawn and no chord cuts it. A
# missing cell ends the run. The result holds the new vertices and the open-arc
# count.
static func _trace(frame: VoxelFrame, vertices: PackedVector3Array, cells: Array, faces: Array, sample_count: int, local_center: Vector3, radius: float, first: Vector3, second: Vector3, normal: Vector3, depth: int, query: TerrainQueryContext, tester: Callable, no_changes: Dictionary, lift: float) -> Dictionary:
	var run := PackedVector3Array()
	var breaks := 0
	var previous_cell := VoxelPicking.NONE
	var previous_face := {}
	var previous_angle := 0.0
	# One extra step closes the circle back onto the first sample.
	for step_index in sample_count + 1:
		var index := step_index % sample_count
		var angle := TAU * float(step_index) / float(sample_count)
		var cell := cells[index] as Vector3i
		var face: Dictionary = faces[index]
		if cell == VoxelPicking.NONE or face.is_empty():
			if run.size() > 1:
				_emit_run(vertices, run)
				breaks += 1
			run = PackedVector3Array()
			previous_face = {}
			previous_angle = angle
			continue
		if previous_face.is_empty():
			run.append((face["point"] as Vector3) + normal * lift)
			previous_cell = cell
			previous_face = face
			previous_angle = angle
			continue
		if cell == previous_cell or _same_plane(previous_face, face):
			run.append((face["point"] as Vector3) + normal * lift)
			previous_cell = cell
			previous_face = face
			previous_angle = angle
			continue
		var step := _resolve_step(frame, local_center, radius, first, second, previous_angle, angle, previous_face, face, normal, depth, query, tester, no_changes)
		if step.is_empty():
			if run.size() > 1:
				_emit_run(vertices, run)
				breaks += 1
			run = PackedVector3Array()
			previous_face = {}
			previous_angle = angle
			continue
		run.append((step["low"] as Vector3) + normal * lift)
		run.append((step["high"] as Vector3) + normal * lift)
		run.append((face["point"] as Vector3) + normal * lift)
		previous_cell = cell
		previous_face = face
		previous_angle = angle
	if run.size() > 1:
		_emit_run(vertices, run)
	return {"vertices": vertices, "breaks": breaks}


# Resolves one height step between two rim samples.
#
# A bounded bisection finds the angular boundary between the two front-face
# planes. The faces are the comparison, not the cells: two neighbouring columns
# of one tread hold different cells and the same plane, so a cell test would see
# a step where none exists.
#
# The result holds the front face of the lower angle side and the front face of
# the upper angle side. Each point reads a rim angle inside its own face, so the
# rim line meets that cell box. An empty result means the boundary could not be
# proven, so the run ends and no chord crosses the step.
static func _resolve_step(frame: VoxelFrame, local_center: Vector3, radius: float, first: Vector3, second: Vector3, low_angle: float, high_angle: float, low_face: Dictionary, high_face: Dictionary, normal: Vector3, depth: int, query: TerrainQueryContext, tester: Callable, no_changes: Dictionary) -> Dictionary:
	var lo_angle := low_angle
	var hi_angle := high_angle
	var lo_face := low_face
	var hi_face := high_face
	for _split in SPLIT_DEPTH:
		if absf(hi_angle - lo_angle) <= SPLIT_ANGLE:
			break
		var mid_angle := (lo_angle + hi_angle) * 0.5
		var mid_rim := _rim_point(local_center, radius, mid_angle, first, second)
		var mid_cell := _probe(frame, mid_rim, normal, depth, query, tester, no_changes)
		if mid_cell == VoxelPicking.NONE:
			return {}
		var mid_face := _front_face(mid_cell, mid_rim, normal)
		if mid_face.is_empty():
			return {}
		if _same_plane(lo_face, mid_face):
			lo_angle = mid_angle
			lo_face = mid_face
		else:
			hi_angle = mid_angle
			hi_face = mid_face
	if _same_plane(lo_face, hi_face):
		return {}
	return {"low": lo_face["point"], "high": hi_face["point"]}


# Emits one run of points as line pairs. A short run holds no segment.
static func _emit_run(vertices: PackedVector3Array, run: PackedVector3Array) -> void:
	for index in range(run.size() - 1):
		vertices.append(run[index])
		vertices.append(run[index + 1])


# Returns true when two cell front faces lie on one plane. Two treads of one
# floor are then one continuous run and no riser is drawn between them.
static func _same_plane(one: Dictionary, other: Dictionary) -> bool:
	return (
		int(one["axis"]) == int(other["axis"])
		and int(one["side"]) == int(other["side"])
		and absf(float(one["plane"]) - float(other["plane"])) <= PLANE_EPSILON
	)


# Returns the surface cell of one rim sample, or NONE when the surface is missing
# or the tester refuses the sample.
static func _probe(frame: VoxelFrame, point: Vector3, normal: Vector3, depth: int, query: TerrainQueryContext, tester: Callable, no_changes: Dictionary) -> Vector3i:
	var cell := TerrainGeometry.surface_along(frame, point, normal, depth, no_changes, query)
	if cell == VoxelPicking.NONE:
		return cell
	if tester.is_valid() and not bool(tester.call(cell, normal, point)):
		return VoxelPicking.NONE
	return cell


# Returns the point where the rim line leaves one cell box on its front side, and
# the identity of that face.
#
# The line is infinite. The point is on the box boundary on the operation normal
# side, so it sits on a face that the user sees. The native box slab runs first,
# and an inclusive slab runs on a grazing line. An empty result means no point
# exists, for a missing cell or a zero normal.
static func _front_face(cell: Vector3i, point: Vector3, normal: Vector3) -> Dictionary:
	if cell == VoxelPicking.NONE:
		return {}
	var direction := normal.normalized()
	if direction == Vector3.ZERO:
		return {}
	var box := AABB(Vector3(cell) - Vector3(0.5, 0.5, 0.5), Vector3.ONE)
	var reach := absf((box.get_center() - point).dot(direction)) + box.size.length() + 1.0
	var hit: Variant = box.intersects_ray(point + direction * reach, -direction)
	if hit == null:
		hit = _slab_exit(box, point, direction)
	if hit == null:
		# The line missed the box. Keep a deterministic point on the front face,
		# so the caller still gets a usable vertex.
		var snapped := Vector3(cell)
		var dominant := TerrainGeometry.dominant_axis(direction)
		snapped[dominant] += 0.5 if direction[dominant] >= 0.0 else -0.5
		hit = snapped
	var axis := _face_axis(hit, box, direction)
	var center := box.get_center()
	var side := 1 if hit[axis] >= center[axis] else -1
	var plane := box.position[axis] + (box.size[axis] if side > 0 else 0.0)
	return {"point": hit, "axis": axis, "side": side, "plane": plane}


# Returns the box axis that the line leaves through.
#
# Only an axis with a real direction component can carry the exit face. A grazing
# line that lies exactly on a side boundary of the box therefore still reports
# its true front face, and two treads of one floor never look like a step.
static func _face_axis(point: Vector3, box: AABB, direction: Vector3) -> int:
	var axis := TerrainGeometry.dominant_axis(direction)
	var closest := INF
	for index in 3:
		if absf(direction[index]) <= SLAB_EPSILON:
			continue
		var low := box.position[index]
		var high := low + box.size[index]
		var gap := minf(absf(point[index] - low), absf(point[index] - high))
		if gap < closest:
			closest = gap
			axis = index
	return axis


# Returns the outward end of the intersection of one infinite line and one box.
# The comparison is inclusive within [constant SLAB_EPSILON], so a line that
# grazes a face still resolves. A parallel line outside the box returns null.
static func _slab_exit(box: AABB, point: Vector3, direction: Vector3) -> Variant:
	var enter := -INF
	var exit := INF
	for axis in 3:
		var low := box.position[axis]
		var high := low + box.size[axis]
		if absf(direction[axis]) <= SLAB_EPSILON:
			if point[axis] < low - SLAB_EPSILON or point[axis] > high + SLAB_EPSILON:
				return null
			continue
		var first := (low - point[axis]) / direction[axis]
		var second := (high - point[axis]) / direction[axis]
		enter = maxf(enter, minf(first, second))
		exit = minf(exit, maxf(first, second))
	if enter > exit + SLAB_EPSILON or not is_finite(exit):
		return null
	return point + direction * exit


# Returns one point of the rim circle.
static func _rim_point(center: Vector3, radius: float, angle: float, first: Vector3, second: Vector3) -> Vector3:
	return center + radius * (cos(angle) * first + sin(angle) * second)


# Returns the active symmetry masks of one context. A null context is one mask.
static func _masks_for(context: VoxelFrame.EditContext) -> Array:
	var masks := []
	if context == null:
		masks.append(0)
		return masks
	for mask in 8:
		if (mask & ~context.axes) == 0:
			masks.append(mask)
	return masks
