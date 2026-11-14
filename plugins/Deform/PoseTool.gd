extends "./DeformTool.gd"

## The pose deform tool.
##
## A press finds the joint of the voxel limb at the picked cell and captures the
## cells that the joint can bend. A drag turns the limb around the view normal by
## the screen angle from the bone to the joint-to-pointer arm, so the bend stays in
## the view plane and the tip lands under the pointer. Only a narrow neck at the
## joint blends the turn, so the rest of the limb stays rigid. A release commits
## one history action.
##
## The bone shows the joint on every hover and through the drag, so the user sees
## the rotation point before the press.

const DeformLimb := preload("./DeformLimb.gd")

## The most limb cells that one pose bends. The walk stops at this bound, so a
## hover stays cheap and a connected blob bends a bounded set.
const LIMB_CELL_LIMIT := 8192
## The limb allowance as a multiple of the footprint ball. A limb may be much
## longer than the brush, so a narrow brush still bends a whole arm.
const LIMB_LIMIT_FACTOR := 16
## The smallest limb allowance, in cells.
const LIMB_MIN_LIMIT := 64
## The rotation below which the drag changes nothing.
const ANGLE_EPSILON := 0.0002
## The arm length of the joint marker, in cells.
const MARKER := 0.6
## The bone screen length below which the bone has no screen direction. A bone
## that points at the viewer cannot show a screen angle, so the tool turns the
## limb by the pointer travel instead.
const DEGENERATE_SCREEN := 0.05
## The passes of the angle fit search. Five passes resolve the angle to about one
## degree of a full turn.
const FIT_PASSES := 5


## One cancellable pose drag.
##
## Every pose entry belongs to one symmetry mask. The job writes the turned cells
## first, then clears only the sources that a write replaced. A destination that
## holds unrelated geometry refuses its write, so the source stays in place and
## the limb never loses a cell. A tie between two sources keeps the material of
## the cell that sits farther from the joint.
## [method DeformJob.compute_changes] is the worker body.
class PoseJob extends DeformJob:
	## The pose entries. Each holds the joint, the rotation axis, the angle of that
	## joint, and the captured cells with their weights.
	var poses: Array = []
	## The estimated drag work.
	var work := 0
	# Every cell that a pose wrote, with the distance of its source along the limb.
	var _written := {}

	func estimated_work() -> int:
		return maxi(1, work)

	func compute_changes() -> Dictionary:
		stage("Posing voxels", work)
		_written = {}
		destination_selection = {}
		removed_cells = {}
		var changes := {}
		var done := 0
		for pose in poses:
			_pose(pose, changes)
			done += (pose["cells"] as Dictionary).size()
			if not checkpoint(done):
				return {}
		for pose in poses:
			_release_replaced(pose, changes)
			done += (pose["cells"] as Dictionary).size()
			if not checkpoint(done):
				return {}
		# The cells that the turn writes are the moved set, so the selection follows
		# the limb. A blocked destination is not written, so it never joins the
		# selection, and a cleared source leaves it.
		for cell: Vector3i in _written:
			destination_selection[cell] = true
		return changes

	# Clears a source cell only when a pose wrote a cell that it turned onto. A
	# destination blocked by unrelated geometry leaves its source where it is.
	func _release_replaced(pose: Dictionary, changes: Dictionary) -> void:
		var cells: Dictionary = pose["cells"]
		if cells.is_empty() or absf(float(pose["angle"])) < ANGLE_EPSILON:
			return
		for cell: Vector3i in cells:
			var turned := DeformLimb.turn_point(pose, cell, float(cells[cell]))
			var destination := DeformLimb.round_cell(turned)
			if destination == cell or not _written.has(destination) or _written.has(cell):
				continue
			changes[cell] = VoxelFrame.material(Color.TRANSPARENT)
			removed_cells[cell] = true

	# Maps every destination of one mask back to its source cell.
	func _pose(pose: Dictionary, changes: Dictionary) -> void:
		var cells: Dictionary = pose["cells"]
		if cells.is_empty() or absf(float(pose["angle"])) < ANGLE_EPSILON:
			return
		var low := Vector3(INF, INF, INF)
		var high := Vector3(-INF, -INF, -INF)
		for cell: Vector3i in cells:
			var source := Vector3(cell)
			var turned := DeformLimb.turn_point(pose, cell, float(cells[cell]))
			low = low.min(source).min(turned)
			high = high.max(source).max(turned)
		var min_cell := Vector3i(floori(low.x) - 1, floori(low.y) - 1, floori(low.z) - 1)
		var max_cell := Vector3i(ceili(high.x) + 1, ceili(high.y) + 1, ceili(high.z) + 1)
		# Every destination samples its own source. A source never draws a line, so
		# a turn cannot smear the limb along the arc.
		_inverse_map(pose, cells, min_cell, max_cell, changes)
		_splat(pose, cells, changes)

	# Walks the turned box and writes the source material of every destination.
	# An occupied cell that no pose moves blocks the destination.
	func _inverse_map(pose: Dictionary, cells: Dictionary, min_cell: Vector3i, max_cell: Vector3i, changes: Dictionary) -> void:
		var completed := 0
		for z in range(min_cell.z, max_cell.z + 1):
			for y in range(min_cell.y, max_cell.y + 1):
				for x in range(min_cell.x, max_cell.x + 1):
					_inverse_cell(pose, Vector3i(x, y, z), cells, changes)
					completed += 1
					if completed % 512 == 0 and not checkpoint(completed):
						return

	func _inverse_cell(pose: Dictionary, destination: Vector3i, cells: Dictionary, changes: Dictionary) -> void:
		if _written.has(destination) or not allows(destination):
			return
		if edited_frame.has(destination) and not cells.has(destination):
			return
		var pivot: Vector3 = pose["pivot"]
		var axis: Vector3 = pose["axis"]
		var angle: float = pose["angle"]
		var offset := Vector3(destination) - pivot
		# The first guess is the full turn. A destination outside the limb has no
		# weight of its own, so the search must start from the full rotation.
		var rigid := pivot + Basis(axis, -angle) * offset
		var point := rigid
		for _pass in 2:
			var cell := DeformLimb.round_cell(point)
			var weight := float(cells.get(cell, 0.0))
			point = pivot + Basis(axis, -angle * weight) * offset
		var source := DeformLimb.round_cell(point)
		if not cells.has(source):
			source = DeformLimb.round_cell(rigid)
			if not cells.has(source):
				return
		_put(changes, destination, edited_frame.get_material(source), _along(pose, source))

	# Writes the turned cell of every source that the inverse map missed. One cell
	# per source, so the turn fills a gap without drawing a line between cells.
	func _splat(pose: Dictionary, cells: Dictionary, changes: Dictionary) -> void:
		for cell: Vector3i in cells:
			var weight := float(cells[cell])
			if weight <= 0.0:
				continue
			var destination := DeformLimb.round_cell(DeformLimb.turn_point(pose, cell, weight))
			if destination == cell or _written.has(destination) or not allows(destination):
				continue
			if edited_frame.has(destination) and not cells.has(destination):
				continue
			_put(changes, destination, edited_frame.get_material(cell), _along(pose, cell))

	# Keeps the material of the source that sits farther from the joint.
	func _put(changes: Dictionary, cell: Vector3i, material: PackedFloat32Array, along: float) -> void:
		if _written.has(cell) and float(_written[cell]) >= along:
			return
		changes[cell] = material
		_written[cell] = along

	func _along(pose: Dictionary, cell: Vector3i) -> float:
		var pivot: Vector3 = pose["pivot"]
		var bone: Vector3 = pose["bone"]
		return (Vector3(cell) - pivot).dot(bone)




