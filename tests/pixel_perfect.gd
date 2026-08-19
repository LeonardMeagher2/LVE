extends "res://tests/test.gd"

var _p := PixelPerfectStroke.new()
var _drawn: Array[Vector3i] = []


func _ready() -> void:
	test("draws a clean diagonal and skips transient cells", _run)


func _run() -> void:
	step("Given a stroke that starts at the origin", func():
		_p.reset()
		_p.feed(Vector3i(0, 0, 0))
	)

	step("When the user draws a wobbly diagonal", func():
		_drawn = _p.feed(Vector3i(1, 1, 0))
		_drawn += _p.feed(Vector3i(2, 2, 0))
		_drawn += _p.feed(Vector3i(2, 3, 0))
		_drawn += _p.feed(Vector3i(3, 3, 0))
		_drawn += _p.feed(Vector3i(4, 4, 0))
		_drawn += _p.feed(Vector3i(4, 5, 0))
		_drawn += _p.feed(Vector3i(5, 5, 0))
	)

	step("Then the drawn cells form a clean diagonal", func():
		expect(_drawn.has(Vector3i(1, 1, 0)), "the first diagonal cell is drawn")
		expect(_drawn.has(Vector3i(2, 2, 0)), "the second diagonal cell is drawn")
		expect(_drawn.has(Vector3i(3, 3, 0)), "the third diagonal cell is drawn")
		expect(_drawn.has(Vector3i(4, 4, 0)), "the fourth diagonal cell is drawn")
		expect(_drawn.size() == 4, "the transient wobble cells are skipped")
	)

	step("When the user releases", func():
		_drawn += _p.flush()
	)

	step("Then the final cursor cell is painted", func():
		expect(_drawn.has(Vector3i(5, 5, 0)), "the cursor cell is painted on release")
	)

	step("When the user backtracks and moves on", func():
		_drawn += _p.feed(Vector3i(6, 5, 0))
		_drawn += _p.feed(Vector3i(7, 5, 0))
		_drawn += _p.feed(Vector3i(6, 5, 0))
		_drawn += _p.feed(Vector3i(6, 6, 0))
		_drawn += _p.feed(Vector3i(7, 6, 0))
		_drawn += _p.flush()
	)

	step("Then the transient cell is skipped and the cursor is painted", func():
		expect(_drawn.has(Vector3i(6, 5, 0)), "the frontier cell is drawn")
		expect(_drawn.has(Vector3i(7, 6, 0)), "the cursor cell is painted")
		expect(not _drawn.has(Vector3i(6, 6, 0)), "the transient cell is skipped")
	)

	step("When the user jumps far while the stroke is buffering", func():
		_drawn += _p.feed(Vector3i(8, 6, 0))
		_drawn += _p.feed(Vector3i(12, 10, 0))
		_drawn += _p.flush()
	)

	step("Then every drawn cell connects to its neighbor", func():
		expect(_drawn.has(Vector3i(12, 10, 0)), "the stroke reaches the cursor")
		var connected := true
		for i in range(1, _drawn.size()):
			if not _adjacent(_drawn[i - 1], _drawn[i]):
				connected = false
		expect(connected, "no gaps in the stroke")
	)


func _adjacent(a: Vector3i, b: Vector3i) -> bool:
	return maxi(absi(a.x - b.x), maxi(absi(a.y - b.y), absi(a.z - b.z))) <= 1
