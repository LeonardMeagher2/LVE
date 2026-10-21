extends "res://tests/test.gd"

# Run this optional benchmark directly. Keep it outside automatic suite discovery.
# Compare warmed alternatives in one process with alternating execution order.
const REPEATS := 5
const WARMUPS := 2
const ProbeScript := preload("./sculpt_latency_tool.gd")

var _tool: Node3D
var _frame: VoxelFrame
var _fixture: VoxelFrame
var _renderer: VoxelRenderer
var _viewport: SubViewport
var _settings := preload("res://plugins/Sculpt/settings.tres")
var _measuring := false
var _last_frame_us := 0
var _longest_frame_us := 0
var _last_chunks := {}


func _ready() -> void:
	timeout = 120.0
	test("a small rendered Smooth stroke matches its reference", func(): await _compare(4), "small")
	test("a medium rendered Smooth stroke matches its reference", func(): await _compare(16), "medium")
	test("a maximum rendered Smooth stroke matches its reference", func(): await _compare(32), "large")


func _process(_delta: float) -> void:
	if not _measuring:
		return
	var now := Time.get_ticks_usec()
	_longest_frame_us = maxi(_longest_frame_us, now - _last_frame_us)
	_last_frame_us = now


func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.symmetry_axes = 0
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	_settings.tool = _settings.Tools.SMOOTH
	_settings.strength = 1.0
	_settings.falloff = 0.5
	_viewport = editor_viewport()
	_viewport.get_parent().stretch = false
	_viewport.size = Vector2i(800, 500)
	activate_tool("sculpt")
	plugin("SculptPlugin").deactivate_tool()
	_tool = preload("res://plugins/Sculpt/SculptTool.tscn").instantiate()
	_tool.set_script(ProbeScript)
	plugin("SculptPlugin").add_editor_node(_tool)
	_tool.set_process(false)
	_renderer = viewport_scene().get_node("VoxelRenderer")
	_frame = State.get_current_voxel_frame()
	var changes := {}
	var material := VoxelFrame.material(Color.from_rgba8(100, 180, 220))
	for x in range(-36, 37):
		for z in range(-36, 37):
			for y in range(-3, 1):
				changes[Vector3i(x, y, z)] = material
			if posmod(x, 3) == 0 and posmod(z, 3) == 0:
				changes[Vector3i(x, 1, z)] = material
	_frame.set_cells(changes)
	_fixture = _frame.copy_frame()
	sync_viewport()
	camera_rig().configure()
	camera_rig().set_view("top")
	camera_rig().is_orthogonal = true
	await _settle()


func _cleanup_test() -> void:
	_measuring = false
	if is_instance_valid(_tool):
		if _tool._edit != null:
			_tool.finish_on_switch()
		while _tool._smooth_job != null:
			await get_tree().process_frame
		_tool.free()
	_fixture = null
	_last_chunks = {}


func _compare(radius: int) -> void:
	step("Given the same rough surface and brush radius", func():
		_settings.radius = radius
	)
	var reference := []
	var candidate := []
	for pair in WARMUPS + REPEATS:
		var first: bool = pair % 2 == 0
		var a: Dictionary = await _stroke(first)
		var a_chunks := _last_chunks
		var b: Dictionary = await _stroke(not first)
		step("Then the paired strokes preserve the same geometry and materials", func():
			expect(VoxelEditTransaction._chunks_equal(a_chunks, _last_chunks), "the paired strokes produce identical full materials")
		)
		if pair >= WARMUPS:
			reference.append(a if first else b)
			candidate.append(b if first else a)
	step("Then the real strokes report edit and visible completion", func():
		for path in ["reference", "candidate"]:
			var rows: Array = reference if path == "reference" else candidate
			print("MEASURE sculpt_viewport radius=%d path=%s headless=%s input_us=%d edit_us=%d visible_us=%d gap_us=%d" % [
				radius, path, str(DisplayServer.get_name() == "headless"),
				_median(rows, "input"), _median(rows, "edit"),
				_median(rows, "visible"), _median(rows, "gap"),
			])
	)


func _stroke(reference: bool) -> Dictionary:
	_frame.restore(_fixture.capture())
	State.undo_redo.clear_history()
	sync_viewport()
	await _settle()
	_tool.use_reference = reference
	var position := camera_rig().unproject_position(Vector3(0, 1, 0))
	var button := InputEventMouseButton.new()
	button.button_index = MOUSE_BUTTON_LEFT
	button.pressed = true
	button.button_mask = MOUSE_BUTTON_MASK_LEFT
	button.position = position
	var started := Time.get_ticks_usec()
	_last_frame_us = started
	_longest_frame_us = 0
	_measuring = true
	_viewport.push_input(button)
	# The press applies one pass. Submit its preview without another application.
	_tool._process(0.0)
	button = button.duplicate()
	button.pressed = false
	button.button_mask = 0
	_viewport.push_input(button)
	var input_us := Time.get_ticks_usec() - started
	while _tool._edit != null:
		await get_tree().process_frame
	var edit_us := Time.get_ticks_usec() - started
	await _settle()
	var visible_us := Time.get_ticks_usec() - started
	_measuring = false
	_last_chunks = _frame.capture()
	step("Then the stroke changes the surface and supports undo", func():
		expect(State.undo_redo.has_undo(), "the Smooth stroke changes the rough surface")
		State.undo()
		expect(VoxelEditTransaction._chunks_equal(_fixture.capture(), _frame.capture()), "one undo restores the full fixture")
	)
	return {"input": input_us, "edit": edit_us, "visible": visible_us, "gap": _longest_frame_us}


func _settle() -> void:
	await get_tree().process_frame
	while not _renderer.is_settled():
		await get_tree().process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw


func _median(rows: Array, key: String) -> int:
	var values := []
	for row in rows:
		values.append(int(row[key]))
	values.sort()
	return values[values.size() / 2]