var _joint_found := false
var _pivot := Vector3.ZERO
var _bone_dir := Vector3.ZERO
var _reach := 1.0
var _band := 0.0
var _limb := {}
var _poses: Array = []
var _bone: MeshInstance3D


# The hover joint and whether the press can capture a cell, keyed by the inputs
# that shape them. A pointer move inside one cell then costs no scan.
var _hover_key := ""
var _hover_joint := {}
var _hover_moves := false


func _action_name() -> String:
	return "Pose"


func _operation_label() -> String:
	return "Posing voxels"


func _ready() -> void:
	super._ready()
	_bone = get_node_or_null("Bone") as MeshInstance3D
	if _bone == null:
		return
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color.WHITE
	# The bone must stay readable inside geometry, like the footprint ring.
	material.no_depth_test = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_bone.material_override = material
	_bone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_bone.visible = false


func _clear_state() -> void:
	super._clear_state()
	_joint_found = false
	_limb = {}
	_poses = []
	_pivot = Vector3.ZERO
	_bone_dir = Vector3.ZERO
	_reach = 1.0
	_band = 0.0
	_hover_key = ""
	_hover_joint = {}
	_hover_moves = false
	if _bone != null:
		_bone.visible = false


func _capture_gesture(pick: PickResult) -> bool:
	var joint := DeformLimb.joint_pivot(_source_frame, _anchor, _stroke_size, _stroke_context)
	_joint_found = bool(joint["found"])
	if not _joint_found:
		return false
	_pivot = joint["pivot"]
	_bone_dir = joint["bone_dir"]
	_reach = float(joint["reach"])
	_band = DeformLimb.joint_band(_stroke_size, _stroke_falloff)
	# The allowance follows the footprint, so a small brush still bends a short
	# limb and a huge connected blob keeps its bend inside the brush.
	var ball := roundi(0.5236 * float(_stroke_size * _stroke_size * _stroke_size))
	var allowance := clampi(ball * LIMB_LIMIT_FACTOR, LIMB_MIN_LIMIT, LIMB_CELL_LIMIT)
	_limb = DeformLimb.capture_limb(_source_frame, _anchor, _pivot, _bone_dir, _band, allowance, _stroke_context)
	if _limb.is_empty():
		return false
	_poses = _build_poses()
	return true


