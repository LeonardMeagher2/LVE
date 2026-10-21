extends "res://tests/test.gd"

# The Smooth tests drive the pure 3D occupancy rounding module. They build
# occupancy sets and candidate cell lists, then check the rounding rule. They
# never touch the tool, the settings, or the editor state. The harness still
# loads the main scene, because the State autoload registers every plugin at
# startup.

const SmoothOperation := preload("res://plugins/Sculpt/SmoothOperation.gd")

const EPSILON := 1e-9

var _occupied := {}
var _cells: Array = []
var _result := {}
var _other := {}
var _weights := {}


func _ready() -> void:
	test("a flat face is unchanged", _flat_face_unchanged, "flat_face_unchanged")
	test("a one-cell plate is unchanged", _thin_plate_unchanged, "thin_plate_unchanged")
	test("a one-cell wall is unchanged", _thin_wall_unchanged, "thin_wall_unchanged")
	test("an isolated candidate is removed", _isolated_removed, "isolated_removed")
	test("rounding leaves no newly isolated eligible remnant", _isolated_remnant, "isolated_remnant")
	test("remnant cleanup respects the patch and falloff", _isolated_boundaries, "isolated_boundaries")
	test("a convex edge cell is removed", _convex_edge_removed, "convex_edge_removed")
	test("a convex corner cell is removed", _convex_corner_removed, "convex_corner_removed")
	test("a convex edge rounds one cell only", _edge_bevel_depth, "edge_bevel_depth")
	test("a concave corner cell is filled", _concave_corner_filled, "concave_corner_filled")
	test("mirrored features round equally", _mirrored_equal, "mirrored_equal")
	test("the insertion order does not change the result", _insertion_order_independent, "insertion_order_independent")
	test("the operation never mutates the input set", _pass_does_not_mutate_input, "pass_does_not_mutate_input")
	test("a symmetric feature has no surface normal", _no_normal_keeps_state, "no_normal_keeps_state")
	test("the occupancy fraction is deterministic", _fraction_deterministic, "fraction_deterministic")
	test("the strength scales the pass rate", _strength_scales_rate, "strength_scales_rate")
	test("a split elapsed time gives the same result", _delta_split_identical, "delta_split_identical")
	test("an exact pass boundary is independent of the frame rate", _delta_boundary, "delta_boundary")
	test("the pass cap bounds one call and keeps the carry", _pass_cap_bounds_call, "pass_cap_bounds_call")
	test("empty geometry runs no pass and keeps the carry", _empty_no_pass, "empty_no_pass")
	test("the kernel holds one cell and its neighbors", _kernel_offsets_shape, "kernel_offsets_shape")
	test("the weights scale the rounding rate", _weights_scale_rate, "weights_scale_rate")
	test("a weighted pass preserves the excess fractional credit", _weighted_credit_remainder, "weighted_credit_remainder")
	test("all-one weights match the default rate", _uniform_weights_match_default, "uniform_weights_match_default")
	test("the weighted insertion order does not change the result", _weighted_insertion_order, "weighted_insertion_order")
	test("a weighted split gives the same geometry and credits", _weighted_split_identical, "weighted_split_identical")


# Resets the fixtures. Each test builds its own set in a step.
func _setup_test() -> void:
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


func _has_remove(cell: Vector3i) -> bool:
	return (_result["remove"] as Array).has(cell)


func _has_add(cell: Vector3i) -> bool:
	return (_result["add"] as Array).has(cell)


# The occupied height of one column, from the base cell upward.
func _height(occupied: Dictionary, base: Vector3i) -> int:
	var cell := base
	var count := 0
	while occupied.has(cell):
		count += 1
		cell.y += 1
	return count


