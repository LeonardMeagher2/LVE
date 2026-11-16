extends "res://tests/test.gd"

## Behavior tests for the dither painting brush.
##
## The tests drive the real viewport and the real Paint toolbar. The fixture is
## one solid gray block, so the paint mask is the only reason a cell keeps its
## color. The dither tool writes visible surface cells only.

const DitherMask := preload("res://Globals/State/Tools/DitherMask.gd")
const NEIGHBORS := [
	Vector3i.LEFT,
	Vector3i.RIGHT,
	Vector3i.UP,
	Vector3i.DOWN,
	Vector3i.FORWARD,
	Vector3i.BACK,
]

var _settings := preload("res://plugins/paint/PaintSettings.tres")
var viewport: SubViewport
var center := Vector2.ZERO
var target := VoxelPicking.NONE
var _gray := Color.from_rgba8(150, 150, 150)
var _red := Color.from_rgba8(200, 60, 60)
var _source := {}
var _shown := {}
var _move_pos := Vector2.ZERO


func _ready() -> void:
	timeout = 30.0
	test("the 3D Bayer order and surface fraction are exact", _mask, "mask")
	test("the dither brush writes only masked surface cells", _paint, "paint")
	test("the dither density changes the surface share", _density, "density")
	test("the dither pattern starts at the stroke origin", _origin, "origin")
	test("the dither preview matches the surface write", _preview, "preview")
	test("the dither preview follows a cursor move in the same frame", _preview_move, "preview_move")
	test("the dither mask follows the mirrored stamp", _symmetry, "symmetry")


func before_test() -> void:
	_settings.tool = PaintToolSettings.Tools.DITHER
	_settings.diameter = 8
	_settings.shape = StampToolSettings.BrushShape.CUBE
	_settings.pixel_perfect = false
	_settings.dither_density = 0.5
	State.current_color = _red
	State.symmetry_axes = 0
	State.slice_enabled = false
	viewport = editor_viewport()
	viewport.get_parent().stretch = false
	viewport.size = Vector2i(800, 500)
	center = Vector2(400.0, 250.0)
	activate_tool("paint")
	select_toolbar_item("paint", "Dither Brush")
	_fill_block(12)


func _fill_block(radius: int) -> void:
	var frame := State.get_current_voxel_frame()
	var cells := {}
	for z in range(-radius, radius + 1):
		for y in range(-radius, radius + 1):
			for x in range(-radius, radius + 1):
				cells[Vector3i(x, y, z)] = VoxelFrame.material(_gray)
	frame.set_cells(cells)
	sync_viewport()


func _aim_center() -> void:
	var pick := aim(center)
	expect(pick.hit != VoxelPicking.NONE, "the center aim hits the block")
	target = pick.target


func _pattern() -> Dictionary:
	var pattern: Dictionary = _settings.pattern()
	expect(not pattern.is_empty(), "the brush pattern is ready")
	return pattern


func _exposed(frame: VoxelFrame, cell: Vector3i) -> bool:
	for neighbor: Vector3i in NEIGHBORS:
		if not frame.has(cell + neighbor):
			return true
	return false


func _surface_candidates() -> Array:
	var frame := State.get_current_voxel_frame()
	var candidates: Array = []
	for cell_offset: Vector3i in _pattern():
		var cell := target + cell_offset
		if frame.has(cell) and _exposed(frame, cell):
			candidates.append(cell_offset)
	return candidates


func _expected(density: float) -> Dictionary:
	var frame := State.get_current_voxel_frame()
	var selected := DitherMask.select_offsets(_pattern().keys(), target, density, frame, target)
	var cells := {}
	for cell_offset: Vector3i in selected:
		cells[target + cell_offset] = true
	return cells


func _actual_red() -> Dictionary:
	var frame := State.get_current_voxel_frame()
	var cells := {}
	for cell: Vector3i in frame.positions():
		if frame.get_color(cell) == _red:
			cells[cell] = true
	return cells


func _same_set(first: Dictionary, second: Dictionary) -> bool:
	if first.size() != second.size():
		return false
	for cell in first:
		if not second.has(cell):
			return false
	return true


