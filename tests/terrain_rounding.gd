extends "res://tests/test.gd"

# The broad rounding tests drive the pure 3D occupancy rounding module at the
# broad radius. The base radius keeps its own tests in `terrain_smooth.gd`. These
# tests cover the rounding depth, the bounded fixed point, the thin-feature
# protection, the deterministic result, and the cancellation contract. They
# never touch the tool, the settings, or the editor state.

const SmoothOperation := preload("res://plugins/Terrain/SmoothOperation.gd")

const BASE := SmoothOperation.KERNEL_RADIUS
const BROAD := SmoothOperation.BROAD_RADIUS

var _occupied := {}
var _cells: Array = []
var _result := {}
var _other := {}
var _weights := {}


func _ready() -> void:
	test("the broad edge rounds two cells and stops", _broad_edge_rounds, "broad_edge")
	test("the ball radius sets the rounding depth", _radius_scales_depth, "broad_depth")
	test("the broad corner is bounded", _broad_corner_bounded, "broad_corner")
	test("the broad rule keeps a flat face", _broad_flat_face, "broad_flat")
	test("the broad rule fills a notch deeper and stops", _broad_notch, "broad_notch")
	test("the broad rule keeps one- and two-cell plates", _broad_thin_plate, "broad_plate")
	test("the broad rule keeps a small cube on the base rule", _broad_small_cube, "broad_cube")
	test("the broad rule rounds a spike tip and keeps the plate", _broad_spike, "broad_spike")
	test("mirrored features round equally at the broad radius", _broad_mirrored, "broad_mirrored")
	test("the broad insertion order does not change the result", _broad_insertion_order, "broad_order")
	test("a broad split gives the same result as one call", _broad_split, "broad_split")
	test("a cancelled broad pass applies nothing", _broad_cancel, "broad_cancel")
	test("the broad rule never writes outside the patch", _broad_patch_boundary, "broad_patch")
	test("the base radius keeps its one-cell bevel", _base_bevel, "broad_base")
	test("the read halo and the read offsets follow the radius", _halo_contract, "broad_halo")
	test("a truncated gather through the read halo matches the full set", _halo_truncated_matches, "broad_truncated")
	test("a single surface cell reads only its declared halo", _halo_single_cell, "broad_single")
	test("a compound shape stops changing and does not oscillate", _compound_stability, "broad_stable")
	test("no pass leaves a voxel without a face neighbor", _no_isolated_remnant, "broad_isolated")


# Resets the fixtures. Each test builds its own set in a step.
func before_test() -> void:
	_occupied = {}
	_cells = []
	_result = {}
	_other = {}
	_weights = {}


# --- Helpers ----------------------------------------------------------------

# Fills the inclusive box from lo to hi into _occupied.
func _fill(lo: Vector3i, hi: Vector3i) -> void:
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			for z in range(lo.z, hi.z + 1):
				_occupied[Vector3i(x, y, z)] = true


# Returns every cell of the inclusive box.
func _box(lo: Vector3i, hi: Vector3i) -> Array:
	var cells := []
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			for z in range(lo.z, hi.z + 1):
				cells.append(Vector3i(x, y, z))
	return cells


# A convex edge along z. The solid is the quadrant x <= 0 and y <= 0.
func _quadrant_edge() -> void:
	_occupied = {}
	for x in range(-10, 1):
		for y in range(-10, 1):
			for z in range(-8, 9):
				_occupied[Vector3i(x, y, z)] = true
	_cells = _box(Vector3i(-6, -6, -6), Vector3i(6, 6, 6))


# The removed depth of the edge along x = 0. The value is the first occupied
# cell from the corner toward -y.
func _edge_depth(occupied: Dictionary) -> int:
	var depth := 0
	while not occupied.has(Vector3i(0, -depth, 0)):
		depth += 1
	return depth


func _has_remove(cell: Vector3i) -> bool:
	return (_result["remove"] as Array).has(cell)


func _has_add(cell: Vector3i) -> bool:
	return (_result["add"] as Array).has(cell)


