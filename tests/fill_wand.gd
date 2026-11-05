extends "res://tests/test.gd"

# One process runs the fill and wand tests. Each test keeps the steps and checks
# of its original scene. The user arguments after `--` name the tests to run, so
# an old scene name still selects its own test.

var _selection_settings := preload("res://plugins/selection/settings.tres")

var viewport: SubViewport
var center := Vector2.ZERO
var r1 := VoxelPicking.NONE
var r2 := VoxelPicking.NONE
var r3 := VoxelPicking.NONE
var control := VoxelPicking.NONE
var empty_floor := VoxelPicking.NONE
var seed := VoxelPicking.NONE
var blob_a: Array[Vector3i] = []
var blob_b: Array[Vector3i] = []
var wand_a := VoxelPicking.NONE
var wand_b := VoxelPicking.NONE
var wand_c := VoxelPicking.NONE
var red := VoxelPicking.NONE
var _default_stretch := true
var _default_mode := 0
var _default_connected := true
var _default_fill_connected := true
var _defaults_ready := false


func _ready() -> void:
	test("fill recolors every voxel of the same color when connected is off", _fill_all, "fill_all")
	test("the wand selects all connected voxels of one color", _wand_select, "wand_select")
	test("wand selects every voxel of the same color when connected is off", _wand_all, "wand_all")
	test("the slice stops a fill at the floor layer", _slice_fill, "slice_fill")


# Each test starts from a fresh document. The selection mode and its connected
# option live in a shared resource, so they are restored here. The fill option
# drives its own resource, so its button is restored. The viewport stretch
# returns to its startup value, so a test that keeps the default size sees the
# same size as a fresh process.
func _setup_test() -> void:
	var fill_options: Node = plugin("PaintPlugin")._options
	var connected := fill_options.get_node("Fill/Connected") as Button
	if not _defaults_ready:
		_default_stretch = editor_viewport().get_parent().stretch
		_default_mode = _selection_settings.mode
		_default_connected = _selection_settings.connected
		_default_fill_connected = connected.button_pressed
		_defaults_ready = true
	State.stop()
	State.document = VoxelDocument.new()
	State.slice_enabled = false
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	_selection_settings.mode = _default_mode
	_selection_settings.connected = _default_connected
	if connected != null and connected.button_pressed != _default_fill_connected:
		connected.button_pressed = _default_fill_connected
	editor_viewport().get_parent().stretch = _default_stretch
	await get_tree().process_frame


# Shared viewport setup. The fill and wand_select cases use a fixed 800 by 500
# view. The wand_all case keeps the default view size.
func _view_setup() -> void:
	viewport = editor_viewport()
	viewport.get_parent().stretch = false
	viewport.size = Vector2i(800, 500)
	center = Vector2(400.0, 250.0)


func _click(pos: Vector2, with_shift := false) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	press.shift_pressed = with_shift
	viewport.push_input(press)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = pos
	release.shift_pressed = false
	viewport.push_input(release)


func _screen_pos_of(cell: Vector3i) -> Vector2:
	for dy in range(0, int(viewport.size.y), 10):
		for dx in range(0, int(viewport.size.x), 10):
			var pos := Vector2(dx, dy)
			if aim(pos).target == cell:
				return pos
	return Vector2.INF


func _empty_screen_pos() -> Vector2:
	for dy in range(int(viewport.size.y) - 20, 0, -40):
		for dx in range(20, int(viewport.size.x), 40):
			var res := aim(Vector2(dx, dy))
			if res.target != VoxelPicking.NONE and res.hit == VoxelPicking.NONE:
				return Vector2(dx, dy)
	return Vector2.INF


func _slice_fill() -> void:
	step("Given a red stack on the floor and a slice at layer 0", func():
		_view_setup()
		select_toolbar_item("paint", "Bucket Fill")
		State.set_color(Color.BLUE)
		var req := pick_request(center)
		seed = VoxelPicking.start_pick(req.origin, req.dir, req.frame, req.forward, true).target
		var f: VoxelFrame = State.document.frames[State.current_frame]
		f.set_cell(seed, VoxelFrame.material(Color.RED))
		f.set_cell(seed + Vector3i(1, 0, 0), VoxelFrame.material(Color.RED))
		f.set_cell(seed + Vector3i(0, 1, 0), VoxelFrame.material(Color.RED))
		f.set_cell(seed + Vector3i(0, 2, 0), VoxelFrame.material(Color.RED))
		f.set_cell(seed + Vector3i(0, -1, 0), VoxelFrame.material(Color.RED))
		State.floor_index = seed.y
		State.slice_enabled = true
		sync_viewport()
	)
	step("When the user fills the slice cell", func():
		var pos := _slice_screen_pos_of(seed)
		expect(pos != Vector2.INF, "the slice cell is visible")
		_click(pos)
	)
	step("Then the fill stays on the layer", func():
		var f: VoxelFrame = State.document.frames[State.current_frame]
		expect(f.get_color(seed) == Color.BLUE, "the clicked slice cell takes the fill color")
		expect(f.get_color(seed + Vector3i(1, 0, 0)) == Color.BLUE, "a connected cell on the layer takes the fill color")
		expect(f.get_color(seed + Vector3i(0, 1, 0)) == Color.RED, "the cell above the layer keeps its color")
		expect(f.get_color(seed + Vector3i(0, 2, 0)) == Color.RED, "a farther cell above the layer keeps its color")
		expect(f.get_color(seed + Vector3i(0, -1, 0)) == Color.RED, "the cell below the layer keeps its color")
	)