# Builds a one-cell plate with an identical spike at each side. The left spike
# keeps full weight and the right spike keeps a quarter weight. Only the spike
# cells are candidates, like the tool patch that follows the surface.
func _two_weighted_spikes() -> void:
	_occupied = {}
	for x in range(-8, 9):
		for z in range(-2, 3):
			_occupied[Vector3i(x, 0, z)] = true
	for y in range(1, 5):
		_occupied[Vector3i(-3, y, 0)] = true
		_occupied[Vector3i(3, y, 0)] = true
	_cells = []
	for y in range(1, 5):
		_cells.append(Vector3i(-3, y, 0))
		_cells.append(Vector3i(3, y, 0))
	_weights = {}
	for cell: Vector3i in _cells:
		_weights[cell] = 1.0 if cell.x < 0 else 0.25


# --- Shape rules ------------------------------------------------------------

func _flat_face_unchanged() -> void:
	step("Given a half-space with a flat top face", func():
		_occupied = {}
		_fill(Vector3i(-4, -4, -4), Vector3i(4, 0, 4))
		_cells = _box(Vector3i(-3, -1, -3), Vector3i(3, 2, 3))
	)
	step("When the set rounds for six passes", func():
		_result = SmoothOperation.relax(_occupied, _cells, 6)
	)
	step("Then no candidate moves", func():
		expect((_result["remove"] as Array).is_empty(), "a flat face removes no cell")
		expect((_result["add"] as Array).is_empty(), "a flat face adds no cell")
	)


func _thin_plate_unchanged() -> void:
	step("Given a one-cell plate", func():
		_occupied = {}
		for x in range(-4, 5):
			for z in range(-4, 5):
				_occupied[Vector3i(x, 0, z)] = true
		_cells = _box(Vector3i(-3, -1, -3), Vector3i(3, 1, 3))
	)
	step("When the set rounds for six passes", func():
		_result = SmoothOperation.relax(_occupied, _cells, 6)
	)
	step("Then the plate is unchanged", func():
		expect((_result["remove"] as Array).is_empty(), "a thin plate removes no cell")
		expect((_result["add"] as Array).is_empty(), "a thin plate adds no cell")
	)


func _thin_wall_unchanged() -> void:
	step("Given a one-cell vertical wall", func():
		_occupied = {}
		for y in range(-4, 5):
			for z in range(-4, 5):
				_occupied[Vector3i(0, y, z)] = true
		_cells = _box(Vector3i(-1, -3, -3), Vector3i(1, 3, 3))
	)
	step("When the set rounds for six passes", func():
		_result = SmoothOperation.relax(_occupied, _cells, 6)
	)
	step("Then the wall is unchanged", func():
		expect((_result["remove"] as Array).is_empty(), "a thin wall removes no cell")
		expect((_result["add"] as Array).is_empty(), "a thin wall adds no cell")
	)


func _isolated_removed() -> void:
	step("Given one isolated voxel", func():
		_occupied = {Vector3i.ZERO: true}
		_cells = [Vector3i.ZERO]
	)
	step("When the set rounds for four passes", func():
		_result = SmoothOperation.relax(_occupied, _cells, 4)
	)
	step("Then the isolated candidate is removed without seeding geometry", func():
		expect(_result["remove"] == [Vector3i.ZERO], "the isolated voxel is removed")
		expect((_result["occupied"] as Dictionary).is_empty(), "no isolated remnant survives")
		expect((_result["add"] as Array).is_empty(), "an isolated voxel seeds nothing")
	)


func _isolated_remnant() -> void:
	step("Given a three-voxel feature with a symmetric middle", func():
		_occupied = {Vector3i.LEFT: true, Vector3i.ZERO: true, Vector3i.RIGHT: true}
		_cells = [Vector3i.LEFT, Vector3i.ZERO, Vector3i.RIGHT]
	)
	step("When one pass removes the unsupported tips", func():
		_result = SmoothOperation.relax(_occupied, _cells, 1)
		var reverse := _cells.duplicate()
		reverse.reverse()
		_other = SmoothOperation.relax(_occupied, reverse, 1)
	)
	step("Then the newly isolated middle is removed in the same pass", func():
		expect((_result["occupied"] as Dictionary).is_empty(), "the pass leaves no one-voxel remnant")
		expect((_result["remove"] as Array).size() == 3, "the cleanup reports every removed voxel")
		expect(_result["remove"] == _other["remove"], "cleanup is independent of candidate order")
		expect(_occupied.size() == 3, "cleanup preserves the frozen input")
	)