# --- Shape rules ------------------------------------------------------------

func _broad_edge_rounds() -> void:
	step("Given a convex edge and the broad radius", func():
		_quadrant_edge()
	)
	step("When the set rounds for twelve passes and then for forty", func():
		_result = SmoothOperation.relax(_occupied, _cells, 12, BROAD)
		_other = SmoothOperation.relax(_occupied, _cells, 40, BROAD)
	)
	step("Then the edge loses two cells and the fixed point holds", func():
		var occupied: Dictionary = _result["occupied"]
		expect(not occupied.has(Vector3i(0, 0, 0)), "the corner cell is removed")
		expect(not occupied.has(Vector3i(0, -1, 0)), "the second edge cell is removed")
		expect(occupied.has(Vector3i(0, -2, 0)), "the third edge cell is kept, so the bevel stops")
		expect(occupied.has(Vector3i(0, -3, 0)), "the face beyond the bevel stays")
		expect(_result["occupied"] == _other["occupied"], "forty passes change nothing more")
		expect(_edge_depth(occupied) == 2, "the removed depth is two cells")
	)


func _radius_scales_depth() -> void:
	step("Given a convex edge and three radii", func():
		_quadrant_edge()
	)
	step("When the set rounds for twelve passes at each radius", func():
		_result = SmoothOperation.relax(_occupied, _cells, 12, BASE)
		_other = {
			2: SmoothOperation.relax(_occupied, _cells, 12, 2),
			3: SmoothOperation.relax(_occupied, _cells, 12, 3),
		}
	)
	step("Then the removed depth follows the ball radius", func():
		expect(_edge_depth(_result["occupied"]) == 1, "the base radius removes one cell")
		expect(_edge_depth(_other[2]["occupied"]) == 2, "radius two removes two cells")
		expect(_edge_depth(_other[3]["occupied"]) == 3, "radius three removes three cells")
	)


func _broad_corner_bounded() -> void:
	step("Given a convex corner of an octant", func():
		_occupied = {}
		_fill(Vector3i(-10, -10, -10), Vector3i(0, 0, 0))
		_cells = _box(Vector3i(-6, -6, -6), Vector3i(6, 6, 6))
	)
	step("When the set rounds for twelve passes and then for forty", func():
		_result = SmoothOperation.relax(_occupied, _cells, 12, BROAD)
		_other = SmoothOperation.relax(_occupied, _cells, 40, BROAD)
	)
	step("Then the corner rounds and the fixed point holds", func():
		var occupied: Dictionary = _result["occupied"]
		expect(not occupied.has(Vector3i(0, 0, 0)), "the corner cell is removed")
		expect(occupied.has(Vector3i(-2, -2, -2)), "a cell two diagonal steps in stays")
		expect(_result["occupied"] == _other["occupied"], "forty passes change nothing more")
	)


func _broad_flat_face() -> void:
	step("Given a half-space with a flat top face", func():
		_occupied = {}
		_fill(Vector3i(-6, -6, -6), Vector3i(6, 0, 6))
		_cells = _box(Vector3i(-3, -1, -3), Vector3i(3, 2, 3))
	)
	step("When the set rounds for six passes at the broad radius", func():
		_result = SmoothOperation.relax(_occupied, _cells, 6, BROAD)
	)
	step("Then no candidate moves", func():
		expect((_result["remove"] as Array).is_empty(), "a flat face removes no cell")
		expect((_result["add"] as Array).is_empty(), "a flat face adds no cell")
	)


func _broad_notch() -> void:
	step("Given an inside corner with an empty quadrant", func():
		_occupied = {}
		for x in range(-6, 7):
			for y in range(-6, 7):
				for z in range(-6, 7):
					if x <= 0 or y <= 0:
						_occupied[Vector3i(x, y, z)] = true
		_cells = _box(Vector3i(-2, -2, -3), Vector3i(5, 5, 3))
	)
	step("When the set rounds for eight passes at both radii and then forty", func():
		_result = SmoothOperation.relax(_occupied, _cells, 8, BROAD)
		_other = {
			"base": SmoothOperation.relax(_occupied, _cells, 8, BASE),
			"late": SmoothOperation.relax(_occupied, _cells, 40, BROAD),
		}
	)
	step("Then the broad rule fills deeper and stops", func():
		expect(_has_add(Vector3i(1, 1, 0)), "the corner cell fills")
		expect((_result["add"] as Array).size() > (_other["base"]["add"] as Array).size(), "the broad rule fills more than the base rule")
		expect(_result["add"] == _other["late"]["add"], "forty passes change nothing more")
	)