func _slice_screen_pos_of(cell: Vector3i) -> Vector2:
	for dy in range(0, int(viewport.size.y), 8):
		for dx in range(0, int(viewport.size.x), 8):
			var pos := Vector2(dx, dy)
			var req := pick_request(pos)
			if VoxelPicking.start_pick(req.origin, req.dir, req.frame, req.forward, true).target == cell:
				return pos
	return Vector2.INF


func _fill_all() -> void:
	step("Given the fill tool with a blue brush and three separate red voxels", func():
		_view_setup()
		select_toolbar_item("paint", "Bucket Fill")
		State.set_color(Color.BLUE)
		r1 = aim(center).target
		r2 = r1 + Vector3i(8, 0, 0)
		r3 = r1 + Vector3i(16, 0, 0)
		control = r1 + Vector3i(0, 1, 0)
		var f: VoxelFrame = State.document.frames[State.current_frame]
		f.set_cell(r1, VoxelFrame.material(Color.RED))
		f.set_cell(r2, VoxelFrame.material(Color.RED))
		f.set_cell(r3, VoxelFrame.material(Color.RED))
		f.set_cell(control, VoxelFrame.material(Color.GREEN))
	)

	step("When the user hovers a voxel with Fill", func():
		var motion := InputEventMouseMotion.new()
		motion.position = _screen_pos_of(r2)
		viewport.push_input(motion)
	)
	step("Then Fill shows its wire cube on the voxel", func():
		var tool: Node3D = plugin("PaintPlugin")._fill_tool
		expect(tool.visible and tool.position == Vector3(r2), "the Fill cursor follows the hovered voxel")
		var cursor: MeshInstance3D = tool.get_node("Cursor")
		expect(cursor.mesh.surface_get_primitive_type(0) == Mesh.PRIMITIVE_LINES, "the Fill cursor uses wire lines")
		expect(cursor.mesh.surface_get_array_len(0) == 24, "the Fill cursor shows all twelve cube edges")
	)
	step("When the user moves the Fill cursor over an empty floor cell", func():
		empty_floor = r1 + Vector3i(0, 0, 4)
		var motion := InputEventMouseMotion.new()
		motion.position = camera_rig().unproject_position(Vector3(empty_floor) + Vector3(0, -0.5, 0))
		viewport.push_input(motion)
	)
	step("Then the wire cursor follows the empty floor cell like the picker", func():
		var tool: Node3D = plugin("PaintPlugin")._fill_tool
		expect(tool.visible and tool.position == Vector3(empty_floor), "the Fill cursor stays visible over the empty floor cell")
	)
	step("Then the option bar shows a connected icon toggle", func():
		var b := _find_option_button("Connected")
		expect(b != null, "the connected toggle exists")
		if b == null:
			return
		expect(b.toggle_mode, "the connected control is a toggle button")
		expect(b.icon != null, "the connected toggle shows an icon")
		expect(b.button_pressed, "the connected toggle starts on")
	)

	step("When the user fills one red voxel with connected on", func():
		expect(_find_option_button("Connected").button_pressed == true, "connected is on by default")
		_click(_screen_pos_of(r2))
	)

	step("Then only that voxel changes color", func():
		var f: VoxelFrame = State.document.frames[State.current_frame]
		expect(f.get_color(r2) == Color.BLUE, "the clicked voxel takes the brush color")
		expect(f.get_color(r1) == Color.RED, "the distant red voxel keeps its color")
		expect(f.get_color(r3) == Color.RED, "the farthest red voxel keeps its color")
	)

	step("When the user turns connected off and fills another red voxel", func():
		press_option("Connected")
		_click(_screen_pos_of(r1))
	)

	step("Then every red voxel takes the brush color", func():
		var f: VoxelFrame = State.document.frames[State.current_frame]
		expect(f.get_color(r1) == Color.BLUE, "the first red voxel takes the brush color")
		expect(f.get_color(r3) == Color.BLUE, "the last red voxel takes the brush color")
		expect(f.get_color(control) == Color.GREEN, "the green voxel keeps its color")
	)