func _press(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = pos
	viewport.push_input(event)


func _release(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	event.position = pos
	viewport.push_input(event)


func _click(pos: Vector2) -> void:
	_press(pos)
	_release(pos)


func _hover(pos: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	viewport.push_input(event)


func _set_option(control_name: String, value: float) -> void:
	var options: Node = plugin("PaintPlugin")._options
	options.get_node("Brush/" + control_name).value = value


func _wait_cursor() -> void:
	var tool := active_tool_node("PaintPlugin")
	var cursor: MeshInstance3D = tool.get_node("Cursor")
	var deadline := Time.get_ticks_msec() + 5000
	while (tool._hover_job != null or not cursor.is_settled()) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	expect(tool._hover_job == null, "the pattern job finished")
	expect(cursor.is_settled(), "the cursor finished its preview")


func _shown_cells() -> Dictionary:
	var cells := {}
	for cell_offset: Vector3i in _shown:
		cells[target + cell_offset] = true
	return cells


func _mask() -> void:
	step("Given the 4 by 4 by 4 Bayer table and a solid block", func():
		_aim_center()
		var thresholds := {}
		for z in 4:
			for y in 4:
				for x in 4:
					thresholds[DitherMask.threshold(Vector3i(x, y, z), Vector3i.ZERO)] = true
		expect(thresholds.size() == 64, "the tile holds every threshold once")
	)
	step("Then the surface fraction keeps the requested count", func():
		var frame := State.get_current_voxel_frame()
		var candidates := _surface_candidates()
		var half := DitherMask.select_offsets(_pattern().keys(), target, 0.5, frame, target)
		var none := DitherMask.select_offsets(_pattern().keys(), target, 0.0, frame, target)
		var all := DitherMask.select_offsets(_pattern().keys(), target, 1.0, frame, target)
		expect(half.size() == roundi(candidates.size() * 0.5), "half keeps half of the surface cells")
		expect(none.is_empty(), "density zero keeps no cell")
		expect(all.size() == candidates.size(), "density one keeps every surface cell")
		var picked := {}
		for cell_offset in half:
			picked[cell_offset] = true
		expect(picked.size() == half.size(), "the selected surface cells are unique")
	)


func _paint() -> void:
	step("Given a solid gray block and a 50% dither stamp", func():
		_aim_center()
	)
	step("When the user clicks the center", func():
		_click(center)
	)
	step("Then only masked surface cells are red", func():
		var expected := _expected(0.5)
		var actual := _actual_red()
		var candidates := _surface_candidates()
		expect(not expected.is_empty(), "the density keeps some surface cells")
		expect(expected.size() == roundi(candidates.size() * 0.5), "the stroke keeps half of the surface cells")
		expect(_same_set(actual, expected), "the stroke writes the selected surface cells")
		expect(actual.size() < DitherMask.select_offsets(_pattern().keys(), target, 1.0, State.get_current_voxel_frame(), target).size(), "the stroke leaves some surface cells unchanged")
		expect(State.get_current_voxel_frame().count() == 25 ** 3, "the paintbrush adds no cell")
	)
	step("When the user undoes the stroke", func():
		State.undo_redo.undo()
	)
	step("Then the block is gray again", func():
		expect(_actual_red().is_empty(), "the undo restores every cell")
	)


func _density() -> void:
	step("Given a solid gray block", func():
		_aim_center()
	)
	for density in [0.0, 0.25, 0.75, 1.0, 0.5]:
		step("When the user paints with density %.2f" % density, func():
			_set_option("DitherDensity", density)
			expect(is_equal_approx(_settings.dither_density, density), "the density setting follows the control")
			_click(center)
		)
		step("Then the painted share matches density %.2f" % density, func():
			var expected := _expected(density)
			var actual := _actual_red()
			var candidates := _surface_candidates()
			expect(_same_set(actual, expected), "the stroke uses the density-%.2f selection" % density)
			expect(actual.size() == roundi(candidates.size() * density), "the stroke keeps the requested surface share")
		)
		step("When the user undoes the density-%.2f stroke" % density, func():
			State.undo_redo.undo()
		)
		step("Then the block is gray again", func():
			expect(_actual_red().is_empty(), "the undo restores the density-%.2f stroke" % density)
		)


func _origin() -> void:
	step("Given a 25% dither stamp", func():
		_aim_center()
		_set_option("DitherDensity", 0.25)
		_hover(center)
	)
	await _wait_cursor()
	step("Then the hovered cell starts the preview pattern", func():
		_shown = active_tool_node("PaintPlugin").get_node("Cursor").installed_cells()
		expect(_shown.has(Vector3i.ZERO), "the cursor cell has the first threshold")
	)
	step("When the user clicks the origin", func():
		_click(center)
	)
	step("Then the origin cell is painted", func():
		expect(_actual_red().has(target), "the first stroke cell is painted")
	)
	step("When the user undoes and moves to another cell", func():
		State.undo_redo.undo()
		var pos := center
		var pick := aim(pos)
		while pick.target == target:
			pos += Vector2(0.0, 10.0)
			pick = aim(pos)
		target = pick.target
		_move_pos = pos
		_hover(pos)
	)
	await _wait_cursor()
	step("Then the new cursor cell starts a new preview pattern", func():
		_shown = active_tool_node("PaintPlugin").get_node("Cursor").installed_cells()
		expect(_shown.has(Vector3i.ZERO), "the new stroke starts a new pattern")
	)
	step("When the user clicks the new origin", func():
		_click(_move_pos)
	)
	step("Then the new origin cell is painted", func():
		expect(_actual_red().has(target), "the new stroke starts at its own first cell")
	)


func _preview() -> void:
	step("Given a solid gray block and a 50% dither stamp", func():
		_aim_center()
		_hover(center)
	)
	await _wait_cursor()
	step("Then the cursor shows the selected surface cells", func():
		_shown = active_tool_node("PaintPlugin").get_node("Cursor").installed_cells()
		var candidates := _surface_candidates()
		expect(_shown.size() == roundi(candidates.size() * 0.5), "the preview keeps half of the surface cells")
		var surface := {}
		for cell_offset: Vector3i in candidates:
			surface[cell_offset] = true
		var only_surface := true
		for cell_offset in _shown:
			only_surface = only_surface and surface.has(cell_offset)
		expect(only_surface, "the preview shows only surface cells")
	)
	step("When the user clicks the previewed cells", func():
		_click(center)
	)
	step("Then the write matches the preview exactly", func():
		expect(_same_set(_actual_red(), _shown_cells()), "the stroke writes the previewed cells")
	)
	step("When the user undoes and lowers the density", func():
		State.undo_redo.undo()
		_set_option("DitherDensity", 0.25)
		_hover(center)
	)
	await _wait_cursor()
	step("Then the cursor shows the lower surface share", func():
		_shown = active_tool_node("PaintPlugin").get_node("Cursor").installed_cells()
		var candidates := _surface_candidates()
		expect(_shown.size() == roundi(candidates.size() * 0.25), "the preview follows the density")
	)
	step("When the user clicks again", func():
		_click(center)
	)
	step("Then the write still matches the preview", func():
		expect(_same_set(_actual_red(), _shown_cells()), "the lower-density stroke writes the previewed cells")
	)


func _preview_move() -> void:
	step("Given a visible dither cursor", func():
		_aim_center()
		_hover(center)
	)
	await _wait_cursor()
	step("When the user moves the cursor to another cell", func():
		var pos := center
		var pick := aim(pos)
		while pick.target == target:
			pos += Vector2(0.0, 10.0)
			pick = aim(pos)
		target = pick.target
		_hover(pos)
		var cursor: MeshInstance3D = active_tool_node("PaintPlugin").get_node("Cursor")
		var expected := DitherMask.filter_pattern(_pattern(), target, 0.5, State.get_current_voxel_frame(), target)
		expect(cursor.is_settled(), "the inline preview installs in the same input")
		expect(_same_set(cursor.installed_cells(), expected), "the moved cursor shows the new surface cells")
	)


func _symmetry() -> void:
	step("Given a solid block and X symmetry", func():
		State.symmetry_axes = 1
		State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
		_aim_center()
		_source = _expected(0.5)
	)
	step("When the user paints one dither stamp", func():
		_click(center)
	)
	step("Then the write is the mirrored surface selection", func():
		var expected := _source.duplicate()
		var context := State.drawing_context()
		for cell: Vector3i in _source:
			expected[context.reflect(cell, 1)] = true
		expect(_same_set(_actual_red(), expected), "the symmetry mirrors the selected surface cells")
	)
