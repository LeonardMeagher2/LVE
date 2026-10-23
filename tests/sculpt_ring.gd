extends "res://tests/test.gd"

# Exercise the surface ring helper of the sculpt tools.
#
# The ring is the outer boundary of one brush footprint on the voxel surface. It
# must be one exact continuous circle on flat ground, it must land on the real
# cell face on a step, a slope, or a wall, and it must never draw a diagonal
# chord through solid or air.
#
# The helper is pure geometry, so the tests build their own frames and never
# open a tool, an edit, or a document.

const Ring := preload("res://plugins/Sculpt/SculptRing.gd")
const Geometry := preload("res://plugins/Sculpt/SculptGeometry.gd")
const BrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")

const EPS := 1e-4
const TOP := 0.5
const HALF := 44

var _frame: VoxelFrame
var _selection := {}


func _ready() -> void:
	test("a flat floor gives one exact continuous circle", _flat, "flat")
	test("every size spans its own width with the even bias", _sizes, "sizes")
	test("a face normal lands on the real face of six axes", _faces, "faces")
	test("an oblique normal keeps the exact cell front face", _oblique, "oblique")
	test("a step and a cliff show a riser and no cutting chord", _stairs, "stairs")
	test("a hole breaks the run and leaves no wrong segment", _holes, "holes")
	test("eight symmetry masks bake the whole pattern", _symmetry, "symmetry")
	test("an eligibility rule clips the ring to the real region", _eligibility, "eligibility")
	test("an empty floor gives a plane ring only for a seeding tool", _floor, "floor")
	test("a cancelled job returns no vertices", _cancel, "cancel")
	test("the boundary cost stays within the perimeter", _cost, "cost")
	test("the helper reads no state and mutates no resource", _isolation, "isolation")


# --- A flat floor -------------------------------------------------------------

func _flat() -> void:
	_frame = _frame_of(_slab(-HALF, HALF, 0, 0, -HALF, HALF))
	step("Given a flat floor and one brush of size 8", func() -> void:
		expect(_frame.has(Vector3i.ZERO), "the floor holds the center cell")
		expect(_frame.has(Vector3i(HALF, 0, -HALF)), "the floor reaches its far corner")
	)
	var size := 8
	step("When the ring is built with no outward lift", func() -> void:
		var fit := _fit(Vector3(0, TOP, 0), Vector3.UP, Vector3.RIGHT, Vector3.BACK)
		var data := Ring.surface_ring_data(_frame, fit, fit.origin, size, _context(), Callable(), null, null, 0.0)
		var vertices: PackedVector3Array = data["vertices"]
		var offset := BrushSize.center_offset(size)
		var radius := BrushSize.radius(size)
		expect(vertices.size() > 0, "the ring emits vertices")
		expect(int(data["segments"]) == Ring.segments_for(size), "a whole circle emits every segment")
		expect(int(data["breaks"]) == 0, "a flat floor has no break")
		expect(int(data["queries"]) == int(data["samples"]), "a flat floor asks one query per sample")
		var off_plane := 0
		var off_circle := 0
		var continuous := 0
		var planar_center := Vector2(offset, offset)
		for vertex in vertices:
			if absf(vertex.y - TOP) > EPS:
				off_plane += 1
			if absf((Vector2(vertex.x, vertex.z) - planar_center).length() - radius) > EPS:
				off_circle += 1
			if absf(vertex.x - roundf(vertex.x)) > 1e-3 or absf(vertex.z - roundf(vertex.z)) > 1e-3:
				continuous += 1
		expect(off_plane == 0, "every vertex sits on the top face plane")
		expect(off_circle == 0, "every vertex sits on the true circle of the brush")
		expect(continuous > 0, "the rim keeps continuous non-integer tangential points")
	)


# --- Every size ---------------------------------------------------------------