func _isolated_boundaries() -> void:
	step("Given a middle voxel outside the writable patch", func():
		_occupied = {Vector3i.LEFT: true, Vector3i.ZERO: true, Vector3i.RIGHT: true}
		_result = SmoothOperation.relax(_occupied, [Vector3i.LEFT, Vector3i.RIGHT], 1)
	)
	step("Then cleanup leaves the read-only middle alone", func():
		expect(_result["occupied"] == {Vector3i.ZERO: true}, "the patch boundary protects an unselected support")
	)
	step("When the middle has only half an application of influence", func():
		_cells = [Vector3i.LEFT, Vector3i.ZERO, Vector3i.RIGHT]
		_weights = {Vector3i.LEFT: 1.0, Vector3i.ZERO: 0.5, Vector3i.RIGHT: 1.0}
		_result = SmoothOperation.relax(_occupied, _cells, 1, 1, 0.5, 0.5, _weights)
	)
	step("Then cleanup waits for the middle to earn its application", func():
		expect(_result["occupied"] == {Vector3i.ZERO: true}, "partial influence does not bypass the falloff")
		_other = SmoothOperation.relax(_result["occupied"], _cells, 1, 1, 0.5, 0.5, _weights, _result["credits"])
		expect((_other["occupied"] as Dictionary).is_empty(), "the next application removes the eligible remnant")
	)


func _convex_edge_removed() -> void:
	step("Given a convex edge along z", func():
		_occupied = {}
		for x in range(-4, 1):
			for y in range(-4, 1):
				for z in range(-4, 5):
					_occupied[Vector3i(x, y, z)] = true
		_cells = _box(Vector3i(-2, -2, -2), Vector3i(1, 1, 2))
	)
	step("When the set rounds for four passes", func():
		_result = SmoothOperation.relax(_occupied, _cells, 4)
	)
	step("Then the edge cell goes and the face stays", func():
		expect(_has_remove(Vector3i(0, 0, 0)), "the convex edge cell is removed")
		expect(not _has_remove(Vector3i(0, -1, 0)), "the face cell beside the edge is kept")
		expect((_result["add"] as Array).is_empty(), "a convex edge fills nothing")
	)


func _convex_corner_removed() -> void:
	step("Given a convex corner of an octant", func():
		_occupied = {}
		_fill(Vector3i(-4, -4, -4), Vector3i(0, 0, 0))
		_cells = _box(Vector3i(-2, -2, -2), Vector3i(1, 1, 1))
	)
	step("When the set rounds for four passes", func():
		_result = SmoothOperation.relax(_occupied, _cells, 4)
	)
	step("Then the corner cell goes", func():
		expect(_has_remove(Vector3i(0, 0, 0)), "the convex corner cell is removed")
		expect(not _has_remove(Vector3i(-1, -1, -1)), "the interior cell beside the corner is kept")
	)


func _edge_bevel_depth() -> void:
	step("Given a convex edge", func():
		_occupied = {}
		for x in range(-6, 1):
			for y in range(-6, 1):
				for z in range(-4, 5):
					_occupied[Vector3i(x, y, z)] = true
		_cells = _box(Vector3i(-2, -2, -2), Vector3i(2, 2, 2))
	)
	step("When the set rounds for twenty passes", func():
		_result = SmoothOperation.relax(_occupied, _cells, 20)
	)
	step("Then the bevel stops at one cell", func():
		expect(_has_remove(Vector3i(0, 0, 0)), "the edge cell is removed")
		expect(not _has_remove(Vector3i(0, -1, 0)), "the second cell is kept, so the bevel is bounded")
		expect(not _has_remove(Vector3i(0, -2, 0)), "the third cell is kept")
	)