func _broad_thin_plate() -> void:
	step("Given a two-cell plate", func():
		_occupied = {}
		for x in range(-6, 7):
			for z in range(-6, 7):
				for y in range(2):
					_occupied[Vector3i(x, y, z)] = true
		_cells = _box(Vector3i(-3, -2, -3), Vector3i(3, 3, 3))
	)
	step("When the plate rounds for six passes at every radius", func():
		_result = SmoothOperation.relax(_occupied, _cells, 6, BASE)
		_other = {
			2: SmoothOperation.relax(_occupied, _cells, 6, 2),
			3: SmoothOperation.relax(_occupied, _cells, 6, 3),
		}
	)
	step("Then the two-cell plate never loses a cell", func():
		expect((_result["remove"] as Array).is_empty(), "the base rule keeps the two-cell plate")
		expect((_other[2]["remove"] as Array).is_empty(), "radius two keeps the two-cell plate")
		expect((_other[3]["remove"] as Array).is_empty(), "radius three keeps the two-cell plate")
		expect((_other[2]["add"] as Array).is_empty(), "radius two adds nothing to the plate")
	)
	step("Given a one-cell plate and a one-cell wall", func():
		_occupied = {}
		for x in range(-6, 7):
			for z in range(-6, 7):
				_occupied[Vector3i(x, 0, z)] = true
		_cells = _box(Vector3i(-3, -1, -3), Vector3i(3, 1, 3))
	)
	step("Then the one-cell plate is unchanged at the broad radius", func():
		_result = SmoothOperation.relax(_occupied, _cells, 6, BROAD)
		expect((_result["remove"] as Array).is_empty(), "the one-cell plate survives")
		expect((_result["add"] as Array).is_empty(), "the one-cell plate fills nothing")
	)


func _broad_small_cube() -> void:
	step("Given a small cube and a patch over it", func():
		_occupied = {}
		_fill(Vector3i.ZERO, Vector3i(4, 4, 4))
		_cells = _box(Vector3i(-1, -1, -1), Vector3i(5, 5, 5))
	)
	step("When the cube rounds for one pass and for eight at both radii", func():
		_result = SmoothOperation.relax(_occupied, _cells, 1, BASE)
		_other = {
			"broad1": SmoothOperation.relax(_occupied, _cells, 1, BROAD),
			"base8": SmoothOperation.relax(_occupied, _cells, 8, BASE),
			"broad8": SmoothOperation.relax(_occupied, _cells, 8, BROAD),
		}
	)
	step("Then the small cube keeps the base rule and never vanishes", func():
		expect(_result["occupied"] == _other["broad1"]["occupied"], "one broad pass matches one base pass")
		expect((_other["broad1"]["occupied"] as Dictionary).size() > 0, "the broad rule does not erase the cube in one pass")
		expect(_other["base8"]["occupied"] == _other["broad8"]["occupied"], "eight broad passes match eight base passes")
	)


func _broad_spike() -> void:
	step("Given a plate with a five-cell spike", func():
		_occupied = {}
		for x in range(-8, 9):
			for z in range(-8, 9):
				_occupied[Vector3i(x, 0, z)] = true
		for y in range(1, 6):
			_occupied[Vector3i(0, y, 0)] = true
		_cells = _box(Vector3i(-3, -2, -3), Vector3i(3, 7, 3))
	)
	step("When the set rounds for one pass at the broad radius", func():
		_result = SmoothOperation.relax(_occupied, _cells, 1, BROAD)
	)
	step("Then the tip rounds and the plate stays", func():
		var occupied: Dictionary = _result["occupied"]
		expect(not occupied.has(Vector3i(0, 5, 0)), "the spike tip is removed")
		expect(occupied.has(Vector3i(3, 0, 3)), "the plate away from the spike stays")
	)


