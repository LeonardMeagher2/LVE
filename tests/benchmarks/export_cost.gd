extends "res://tests/test.gd"


const RADIUS := 10
const FRAMES := 24
const TILE := 128
const REPEATS := 2

var exporter: Node
var document: VoxelDocument
var sheet_path := ""
var gif_path := ""


func _ready() -> void:
	timeout = 900.0
	test("the sprite sheet and the GIF report their export cost", _cost, "export_cost")


func before_test() -> void:
	State.stop()
	State.current_frame = 0
	exporter = plugin("ExportPlugin")
	exporter.show_editor_tab()
	exporter._model_playback.is_playing = false
	sheet_path = "user://bench_export_%s.png" % Time.get_ticks_usec()
	gif_path = "user://bench_export_%s.gif" % Time.get_ticks_usec()


func after_test() -> void:
	if is_instance_valid(exporter):
		exporter._restore_export_settings()
		exporter.show_editor_tab()
	for path in [sheet_path, gif_path]:
		if not path.is_empty() and FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _cost() -> void:
	step("Given an animation of mixed-material spheres", func():
		document = _document()
		State.document = document
		State.frames_changed.emit()
		expect(document.frames.size() == FRAMES, "the fixture holds every frame")
		expect(document.frames[0].count() > 1000, "each frame holds a sphere")
		exporter._model_camera.is_orthogonal = true
		exporter._sheet_settings.get_node("ViewRow/Center").set_pressed_no_signal(false)
		exporter._sheet_settings.get_node("TurntableRow/Turntable").set_pressed_no_signal(false)
	)
	if DisplayServer.get_name() == "headless":
		step("Then the export benchmark needs a window", func():
			expect(true, "a headless run cannot render a sprite sheet or a GIF")
		)
		return
	await _measure_export("sheet", func():
		return await exporter.export_sprite_sheet(sheet_path, 0, FRAMES - 1, TILE, 2, false)
	)
	await _measure_export("gif", func():
		return await exporter.export_gif_settings(gif_path, {
			"first_frame": 0,
			"last_frame": FRAMES - 1,
			"tile_size": TILE,
			"view": "front",
			"views": 1,
			"center": false,
		})
	)
	step("Then both files hold the animation", func():
		expect(FileAccess.file_exists(sheet_path), "the sprite sheet is written")
		expect(FileAccess.file_exists(gif_path), "the GIF is written")
	)


func _measure_export(name: String, body: Callable) -> void:
	var times: Array[int] = []
	for index in REPEATS:
		var started := Time.get_ticks_usec()
		var result: Variant = await body.call()
		times.append(Time.get_ticks_usec() - started)
		expect(int(result) == OK, "the %s export completes" % name)
	var measured := times.duplicate()
	measured.sort()
	var median: int = measured[measured.size() / 2]
	print("MEASURE export_cost %s: us=%d frames=%d cells=%d" % [name, median, FRAMES, _cells(document)])


func _document() -> VoxelDocument:
	var value := VoxelDocument.new()
	value.frames.clear()
	value.frame_delays.clear()
	for frame_index in FRAMES:
		var frame := value.add_frame()
		var changes := {}
		var offset := frame_index / 3
		for x in range(-RADIUS, RADIUS + 1):
			for y in range(-RADIUS, RADIUS + 1):
				for z in range(-RADIUS, RADIUS + 1):
					if x * x + y * y + z * z > RADIUS * RADIUS:
						continue
					changes[Vector3i(x + offset, y, z)] = VoxelFrame.material(_color(x, y, z))
		frame.set_cells(changes)
		value.set_frame_delay(frame_index, 100)
	return value


func _cells(value: VoxelDocument) -> int:
	var total := 0
	for frame in value.frames:
		total += frame.count()
	return total


func _color(x: int, y: int, z: int) -> Color:
	match absi(x * 3 + y * 5 + z * 7) % 4:
		0:
			return Color(0.8, 0.1, 0.1)
		1:
			return Color(0.1, 0.6, 0.2)
		2:
			return Color(0.2, 0.3, 0.9)
	return Color(0.9, 0.8, 0.2)