func _sizes() -> void:
	_frame = _frame_of(_slab(-HALF, HALF, 0, 0, -HALF, HALF))
	step("Given a floor that covers every size through 64", func() -> void:
		expect(_frame.has(Vector3i(HALF, 0, HALF)), "the floor reaches the widest corner")
	)
	step("Then every size spans its own width on both axes", func() -> void:
		for size in [1, 2, 63, 64]:
			var fit := _fit(Vector3(0, TOP, 0), Vector3.UP, Vector3.RIGHT, Vector3.BACK)
			var data := Ring.surface_ring_data(_frame, fit, fit.origin, size, _context(), Callable(), null, null, 0.0)
			var vertices: PackedVector3Array = data["vertices"]
			var offset := BrushSize.center_offset(size)
			var radius := BrushSize.radius(size)
			var low := INF
			var high := -INF
			var low_side := INF
			var high_side := -INF
			for vertex in vertices:
				low = minf(low, vertex.x)
				high = maxf(high, vertex.x)
				low_side = minf(low_side, vertex.z)
				high_side = maxf(high_side, vertex.z)
			expect(vertices.size() > 0, "size %d emits a ring" % size)
			# The side axis may hold no sample exactly on its extreme, so the span
			# may fall short by the chord sagitta of one segment.
			var sagitta := radius * (1.0 - cos(PI / float(Ring.segments_for(size))))
			expect(absf((high - low) - float(size)) <= 1e-3, "size %d spans %d cells" % [size, size])
			expect(absf((high_side - low_side) - float(size)) <= 2.0 * sagitta + 1e-3, "size %d spans %d cells on the side axis" % [size, size])
			expect(absf(high - (offset + radius)) <= 1e-3, "size %d reaches its high edge" % size)
			expect(absf(low - (offset - radius)) <= 1e-3, "size %d reaches its low edge" % size)
	)
	step("Then the same ring spans the same width in negative cells", func() -> void:
		var size := 5
		var center := Vector3(-20.5, TOP, -30.5)
		var fit := _fit(center, Vector3.UP, Vector3.RIGHT, Vector3.BACK)
		var data := Ring.surface_ring_data(_frame, fit, center, size, _context(), Callable(), null, null, 0.0)
		var vertices: PackedVector3Array = data["vertices"]
		var radius := BrushSize.radius(size)
		var low := INF
		var high := -INF
		for vertex in vertices:
			low = minf(low, vertex.x)
			high = maxf(high, vertex.x)
		expect(vertices.size() > 0, "the negative center emits a ring")
		expect(absf((high - low) - float(size)) <= 1e-3, "the negative ring spans its own width")
		expect(absf(low - (center.x + BrushSize.center_offset(size) - radius)) <= 1e-3, "the negative ring starts on the half cell edge")
	)


# --- The exact face -----------------------------------------------------------

func _faces() -> void:
	_frame = _frame_of(_slab(-10, 10, -10, 10, -10, 10))
	step("Given a solid cube", func() -> void:
		expect(_frame.has(Vector3i.ZERO), "the cube holds its center")
		expect(_frame.has(Vector3i(-10, -10, -10)), "the cube holds its low corner")
	)
	step("Then every axis normal lands on the real face plane", func() -> void:
		var outward := 10.5
		var cases := [
			[Vector3(0, outward, 0), Vector3.UP, Vector3.RIGHT, Vector3.BACK, 1, outward],
			[Vector3(0, -outward, 0), Vector3.DOWN, Vector3.RIGHT, Vector3.BACK, 1, -outward],
			[Vector3(outward, 0, 0), Vector3.RIGHT, Vector3.UP, Vector3.BACK, 0, outward],
			[Vector3(-outward, 0, 0), Vector3.LEFT, Vector3.UP, Vector3.BACK, 0, -outward],
			[Vector3(0, 0, outward), Vector3.BACK, Vector3.RIGHT, Vector3.UP, 2, outward],
			[Vector3(0, 0, -outward), Vector3.FORWARD, Vector3.RIGHT, Vector3.UP, 2, -outward],
		]
		for entry in cases:
			var origin: Vector3 = entry[0]
			var fit := _fit(origin, entry[1], entry[2], entry[3])
			var data := Ring.surface_ring_data(_frame, fit, origin, 8, _context(), Callable(), null, null, 0.0)
			var vertices: PackedVector3Array = data["vertices"]
			var axis := int(entry[4])
			var plane := float(entry[5])
			var others := [0, 1, 2]
			others.erase(axis)
			expect(vertices.size() > 0, "the %s face emits a ring" % origin)
			var wrong := 0
			var continuous := 0
			for vertex in vertices:
				if absf(vertex[axis] - plane) > EPS:
					wrong += 1
				if absf(vertex[others[0]] - roundf(vertex[others[0]])) > 1e-3 or absf(vertex[others[1]] - roundf(vertex[others[1]])) > 1e-3:
					continuous += 1
			expect(wrong == 0, "every vertex sits on the exact face plane")
			expect(continuous > 0, "the face ring keeps continuous tangential points on the real plane")
	)


