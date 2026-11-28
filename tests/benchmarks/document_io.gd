extends "res://tests/test.gd"


const SPAN := 32
const FRAMES := 2
const WARMUPS := 1
const REPEATS := 2
const MATERIALS := 4

var path := "user://bench_document_io.lve"
var document: VoxelDocument
var encoded := PackedByteArray()


func _ready() -> void:
	timeout = 600.0
	test("the document encode, save, and load cases report their cost", _cost, "document_io")


func _cost() -> void:
	step("Given a two frame document with mixed materials", func():
		document = _document()
		expect(document.active_layer().frames.size() == FRAMES, "the fixture holds both frames")
		expect(_cells(document) > SPAN * SPAN * SPAN / 2, "the fixture holds a dense block")
	)
	step("When the document is encoded, saved, and loaded warmed", func():
		_measure("encode", func():
			encoded = document.encode_document()
			return encoded.size()
		)
		_measure("save", func():
			return document.save_file(path, null, encoded)
		)
		_measure("load", func():
			var loaded := VoxelDocument.load_file(path)
			return _cells(loaded) if loaded != null else -1
		)
	)
	step("Then the saved file loads back with the same frames and cells", func():
		var loaded := VoxelDocument.load_file(path)
		expect(loaded != null, "the saved document loads")
		if loaded == null:
			return
		expect(loaded.active_layer().frames.size() == FRAMES, "the loaded document keeps both frames")
		expect(_cells(loaded) == _cells(document), "the loaded document keeps every cell")
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	)


func _measure(name: String, body: Callable) -> void:
	var times: Array[int] = []
	var size := 0
	for index in WARMUPS + REPEATS:
		var started := Time.get_ticks_usec()
		size = int(body.call())
		times.append(Time.get_ticks_usec() - started)
	var measured := times.slice(WARMUPS)
	measured.sort()
	var median: int = measured[measured.size() / 2]
	print("MEASURE document_io %s: us=%d size=%d cells=%d" % [name, median, size, _cells(document)])


func _document() -> VoxelDocument:
	var value := VoxelDocument.new()
	value.active_layer().frames.clear()
	value.frame_delays.clear()
	var half := SPAN / 2
	for frame_index in FRAMES:
		var frame := value.add_frame()
		var changes := {}
		for x in range(-half, half):
			for y in range(-half, half):
				for z in range(-half, half):
					if (x + y + z + frame_index) % 5 == 0:
						continue
					changes[Vector3i(x, y, z)] = VoxelFrame.material(_color(x, y, z, frame_index))
		frame.set_cells(changes)
	return value


func _cells(value: VoxelDocument) -> int:
	var total := 0
	for frame in value.active_layer().frames:
		total += frame.count()
	return total


func _color(x: int, y: int, z: int, frame_index: int) -> Color:
	var slot := absi(x * 3 + y * 5 + z * 7 + frame_index) % MATERIALS
	match slot:
		0:
			return Color(0.8, 0.1, 0.1)
		1:
			return Color(0.1, 0.6, 0.2, 1.0)
		2:
			return Color(0.2, 0.3, 0.9)
	return Color(0.9, 0.8, 0.2)
