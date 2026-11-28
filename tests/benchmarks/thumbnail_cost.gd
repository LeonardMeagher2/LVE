extends "res://tests/test.gd"


const SPAN := 48
const WARMUPS := 1
const REPEATS := 2

var document: VoxelDocument


func _ready() -> void:
	timeout = 600.0
	test("the document preview reports its render cost", _cost, "thumbnail_cost")


func _cost() -> void:
	step("Given a dense frame with mixed materials", func():
		document = _document()
		State.document = document
		State.frames_changed.emit()
		expect(document.active_layer().frames[0].count() > SPAN * SPAN * SPAN / 2, "the fixture holds a dense block")
	)
	if DisplayServer.get_name() == "headless":
		step("Then the preview benchmark needs a window", func():
			expect(true, "a headless run cannot render a document preview")
		)
		return
	var times: Array[int] = []
	for index in WARMUPS + REPEATS:
		var started := Time.get_ticks_usec()
		var image: Image = await VoxelImageRenderer.render_document_preview(document)
		times.append(Time.get_ticks_usec() - started)
		step("Then the preview renders an image", func():
			expect(image != null and image.get_width() == 256, "the preview is a 256 pixel image")
		)
	var measured := times.slice(WARMUPS)
	measured.sort()
	var median: int = measured[measured.size() / 2]
	print("MEASURE thumbnail_cost preview: us=%d cells=%d" % [median, document.active_layer().frames[0].count()])


func _document() -> VoxelDocument:
	var value := VoxelDocument.new()
	value.active_layer().frames.clear()
	value.frame_delays.clear()
	var frame := value.add_frame()
	var changes := {}
	var half := SPAN / 2
	for x in range(-half, half):
		for y in range(-half, half):
			for z in range(-half, half):
				if (x + y + z) % 7 == 0:
					continue
				changes[Vector3i(x, y, z)] = VoxelFrame.material(_color(x, y, z))
	frame.set_cells(changes)
	return value


func _color(x: int, y: int, z: int) -> Color:
	match absi(x * 3 + y * 5 + z * 7) % 4:
		0:
			return Color(0.8, 0.1, 0.1)
		1:
			return Color(0.1, 0.6, 0.2)
		2:
			return Color(0.2, 0.3, 0.9)
	return Color(0.9, 0.8, 0.2)