func _concave_corner_filled() -> void:
	step("Given a concave inside corner", func():
		_occupied = {}
		for x in range(-4, 5):
			for y in range(-4, 5):
				for z in range(-4, 5):
					if x <= 0 or y <= 0:
						_occupied[Vector3i(x, y, z)] = true
		_cells = _box(Vector3i(-2, -2, -2), Vector3i(2, 2, 2))
	)
	step("When the set rounds for four passes", func():
		_result = SmoothOperation.relax(_occupied, _cells, 4)
	)
	step("Then the corner fills", func():
		expect(_has_add(Vector3i(1, 1, 0)), "the concave corner cell is filled")
	)


func _mirrored_equal() -> void:
	step("Given two mirrored spikes", func():
		_occupied = {}
		_fill(Vector3i(-6, -6, -6), Vector3i(6, 0, 6))
		for y in range(1, 4):
			_occupied[Vector3i(3, y, 0)] = true
			_occupied[Vector3i(-3, y, 0)] = true
		_cells = _box(Vector3i(-5, -1, -2), Vector3i(5, 4, 2))
	)
	step("When the set rounds for four passes", func():
		_result = SmoothOperation.relax(_occupied, _cells, 4)
	)
	step("Then the mirrored cells get equal decisions", func():
		var right := _has_remove(Vector3i(3, 3, 0))
		var left := _has_remove(Vector3i(-3, 3, 0))
		expect(right, "the right spike tip is removed")
		expect(right == left, "the mirrored spike tip gets the same decision")
	)


func _insertion_order_independent() -> void:
	step("Given the same set in two insertion orders", func():
		_occupied = {}
		for x in range(-4, 1):
			for y in range(-4, 1):
				for z in range(-4, 5):
					_occupied[Vector3i(x, y, z)] = true
		_other = {}
		var keys := _occupied.keys()
		keys.reverse()
		for cell: Vector3i in keys:
			_other[cell] = true
		_cells = _box(Vector3i(-2, -2, -2), Vector3i(1, 1, 2))
	)
	step("When both sets round for four passes", func():
		_result = SmoothOperation.relax(_occupied, _cells, 4)
		_other = SmoothOperation.relax(_other, _cells, 4)
	)
	step("Then both results match", func():
		expect(_result["remove"] == _other["remove"], "the insertion order does not change the removed cells")
		expect(_result["add"] == _other["add"], "the insertion order does not change the filled cells")
		expect(not (_result["remove"] as Array).is_empty(), "the edge moves in both orders")
	)


func _pass_does_not_mutate_input() -> void:
	step("Given a convex edge", func():
		_occupied = {}
		_fill(Vector3i(-4, -4, -4), Vector3i(0, 0, 0))
		_cells = _box(Vector3i(-2, -2, -2), Vector3i(1, 1, 1))
		_other = _occupied.duplicate()
	)
	step("When the set rounds for four passes", func():
		_result = SmoothOperation.relax(_occupied, _cells, 4)
	)
	step("Then the input set is unchanged and the result is a new set", func():
		expect(_occupied == _other, "the operation never mutates the input")
		expect(_result["occupied"] != _occupied, "the result is a new set")
	)


func _no_normal_keeps_state() -> void:
	step("Given a symmetric feature and a surface cell", func():
		var symmetric := {Vector3i.ZERO: true, Vector3i(1, 0, 0): true, Vector3i(-1, 0, 0): true}
		var surface := {Vector3i.ZERO: true, Vector3i(0, -1, 0): true}
		_result = {
			"symmetric": SmoothOperation.surface_normal(symmetric, Vector3i.ZERO),
			"surface": SmoothOperation.surface_normal(surface, Vector3i.ZERO),
		}
	)
	step("Then the symmetric cell has no normal and the surface cell points outward", func():
		expect(_result["symmetric"] == null, "a locally symmetric cell has no defined normal")
		var normal: Vector3 = _result["surface"]
		expect(normal != null and normal.y > 0.9, "a surface cell points outward")
	)