func _oblique() -> void:
	_frame = _frame_of(_slab(-HALF, HALF, 0, 0, -HALF, HALF))
	step("Given a flat floor and a tilted surface normal", func() -> void:
		var normal := Vector3(0.5, sqrt(3.0) * 0.5, 0.0)
		var first := normal.cross(Vector3.UP).normalized()
		var fit := _fit(Vector3(0, TOP, 0), normal, first, normal.cross(first).normalized())
		var data := Ring.surface_ring_data(_frame, fit, fit.origin, 8, _context(), Callable(), null, null, 0.0)
		var vertices: PackedVector3Array = data["vertices"]
		expect(vertices.size() > 0, "an oblique normal emits a ring")
		var off_solid := 0
		var deep := 0
		var non_snapped := 0
		for vertex in vertices:
			if not _near_solid(vertex, EPS):
				off_solid += 1
			if _inside_occupied(vertex, 0.05):
				deep += 1
			if absf(vertex.x - roundf(vertex.x)) > 1e-3 and absf(vertex.z - roundf(vertex.z)) > 1e-3:
				non_snapped += 1
		expect(off_solid == 0, "every oblique vertex sits on a real cell box face")
		expect(deep == 0, "no oblique vertex sits deep inside the solid")
		expect(non_snapped > 0, "the oblique rim is not snapped to cell centers")
	)


# --- A step and a cliff -------------------------------------------------------

func _stairs() -> void:
	step("Given a one cell step and a five cell cliff", func() -> void:
		var step_frame := _step_model(1)
		var cliff_frame := _step_model(5)
		expect(step_frame.has(Vector3i(-1, 0, 0)), "the step holds its low ground")
		expect(step_frame.has(Vector3i(0, 1, 0)), "the step holds its high tread")
		expect(not cliff_frame.has(Vector3i(-1, 5, 0)), "the cliff holds no high cell over the ground")
		expect(cliff_frame.has(Vector3i(0, 5, 0)), "the cliff holds its top")
		_check_profile(step_frame, Vector3(-3.0, TOP, 0.0), "step")
		_check_profile(cliff_frame, Vector3(-3.0, TOP, 0.0), "cliff")
	)


func _check_profile(frame: VoxelFrame, center: Vector3, label: String) -> void:
	_frame = frame
	var fit := _fit(center, Vector3.UP, Vector3.RIGHT, Vector3.BACK)
	var data := Ring.surface_ring_data(frame, fit, center, 8, _context(), Callable(), null, null, 0.0)
	var vertices: PackedVector3Array = data["vertices"]
	expect(vertices.size() > 0, "the %s ring emits vertices" % label)
	var cutting := 0
	var risers := 0
	var deep := 0
	for index in vertices.size() / 2:
		var one := vertices[index * 2]
		var other := vertices[index * 2 + 1]
		var tread := absf(one.y - other.y) <= EPS
		var riser := absf(one.x - other.x) <= 0.05 and absf(one.z - other.z) <= 0.05
		if not tread and not riser:
			cutting += 1
		if riser:
			risers += 1
		for sample_index in range(1, 8):
			if _inside_occupied(one.lerp(other, float(sample_index) / 8.0), 0.05):
				deep += 1
	expect(cutting == 0, "the %s ring draws every step as a tread or a riser" % label)
	expect(deep == 0, "no %s segment passes through a solid voxel" % label)
	expect(risers >= 1, "the %s ring draws its exposed riser" % label)


