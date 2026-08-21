extends Node


func _ready() -> void:
	var packed: PackedScene = load("res://ui/main.tscn")
	var main := packed.instantiate()
	get_tree().root.add_child.call_deferred(main)
	var tries := 0
	while not main.is_inside_tree() and tries < 200:
		await get_tree().process_frame
		tries += 1
	_settle(10)
	_shot("01_empty")

	var d: VoxiDocument = State.document
	d.paint(0, Vector3i(6, 4, 7), Color8(200, 60, 50))
	d.paint(0, Vector3i(7, 4, 7), Color8(200, 60, 50))
	d.paint(0, Vector3i(6, 5, 7), Color8(200, 60, 50))
	d.paint(0, Vector3i(7, 5, 7), Color8(200, 60, 50))
	d.paint(0, Vector3i(6, 6, 7), Color8(70, 110, 200))
	d.paint(0, Vector3i(7, 6, 7), Color8(70, 110, 200))
	d.paint(0, Vector3i(6, 4, 8), Color8(90, 170, 90))
	d.paint(0, Vector3i(7, 4, 8), Color8(90, 170, 90))
	_remember(Color8(200, 60, 50))
	_remember(Color8(70, 110, 200))
	_remember(Color8(90, 170, 90))
	State.cells_changed.emit()
	await _settle(8)
	_shot("02_painted")

	State.playback.add_frame()
	d = State.document
	d.paint(1, Vector3i(6, 5, 7), Color8(230, 200, 70))
	d.paint(1, Vector3i(7, 5, 7), Color8(230, 200, 70))
	d.paint(1, Vector3i(6, 6, 7), Color8(230, 200, 70))
	d.paint(1, Vector3i(7, 6, 7), Color8(230, 200, 70))
	_remember(Color8(230, 200, 70))
	State.cells_changed.emit()
	await _settle(6)

	State.playback.add_frame()
	State.playback.add_frame()
	State.playback.add_frame()
	d = State.document
	d.frames[2].delay_ms = 200
	d.frames[3].delay_ms = 50
	d.frames[4].delay_ms = 100
	d.paint(2, Vector3i(7, 3, 7), Color8(150, 90, 190))
	_remember(Color8(150, 90, 190))
	State.cells_changed.emit()
	State.playback.select_frame(2)
	await _settle(6)
	_shot("03_frames")

	State.set_tool(State.tools["eraser"])
	await _settle(6)
	_shot("04_eraser")

	print("CAPTURE: 4 shot(s) saved to res://tests/capture/shots/")
	get_tree().quit(0)


func _remember(c: Color) -> void:
	State.set_color(c)


func _shot(name: String) -> void:
	var dir := "res://tests/capture/shots"
	DirAccess.make_dir_recursive_absolute(dir)
	RenderingServer.force_draw()
	var img := get_tree().root.get_texture().get_image()
	var file := dir + "/" + name + ".png"
	img.save_png(file)
	print("CAPTURE %s %dx%d" % [name, img.get_width(), img.get_height()])


func _settle(n: int) -> void:
	for i in n:
		await get_tree().process_frame