func _wand_select() -> void:
	step("Given the wand tool and two gray blobs plus one red voxel", func():
		_view_setup()
		activate_tool("selection")
		select_toolbar_item("selection", "Wand")
		var start := aim(center)
		seed = start.target
		blob_a = [seed, seed + Vector3i(1, 0, 0), seed + Vector3i(0, 0, 1)]
		blob_b = [seed + Vector3i(8, 0, 0), seed + Vector3i(9, 0, 0)]
		# Offset in X, not placed directly above seed. The center click's ray has no X
		# component at the default camera angle, so a voxel stacked with the same X and Z as
		# seed can sit exactly on that ray and get hit instead of seed.
		red = seed + Vector3i(1, 1, 0)
		var gray := Color.from_rgba8(150, 150, 150)
		var red_c := Color.from_rgba8(200, 60, 60)
		var f: VoxelFrame = State.document.frames[State.current_frame]
		for c in blob_a:
			f.set_cell(c, VoxelFrame.material(gray))
		for c in blob_b:
			f.set_cell(c, VoxelFrame.material(gray))
		f.set_cell(red, VoxelFrame.material(red_c))
	)

	step("When the user clicks one gray voxel of the first blob", func():
		_click(center, false)
	)

	step("Then only that connected blob is selected", func():
		expect(State.selection.cells.size() == blob_a.size(), "selection holds exactly the first blob")
		for c in blob_a:
			expect(State.selection.contains(c), "blob voxel is selected")
		expect(not State.selection.contains(red), "the red voxel is not selected")
		expect(not State.selection.contains(blob_b[0]), "the distant blob is not selected")
	)

	step("Given add mode for the next click", func():
		press_option("Add")
	)

	step("When the user clicks the distant blob", func():
		var pos := _screen_pos_of(blob_b[0])
		expect(pos != Vector2.INF, "the distant blob is visible on screen")
		_click(pos, false)
	)

	step("Then both blobs are selected", func():
		expect(State.selection.cells.size() == blob_a.size() + blob_b.size(), "selection holds both blobs")
		for c in blob_b:
			expect(State.selection.contains(c), "distant blob voxel is selected")
	)

	step("When the user clicks an empty cell", func():
		var empty := _empty_screen_pos()
		expect(empty != Vector2.INF, "an empty cell screen position exists")
		_click(empty, false)
	)

	step("Then the selection is unchanged", func():
		expect(State.selection.cells.size() == blob_a.size() + blob_b.size(), "the empty cell click changed nothing")
	)

	step("When the user undoes", func():
		State.undo_redo.undo()
	)

	step("Then the selection reverts to the first blob", func():
		expect(State.selection.cells.size() == blob_a.size(), "undo removes the added blob")
		expect(not State.selection.contains(blob_b[0]), "the added blob is gone")
	)


func _wand_all() -> void:
	step("Given the wand tool and three separate gray voxels plus one red voxel", func():
		viewport = editor_viewport()
		activate_tool("selection")
		select_toolbar_item("selection", "Wand")
		var vsize: Vector2i = viewport.size
		if vsize.x <= 0 or vsize.y <= 0:
			viewport.size = Vector2i(800, 500)
			vsize = viewport.size
		center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
		wand_a = aim(center).target
		wand_b = wand_a + Vector3i(8, 0, 0)
		wand_c = wand_a + Vector3i(16, 0, 0)
		red = wand_a + Vector3i(0, 1, 0)
		var gray := Color.from_rgba8(150, 150, 150)
		var f: VoxelFrame = State.document.frames[State.current_frame]
		f.set_cell(wand_a, VoxelFrame.material(gray))
		f.set_cell(wand_b, VoxelFrame.material(gray))
		f.set_cell(wand_c, VoxelFrame.material(gray))
		f.set_cell(red, VoxelFrame.material(Color.RED))
		camera_rig().center_on(f.get_bounds())
	)

	step("When the user clicks one gray voxel with connected on", func():
		expect(_find_option_button("Connected").button_pressed == true, "connected is on by default")
		_click(_screen_pos_of(wand_b))
	)

	step("Then only that voxel is selected", func():
		expect(State.selection.contains(wand_b), "the clicked voxel is selected")
		expect(not State.selection.contains(wand_a), "the distant gray voxel is not selected")
		expect(not State.selection.contains(red), "the red voxel is not selected")
	)

	step("Given no active selection", func():
		State.clear_selection()
	)

	step("When the user turns connected off and clicks another gray voxel", func():
		press_option("Connected")
		_click(_screen_pos_of(wand_c))
	)

	step("Then every gray voxel is selected", func():
		expect(State.selection.contains(wand_c), "the clicked voxel is selected")
		expect(State.selection.contains(wand_a), "the first gray voxel is selected")
		expect(State.selection.contains(wand_b), "the second gray voxel is selected")
		expect(State.selection.cells.size() == 3, "selection holds exactly the three gray voxels")
		expect(not State.selection.contains(red), "the red voxel is not selected")
	)
