extends "res://tests/test.gd"

# Pins the compact box path of the planar region code against the dictionary
# path. The two paths must return the same loops and the same triangulations.

const REGION := preload("res://Globals/Rendering/VoxelPlanarRegion.gd")

var fixtures: Array[Dictionary] = []
var labels: PackedStringArray = []
var ring7 := {}
var plate := {}
var solid16 := {}
var diagonal_line := {}
var sparse_pair := {}
var wall80 := {}
var protected := {Vector2i(1, 0): true, Vector2i(3, 0): true, Vector2i(6, 1): true, Vector2i(2, 3): true, Vector2i(0, 2): true}
var box_error := ""
var limit_error := ""
var square_error := ""
var prepared_error := ""
var simplify_error := ""


func _ready() -> void:
	timeout = 120.0
	test("compact box paths match the dictionary paths", _run)


func _run() -> void:
	step("Given every nonempty three-by-three mask and the named regions", _build)
	step("When both paths run on each fixture", _compare)
	step("Then the paths agree and the compact limits hold", _report)


func _build() -> void:
	for mask in range(1, 512):
		var cells := {}
		for bit in 9:
			if mask & (1 << bit):
				cells[Vector2i(bit % 3, bit / 3)] = true
		_add(cells, "mask %d" % mask)
	ring7 = _rectangle(Vector2i.ZERO, Vector2i(7, 7))
	for cell in _rectangle(Vector2i(2, 2), Vector2i(3, 3)):
		ring7.erase(cell)
	_add(ring7, "seven-by-seven ring with a three-by-three hole")
	plate = _rectangle(Vector2i.ZERO, Vector2i(11, 9))
	for hole in [_rectangle(Vector2i(2, 2), Vector2i(2, 4)), _rectangle(Vector2i(6, 3), Vector2i(3, 3))]:
		for cell in hole:
			plate.erase(cell)
	_add(plate, "eleven-by-nine plate with two holes")
	_add({Vector2i.ZERO: true, Vector2i.ONE: true, Vector2i(2, 0): true}, "three-cell diagonal")
	_add(_rectangle(Vector2i.ZERO, Vector2i(6, 4)), "six-by-four rectangle")
	solid16 = _rectangle(Vector2i.ZERO, Vector2i(16, 16))
	_add(solid16, "sixteen-by-sixteen rectangle")
	_add(_rectangle(Vector2i(40, -7), Vector2i(9, 5)), "nine-by-five rectangle at forty, minus seven")
	_add({Vector2i.ZERO: true}, "single cell")
	diagonal_line = {}
	for index in 16:
		diagonal_line[Vector2i(index, index)] = true
	_add(diagonal_line, "sixteen-cell diagonal line")
	sparse_pair = {Vector2i(-4096, -4096): true, Vector2i(4096, 4096): true}
	_add(sparse_pair, "sparse pair")
	# Taller than the row-mask width. Only the width is a mask, so a dense wall this
	# tall still belongs on the compact path.
	wall80 = _rectangle(Vector2i(3, -5), Vector2i(4, 80))
	_add(wall80, "four-by-eighty wall")


func _compare() -> void:
	box_error = ""
	limit_error = ""
	square_error = ""
	prepared_error = ""
	simplify_error = ""
	var compacted := 0
	for index in fixtures.size():
		var cells := fixtures[index]
		var box := REGION._compact(cells)
		if box == null:
			continue
		compacted += 1
		if REGION._box_loops(box, Callable()) != REGION._contours(cells, {}, Callable(), true):
			box_error = "%s differs" % labels[index]
			break
	# Every fixture except the sparse pair and the diagonal line must use the
	# compact path. A limit that silently rejected them would make the compare
	# above vacuous.
	if box_error.is_empty() and compacted != fixtures.size() - 2:
		box_error = "only %d of %d fixtures used the compact path" % [compacted, fixtures.size()]
	_compare_limits()
	_compare_squares()
	for index in fixtures.size():
		var cells := fixtures[index]
		var plain := REGION.triangulate(cells, protected, Callable())
		var prepared := REGION.triangulate(cells, protected, Callable(), REGION.raw_loops(cells, Callable()))
		if plain != prepared:
			prepared_error = "%s differs" % labels[index]
			break
	for index in fixtures.size():
		var cells := fixtures[index]
		var simplified: Array[PackedVector2Array] = []
		for loop in REGION.raw_loops(cells):
			simplified.append(REGION._simplify(loop, {}))
		if simplified != REGION.contours(cells):
			simplify_error = "%s differs" % labels[index]
			break


func _compare_limits() -> void:
	limit_error = ""
	if REGION._compact({}) != null:
		limit_error = "the empty region compacted"
		return
	for entry in [["the sparse pair", sparse_pair], ["the diagonal line", diagonal_line]]:
		if REGION._compact(entry[1]) != null:
			limit_error = "%s compacted" % entry[0]
			return
	var solid := REGION._compact(solid16)
	if solid == null:
		limit_error = "the sixteen-by-sixteen rectangle did not compact"
	elif solid.width != 16 or solid.height != 16:
		limit_error = "the sixteen-by-sixteen box is %d by %d" % [solid.width, solid.height]
	var ring := REGION._compact(ring7)
	if ring == null:
		limit_error = "the seven-by-seven ring did not compact"
	elif ring.width != 7 or ring.height != 7:
		limit_error = "the seven-by-seven box is %d by %d" % [ring.width, ring.height]
	var wall := REGION._compact(wall80)
	if wall == null:
		limit_error = "the four-by-eighty wall did not compact"
	elif wall.width != 4 or wall.height != 80:
		limit_error = "the four-by-eighty box is %d by %d" % [wall.width, wall.height]


func _compare_squares() -> void:
	square_error = ""
	var ccw := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	for rotation in 4:
		var loop := PackedVector2Array()
		for offset in 4:
			loop.append(ccw[(rotation + offset) % 4])
		if not REGION._unit_square(loop):
			square_error = "rotation %d of a counterclockwise unit square was rejected" % rotation
			return
	if REGION._unit_square(PackedVector2Array([Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0)])):
		square_error = "a clockwise unit square was accepted"
	elif REGION._unit_square(PackedVector2Array([Vector2(0, 0), Vector2(2, 0), Vector2(2, 1), Vector2(0, 1)])):
		square_error = "a two-by-one rectangle was accepted"
	elif REGION._unit_square(PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)])):
		square_error = "a three-point loop was accepted"


func _report() -> void:
	expect(box_error.is_empty(), "the compact boundary walk matches the dictionary walk on every compacted fixture" + _detail(box_error))
	expect(limit_error.is_empty(), "the compact limit rejects the empty, sparse, and diagonal-line regions and sizes the dense boxes exactly" + _detail(limit_error))
	expect(square_error.is_empty(), "the unit square test accepts all four counterclockwise rotations and rejects clockwise, rectangular, and three-point loops" + _detail(square_error))
	expect(prepared_error.is_empty(), "prepared raw loops triangulate the same as the dictionary path on every fixture" + _detail(prepared_error))
	expect(simplify_error.is_empty(), "simplifying the raw loops gives the same contours on every fixture" + _detail(simplify_error))


func _add(cells: Dictionary, label: String) -> void:
	fixtures.append(cells)
	labels.append(label)


func _rectangle(origin: Vector2i, size: Vector2i) -> Dictionary:
	var cells := {}
	for y in size.y:
		for x in size.x:
			cells[origin + Vector2i(x, y)] = true
	return cells


func _detail(error: String) -> String:
	return "" if error.is_empty() else " (%s)" % error