func _fraction_deterministic() -> void:
	step("Given three occupied cells in a kernel", func():
		_occupied = {Vector3i.ZERO: true, Vector3i(1, 0, 0): true, Vector3i(0, 1, 0): true}
	)
	step("When the occupied fraction reads twice", func():
		_result = {
			"first": SmoothOperation.occupied_fraction(_occupied, Vector3i.ZERO),
			"second": SmoothOperation.occupied_fraction(_occupied, Vector3i.ZERO),
		}
	)
	step("Then the fraction is a stable rational", func():
		expect(is_equal_approx(float(_result["first"]), float(_result["second"])), "the fraction is stable")
		expect(is_equal_approx(float(_result["first"]), 3.0 / 27.0), "the fraction counts the kernel")
	)


# --- Rate and time ----------------------------------------------------------

func _strength_scales_rate() -> void:
	step("Given a convex corner", func():
		_occupied = {}
		_fill(Vector3i(-4, -4, -4), Vector3i(0, 0, 0))
		_cells = _box(Vector3i(-3, -3, -3), Vector3i(1, 1, 1))
	)
	step("When the set advances half a second at two rates", func():
		_result = SmoothOperation.advance(_occupied, _cells, 0.5, 4.0)
		_other = SmoothOperation.advance(_occupied, _cells, 0.5, 8.0)
	)
	step("Then the higher rate runs more passes", func():
		expect(int(_result["passes"]) == 2, "rate four runs two passes in half a second")
		expect(int(_other["passes"]) == 4, "rate eight runs four passes in half a second")
		expect((_other["remove"] as Array).size() >= (_result["remove"] as Array).size(), "the higher rate removes at least as much")
		expect(is_equal_approx(float(_result["carry"]), 0.0), "an exact rate leaves no carry")
	)


func _delta_split_identical() -> void:
	step("Given a convex corner", func():
		_occupied = {}
		_fill(Vector3i(-4, -4, -4), Vector3i(0, 0, 0))
		_cells = _box(Vector3i(-3, -3, -3), Vector3i(1, 1, 1))
	)
	step("When the set advances 0.8 seconds in one call", func():
		_result = SmoothOperation.advance(_occupied, _cells, 0.8, 8.0)
	)
	step("When the same time runs at sixty hertz", func():
		var occupied := _occupied
		var carry := 0.0
		for _tick in 48:
			var outcome := SmoothOperation.advance(occupied, _cells, 1.0 / 60.0, 8.0, carry)
			occupied = outcome["occupied"]
			carry = float(outcome["carry"])
		_other = {"occupied": occupied, "carry": carry}
	)
	step("Then every split gives the same occupancy", func():
		expect(int(_result["passes"]) == 6, "the single call runs six passes")
		expect(_result["occupied"] == _other["occupied"], "the split occupancy matches the single call exactly")
	)


func _delta_boundary() -> void:
	step("Given a convex corner with six passes per second", func():
		_occupied = {}
		_fill(Vector3i(-4, -4, -4), Vector3i(0, 0, 0))
		_cells = _box(Vector3i(-3, -3, -3), Vector3i(1, 1, 1))
		_result = SmoothOperation.advance(_occupied, _cells, 1.0, 6.0)
	)
	step("When one second is split across different frame rates", func():
		for rate in [15, 60]:
			var occupied := _occupied
			var carry := 0.0
			var passes := 0
			for _tick in rate:
				var outcome := SmoothOperation.advance(occupied, _cells, 1.0 / float(rate), 6.0, carry)
				occupied = outcome["occupied"]
				carry = outcome["carry"]
				passes += int(outcome["passes"])
			expect(passes == 6, "%d Hz completes all six passes" % rate)
			expect(occupied == _result["occupied"], "%d Hz matches the exact-boundary result" % rate)
	)