func _allows(cell: Vector3i) -> bool:
	return _write_context == null or _write_context.allows(cell)


func _reflect(cell: Vector3i, mask: int) -> Vector3i:
	return _stroke_context.reflect(cell, mask) if _stroke_context != null else cell


func _mirror(point: Vector3, mask: int) -> Vector3:
	return DeformLimb.mirror_point(point, _stroke_context, mask)


# Builds one pose entry per active mask. The cells, the bone, and the joint of
# each mask mirror the captured limb, so a symmetric model stays symmetric.
func _build_poses() -> Array:
	var poses := []
	for mask in DeformLimb.masks_for(_stroke_context):
		var cells := {}
		for cell: Vector3i in _limb:
			cells[_reflect(cell, mask)] = _limb[cell]
		var pivot := _mirror(_pivot, mask)
		var bone := _mirror(_pivot + _bone_dir, mask) - pivot
		poses.append({
			"mask": mask,
			"pivot": pivot,
			"bone": bone.normalized(),
			"cells": cells,
			"angle": 0.0,
		})
	return poses


func _make_job(_target: Vector3i) -> DeformJob:
	if _limb.is_empty() or _poses.is_empty():
		return null
	var pressed := Vector3(_anchor)
	var travel := _drag_point - pressed
	if travel.length() < 0.001:
		return null
	# The axis is the view direction through the joint, so the bend lies in the
	# screen plane.
	var axis := -_view_forward
	var entries := []
	var work := 0
	var magnitude := 0.0
	for pose in _poses:
		var mask: int = pose["mask"]
		var cells: Dictionary = pose["cells"]
		var pivot: Vector3 = pose["pivot"]
		var bone := _mirror(pressed, mask) - pivot
		# The arm runs from the joint to the pointer, so the rotation carries the
		# bone onto the pointer. A travel vector would turn the limb by the angle to
		# the drag, which leaves the tip off the pointer.
		var arm := _mirror(_drag_point, mask) - pivot
		var screen_bone := DeformLimb.screen_vector(bone, _view_right, _view_up)
		var screen_arm := DeformLimb.screen_vector(arm, _view_right, _view_up)
		var angle := 0.0
		if screen_bone.length() < DEGENERATE_SCREEN or screen_arm.length() < DEGENERATE_SCREEN:
			# A bone that points at the viewer has no screen direction, so the bend
			# becomes a twist by the pointer travel. A mirrored mask turns the other
			# way. The lever has a floor, so a short bone cannot turn small pointer
			# motion into a large angle.
			var lever := maxf(DeformLimb.screen_length(bone, _view_right, _view_up), maxf(float(_stroke_size) * 0.5, 0.5))
			angle = DeformLimb.screen_vector(travel, _view_right, _view_up).length() / lever * DeformLimb.mask_handedness(mask)
		else:
			# The angle is the screen angle from the bone to the joint-to-pointer
			# arm, so the tip lands under the pointer.
			angle = screen_bone.angle_to(screen_arm)
		work += cells.size()
		entries.append({
			"mask": mask,
			"pivot": pivot,
			"bone": bone.normalized(),
			"cells": cells,
			"angle": angle,
			"axis": axis,
		})
		magnitude = maxf(magnitude, absf(float(entries[entries.size() - 1]["angle"])))
	if magnitude < ANGLE_EPSILON:
		return null
	# One magnitude serves every mask, so an obstacle on one side limits both sides.
	var fitted := _fit_angle(entries, magnitude)
	if fitted < ANGLE_EPSILON:
		return null
	for entry in entries:
		entry["angle"] = signf(float(entry["angle"])) * fitted
	var job := PoseJob.new()
	job.poses = entries
	# The map walks the box that the turned limb sweeps, so the estimate follows
	# that box. A large box then runs on a worker instead of the main thread.
	for entry in entries:
		work = maxi(work, _swept_volume(entry))
	job.work = work
	return job