func _broad_mirrored() -> void:
	step("Given two mirrored spikes on a plate", func():
		_occupied = {}
		for x in range(-8, 9):
			for z in range(-3, 4):
				_occupied[Vector3i(x, 0, z)] = true
		for y in range(1, 5):
			_occupied[Vector3i(-3, y, 0)] = true
			_occupied[Vector3i(3, y, 0)] = true
		_cells = _box(Vector3i(-5, -1, -3), Vector3i(5, 5, 3))
	)
	step("When the set rounds for four passes at the broad radius", func():
		_result = SmoothOperation.relax(_occupied, _cells, 4, BROAD)
	)
	step("Then the mirrored cells get equal decisions", func():
		var right := _has_remove(Vector3i(3, 4, 0))
		var left := _has_remove(Vector3i(-3, 4, 0))
		expect(right, "the right spike tip is removed")
		expect(right == left, "the mirrored spike tip gets the same decision")
	)


func _broad_insertion_order() -> void:
	step("Given a convex edge in two insertion orders", func():
		_quadrant_edge()
		_other = {}
		var keys := _occupied.keys()
		keys.reverse()
		for cell: Vector3i in keys:
			_other[cell] = true
	)
	step("When both sets round for eight passes at the broad radius", func():
		_result = SmoothOperation.relax(_occupied, _cells, 8, BROAD)
		_other = SmoothOperation.relax(_other, _cells, 8, BROAD)
	)
	step("Then both results match", func():
		expect(_result["remove"] == _other["remove"], "the insertion order does not change the removed cells")
		expect(_result["add"] == _other["add"], "the insertion order does not change the filled cells")
		expect(not (_result["remove"] as Array).is_empty(), "the edge moves in both orders")
	)


func _broad_split() -> void:
	step("Given a convex edge", func():
		_quadrant_edge()
	)
	step("When the set advances six passes in one dab", func():
		_result = SmoothOperation.advance(_occupied, _cells, 6, BROAD)
	)
	step("When the same six passes run as two dabs of three", func():
		var occupied := _occupied
		for _dab in 2:
			var outcome := SmoothOperation.advance(occupied, _cells, 3, BROAD, 0.5, 0.5, _weights)
			occupied = outcome["occupied"]
		_other = {"occupied": occupied}
	)
	step("Then the two dabs give the same occupancy", func():
		expect(int(_result["passes"]) == 6, "the single dab runs six passes")
		expect(_result["occupied"] == _other["occupied"], "the two dabs match the single dab exactly")
	)


func _broad_cancel() -> void:
	step("Given a convex edge and a cancel that stops at once", func():
		_quadrant_edge()
		_other = _occupied.duplicate()
	)
	step("When the broad pass is cancelled", func():
		_result = SmoothOperation.relax(_occupied, _cells, 8, BROAD, 0.5, 0.5, {}, func(_count: int) -> bool: return false)
	)
	step("Then the pass applies nothing", func():
		expect(_result.has("cancelled"), "the pass reports its cancellation")
		expect(_result["occupied"] == _other, "the occupancy is the unchanged input")
		expect((_result["remove"] as Array).is_empty() and (_result["add"] as Array).is_empty(), "the cancelled pass removes and adds nothing")
		expect(_occupied == _other, "the cancel preserves the frozen input")
	)