func _pass_cap_bounds_call() -> void:
	step("Given a convex corner and a long hold", func():
		_occupied = {}
		_fill(Vector3i(-4, -4, -4), Vector3i(0, 0, 0))
		_cells = _box(Vector3i(-3, -3, -3), Vector3i(1, 1, 1))
	)
	step("When ten seconds run at eight passes per second", func():
		_result = SmoothOperation.advance(_occupied, _cells, 10.0, 8.0)
	)
	step("Then the call runs the cap and keeps the rest in the carry", func():
		expect(int(_result["passes"]) == SmoothOperation.MAX_PASSES_PER_CALL, "one call runs the pass cap")
		expect(is_equal_approx(float(_result["carry"]), 80.0 - float(SmoothOperation.MAX_PASSES_PER_CALL)), "the leftover stays in the carry")
	)


func _empty_no_pass() -> void:
	step("Given an empty geometry and a long hold", func():
		_result = SmoothOperation.advance({}, [], 2.0, 8.0, 0.25)
	)
	step("Then no pass runs and the carry is kept", func():
		expect(int(_result["passes"]) == 0, "empty geometry runs no pass")
		expect(is_equal_approx(float(_result["carry"]), 0.25), "empty geometry banks no burst and keeps the carry")
		expect((_result["remove"] as Array).is_empty() and (_result["add"] as Array).is_empty(), "empty geometry changes nothing")
	)


func _kernel_offsets_shape() -> void:
	step("Given the kernel offsets of radius one and two", func():
		_result = {
			"one": SmoothOperation.kernel_offsets(1),
			"two": SmoothOperation.kernel_offsets(2),
		}
	)
	step("Then the kernel holds the full cube around the cell", func():
		expect((_result["one"] as Array).size() == 27, "radius one holds 27 offsets")
		expect((_result["one"] as Array).has(Vector3i.ZERO), "the kernel holds the cell itself")
		expect((_result["two"] as Array).size() == 125, "radius two holds 125 offsets")
	)


# --- Weighted rate ----------------------------------------------------------

func _weighted_credit_remainder() -> void:
	step("Given one candidate with a three-quarter rate", func():
		_occupied = {Vector3i.ZERO: true}
		_cells = [Vector3i.ZERO]
		_weights = {Vector3i.ZERO: 0.75}
	)
	step("When two passes earn one and a half credits", func():
		_result = SmoothOperation.relax(_occupied, _cells, 2, SmoothOperation.KERNEL_RADIUS, 0.5, 0.5, _weights)
	)
	step("Then the unused half credit remains for the next pass", func():
		expect(is_equal_approx(float(_result["credits"][Vector3i.ZERO]), 0.5), "one evaluation retains its unused half credit")
		_other = SmoothOperation.relax(_result["occupied"], _cells, 1, SmoothOperation.KERNEL_RADIUS, 0.5, 0.5, _weights, _result["credits"])
		expect(is_equal_approx(float(_other["credits"][Vector3i.ZERO]), 0.25), "the next evaluation retains its unused quarter credit")
	)

func _weights_scale_rate() -> void:
	step("Given two identical spikes at different weights", func():
		_two_weighted_spikes()
	)
	step("When the set advances one second at four passes per second", func():
		_result = SmoothOperation.advance(_occupied, _cells, 1.0, 4.0, 0.0, SmoothOperation.KERNEL_RADIUS, 0.5, 0.5, _weights)
	)
	step("Then the full-weight spike rounds faster than the quarter-weight one", func():
		var fast := _height(_result["occupied"], Vector3i(-3, 0, 0))
		var slow := _height(_result["occupied"], Vector3i(3, 0, 0))
		expect(fast < 5, "the full-weight spike loses cells")
		expect(slow > fast, "the quarter-weight spike keeps more height after the same time")
		expect(slow == 4, "the quarter-weight spike loses one cell in four passes")
	)