# --- A hole -------------------------------------------------------------------

func _holes() -> void:
	var changes := _slab(-HALF, HALF, 0, 0, -HALF, HALF)
	for x in range(3, 6):
		for z in range(-2, 3):
			changes.erase(Vector3i(x, 0, z))
	_frame = _frame_of(changes)
	step("Given a floor with a hole under the rim", func() -> void:
		expect(not _frame.has(Vector3i(4, 0, 0)), "the hole is empty")
		expect(_frame.has(Vector3i(6, 0, 0)), "the floor continues beside the hole")
	)
	step("Then the ring breaks and keeps no wrong segment", func() -> void:
		var fit := _fit(Vector3(0, TOP, 0), Vector3.UP, Vector3.RIGHT, Vector3.BACK)
		var data := Ring.surface_ring_data(_frame, fit, fit.origin, 8, _context(), Callable(), null, null, 0.0)
		var vertices: PackedVector3Array = data["vertices"]
		expect(int(data["breaks"]) > 0, "the hole breaks the run")
		expect(vertices.size() / 2 < int(data["samples"]), "the ring is an open arc")
		var wrong := 0
		for index in vertices.size() / 2:
			var one := vertices[index * 2]
			var other := vertices[index * 2 + 1]
			if absf(one.y - TOP) > EPS or absf(other.y - TOP) > EPS:
				wrong += 1
			if not one.is_finite() or not other.is_finite():
				wrong += 1
		expect(wrong == 0, "every remaining segment stays on the floor plane")
	)


# --- Symmetry -----------------------------------------------------------------

func _symmetry() -> void:
	_frame = _frame_of(_slab(-HALF, HALF, 0, 0, -HALF, HALF))
	step("Given eight symmetry masks around the origin and an even size", func() -> void:
		var fit := _fit(Vector3(0, TOP, 0), Vector3.UP, Vector3.RIGHT, Vector3.BACK)
		var context := _context(7, Vector3i.ZERO)
		var data := Ring.surface_ring_data(_frame, fit, fit.origin, 4, context, Callable(), null, null, 0.0)
		var vertices: PackedVector3Array = data["vertices"]
		expect(int(data["masks"]) == 8, "every mask is baked")
		expect(vertices.size() > 0, "the symmetric ring emits vertices")
		var keys := {}
		for vertex in vertices:
			keys[_key(vertex)] = true
		var missing := 0
		for vertex in vertices:
			if not keys.has(_key(-vertex)):
				missing += 1
		expect(missing == 0, "every vertex has its own mirrored partner")
	)


# --- Eligibility --------------------------------------------------------------

func _eligibility() -> void:
	_frame = _frame_of(_slab(-HALF, HALF, 0, 0, -HALF, HALF))
	var fit := _fit(Vector3(0, TOP, 0), Vector3.UP, Vector3.RIGHT, Vector3.BACK)
	step("Given a Grow Add rule that tests the destination cell", func() -> void:
		_selection = {}
		var data := Ring.surface_ring_data(_frame, fit, fit.origin, 8, _context(), Callable(self, "_destination_allowed"), null, null, 0.0)
		expect(int(data["segments"]) == Ring.segments_for(8), "an open rule keeps the whole ring")
	)
	step("When the rule allows only the support cells", func() -> void:
		_selection = {}
		for cell in _slab(-HALF, HALF, 0, 0, -HALF, HALF):
			_selection[cell] = true
		var data := Ring.surface_ring_data(_frame, fit, fit.origin, 8, _context(), Callable(self, "_destination_allowed"), null, null, 0.0)
		expect((data["vertices"] as PackedVector3Array).is_empty(), "a support only selection leaves no ring")
	)
	step("When the rule allows half of the destinations", func() -> void:
		_selection = {}
		for cell in _slab(2, HALF, 1, 1, -HALF, HALF):
			_selection[cell] = true
		var data := Ring.surface_ring_data(_frame, fit, fit.origin, 8, _context(), Callable(self, "_destination_allowed"), null, null, 0.0)
		var segments := int(data["segments"])
		expect(segments > 0, "the allowed half keeps a ring")
		expect(segments < Ring.segments_for(8), "the refused half clips the ring")
		expect(int(data["breaks"]) > 0, "the clip opens the run")
	)