func _broad_patch_boundary() -> void:
	step("Given a convex edge with a small patch and a read-only neighbor", func():
		_quadrant_edge()
		# Only the corner region is writable. The cells outside stay read only.
		_cells = _box(Vector3i(-2, -2, -1), Vector3i(2, 2, 1))
		_other = _occupied.duplicate()
	)
	step("When the patch rounds for eight passes at the broad radius", func():
		_result = SmoothOperation.relax(_occupied, _cells, 8, BROAD)
	)
	step("Then only patch cells differ and the frozen input is unchanged", func():
		expect(_occupied == _other, "the operation never mutates the input")
		for cell: Vector3i in _result["remove"]:
			expect((_cells as Array).has(cell), "a removed cell is inside the patch")
		for cell: Vector3i in _result["add"]:
			expect((_cells as Array).has(cell), "an added cell is inside the patch")
		var occupied: Dictionary = _result["occupied"]
		expect(occupied.has(Vector3i(0, -4, 0)), "a read-only cell outside the patch stays")
		expect(occupied.has(Vector3i(-4, 0, 0)), "the halo neighbor outside the patch is untouched")
		expect(not occupied.has(Vector3i(0, 0, 0)), "the patch corner still rounds")
	)


func _base_bevel() -> void:
	step("Given a convex edge at the base radius", func():
		_quadrant_edge()
	)
	step("When the set rounds for twenty passes", func():
		_result = SmoothOperation.relax(_occupied, _cells, 20, BASE)
	)
	step("Then the bevel stops at one cell", func():
		expect(_edge_depth(_result["occupied"]) == 1, "the base radius removes one cell only")
	)


# --- Read halo contract -----------------------------------------------------

func _halo_contract() -> void:
	step("Given the base and the broad radius", func():
		_result = {
			"base_halo": SmoothOperation.required_halo(BASE),
			"broad_halo": SmoothOperation.required_halo(BROAD),
			"base_read": SmoothOperation.read_offsets(BASE),
			"broad_read": SmoothOperation.read_offsets(BROAD),
		}
	)
	step("Then the halo and the read set follow the radius", func():
		expect(int(_result["base_halo"]) == 1, "radius one keeps the base halo of one cell")
		expect(int(_result["broad_halo"]) == SmoothOperation.THIN_MULTIPLIER * BROAD, "the broad halo covers the thin probes")
		var base_read: Array = _result["base_read"]
		expect(base_read.size() == 27, "radius one reads the cubic kernel")
		var broad_read: Array = _result["broad_read"]
		expect(broad_read.has(Vector3i(2 * BROAD, 0, 0)), "the read set covers the two balls on an axis")
		expect(broad_read.has(Vector3i(2, 2, 2)), "the read set covers a diagonal of the two balls")
		expect(broad_read.has(Vector3i(SmoothOperation.THIN_MULTIPLIER * BROAD, 0, 0)), "the read set covers the thin probe on an axis")
		expect(not broad_read.has(Vector3i(0, 0, SmoothOperation.THIN_MULTIPLIER * BROAD + 1)), "the read set stays inside the declared halo")
	)


func _halo_truncated_matches() -> void:
	step("Given a thick solid with a flat face, a convex edge, and a concave notch", func():
		_compound()
		_cells = _compound_candidates()
	)
	step("When the full set and the truncated read set round for eight passes", func():
		_result = SmoothOperation.relax(_occupied, _cells, 8, BROAD)
		_other = SmoothOperation.relax(_gather_reads(_occupied, _cells, BROAD), _cells, 8, BROAD)
	)
	step("Then both give the same decisions", func():
		expect(_result["remove"] == _other["remove"], "the truncated gather removes the same cells")
		expect(_result["add"] == _other["add"], "the truncated gather adds the same cells")
		expect(not (_result["remove"] as Array).is_empty(), "the fixture moves some cells")
	)


func _halo_single_cell() -> void:
	step("Given one selected surface cell of a thick solid", func():
		_compound()
		_cells = [Vector3i(-3, 0, 2)]
	)
	step("When the full set and the read halo around that one cell round for four passes", func():
		_result = SmoothOperation.relax(_occupied, _cells, 4, BROAD)
		_other = SmoothOperation.relax(_gather_reads(_occupied, _cells, BROAD), _cells, 4, BROAD)
	)
	step("Then the single cell decides the same on both sets", func():
		expect(_result["remove"] == _other["remove"], "the single cell removes the same")
		expect(_result["add"] == _other["add"], "the single cell adds the same")
	)