func _uniform_weights_match_default() -> void:
	step("Given a convex corner and an all-one weight set", func():
		_occupied = {}
		_fill(Vector3i(-4, -4, -4), Vector3i(0, 0, 0))
		_cells = _box(Vector3i(-3, -3, -3), Vector3i(1, 1, 1))
		_weights = {}
		for cell: Vector3i in _cells:
			_weights[cell] = 1.0
	)
	step("When the set rounds with and without explicit weights", func():
		_result = SmoothOperation.relax(_occupied, _cells, 4)
		_other = SmoothOperation.relax(_occupied, _cells, 4, SmoothOperation.KERNEL_RADIUS, 0.5, 0.5, _weights)
	)
	step("Then the explicit all-one weights match the default", func():
		expect(_result["remove"] == _other["remove"], "the uniform weights remove the same cells")
		expect(_result["add"] == _other["add"], "the uniform weights fill the same cells")
		expect(_result["credits"] == _other["credits"], "the uniform weights keep the same credits")
	)


func _weighted_insertion_order() -> void:
	step("Given the same weighted corner in two insertion orders", func():
		var forward := {}
		_fill(Vector3i(-4, -4, -4), Vector3i(0, 0, 0))
		for cell: Vector3i in _occupied:
			forward[cell] = true
		var backward := {}
		var keys := forward.keys()
		keys.reverse()
		for cell: Vector3i in keys:
			backward[cell] = true
		var cells := _box(Vector3i(-3, -3, -3), Vector3i(1, 1, 1))
		var reversed_cells := cells.duplicate()
		reversed_cells.reverse()
		var weights := {}
		for cell: Vector3i in cells:
			weights[cell] = 0.5 if cell.x >= 0 else 1.0
		_result = SmoothOperation.relax(forward, cells, 4, SmoothOperation.KERNEL_RADIUS, 0.5, 0.5, weights)
		_other = SmoothOperation.relax(backward, reversed_cells, 4, SmoothOperation.KERNEL_RADIUS, 0.5, 0.5, weights)
	)
	step("Then both orders give the same cells and credits", func():
		expect(_result["remove"] == _other["remove"], "the weighted insertion order does not change the removed cells")
		expect(_result["add"] == _other["add"], "the weighted insertion order does not change the filled cells")
		expect(_result["credits"] == _other["credits"], "the weighted insertion order does not change the credits")
		expect(not (_result["remove"] as Array).is_empty(), "the weighted corner moves in both orders")
	)


func _weighted_split_identical() -> void:
	step("Given two identical spikes at different weights", func():
		_two_weighted_spikes()
	)
	step("When the set advances 0.8 seconds in one call", func():
		_result = SmoothOperation.advance(_occupied, _cells, 0.8, 8.0, 0.0, SmoothOperation.KERNEL_RADIUS, 0.5, 0.5, _weights)
	)
	step("When the same time runs at sixty hertz", func():
		var occupied := _occupied
		var credits := {}
		var carry := 0.0
		for _tick in 48:
			var outcome := SmoothOperation.advance(occupied, _cells, 1.0 / 60.0, 8.0, carry, SmoothOperation.KERNEL_RADIUS, 0.5, 0.5, _weights, credits)
			occupied = outcome["occupied"]
			credits = outcome["credits"]
			carry = float(outcome["carry"])
		_other = {"occupied": occupied, "credits": credits}
	)
	step("Then the geometry and the credits match exactly", func():
		expect(int(_result["passes"]) == 6, "the single call runs six passes")
		expect(_result["occupied"] == _other["occupied"], "the weighted split geometry matches")
		expect(_result["credits"] == _other["credits"], "the weighted split credits match")
	)