# Returns true when the destination of one Grow Add sample stays in the
# selection. The rule reads the destination cell, never the support cell.
func _destination_allowed(cell: Vector3i, normal: Vector3, _point: Vector3) -> bool:
	return _selection.is_empty() or _selection.has(Geometry.layer_step(cell, normal, 1))


# --- An empty floor -----------------------------------------------------------

func _floor() -> void:
	step("Given the seed rule of every sculpt tool", func() -> void:
		expect(Ring.floor_ring_applies(SculptToolSettings.Tools.GROW, SculptToolSettings.GrowMode.ADD), "Grow Add seeds the floor")
		expect(Ring.floor_ring_applies(SculptToolSettings.Tools.FLATTEN, SculptToolSettings.GrowMode.ADD), "Flatten seeds the floor")
		expect(not Ring.floor_ring_applies(SculptToolSettings.Tools.GROW, SculptToolSettings.GrowMode.REMOVE), "Grow Remove seeds nothing")
		expect(not Ring.floor_ring_applies(SculptToolSettings.Tools.SMOOTH, SculptToolSettings.GrowMode.ADD), "Smooth seeds nothing")
	)
	step("Then an empty frame gives no surface ring and a clean plane ring", func() -> void:
		var empty := VoxelFrame.new()
		var fit := _fit(Vector3(0, TOP, 0), Vector3.UP, Vector3.RIGHT, Vector3.BACK)
		var surface := Ring.surface_ring(empty, fit, fit.origin, 8, _context(), Callable(), null, null, 0.0)
		expect(surface.is_empty(), "an empty frame gives no surface ring")
		var plane := Ring.plane_ring(fit, fit.origin, 8, _context(), 0.0)
		expect(plane.size() == Ring.segments_for(8) * 2, "the plane ring closes every segment")
		var radius := BrushSize.radius(8)
		var center_planar := Vector2(BrushSize.center_offset(8), BrushSize.center_offset(8))
		var off_plane := 0
		var off_circle := 0
		for vertex in plane:
			if absf(vertex.y - TOP) > EPS:
				off_plane += 1
			if absf((Vector2(vertex.x, vertex.z) - center_planar).length() - radius) > EPS:
				off_circle += 1
		expect(off_plane == 0, "the plane ring lies in the floor plane")
		expect(off_circle == 0, "the plane ring is the true circle")
	)


# --- Cancellation -------------------------------------------------------------

func _cancel() -> void:
	_frame = _frame_of(_slab(-HALF, HALF, 0, 0, -HALF, HALF))
	var fit := _fit(Vector3(0, TOP, 0), Vector3.UP, Vector3.RIGHT, Vector3.BACK)
	step("Given a ring that passes several checkpoints", func() -> void:
		expect(Ring.segments_for(64) > Ring.CHECKPOINT, "the largest ring passes the checkpoint")
	)
	step("When the job was cancelled before the build", func() -> void:
		var data := Ring.surface_ring_data(_frame, fit, fit.origin, 64, _context(), Callable(), _gate(0), null, 0.0)
		expect((data["vertices"] as PackedVector3Array).is_empty(), "a pre cancelled job returns no vertices")
		expect(int(data["queries"]) > 0, "the cancelled build stopped at a checkpoint")
	)
	step("When the job is cancelled in the middle of the build", func() -> void:
		var data := Ring.surface_ring_data(_frame, fit, fit.origin, 64, _context(), Callable(), _gate(2), null, 0.0)
		expect((data["vertices"] as PackedVector3Array).is_empty(), "a mid cancelled job returns no vertices")
		expect(int(data["queries"]) > Ring.CHECKPOINT, "the build ran past the first checkpoint")
	)