func _compound_stability() -> void:
	step("Given a compound shape and the broad radius", func():
		_compound()
		_cells = _compound_candidates()
	)
	step("When the set rounds for one, two, three, ten, thirty, and forty passes", func():
		_result = {
			1: SmoothOperation.relax(_occupied, _cells, 1, BROAD),
			2: SmoothOperation.relax(_occupied, _cells, 2, BROAD),
			3: SmoothOperation.relax(_occupied, _cells, 3, BROAD),
			10: SmoothOperation.relax(_occupied, _cells, 10, BROAD),
			30: SmoothOperation.relax(_occupied, _cells, 30, BROAD),
			40: SmoothOperation.relax(_occupied, _cells, 40, BROAD),
		}
	)
	step("Then the shape stops changing and never oscillates", func():
		expect(_result[30]["occupied"] == _result[40]["occupied"], "thirty and forty passes agree")
		expect(_result[10]["occupied"] != _result[40]["occupied"], "the surface still rounds after ten passes")
		expect(_result[1]["occupied"] != _result[2]["occupied"], "the first pass moves the surface")
		var again: Dictionary = SmoothOperation.relax(_result[30]["occupied"], _cells, 1, BROAD)["occupied"]
		expect(again == _result[30]["occupied"], "one more pass on the fixed point changes nothing")
	)


func _no_isolated_remnant() -> void:
	step("Given a thick solid with a small closed cavity", func():
		_occupied = {}
		_fill(Vector3i(-6, -6, -6), Vector3i(6, 6, 6))
		for x in range(-1, 2):
			for y in range(-1, 2):
				for z in range(-1, 2):
					_occupied.erase(Vector3i(x, y, z))
		_cells = _box(Vector3i(-3, -3, -3), Vector3i(3, 3, 3))
	)
	step("When the cavity rounds for eight passes at the broad radius and at the base radius", func():
		_result = SmoothOperation.relax(_occupied, _cells, 8, BROAD)
		_other = SmoothOperation.relax(_occupied, _cells, 8, BASE)
	)
	step("Then no occupied cell lacks a face neighbor", func():
		expect(not _has_isolated(_result["occupied"]), "the broad pass leaves no isolated voxel")
		expect(not _has_isolated(_other["occupied"]), "the base pass leaves no isolated voxel")
	)


# --- Helpers for the compound fixtures --------------------------------------

# A thick block with a convex ridge, an inside corner, and a two-cell fin.
func _compound() -> void:
	_occupied = {}
	for x in range(-8, 9):
		for z in range(-8, 9):
			for y in range(-6, 1):
				if x > 2 and y > -4:
					continue
				_occupied[Vector3i(x, y, z)] = true
	for x in range(-8, -4):
		for z in range(-2, 3):
			for y in range(1, 4):
				_occupied[Vector3i(x, y, z)] = true
	for z in range(3, 9):
		for x in range(-2, 3):
			_occupied[Vector3i(x, 0, z)] = true
			_occupied[Vector3i(x, 1, z)] = true


func _compound_candidates() -> Array:
	var cells := []
	for x in range(-6, 7):
		for z in range(-6, 7):
			for y in range(-2, 5):
				cells.append(Vector3i(x, y, z))
	return cells


# Returns the occupancy a candidate reads, gathered through the declared halo of
# every candidate. A sparse gather reads the exact read set.
func _gather_reads(solid: Dictionary, cells: Array, radius: int) -> Dictionary:
	var offsets: Array = SmoothOperation.read_offsets(radius)
	var out := {}
	for cell: Vector3i in cells:
		for offset: Vector3i in offsets:
			var point := cell + offset
			if solid.has(point):
				out[point] = true
	return out


# True when any occupied cell has no face neighbor.
func _has_isolated(occupied: Dictionary) -> bool:
	for cell: Vector3i in occupied:
		var alone := true
		for offset: Vector3i in SmoothOperation.NEIGHBOR_OFFSETS:
			if occupied.has(cell + offset):
				alone = false
				break
		if alone:
			return true
	return false