# Returns the cell count of the box that one turned limb sweeps.
func _swept_volume(entry: Dictionary) -> int:
	var cells: Dictionary = entry["cells"]
	var low := Vector3(INF, INF, INF)
	var high := Vector3(-INF, -INF, -INF)
	for cell: Vector3i in cells:
		var turned := DeformLimb.turn_point(entry, cell, float(cells[cell]))
		low = low.min(Vector3(cell)).min(turned)
		high = high.max(Vector3(cell)).max(turned)
	return roundi((high.x - low.x + 3.0) * (high.y - low.y + 3.0) * (high.z - low.z + 3.0))


# Returns the largest magnitude up to [param magnitude] that turns every cell into
# an allowed cell. A blocked destination lowers the angle instead of leaving one
# side behind, so a symmetric pair always moves together.
func _fit_angle(entries: Array, magnitude: float) -> float:
	if _fits(entries, magnitude):
		return magnitude
	var low := 0.0
	var high := magnitude
	for _pass in FIT_PASSES:
		var middle := (low + high) * 0.5
		if _fits(entries, middle):
			low = middle
		else:
			high = middle
	return low


func _fits(entries: Array, magnitude: float) -> bool:
	for entry in entries:
		var cells: Dictionary = entry["cells"]
		var angle := signf(float(entry["angle"])) * magnitude
		for cell: Vector3i in cells:
			var turned := DeformLimb.turn_point(entry, cell, float(cells[cell]), angle)
			var destination := DeformLimb.round_cell(turned)
			if not _allows(destination):
				return false
			if destination == cell:
				continue
			# The fit reads the press-time frame, never the published preview. A
			# destination that the last preview filled would else lower the angle on
			# every second update, and the bend would flash between two values.
			if _baseline != null and _baseline.has(destination) and not cells.has(destination):
				return false
	return true

# Returns the hover joint and whether the press can capture a cell. The scan runs
# again only when an input that shapes it changes.
func _hover_state(pick: PickResult) -> Dictionary:
	var frame := State.get_current_voxel_frame()
	if frame == null:
		return {}
	var context := State.drawing_context()
	var key := _hover_key_for(pick, frame, context)
	if key == _hover_key:
		return {"joint": _hover_joint, "moves": _hover_moves}
	var joint := DeformLimb.joint_pivot(frame, pick.hit, _settings.size, context)
	var moves := false
	if bool(joint["found"]):
		# The hover answers one question: can the press capture a cell? One cell
		# is enough, so the walk never reads the whole limb.
		var band := DeformLimb.joint_band(_settings.size, _settings.falloff)
		var limb := DeformLimb.capture_limb(frame, pick.hit, joint["pivot"], joint["bone_dir"], band, 1, context)
		moves = not limb.is_empty()
	_hover_key = key
	_hover_joint = joint
	_hover_moves = moves
	return {"joint": _hover_joint, "moves": _hover_moves}


# Returns the hover cache key of one pick. The key holds the picked cell and every
# context input that the joint walk and the capture read. A sum of the cell
# components would collide two cells, and a missing input would show a stale joint.
func _hover_key_for(pick: PickResult, frame: VoxelFrame, context: VoxelFrame.EditContext) -> String:
	return str([
		frame.get_instance_id(), pick.hit,
		_settings.size, _settings.falloff,
		State.selection.revision,
		context.slice_axis, context.slice_index, context.slice_count,
		context.bounded_axes, context.bounds_min, context.bounds_max,
	])


# Poses the bone. It runs from the joint to the pointer: the exact drag point
# during a drag, and the cell center on a hover. A small marker cross shows the
# joint. An idle hover shows the same, so the user sees the rotation point before
# the press.
func _pose_bone(pick: PickResult) -> void:
	if _bone == null:
		return
	if pick == null or pick.hit == VoxelPicking.NONE or not is_inside_tree():
		_hide_bone()
		return
	var pivot := _pivot
	var tip := Vector3(pick.hit)
	if _edit == null:
		var state := _hover_state(pick)
		if state.is_empty() or not bool(state["joint"]["found"]) or not bool(state["moves"]):
			_hide_bone()
			return
		pivot = state["joint"]["pivot"]
	elif not _joint_found:
		_hide_bone()
		return
	else:
		# One line only. The rounded drag cell and the exact pointer are within
		# half a cell, so a second arm would read as a doubled bone.
		tip = _drag_point
	var vertices := PackedVector3Array()
	vertices.append(pivot)
	vertices.append(tip)
	# The joint marker is a three-axis cross, so it reads from any view.
	for offset in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
		vertices.append(pivot - offset * MARKER)
		vertices.append(pivot + offset * MARKER)
	_bone.global_transform = Transform3D(Basis.IDENTITY, Vector3.ZERO)
	_bone.mesh = TerrainRing.build_mesh(vertices)
	visible = true
	_bone.visible = true


func _hide_bone() -> void:
	if _bone != null:
		_bone.visible = false