class GateJob extends VoxelFrame.EditJob:
	var allowed := 0
	var calls := 0

	func checkpoint(_completed: int) -> bool:
		calls += 1
		return calls <= allowed


func _gate(allowed: int) -> VoxelFrame.EditJob:
	var job := GateJob.new()
	job.allowed = allowed
	return job


# --- Cost ---------------------------------------------------------------------

func _cost() -> void:
	var flat := _frame_of(_slab(-HALF, HALF, 0, 0, -HALF, HALF))
	var slope := _slope_model()
	step("Then the largest flat ring stays within the perimeter cost", func() -> void:
		var fit := _fit(Vector3(0, TOP, 0), Vector3.UP, Vector3.RIGHT, Vector3.BACK)
		var started := Time.get_ticks_usec()
		var data := Ring.surface_ring_data(flat, fit, fit.origin, 64, _context(), Callable(), null, null, 0.0)
		var elapsed := Time.get_ticks_usec() - started
		var samples := int(data["samples"])
		expect(int(data["queries"]) == samples, "the flat ring asks exactly one query per sample")
		expect(int(data["segments"]) == samples, "the flat ring emits one segment per sample")
		expect(int(data["segments"]) <= Ring.MAX_SEGMENTS, "the emitted segments stay bounded")
		print("    flat size 64: %d queries, %d segments, %.2f ms" % [data["queries"], data["segments"], elapsed / 1000.0])
	)
	step("Then a staircase slope stays within a small multiple of the perimeter", func() -> void:
		var fit := _fit(Vector3(0, TOP, 0), Vector3.UP, Vector3.RIGHT, Vector3.BACK)
		var started := Time.get_ticks_usec()
		var data := Ring.surface_ring_data(slope, fit, fit.origin, 16, _context(), Callable(), null, null, 0.0)
		var elapsed := Time.get_ticks_usec() - started
		var samples := int(data["samples"])
		expect((data["vertices"] as PackedVector3Array).size() > 0, "the slope emits a ring")
		expect(int(data["queries"]) <= samples * 4, "a staircase adds only its bounded bisections")
		expect(int(data["segments"]) <= samples * 2, "the stepped ring stays within twice the samples")
		print("    slope size 16: %d queries, %d segments, %d breaks, %.2f ms" % [data["queries"], data["segments"], data["breaks"], elapsed / 1000.0])
	)


# --- Isolation ----------------------------------------------------------------

func _isolation() -> void:
	step("Then the helper names no editor state and no node", func() -> void:
		var source := FileAccess.get_file_as_string("res://plugins/Sculpt/SculptRing.gd")
		for forbidden in ["State.", "get_node", "add_child", "get_tree", "get_viewport", "Engine.", "WorkerThreadPool", "Node3D", "MeshInstance3D"]:
			expect(not source.contains(forbidden), "the helper never names %s" % forbidden)
	)
	step("Then the mesh build mutates no shared material", func() -> void:
		var material: StandardMaterial3D = load("res://plugins/cursor_material.tres")
		var albedo := material.albedo_color
		var shading := material.shading_mode
		var priority := material.render_priority
		var depth_test := material.no_depth_test
		var fit := _fit(Vector3(0, TOP, 0), Vector3.UP, Vector3.RIGHT, Vector3.BACK)
		var small := _frame_of(_slab(-8, 8, 0, 0, -8, 8))
		var vertices := Ring.surface_ring(small, fit, fit.origin, 8, _context(), Callable(), null, null, 0.0)
		var mesh := Ring.build_mesh(vertices)
		expect(vertices.size() > 0, "the small ring emits vertices")
		expect(mesh.get_surface_count() == 1, "the mesh holds one line surface")
		expect(mesh.surface_get_material(0) == null, "the mesh carries no surface material")
		expect(
			material.albedo_color == albedo and material.shading_mode == shading
			and material.render_priority == priority and material.no_depth_test == depth_test,
			"the cursor material is unchanged"
		)
	)


# --- Fixtures -----------------------------------------------------------------

func _frame_of(changes: Dictionary) -> VoxelFrame:
	var frame := VoxelFrame.new()
	frame.set_cells(changes)
	return frame


func _slab(x_low: int, x_high: int, y_low: int, y_high: int, z_low: int, z_high: int) -> Dictionary:
	var changes := {}
	var material := VoxelFrame.material(Color.WHITE)
	for x in range(x_low, x_high + 1):
		for y in range(y_low, y_high + 1):
			for z in range(z_low, z_high + 1):
				changes[Vector3i(x, y, z)] = material
	return changes


# A low ground on the negative side and a raised top on the positive side.
func _step_model(height: int) -> VoxelFrame:
	var changes := _slab(-HALF, -1, 0, 0, -HALF, HALF)
	var raised := _slab(0, HALF, 0, height, -HALF, HALF)
	for cell in raised:
		changes[cell] = raised[cell]
	return _frame_of(changes)


# A staircase that rises one cell every two columns.
func _slope_model() -> VoxelFrame:
	var changes := {}
	var material := VoxelFrame.material(Color.WHITE)
	for x in range(-HALF, HALF + 1):
		var top := maxi(0, x) / 2
		for y in range(0, top + 1):
			for z in range(-HALF, HALF + 1):
				changes[Vector3i(x, y, z)] = material
	return _frame_of(changes)


func _fit(origin: Vector3, normal: Vector3, first: Vector3, second: Vector3) -> SculptFrame:
	var frame := SculptFrame.new()
	frame.origin = origin
	frame.normal = normal.normalized()
	frame.tangent_u = first.normalized()
	frame.tangent_v = second.normalized()
	frame.axis = Geometry.dominant_axis(frame.normal)
	frame.sign = 1 if frame.normal[frame.axis] >= 0.0 else -1
	return frame


func _context(axes := 0, origin_twice := Vector3i.ZERO) -> VoxelFrame.EditContext:
	var context := VoxelFrame.EditContext.new()
	context.axes = axes
	context.origin_twice = origin_twice
	return context


# --- Cell probes --------------------------------------------------------------

# Returns true when a point lies inside an occupied cell with the given margin
# from every face. A point exactly on a face is never inside.
func _inside_occupied(point: Vector3, margin: float) -> bool:
	for cell in _nearby(point):
		if not _frame.has(cell):
			continue
		var delta := (point - Vector3(cell)).abs()
		if delta.x <= 0.5 - margin and delta.y <= 0.5 - margin and delta.z <= 0.5 - margin:
			return true
	return false


# Returns true when a point lies on or inside an occupied cell box, within the
# tolerance.
func _near_solid(point: Vector3, tolerance: float) -> bool:
	for cell in _nearby(point):
		if not _frame.has(cell):
			continue
		var delta := (point - Vector3(cell)).abs()
		if delta.x <= 0.5 + tolerance and delta.y <= 0.5 + tolerance and delta.z <= 0.5 + tolerance:
			return true
	return false


func _nearby(point: Vector3) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	var base := Vector3i(roundi(point.x), roundi(point.y), roundi(point.z))
	for x in range(base.x - 1, base.x + 2):
		for y in range(base.y - 1, base.y + 2):
			for z in range(base.z - 1, base.z + 2):
				cells.append(Vector3i(x, y, z))
	return cells


func _key(point: Vector3) -> String:
	return "%d:%d:%d" % [roundi(point.x * 1000.0), roundi(point.y * 1000.0), roundi(point.z * 1000.0)]
