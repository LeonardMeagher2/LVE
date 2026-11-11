extends "res://tests/test.gd"

# One process runs the terrain tests. The parent registers the terrain plugin in
# State, so the setup looks the existing plugin up under the scene root. The
# tests drive the real viewport input, the deterministic time hook, and the
# shared geometry helpers.

const FLOOR_AXIS := {"right": 0, "left": 0, "top": 1, "bottom": 1, "front": 2, "back": 2, "isometric": 1}
const VIEW_AXIS := {"right": 0, "left": 0, "top": 1, "bottom": 1, "front": 2, "back": 2, "isometric": 1}

var _settings := preload("res://plugins/Terrain/settings.tres")

var viewport: SubViewport
var tool: Node3D
var frame: VoxelFrame
var press := Vector2.ZERO
var target := VoxelPicking.NONE
var outward := VoxelPicking.NONE
var inward := VoxelPicking.NONE
var anchor := VoxelPicking.NONE
var mirror := VoxelPicking.NONE
var axis := 1
var grown := 0
var split_cells := {}
var dig_original := {}
var center_height := 0
var edge_height := 0


func _ready() -> void:
	test("grow adds voxels outward on an empty floor", _build_empty_floor, "build_empty_floor")
	test("Build stops at the centered document size", _build_stops_at_document_edge, "build_stops_at_document_edge")
	test("Build stops at the slice boundary", _build_stops_at_slice, "build_stops_at_slice")
	test("an angled press seeds the floor cell under the pointer", _build_empty_floor_angle, "build_empty_floor_angle")
	test("a press from below seeds the cell below the floor plane", _build_empty_floor_below, "build_empty_floor_below")
	test("a flatten stroke that leaves the model fills on its own plane", _flatten_leaves_model, "flatten_leaves_model")
	test("grow remove on an empty floor changes nothing", _build_remove_empty, "build_remove_empty")
	test("the pressed face sets the signed outward normal on every axis", _build_signed_normals, "build_signed_normals")
	test("one Build dab adds the strength scaled by the falloff", _build_strength, "build_strength")
	test("a hard-edge flat patch raises one uniform layer", _build_uniform_layer, "build_uniform_layer")
	test("a hard-edge staircase patch raises a coherent layer", _build_uniform_oblique, "build_uniform_oblique")
	test("a steep staircase raises one shell per layer", _build_steep_layer, "build_steep_layer")
	test("a steep staircase digs one shell per layer", _build_steep_remove, "build_steep_remove")
	test("one Build layer and one Dig layer restore the same surface", _build_dig_symmetry, "build_dig_symmetry")
	test("a steep staircase advances every column the same depth", _build_steep_repeat, "build_steep_repeat")
	test("reversed sample order writes the same cells", _build_order_independent, "build_order_independent")
	test("each Build dab adds the strength again", _build_repeat, "build_repeat")
	test("the strength clamps to a whole layer count", _build_exact_boundary, "build_exact_boundary")
	test("smooth falloff makes deterministic nested height bands", _build_falloff_bands, "build_falloff_bands")
	test("a revisited sample keeps its step count", _build_progress_retained, "build_progress_retained")
	test("a stationary tower grows past the scan depth without overwriting", _build_deep_tower, "build_deep_tower")
	test("flatten fills and cuts samples to one surface without overshoot", _flatten_surface, "flatten_surface")
	test("flatten mirrors its target through the symmetry normal", _flatten_symmetry_target, "flatten_symmetry_target")
	test("a surface plane follows a slope and is not cardinal", _surface_slope, "surface_slope")
	test("a flat plate keeps its cardinal normal", _surface_planar, "surface_planar")
	test("an isolated voxel falls back to the clicked face", _surface_degenerate, "surface_degenerate")
	test("a stray voxel keeps the plane near the plate normal", _surface_noise, "surface_noise")
	test("an opposing wall does not tilt the plane", _surface_opposing, "surface_opposing")
	test("a collinear surface falls back to the clicked face", _surface_collinear, "surface_collinear")
	test("the surface normal matches a known height gradient", _gradient_synthetic, "gradient_synthetic")
	test("the read samples the full brush disc", _gradient_full_disc, "gradient_full_disc")
	test("grow on a slope adds along the surface normal", _build_slope, "build_slope")
	test("successive steps keep one coherent layer", _oblique_steps, "oblique_steps")
	test("a ray with tied components keeps one path for both signs", _oblique_ties, "oblique_ties")
	test("flatten on a slope cuts toward the surface plane", _flatten_slope, "flatten_slope")
	test("flatten settles to one slope and does not oscillate", _flatten_converges, "flatten_converges")
	test("a surface plane mirrors through a symmetry plane", _surface_symmetry, "surface_symmetry")
	test("grab drags on the true camera-facing plane", _grab_oblique, "grab_oblique")
	test("grab stretches voxels, keeps materials, and preserves unrelated geometry", _grab_stretch, "grab_stretch")
	test("grab keeps a source whose destination leaves the selection", _grab_selection_destination, "grab_selection_destination")
	test("grab ignores sources and destinations outside the document size", _grab_stops_at_document_edge, "grab_stops_at_document_edge")
	test("smooth fields stay inside the document size", _smooth_stops_at_document_edge, "smooth_stops_at_document_edge")
	test("grab without a source changes nothing", _grab_empty, "grab_empty")
	test("a large grab runs on the worker pool and publishes once", _grab_worker, "grab_worker")
	test("a grab honors the shared radius bound past the old cap", _grab_shared_radius, "grab_shared_radius")
	test("a queued return to the origin closes the edit", _grab_pending_return, "grab_pending_return")
	test("a cancelled worker cannot touch a replacement stroke", _cancel_repress, "cancel_repress")
	test("a grow stroke supports undo, redo, Escape, a switch, and a context change", _stroke_history, "stroke_history")
	test("a lost left release finishes the stroke", _lost_release, "lost_release")
	test("frame-spaced motion interpolates without amplifying time", _motion_interpolation, "motion_interpolation")
	test("selection and symmetry limit and mirror a grow stroke", _selection_symmetry, "selection_symmetry")
	test("the Grab options keep the shared radius and hide strength", _grab_controls, "grab_controls")


func before_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.current_color = Color.from_rgba8(200, 60, 60)
	State.floor_index = 0
	State.slice_layers = 0
	_settings.tool = _settings.Tools.BUILD
	_settings.build_mode = _settings.BuildMode.ADD
	_settings.radius = 5
	_settings.strength = 8.0
	_settings.falloff = 0.0
	viewport = editor_viewport()
	viewport.get_parent().stretch = false
	viewport.size = Vector2i(800, 500)
	camera_rig().is_orthogonal = true
	frame = State.get_current_voxel_frame()
	await _ensure_plugin()
	activate_tool("terrain")
	plugin("TerrainPlugin").activate_tool()
	tool = plugin("TerrainPlugin")._tool
	tool.set_process(true)
	await get_tree().process_frame


func after_test() -> void:
	if tool != null and tool._edit != null:
		tool.finish_on_switch()
	State.stop()


func _ensure_plugin() -> void:
	# The parent registers the plugin in State. Wait for the deferred add.
	for _frame in 5:
		if plugin("TerrainPlugin") != null:
			return
		await get_tree().process_frame


# --- Shared helpers ---------------------------------------------------------

func _view(view: String) -> void:
	State.floor_axis = FLOOR_AXIS[view]
	camera_rig().set_view(view)
	camera_rig().is_orthogonal = true


func _pos(world: Vector3) -> Vector2:
	return camera_rig().unproject_position(world)


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


func _motion(pos: Vector2, relative: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	event.relative = relative
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	viewport.push_input(event)


func _hover(pos: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	viewport.push_input(event)


func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	get_tree().root.push_input(event)


func _column_height(cell_column: Vector3i, plane_axis: int, sign: int, plane: int) -> int:
	var cell := cell_column
	cell[plane_axis] = plane
	var count := 0
	while frame.has(cell):
		count += 1
		cell[plane_axis] += sign
	return count


func _cell_colors(source: VoxelFrame) -> Dictionary:
	var colors := {}
	for cell in source.positions():
		colors[cell] = source.get_color(cell)
	return colors


func _cell_materials(source: VoxelFrame) -> Dictionary:
	var materials := {}
	for cell in source.positions():
		materials[cell] = source.get_material(cell)
	return materials


func _same_cells(first: Dictionary, second: Dictionary) -> bool:
	if first.size() != second.size():
		return false
	for cell in first:
		if not second.has(cell):
			return false
	return true


func _job_samples(source: VoxelFrame, hit: Vector3i, entry: Vector3i, radius: int) -> Array:
	var surface_frame := TerrainFrame.from_surface(source, hit, entry, radius, TerrainFrame.from_face(hit, entry))
	var samples := []
	for off in TerrainGeometry.disk_offsets(radius):
		var point: Vector3 = surface_frame.origin + float(off["u"]) * surface_frame.tangent_u + float(off["v"]) * surface_frame.tangent_v
		samples.append({
			"anchor": TerrainGeometry.cell_at(point),
			"point": point,
			"normal": surface_frame.normal,
			"plane_origin": surface_frame.origin,
			"surface": TerrainGeometry.surface_along(source, point, surface_frame.normal, 16, {}),
			"steps": 1,
		})
	return samples


func _run_job(source: VoxelFrame, samples: Array) -> Array:
	var job = tool.get_script().TerrainTickJob.new()
	job.edited_frame = source.copy_frame()
	job.samples = samples
	job.material = VoxelFrame.material(Color.WHITE)
	job.run()
	var added := []
	for cell in job.edited_frame.positions():
		if not source.has(cell):
			added.append(cell)
	added.sort()
	return added


func _await_tool_idle() -> void:
	for _frame in 600:
		if tool._tick_job == null and tool._grab_job == null and not State.edit_busy():
			await get_tree().process_frame
			return
		await get_tree().process_frame


func _await_edit_closed() -> void:
	for _frame in 600:
		if tool._edit == null and tool._grab_job == null and not State.edit_busy():
			await get_tree().process_frame
			return
		await get_tree().process_frame


# Waits until the accepted path is consumed, no job runs, and the stroke closes.
func _await_drained() -> void:
	for _frame in 1200:
		if not tool._busy() and not tool._has_pending() and tool._edit == null:
			await get_tree().process_frame
			return
		await get_tree().process_frame


func _fill_ramp(x_max: int, slope: int, z_min: int, z_max: int) -> void:
	for x in range(0, x_max + 1):
		var top := slope * x
		for y in range(0, top + 1):
			for z in range(z_min, z_max + 1):
				frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.WHITE))


# --- Build and flatten -------------------------------------------------------

func _build_empty_floor() -> void:
	step("Given the Build tool in Add mode on an empty floor", func():
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 1
		_settings.falloff = 0.0
		_settings.strength = 10.0
		_view("top")
		press = _pos(Vector3.ZERO)
		var pick := aim(press)
		expect(pick.hit == VoxelPicking.NONE, "the press misses the model")
		target = pick.target
		expect(target != VoxelPicking.NONE, "the floor pick has a target")
	)
	step("When the user presses and holds the Build tool", func():
		_press(press)
		expect(tool._edit != null, "the press opens an edit")
		tool.advance_stroke(0.5)
		_release(press)
	)
	step("Then the floor grows outward from the press plane", func():
		expect(frame.has(target), "the seed cell appears on the floor")
		expect(frame.has(target + Vector3i(0, 1, 0)), "the growth continues outward")
		expect(State.undo_redo.has_undo(), "the stroke records one history action")
	)


func _build_stops_at_document_edge() -> void:
	step("Given Build on an empty floor with a four-cell Y size", func():
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 1
		_settings.falloff = 0.0
		_settings.strength = 1.0
		_view("top")
		State.floor_index = 0
		State.set_size(Vector3i(0, 4, 0))
		press = _pos(Vector3.ZERO)
		target = aim(press).target
		expect(State.document.axis_cell_range(1) == Vector2i(-2, 2), "the Y size covers cells minus two through one")
	)
	step("When the user presses three times", func():
		for _press_index in 3:
			_press(press)
			_release(press)
	)
	step("Then the column stops at the top bound", func():
		expect(frame.has(Vector3i(target.x, 1, target.z)), "the last writable layer is built")
		expect(not frame.has(Vector3i(target.x, 2, target.z)), "the layer past the size is refused")
	)


func _build_stops_at_slice() -> void:
	step("Given Build on an empty floor with one slice layer each side", func():
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 1
		_settings.falloff = 0.0
		_settings.strength = 1.0
		_view("top")
		State.floor_index = 0
		State.slice_layers = 1
		State.set_size(Vector3i.ZERO)
		press = _pos(Vector3.ZERO)
		target = aim(press).target
		expect(State.slice_first() == -1 and State.slice_last() == 0, "the slab holds one layer each side")
	)
	step("When the user presses three times", func():
		for _press_index in 3:
			_press(press)
			_release(press)
	)
	step("Then the column stops at the slice top", func():
		expect(frame.has(Vector3i(target.x, 0, target.z)), "the floor layer is built")
		expect(not frame.has(Vector3i(target.x, 1, target.z)), "the layer above the slab is refused")
	)


func _build_empty_floor_angle() -> void:
	step("Given the Build tool on an empty floor seen at an angle", func():
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 1
		_settings.falloff = 0.0
		_settings.strength = 1.0
		_view("isometric")
		press = _pos(Vector3(0.4, 0.0, 0.4))
		var pick := aim(press)
		expect(pick.hit == VoxelPicking.NONE, "the press misses the model")
		target = pick.target
		expect(target != VoxelPicking.NONE, "the floor pick has a target")
		_hover(press)
	)
	var ring := tool.get_node("Footprint") as MeshInstance3D
	var idle_pose := ring.global_transform.origin
	step("When the user presses once and moves one pixel", func():
		_press(press)
		expect(ring.global_transform.origin.distance_to(idle_pose) <= 1e-3, "the press keeps the ring on the floor grid")
		_motion(press + Vector2(1.0, 1.0), Vector2(1.0, 1.0))
		_release(press + Vector2(1.0, 1.0))
	)
	step("Then the press seeds one cell and the small move adds none", func():
		expect(frame.count() == 1, "the press adds exactly one cell (%d)" % frame.count())
		expect(frame.has(target), "the seed cell is the clicked floor cell")
	)


func _build_empty_floor_below() -> void:
	step("Given the Build tool on an empty floor seen from below", func():
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 1
		_settings.falloff = 0.0
		_settings.strength = 1.0
		_view("bottom")
		press = _pos(Vector3(0.0, 0.0, 0.0))
		var pick := aim(press)
		expect(pick.hit == VoxelPicking.NONE, "the press misses the model")
		target = pick.target
		expect(target == Vector3i(0, -1, 0), "the floor pick is on the side below the plane")
	)
	step("When the user presses once", func():
		_press(press)
		_release(press)
	)
	step("Then the seed cell is on the side the pointer is on", func():
		expect(frame.count() == 1, "the press adds exactly one cell (%d)" % frame.count())
		expect(frame.has(Vector3i(0, -1, 0)), "the seed sits below the floor plane")
	)


func _flatten_leaves_model() -> void:
	step("Given a plate and Flatten seen from below", func():
		_view("bottom")
		for x in range(-2, 3):
			for z in range(-2, 3):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.FLATTEN
		_settings.radius = 5
		_settings.falloff = 0.0
		_settings.strength = 1.0
		press = _pos(Vector3(0.0, 0.0, 0.0))
		split_cells = _cell_colors(frame)
	)
	step("When the user drags off the plate into empty space", func():
		_press(press)
		_motion(_pos(Vector3(6.0, 0.0, 0.0)), Vector2(6.0, 0.0))
		_release(_pos(Vector3(6.0, 0.0, 0.0)))
	)
	step("Then the fill stays on the pressed plane", func():
		var below := 0
		for cell in frame.positions():
			if split_cells.has(cell):
				continue
			if cell.y < 0:
				below += 1
		expect(below == 0, "no cell lands below the pressed surface (%d)" % below)
	)


func _build_remove_empty() -> void:
	step("Given the Build tool in Remove mode on an empty floor", func():
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.REMOVE
		_settings.radius = 5
		_settings.strength = 10.0
		_view("top")
		press = _pos(Vector3.ZERO)
	)
	step("When the user presses and holds", func():
		_press(press)
		tool.advance_stroke(0.5)
		_release(press)
	)
	step("Then nothing changes and no history is recorded", func():
		expect(frame.count() == 0, "Remove never seeds an empty sample")
		expect(not State.undo_redo.has_undo(), "the empty stroke adds no history")
		expect(not State.edit_busy(), "the release ends the edit")
	)


func _build_signed_normals() -> void:
	for view in ["front", "right", "top", "bottom"]:
		step("Given a single voxel seen from the %s" % view, func():
			State.document = VoxelDocument.new()
			frame = State.get_current_voxel_frame()
			_view(view)
			_settings.tool = _settings.Tools.BUILD
			_settings.build_mode = _settings.BuildMode.ADD
			_settings.radius = 1
			_settings.falloff = 0.0
			_settings.strength = 10.0
			press = _pos(Vector3.ZERO)
			var base := aim(press).target
			frame.set_cell(base, VoxelFrame.material(Color.WHITE))
			sync_viewport()
			var pick := aim(press)
			expect(pick.hit != VoxelPicking.NONE, "the ray hits the voxel")
			outward = pick.hit + pick.entry
			inward = pick.hit - pick.entry
			axis = VIEW_AXIS[view]
		)
		step("When the user grows the %s face" % view, func():
			_press(press)
			expect(tool._stroke_frame.axis == axis, "the pressed face sets the %s axis" % view)
			expect(tool._stroke_frame.sign == (-1 if view == "bottom" else 1), "the face sets the outward sign")
			tool.advance_stroke(0.3)
			_release(press)
		)
		step("Then the voxel grows along the outward normal", func():
			expect(frame.has(outward), "the added voxel is on the outward side")
			expect(not frame.has(inward), "the voxel does not grow inward")
		)


func _build_strength() -> void:
	step("Given Build with falloff on an empty floor", func():
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 9
		_settings.falloff = 0.5
		_settings.strength = 4
		_view("top")
		press = _pos(Vector3.ZERO)
		target = aim(press).target
	)
	step("When the user presses once", func():
		_press(press)
		_release(press)
		split_cells = _cell_colors(frame)
		center_height = _column_height(target, 1, 1, 0)
		edge_height = _column_height(target + Vector3i(4, 0, 0), 1, 1, 0)
	)
	step("Then the center gains the full strength and the edge gains less", func():
		expect(center_height == 4, "the center gains the full strength (%d)" % center_height)
		expect(edge_height > 1, "the edge gains at least one layer (%d)" % edge_height)
		expect(center_height > edge_height, "the falloff decreases the edge growth")
	)


func _build_uniform_layer() -> void:
	step("Given a flat plate and the Build tool with no falloff", func():
		_view("top")
		for x in range(-4, 5):
			for z in range(-4, 5):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 5
		_settings.falloff = 0.0
		_settings.strength = 1.0
		press = _pos(Vector3.ZERO)
	)
	step("When the user presses once", func():
		_press(press)
		_release(press)
	)
	step("Then every footprint column gains exactly one layer", func():
		var uniform := true
		for entry in TerrainGeometry.disk_offsets(5):
			if _column_height(Vector3i(entry["u"], 0, entry["v"]), 1, 1, 0) != 2:
				uniform = false
		expect(uniform, "every footprint column has the same height")
	)
	step("When the user applies two more layers", func():
		_press(press)
		tool.advance_stroke(1.0)
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then every footprint column keeps the same depth", func():
		var uniform := true
		for entry in TerrainGeometry.disk_offsets(5):
			if _column_height(Vector3i(entry["u"], 0, entry["v"]), 1, 1, 0) != 5:
				uniform = false
		expect(uniform, "repeated presses keep a uniform depth")
	)


func _build_uniform_oblique() -> void:
	step("Given a gentle staircase and the Build tool with no falloff", func():
		_view("top")
		for x in range(0, 10):
			for y in range(0, x / 2 + 1):
				for z in range(-4, 5):
					frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		split_cells = _cell_colors(frame)
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 5
		_settings.falloff = 0.0
		_settings.strength = 1.0
		press = _pos(Vector3(4.0, 2.0, 0.0))
	)
	step("When the user presses once", func():
		_press(press)
		expect(tool._stroke_frame.follows_surface and tool._stroke_frame.normal.x < -0.2, "the stroke follows the staircase slope")
		grown = tool._samples.size()
		_release(press)
	)
	step("Then every column gains one cell with no holes", func():
		var added := 0
		var columns := {}
		var rests_on_surface := true
		for cell in frame.positions():
			if split_cells.has(cell):
				continue
			added += 1
			columns[Vector2i(cell.x, cell.z)] = true
			if not frame.has(cell - Vector3i(0, 1, 0)):
				rests_on_surface = false
		expect(grown > 0, "the stroke has a footprint")
		expect(added == columns.size(), "the stroke adds one cell per footprint column")
		expect(rests_on_surface, "every added cell rests on a support")
	)


# A slope-two staircase. A positive slope rises toward +x, a negative slope
# rises toward -x. The surface is one cell wide in the layer column, so a
# coherent shell must add exactly one cell per column.
func _steep_frame(slope: int) -> VoxelFrame:
	var source := VoxelFrame.new()
	for x in range(0, 14):
		var top: int = slope * x if slope > 0 else -slope * (13 - x)
		for y in range(0, top + 1):
			for z in range(-5, 6):
				source.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.WHITE))
	return source


func _steep_cells(slope: int) -> void:
	for x in range(0, 14):
		var top: int = slope * x if slope > 0 else -slope * (13 - x)
		for y in range(0, top + 1):
			for z in range(-5, 6):
				frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.WHITE))


func _build_steep_layer() -> void:
	step("Given a slope-two staircase and the Build tool", func():
		_view("top")
		_steep_cells(2)
		sync_viewport()
		split_cells = _cell_colors(frame)
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 5
		_settings.falloff = 0.0
		_settings.strength = 1.0
		press = _pos(Vector3(6.0, 12.0, 0.0))
	)
	step("When the user presses once", func():
		_press(press)
		expect(tool._stroke_frame.follows_surface and tool._stroke_frame.normal.x < -0.5, "the stroke follows the steep slope")
		grown = tool._samples.size()
		_release(press)
	)
	step("Then every column gains one cell that rests on its support", func():
		var added := []
		var rests := true
		for cell in frame.positions():
			if split_cells.has(cell):
				continue
			added.append(cell)
			if not frame.has(cell + Vector3i(1, 0, 0)):
				rests = false
		expect(grown > 0, "the stroke has a footprint")
		expect(added.size() == grown, "the shell has one cell per column with no gap")
		expect(rests, "every added cell rests on its support along the layer axis")
	)


func _build_steep_remove() -> void:
	step("Given a slope-two staircase and the Build tool in Remove mode", func():
		_view("top")
		_steep_cells(2)
		sync_viewport()
		split_cells = _cell_colors(frame)
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.REMOVE
		_settings.radius = 5
		_settings.falloff = 0.0
		_settings.strength = 1.0
		press = _pos(Vector3(6.0, 12.0, 0.0))
	)
	step("When the user presses once", func():
		_press(press)
		grown = tool._samples.size()
		_release(press)
	)
	step("Then every column loses its outer cell and keeps its interior", func():
		var removed := []
		var keeps_interior := true
		for cell in split_cells:
			if frame.has(cell):
				continue
			removed.append(cell)
			if not frame.has(cell + Vector3i(1, 0, 0)):
				keeps_interior = false
		expect(removed.size() == grown, "the dig removes one cell per column")
		expect(keeps_interior, "the dig never cuts the interior of a column")
	)


func _build_steep_repeat() -> void:
	step("Given a slope-two staircase and the Build tool", func():
		_view("top")
		_steep_cells(2)
		sync_viewport()
		split_cells = _cell_colors(frame)
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 5
		_settings.falloff = 0.0
		_settings.strength = 1.0
		press = _pos(Vector3(6.0, 12.0, 0.0))
	)
	step("When the user applies three layers", func():
		_press(press)
		grown = tool._samples.size()
		tool.advance_stroke(1.0)
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then every column advances three cells", func():
		var added := []
		var rests := true
		for cell in frame.positions():
			if split_cells.has(cell):
				continue
			added.append(cell)
			if not frame.has(cell + Vector3i(1, 0, 0)):
				rests = false
		expect(added.size() == 3 * grown, "three layers add three cells per column")
		expect(rests, "every added cell rests on an occupied support")
	)


func _build_dig_symmetry() -> void:
	step("Given a flat plate and the Build tool", func():
		_view("top")
		for x in range(-4, 5):
			for z in range(-4, 5):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		dig_original = _cell_colors(frame)
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 5
		_settings.falloff = 0.0
		_settings.strength = 1.0
		press = _pos(Vector3(0.0, 1.0, 0.0))
	)
	step("When one Build layer applies", func():
		_press(press)
		_release(press)
	)
	step("Then the plate rose one layer", func():
		expect(_cell_colors(frame) != dig_original, "the grow press changed the plate")
	)
	step("When one Dig layer applies to the raised plate", func():
		_settings.build_mode = _settings.BuildMode.REMOVE
		_press(press)
		_release(press)
	)
	step("Then the plate equals the original", func():
		expect(_cell_colors(frame) == dig_original, "one dig layer restored every grown cell")
	)


func _build_order_independent() -> void:
	step("Given a steep staircase footprint and a fixed job", func():
		var all_match := true
		var all_gain := true
		for slope in [2, -2]:
			var source := _steep_frame(slope)
			var hit := Vector3i(6, 6 * slope if slope > 0 else -slope * 7, 0)
			var samples := _job_samples(source, hit, Vector3i(0, 1, 0), 2)
			var forward := {}
			for cell in _run_job(source, samples):
				forward[cell] = true
			samples.reverse()
			var backward := {}
			for cell in _run_job(source, samples):
				backward[cell] = true
			all_match = all_match and _same_cells(forward, backward)
			all_gain = all_gain and not forward.is_empty()
		expect(all_gain, "the steep slope gains cells at both signs")
		expect(all_match, "the sample order does not change the cells at either sign")
	)


func _build_repeat() -> void:
	step("Given a flat plate and the Build tool at strength six", func():
		_view("top")
		for x in range(-4, 5):
			for z in range(-4, 5):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 5
		_settings.falloff = 0.0
		_settings.strength = 6
		press = _pos(Vector3.ZERO)
	)
	step("When the user dabs once", func():
		_press(press)
		_release(press)
		center_height = _column_height(Vector3i(0, 0, 0), 1, 1, 0)
	)
	step("When the user dabs a second time", func():
		_press(press)
		_release(press)
	)
	step("Then each dab adds six layers", func():
		expect(center_height == 7, "one dab adds six layers plus the plate (%d)" % center_height)
		expect(_column_height(Vector3i(0, 0, 0), 1, 1, 0) == 13, "two dabs add twelve layers plus the plate")
	)


func _build_exact_boundary() -> void:
	step("Given the shared strength setting", func():
		_settings.strength = 4.0
	)
	step("Then the strength stores a whole layer count", func():
		expect(_settings.strength == 4, "a whole value stores as it is")
		_settings.strength = 0.5
		expect(_settings.strength == 1, "a value below one clamps to one")
		_settings.strength = 40.0
		expect(_settings.strength == 16, "a value above sixteen clamps to sixteen")
		_settings.strength = 4
	)


func _build_falloff_bands() -> void:
	step("Given a flat plate and the Build tool with falloff", func():
		_view("top")
		for x in range(-5, 6):
			for z in range(-5, 6):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 9
		_settings.falloff = 0.5
		_settings.strength = 12.0
		press = _pos(Vector3.ZERO)
	)
	step("When the user holds for several steps", func():
		_press(press)
		for _tick in 6:
			tool.advance_stroke(1.0)
		_release(press)
		split_cells = _cell_colors(frame)
	)
	step("Then the heights form nested bands that fall to the edge", func():
		var ring_height := {}
		var monotonic := true
		var uniform_ring := true
		for entry in TerrainGeometry.disk_offsets(9):
			var distance := float(entry["distance"])
			var height := _column_height(Vector3i(entry["u"], 0, entry["v"]), 1, 1, 0)
			if ring_height.has(distance) and ring_height[distance] != height:
				uniform_ring = false
			ring_height[distance] = height
		var by_ring := {}
		for distance in ring_height:
			var ring := int(round(distance))
			by_ring[ring] = maxi(int(by_ring.get(ring, 0)), int(ring_height[distance]))
		for distance in range(1, 5):
			if int(by_ring.get(distance, 0)) > int(by_ring.get(distance - 1, 0)):
				monotonic = false
		expect(uniform_ring, "every column at one distance has the same height")
		expect(monotonic, "the height never rises toward the edge")
	)


func _build_progress_retained() -> void:
	step("Given a Build stroke with two dabs", func():
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 1
		_settings.falloff = 0.0
		_settings.strength = 1
		_view("top")
		press = _pos(Vector3.ZERO)
		target = aim(press).target
		_press(press)
		tool.advance_stroke(1.0)
		expect(_column_height(target, 1, 1, 0) == 2, "two dabs add two layers")
	)
	step("When the user leaves and returns", func():
		var far := _pos(Vector3(8.0, 0.0, 0.0))
		_motion(far, far - press)
		_motion(press, press - far)
	)
	step("Then the revisit adds one more dab", func():
		expect(_column_height(target, 1, 1, 0) == 3, "the revisit adds one layer")
	)


func _build_deep_tower() -> void:
	step("Given the Build tool in Add mode on an empty floor", func():
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 1
		_settings.falloff = 0.0
		_settings.strength = 4.0
		_view("top")
		press = _pos(Vector3.ZERO)
		target = aim(press).target
		_press(press)
	)
	step("When the user applies forty layers", func():
		for _tick in 9:
			tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then the tower is a clean column with no overwritten interior", func():
		var height := _column_height(target, 1, 1, 0)
		expect(height == 40, "the tower grows past the scan depth")
		expect(frame.has(target + Vector3i(0, height - 1, 0)), "the tower top is occupied")
		expect(not frame.has(target + Vector3i(0, height, 0)), "the tower has no cell above the top")
		expect(frame.count() == height * TerrainGeometry.disk_offsets(_settings.radius).size(), "every footprint column grows the same clean column")
	)
	step("Given a tall tower and the Build tool in Remove mode", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_view("top")
		anchor = aim(_pos(Vector3.ZERO)).target
		for y in range(0, 40):
			frame.set_cell(anchor + Vector3i(0, y, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		camera_rig().center_on(AABB(Vector3(-2, -2, -2), Vector3(4, 50, 4)))
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.REMOVE
		_settings.radius = 1
		_settings.falloff = 0.0
		_settings.strength = 4.0
		press = _pos(Vector3(anchor + Vector3i(0, 39, 0)))
	)
	step("When the user holds Remove", func():
		_press(press)
		for _tick in 12:
			tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then the tall tower is removed from the top down", func():
		expect(_column_height(anchor, 1, 1, 0) == 0, "Remove clears the whole tower")
	)


func _flatten_surface() -> void:
	step("Given a tall, a short, and an over-tall column", func():
		_settings.tool = _settings.Tools.FLATTEN
		_settings.radius = 9
		_settings.falloff = 0.0
		_settings.strength = 30.0
		_view("top")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		for y in range(0, 5):
			frame.set_cell(anchor + Vector3i(0, y, 0), VoxelFrame.material(Color.WHITE))
		for y in range(0, 2):
			frame.set_cell(anchor + Vector3i(2, y, 0), VoxelFrame.material(Color.WHITE))
		for y in range(0, 7):
			frame.set_cell(anchor + Vector3i(-2, y, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		press = _pos(Vector3(anchor))
	)
	step("When the user presses the tall column top and holds", func():
		_press(press)
		expect(tool._stroke_frame.origin.y > 4.0, "the surface plane sits on the pressed face")
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then every column reaches the flat surface without overshoot", func():
		expect(_column_height(anchor, 1, 1, 0) == 5, "the tall column stays at its height")
		expect(_column_height(anchor + Vector3i(2, 0, 0), 1, 1, 0) == 5, "the short column fills up to the surface")
		expect(_column_height(anchor + Vector3i(-2, 0, 0), 1, 1, 0) == 5, "the over-tall column cuts down to the surface")
		expect(not frame.has(anchor + Vector3i(2, 5, 0)), "the fill does not overshoot")
		expect(not frame.has(anchor + Vector3i(-2, 5, 0)), "the cut does not overshoot")
	)
	step("When the user flattens an empty floor", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_view("top")
		press = _pos(Vector3.ZERO)
		target = aim(press).target
		_press(press)
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then a flat layer appears on the floor", func():
		expect(frame.has(target), "the flatten seeds the floor")
		expect(not frame.has(target + Vector3i(0, 1, 0)), "the flat layer has one cell of height")
	)


func _flatten_symmetry_target() -> void:
	step("Given a front view with the Z symmetry plane away from the target", func():
		_settings.tool = _settings.Tools.FLATTEN
		_settings.radius = 1
		_settings.falloff = 0.0
		_settings.strength = 30.0
		_view("front")
		State.symmetry_axes = 4
		State.symmetry_origin = Vector3(0.0, 0.0, 2.5)
		press = _pos(Vector3.ZERO)
		target = aim(press).target
		mirror = Vector3i(target.x, target.y, 5 - target.z)
	)
	step("When the user flattens an empty floor", func():
		_press(press)
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then each side seeds at its own reflected target", func():
		expect(frame.has(target), "the pressed side seeds at the pressed target")
		expect(frame.has(mirror), "the mirrored side seeds at the reflected target")
	)


# --- Surface plane -----------------------------------------------------------

func _surface_slope() -> void:
	step("Given a ramp that rises two cells per step", func():
		_view("top")
		_fill_ramp(5, 2, -2, 2)
		sync_viewport()
		_settings.tool = _settings.Tools.BUILD
		_settings.radius = 5
		_settings.falloff = 0.0
		_settings.strength = 10.0
		press = _pos(Vector3(2.0, 4.0, 0.0))
		anchor = aim(press).target
		expect(anchor == Vector3i(2, 4, 0), "the press lands on the ramp top")
	)
	step("When the user presses the ramp", func():
		_press(press)
	)
	step("Then the surface plane follows the slope and is not cardinal", func():
		expect(tool._stroke_frame.follows_surface, "the plane follows the surface, not a cube face")
		expect(tool._stroke_frame.normal.x < -0.5, "the surface normal tilts along the slope")
		expect(absf(tool._stroke_frame.normal.y) > 0.3, "the surface normal still faces outward")
		expect(TerrainGeometry.next_cell(anchor, tool._stroke_frame.normal) == Vector3i(1, 4, 0), "the normal steps down the slope")
		_release(press)
	)


func _surface_planar() -> void:
	step("Given a flat plate", func():
		_view("top")
		for x in range(-3, 4):
			for z in range(-3, 4):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		press = _pos(Vector3(0.0, 0.0, 0.0))
	)
	step("When the user presses the plate", func():
		_press(press)
	)
	step("Then the surface normal is the plate normal", func():
		expect(tool._stroke_frame.follows_surface, "the plane follows the surface")
		expect(tool._stroke_frame.normal.dot(Vector3.UP) > 0.99, "the surface normal is the plate normal")
		_release(press)
	)


func _surface_degenerate() -> void:
	step("Given a single isolated voxel", func():
		_view("top")
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.WHITE))
		sync_viewport()
		press = _pos(Vector3.ZERO)
	)
	step("When the user presses the voxel", func():
		_press(press)
	)
	step("Then the plane falls back to the clicked face", func():
		expect(not tool._stroke_frame.follows_surface, "a single voxel falls back")
		expect(tool._stroke_frame.normal == Vector3.UP, "the fallback uses the clicked face normal")
		_release(press)
	)


func _surface_noise() -> void:
	step("Given a flat plate with one stray voxel", func():
		_view("top")
		for x in range(-3, 4):
			for z in range(-3, 4):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		frame.set_cell(Vector3i(3, 1, 3), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		press = _pos(Vector3(0.0, 0.0, 0.0))
	)
	step("When the user presses the plate", func():
		_press(press)
	)
	step("Then the plane stays near the plate normal", func():
		expect(tool._stroke_frame.follows_surface, "the plane follows the surface")
		expect(tool._stroke_frame.normal.dot(Vector3.UP) > 0.9, "the stray voxel does not tilt the plane")
		_release(press)
	)


func _surface_opposing() -> void:
	step("Given a channel with a three-cell floor and two opposing walls", func():
		_view("top")
		for z in range(-3, 4):
			for y in range(0, 4):
				frame.set_cell(Vector3i(2, y, z), VoxelFrame.material(Color.WHITE))
				frame.set_cell(Vector3i(-2, y, z), VoxelFrame.material(Color.WHITE))
			for x in range(-1, 2):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		press = _pos(Vector3(0.0, 0.0, 0.0))
	)
	step("When the user presses the channel floor", func():
		_press(press)
	)
	step("Then the walls do not tilt the plane", func():
		expect(tool._stroke_frame.follows_surface, "the plane follows the surface")
		expect(tool._stroke_frame.normal.dot(Vector3.UP) > 0.9, "the opposing walls stay out of the plane")
		_release(press)
	)


# The channel floor is three cells wide. A one-cell floor gives only collinear
# height samples, so the gradient is undefined and the frame falls back. The
# wider floor gives a real read and still tests the symmetric walls.
func _surface_collinear() -> void:
	step("Given a one-cell-wide strip", func():
		var strip := VoxelFrame.new()
		for z in range(-4, 5):
			strip.set_cell(Vector3i(0, 0, z), VoxelFrame.material(Color.WHITE))
		var points := TerrainGeometry.surface_points(strip, Vector3i.ZERO, Vector3i(0, 1, 0), 3)
		expect(points.size() >= 3, "the strip supplies several height samples")
		expect(not TerrainGeometry.surface_gradient(points, Vector3.UP)["ok"], "collinear heights cannot define a gradient")
	)


func _gradient_synthetic() -> void:
	step("Given a height field with two known slopes", func():
		var points := []
		for x in range(-3, 4):
			for z in range(-3, 4):
				points.append({
					"point": Vector3(float(x), 0.5 * float(x) + 0.25 * float(z), float(z)),
					"weight": 1.0,
				})
		var read := TerrainGeometry.surface_gradient(points, Vector3.UP)
		expect(read["ok"], "the known plane reads")
		var normal: Vector3 = read["normal"]
		expect(normal.is_equal_approx(Vector3(-0.5, 1.0, -0.25).normalized()), "the normal matches the analytic gradient")
	)
	step("Given the opposite slopes", func():
		var points := []
		for x in range(-3, 4):
			for z in range(-3, 4):
				points.append({
					"point": Vector3(float(x), -0.5 * float(x) + 0.25 * float(z), float(z)),
					"weight": 1.0,
				})
		var normal: Vector3 = TerrainGeometry.surface_gradient(points, Vector3.UP)["normal"]
		expect(normal.x > 0.0 and normal.z < 0.0, "each slope sign flips its normal component")
	)


func _gradient_full_disc() -> void:
	step("Given a wide flat plate", func():
		var plate := VoxelFrame.new()
		for x in range(-6, 7):
			for z in range(-6, 7):
				plate.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		var near_size := 3
		var far_size := 13
		expect(TerrainGeometry.surface_points(plate, Vector3i.ZERO, Vector3i(0, 1, 0), near_size).size() == TerrainGeometry.disk_offsets(near_size).size(), "the read samples the size-3 footprint")
		expect(TerrainGeometry.surface_points(plate, Vector3i.ZERO, Vector3i(0, 1, 0), far_size).size() == TerrainGeometry.disk_offsets(far_size).size(), "the read samples the size-13 footprint")
	)
	step("Given a plate that stays flat inside size 7 and rises beyond it", func():
		var ground := VoxelFrame.new()
		for x in range(-3, 4):
			for z in range(-6, 7):
				ground.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		for x in range(4, 7):
			for y in range(0, 4 * (x - 3)):
				for z in range(-6, 7):
					ground.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.WHITE))
		var near := TerrainGeometry.surface_gradient(TerrainGeometry.surface_points(ground, Vector3i.ZERO, Vector3i(0, 1, 0), 7), Vector3.UP)
		var far := TerrainGeometry.surface_gradient(TerrainGeometry.surface_points(ground, Vector3i.ZERO, Vector3i(0, 1, 0), 13), Vector3.UP)
		expect(near["ok"] and far["ok"], "both reads succeed")
		expect(absf((near["normal"] as Vector3).x) < 0.02, "the size-7 read stays flat")
		expect((far["normal"] as Vector3).x < -0.2, "the size-13 read follows the rise beyond size 7")
	)


func _build_slope() -> void:
	step("Given a ramp and the Build tool", func():
		_view("top")
		_fill_ramp(5, 2, -2, 2)
		sync_viewport()
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 9
		_settings.falloff = 0.0
		_settings.strength = 20.0
		press = _pos(Vector3(2.0, 4.0, 0.0))
	)
	step("When the user grows the slope", func():
		_press(press)
		tool.advance_stroke(0.2)
		_release(press)
	)
	step("Then the growth follows the surface normal down the slope", func():
		expect(frame.has(Vector3i(1, 4, 0)), "the added voxel steps along the surface normal")
	)


func _oblique_steps() -> void:
	step("Given an oblique ray through one voxel", func():
		var origin := Vector3.ZERO
		var normal := Vector3(-2.0, 1.0, 0.0).normalized()
		var path := TerrainGeometry.march_cells(origin, normal, 12)
		var cell := path[0]
		var matches := true
		for index in range(1, path.size()):
			cell = TerrainGeometry.next_cell(cell, normal, origin)
			matches = matches and cell == path[index]
		expect(matches, "successive steps match one continuous oblique ray")
		expect(cell.x < -4 and cell.y > 2, "growth advances on both slope axes")
	)
	step("When a terrain job grows several layers", func():
		var job = tool.get_script().TerrainTickJob.new()
		job.edited_frame = VoxelFrame.new()
		job.edited_frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.WHITE))
		job.material = VoxelFrame.material(Color.WHITE)
		job.samples = [{
			"anchor": Vector3i.ZERO, "surface": Vector3i.ZERO, "steps": 12,
			"point": Vector3.ZERO, "normal": Vector3(-2.0, 1.0, 0.0).normalized(),
			"plane_origin": Vector3.ZERO,
		}]
		job.run()
		expect(job.edited_frame.has(Vector3i(-12, 0, 0)), "the layer advances one cell per step along the dominant axis")
		expect(job.edited_frame.count() == 13, "the layer is one clean line with no stray cell")
	)


func _oblique_ties() -> void:
	step("Given rays with two tied components", func():
		var origin := Vector3(0.25, 0.25, 0.25)
		var directions := [
			Vector3(1, 1, 0).normalized(),
			Vector3(-1, -1, 0).normalized(),
			Vector3(1, 0, 1).normalized(),
			Vector3(0, -1, 1).normalized(),
		]
		for direction in directions:
			var path := TerrainGeometry.march_cells(origin, direction, 16)
			var cell := path[0]
			var matches := true
			for index in range(1, path.size()):
				cell = TerrainGeometry.next_cell(cell, direction, origin)
				matches = matches and cell == path[index]
			expect(matches, "the stepped cells match one ray for %v" % direction)
	)
	step("Given a fixed ray origin away from a cell center", func():
		var origin := Vector3(0.25, 0.25, 0.25)
		var direction := Vector3(-2.0, 1.0, 0.0).normalized()
		var path := TerrainGeometry.march_cells(origin, direction, 12)
		var cell := path[0]
		for index in range(1, path.size()):
			cell = TerrainGeometry.next_cell(cell, direction, origin)
		expect(cell == path[path.size() - 1], "the fixed origin keeps the ray coherent")
	)


func _flatten_slope() -> void:
	step("Given a ramp with a bump on its surface", func():
		_view("top")
		_fill_ramp(5, 2, -2, 2)
		frame.set_cell(Vector3i(2, 5, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.FLATTEN
		_settings.radius = 5
		_settings.falloff = 0.0
		_settings.strength = 30.0
		press = _pos(Vector3(3.0, 6.0, 0.0))
	)
	step("When the user flattens the slope", func():
		_press(press)
		expect(tool._stroke_frame.follows_surface, "the flatten uses the surface plane")
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then the bump is cut toward the surface plane", func():
		expect(not frame.has(Vector3i(2, 5, 0)), "the bump above the surface plane is removed")
	)


func _flatten_converges() -> void:
	step("Given a ramp with a tall bump and the Flatten tool", func():
		_view("top")
		_fill_ramp(6, 2, -2, 2)
		for y in range(5, 9):
			frame.set_cell(Vector3i(2, y, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.FLATTEN
		_settings.radius = 5
		_settings.falloff = 0.0
		_settings.strength = 30.0
		press = _pos(Vector3(3.0, 6.0, 0.0))
	)
	step("When the user holds for two ticks", func():
		_press(press)
		tool.advance_stroke(1.0)
		tool.advance_stroke(1.0)
		split_cells = _cell_colors(frame)
	)
	step("Then two more ticks leave the surface unchanged", func():
		tool.advance_stroke(1.0)
		tool.advance_stroke(1.0)
		_release(press)
		expect(_cell_colors(frame) == split_cells, "the settled surface does not oscillate")
		expect(not frame.has(Vector3i(2, 8, 0)), "the cut clears the tall bump")
	)


func _surface_symmetry() -> void:
	step("Given a symmetric ramp with the X symmetry plane", func():
		_view("top")
		for x in range(-6, 6):
			var top := 2 * absi(x + 0) + 1
			top = 2 * absi(2 * x + 1) / 2 + 1
			for y in range(0, top + 1):
				for z in range(-2, 3):
					frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3(-0.5, -0.5, -0.5)
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 9
		_settings.falloff = 0.0
		# One layer per press. A higher strength would let the sideways walk of a
		# steep slope run across the symmetry plane, and the two masks would then
		# write into each other's cells.
		_settings.strength = 1.0
		press = _pos(Vector3(2.0, 6.0, 0.0))
		split_cells = _cell_colors(frame)
	)
	step("When the user grows the slope", func():
		_press(press)
		_release(press)
	)
	step("Then the mirrored slope grows along its own surface normal", func():
		var added := 0
		var mirrored := true
		for cell in frame.positions():
			if split_cells.has(cell):
				continue
			added += 1
			mirrored = mirrored and frame.has(Vector3i(-1 - cell.x, cell.y, cell.z))
		expect(added > 0, "the slope gains voxels")
		expect(mirrored, "every added voxel has its reflected counterpart")
	)


# --- Grab -------------------------------------------------------------------

func _grab_oblique() -> void:
	step("Given a voxel seen from an isometric view", func():
		_settings.tool = _settings.Tools.GRAB
		_settings.radius = 5
		_settings.falloff = 0.5
		_view("isometric")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		for x in range(-1, 2):
			for z in range(-1, 2):
				frame.set_cell(anchor + Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		press = _pos(Vector3(anchor))
	)
	step("When the user presses and drags", func():
		_press(press)
		expect(tool._plane != null, "the grab press locks a plane")
		var forward := -camera_rig().basis.z
		expect(tool._plane.normal.is_equal_approx(forward.normalized()), "the plane normal is the true camera forward")
		var drag_pos := _pos(Vector3(anchor + Vector3i(3, 2, 1)))
		_motion(drag_pos, drag_pos - press)
		var delta: Vector3i = tool._grab_drag - anchor
		expect(delta.x != 0 and delta.y != 0 and delta.z != 0, "the drag keeps all three world-axis components")
		_release(drag_pos)
	)
	step("Then the drag lands on the camera-facing plane", func():
		expect(State.edit_busy() == false, "the release ends the drag")
	)


func _grab_stretch() -> void:
	step("Given a line of voxels with two colors", func():
		_settings.tool = _settings.Tools.GRAB
		_settings.radius = 9
		_settings.falloff = 0.5
		_view("top")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		for x in range(0, 5):
			var color := Color.RED if x == 0 else Color.BLUE
			frame.set_cell(anchor + Vector3i(x, 0, 0), VoxelFrame.material(color))
		frame.set_cell(anchor + Vector3i(10, 0, 0), VoxelFrame.material(Color.GREEN))
		sync_viewport()
		press = _pos(Vector3(anchor))
	)
	step("When the user presses and drags three cells", func():
		_press(press)
		expect(not tool._grab_empty, "the press captures the source voxels")
		expect(tool._grab_sources.size() == 5, "the source region holds the five voxels")
		var drag_pos := _pos(Vector3(anchor + Vector3i(3, 0, 0)))
		_motion(drag_pos, drag_pos - press)
		_release(drag_pos)
	)
	step("Then the center stretches full and the edge moves less", func():
		expect(frame.get_color(anchor + Vector3i(3, 0, 0)) == Color.RED, "the center moves full and keeps its material")
		expect(not frame.has(anchor), "the center leaves its old cell")
		expect(frame.has(anchor + Vector3i(6, 0, 0)), "the far source moves a shorter distance")
		expect(not frame.has(anchor + Vector3i(7, 0, 0)), "the far source does not move the full distance")
	)
	step("Then the unrelated geometry stays", func():
		expect(frame.get_color(anchor + Vector3i(10, 0, 0)) == Color.GREEN, "the distant voxel keeps its material")
	)


func _grab_selection_destination() -> void:
	step("Given a line of voxels with a selection over the first two", func():
		_settings.tool = _settings.Tools.GRAB
		_settings.radius = 9
		_settings.falloff = 0.0
		_view("top")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		for x in range(0, 5):
			frame.set_cell(anchor + Vector3i(x, 0, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		State.selection.clear()
		State.selection.add(anchor)
		State.selection.add(anchor + Vector3i(1, 0, 0))
		State.selection_changed.emit()
		press = _pos(Vector3(anchor))
	)
	step("When the user drags the selected voxels outside the selection", func():
		_press(press)
		var drag_pos := _pos(Vector3(anchor + Vector3i(3, 0, 0)))
		_motion(drag_pos, drag_pos - press)
		_release(drag_pos)
	)
	step("Then the sources stay and no unselected voxel is written", func():
		expect(frame.has(anchor), "the blocked source stays in place")
		expect(frame.has(anchor + Vector3i(1, 0, 0)), "the second source stays in place")
		expect(frame.count() == 5, "no destination leaves the selection")
	)


func _grab_stops_at_document_edge() -> void:
	step("Given a line of voxels with a four-cell X size", func():
		_settings.tool = _settings.Tools.GRAB
		_settings.radius = 9
		_settings.falloff = 0.0
		_view("top")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		for x in range(0, 5):
			frame.set_cell(anchor + Vector3i(x, 0, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		State.set_size(Vector3i(4, 0, 0))
		press = _pos(Vector3(anchor))
		expect(State.document.axis_cell_range(0) == Vector2i(-2, 2), "the X size covers cells minus two through one")
	)
	step("When the user presses and drags outside the size", func():
		_press(press)
		expect(not tool._grab_empty, "the press captures the inside source voxels")
		expect(tool._grab_sources.size() == 2, "only the two inside voxels join the drag")
		var drag_pos := _pos(Vector3(anchor + Vector3i(3, 0, 0)))
		_motion(drag_pos, drag_pos - press)
		_release(drag_pos)
	)
	step("Then no voxel moves outside the size", func():
		expect(frame.count() == 5, "the outside destinations are refused")
		expect(frame.has(anchor), "the first source stays in place")
		expect(frame.has(anchor + Vector3i(1, 0, 0)), "the second source stays in place")
	)


func _smooth_stops_at_document_edge() -> void:
	step("Given a smooth field with a four-cell X size", func():
		State.set_size(Vector3i(4, 0, 0))
		var context := State.drawing_context()
		var fields := TerrainPreview.compute_smooth_fields(Vector3(0, 0, 0), 7, 0.0, context)
		var inside := 0
		var outside := 0
		for field in fields:
			for cell: Vector3i in field["cells"]:
				if context.allows(cell):
					inside += 1
				else:
					outside += 1
		expect(inside > 0, "the smooth field keeps the inside cells")
		expect(outside == 0, "the smooth field drops every outside cell")
	)


func _grab_empty() -> void:
	step("Given the Grab tool on an empty floor", func():
		_settings.tool = _settings.Tools.GRAB
		_view("top")
		press = _pos(Vector3.ZERO)
	)
	step("When the user presses and drags", func():
		_press(press)
		expect(tool._grab_empty, "the grab finds no source voxel")
		_motion(press + Vector2(20.0, 0.0), Vector2(20.0, 0.0))
		_release(press)
	)
	step("Then nothing changes and no history is recorded", func():
		expect(frame.count() == 0, "the empty grab changes nothing")
		expect(not State.undo_redo.has_undo(), "the empty grab adds no history")
	)


func _grab_worker() -> void:
	step("Given a wide plate with the Grab tool", func():
		_settings.tool = _settings.Tools.GRAB
		_settings.radius = 25
		_settings.falloff = 0.5
		_view("top")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		for x in range(-12, 13):
			for z in range(-12, 13):
				var color := Color.RED if (x == 0 and z == 0) else Color.BLUE
				frame.set_cell(anchor + Vector3i(x, 0, z), VoxelFrame.material(color))
		sync_viewport()
		press = _pos(Vector3(anchor))
	)
	step("When the user drags far", func():
		_press(press)
		expect(not tool._grab_empty, "the press captures the wide source region")
		var drag_pos := _pos(Vector3(anchor + Vector3i(30, 0, 0)))
		_motion(drag_pos, drag_pos - press)
		expect(tool._grab_job != null, "the large drag runs on the worker pool")
		expect(State.edit_busy(), "the worker drag owns a foreground operation")
	)
	await _await_tool_idle()
	step("Then the worker publishes the drag once", func():
		expect(frame.get_color(anchor + Vector3i(30, 0, 0)) == Color.RED, "the worker moves the center and keeps its material")
		expect(not State.edit_busy(), "the worker releases its operation")
		_release(press)
	)
	step("Then the whole drag is one history action", func():
		expect(State.undo_redo.has_undo(), "the worker drag records one action")
		State.undo_redo.undo()
		expect(not frame.has(anchor + Vector3i(30, 0, 0)), "one undo clears the worker drag")
	)


func _grab_shared_radius() -> void:
	step("Given a wide plate with the Grab tool and a large shared radius", func():
		_settings.tool = _settings.Tools.GRAB
		_settings.radius = 50
		_settings.falloff = 0.5
		_view("top")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		for x in range(-20, 21):
			for z in range(-20, 21):
				var color := Color.RED if (x == 0 and z == 0) else Color.BLUE
				frame.set_cell(anchor + Vector3i(x, 0, z), VoxelFrame.material(color))
		sync_viewport()
		press = _pos(Vector3(anchor))
	)
	step("When the user presses, the capture uses the shared radius", func():
		_press(press)
		expect(not tool._grab_empty, "the press captures the wide source region")
		expect(tool._grab_sources.size() > 785, "the capture uses the shared radius, not the old small cap")
	)
	step("When the user drags far", func():
		var drag_pos := _pos(Vector3(anchor + Vector3i(10, 0, 0)))
		_motion(drag_pos, drag_pos - press)
		expect(tool._grab_job != null, "the large drag runs on the worker pool")
	)
	await _await_tool_idle()
	step("Then the center moves by the full delta", func():
		expect(frame.get_color(anchor + Vector3i(10, 0, 0)) == Color.RED, "the center moves the full drag and keeps its material")
	)
	step("Then a weighted source reaches its partial destination", func():
		expect(frame.get_color(anchor + Vector3i(21, 0, 0)) == Color.BLUE, "the weighted source reaches its partial destination and keeps its material")
	)
	step("Then the user releases", func():
		_release(press)
	)
	step("Then the whole drag is one history action", func():
		expect(State.undo_redo.has_undo(), "the shared-radius drag records one action")
		State.undo_redo.undo()
		expect(frame.get_color(anchor) == Color.RED, "one undo restores the center to its origin")
		expect(frame.get_color(anchor + Vector3i(10, 0, 0)) == Color.BLUE, "one undo restores the moved position to the plate")
	)


func _grab_pending_return() -> void:
	step("Given a wide plate and a far worker drag", func():
		_settings.tool = _settings.Tools.GRAB
		_settings.radius = 25
		_settings.falloff = 0.5
		_view("top")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		for x in range(-12, 13):
			for z in range(-12, 13):
				frame.set_cell(anchor + Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		press = _pos(Vector3(anchor))
		_press(press)
		var drag_pos := _pos(Vector3(anchor + Vector3i(30, 0, 0)))
		_motion(drag_pos, drag_pos - press)
		expect(tool._grab_job != null, "the large drag runs on the worker pool")
	)
	step("When the user returns to the origin and releases", func():
		var origin_pos := _pos(Vector3(anchor))
		_motion(origin_pos, origin_pos - press)
		_release(origin_pos)
		expect(tool._grab_pending_delta != null, "the return is queued while the worker runs")
	)
	await _await_edit_closed()
	step("Then the model returns to the baseline and the edit closes", func():
		expect(tool._edit == null, "the queued return closes the edit")
		expect(not State.edit_busy(), "no operation remains")
		expect(frame.count() == 625, "the plate is back to its original cell count")
		expect(not State.undo_redo.has_undo(), "the net-zero drag adds no history")
	)


func _cancel_repress() -> void:
	step("Given a wide plate and a worker grab", func():
		_settings.tool = _settings.Tools.GRAB
		_settings.radius = 25
		_settings.falloff = 0.5
		_view("top")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		for x in range(-12, 13):
			for z in range(-12, 13):
				var color := Color.RED if (x == 0 and z == 0) else Color.BLUE
				frame.set_cell(anchor + Vector3i(x, 0, z), VoxelFrame.material(color))
		sync_viewport()
		press = _pos(Vector3(anchor))
		_press(press)
		var drag_pos := _pos(Vector3(anchor + Vector3i(30, 0, 0)))
		_motion(drag_pos, drag_pos - press)
		expect(tool._grab_job != null, "the large drag runs on the worker pool")
	)
	step("When the user cancels and presses again", func():
		_key(KEY_ESCAPE)
		expect(tool._edit == null, "Escape cancels the stroke")
		_press(press)
		expect(tool._edit != null, "the new press opens a new edit")
		var small := _pos(Vector3(anchor + Vector3i(2, 0, 0)))
		_motion(small, small - press)
		_release(small)
	)
	await _await_edit_closed()
	step("Then the cancelled job cannot touch the new stroke", func():
		expect(tool._edit == null, "the new stroke closes after its release")
		expect(not State.edit_busy(), "no operation remains")
		expect(frame.get_color(anchor + Vector3i(2, 0, 0)) == Color.RED, "the new drag applied")
	)


# --- Stroke lifecycle -------------------------------------------------------

func _stroke_history() -> void:
	step("Given a grow stroke on an empty floor", func():
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 1
		_settings.falloff = 0.0
		_settings.strength = 10.0
		_view("top")
		press = _pos(Vector3.ZERO)
		target = aim(press).target
	)
	step("When the user grows and releases", func():
		_press(press)
		tool.advance_stroke(0.3)
		_release(press)
		grown = frame.count()
	)
	step("Then one undo removes the stroke and one redo restores it", func():
		expect(grown > 0, "the stroke grows voxels")
		expect(State.undo_redo.has_undo(), "the stroke records one history action")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo clears the stroke")
		State.undo_redo.redo()
		expect(frame.count() == grown, "one redo restores the stroke")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one more undo returns to the empty floor")
		State.undo_redo.clear_history()
	)
	step("When the user grows and presses Escape", func():
		_press(press)
		tool.advance_stroke(0.3)
		expect(frame.count() > 0, "the held stroke grows")
		_key(KEY_ESCAPE)
	)
	step("Then the stroke rolls back", func():
		expect(frame.count() == 0, "Escape rolls the stroke back")
		expect(not State.undo_redo.has_undo(), "the cancelled stroke adds no history")
	)
	step("When the user grows and switches tools", func():
		_press(press)
		tool.advance_stroke(0.3)
		expect(frame.count() > 0, "the held stroke grows")
		activate_tool("Toolbar")
	)
	step("Then the switch commits the stroke as one action", func():
		expect(frame.count() > 0, "the switched stroke keeps its voxels")
		expect(State.undo_redo.has_undo(), "the switched stroke records one action")
		State.undo_redo.undo()
		expect(frame.count() == 0, "one undo clears the switched stroke")
	)
	step("When the user grows and the document changes", func():
		activate_tool("terrain")
		_press(press)
		tool.advance_stroke(0.3)
		expect(frame.count() > 0, "the held stroke grows")
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
	)
	step("Then the stroke is discarded", func():
		expect(frame.count() == 0, "the document change discards the stroke")
		expect(not State.undo_redo.has_undo(), "the discarded stroke adds no history")
		expect(not State.edit_busy(), "the document change ends the edit")
	)


func _lost_release() -> void:
	step("Given a grow stroke on an empty floor", func():
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 1
		_settings.falloff = 0.0
		_settings.strength = 10.0
		_view("top")
		press = _pos(Vector3.ZERO)
	)
	step("When the user moves with the left button already released", func():
		_press(press)
		tool.advance_stroke(0.3)
		expect(tool._edit != null, "the stroke is open")
		var event := InputEventMouseMotion.new()
		event.position = press + Vector2(20.0, 0.0)
		viewport.push_input(event)
	)
	step("Then the stroke finishes like a release", func():
		expect(tool._edit == null, "the lost release closes the edit")
		expect(State.undo_redo.has_undo(), "the finished stroke records one action")
	)


func _motion_interpolation() -> void:
	step("Given a grow stroke on an empty floor", func():
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 1
		_settings.falloff = 0.0
		_settings.strength = 1.0
		_view("top")
		press = _pos(Vector3.ZERO)
		target = aim(press).target
	)
	step("When the user drags four cells in one motion and no frame elapses", func():
		_press(press)
		var drag_pos := _pos(Vector3(4.0, 0.0, 0.0))
		_motion(drag_pos, drag_pos - press)
		_release(drag_pos)
	)
	step("Then every crossed brush center applied its dab", func():
		expect(frame.has(target), "the start center grew")
		expect(frame.has(target + Vector3i(2, 0, 0)), "a midpoint center grew")
		expect(frame.has(target + Vector3i(4, 0, 0)), "the endpoint center grew")
		expect(State.undo_redo.has_undo(), "the whole drag records one history action")
	)


func _selection_symmetry() -> void:
	step("Given a selection over part of the floor", func():
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 5
		_settings.falloff = 0.0
		_settings.strength = 10.0
		_view("top")
		press = _pos(Vector3.ZERO)
		target = aim(press).target
		State.selection.clear()
		State.selection.add(target)
		State.selection.add(target + Vector3i(1, 0, 0))
		State.selection_changed.emit()
	)
	step("When the user grows", func():
		_press(press)
		tool.advance_stroke(0.3)
		_release(press)
	)
	step("Then only the selected samples grow", func():
		expect(frame.has(target), "the selected center column grows")
		expect(frame.has(target + Vector3i(1, 0, 0)), "the second selected column grows")
		expect(not frame.has(target + Vector3i(-1, 0, 0)), "an unselected column stays empty")
	)
	step("Given a symmetric grow stroke across the X plane", func():
		State.clear_selection()
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3(-0.5, -0.5, -0.5)
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_view("top")
		press = _pos(Vector3(2.0, 0.0, 0.0))
		target = aim(press).target
		mirror = Vector3i(-1 - target.x, target.y, target.z)
	)
	step("When the user grows", func():
		_press(press)
		tool.advance_stroke(0.3)
		_release(press)
	)
	step("Then the mirrored column grows too", func():
		expect(frame.has(target), "the pressed column grows")
		expect(frame.has(mirror), "the mirrored column grows")
	)


# --- Smooth -----------------------------------------------------------------

func _flat_plate(half: int) -> void:
	for x in range(-half, half + 1):
		for z in range(-half, half + 1):
			frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))


func _smooth_flat() -> void:
	step("Given a flat plate and the Smooth tool", func():
		_view("top")
		_flat_plate(4)
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 7
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3.ZERO)
		split_cells = _cell_colors(frame)
	)
	step("When the user holds on the flat plate", func():
		_press(press)
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then the flat plate is unchanged", func():
		expect(_cell_colors(frame) == split_cells, "a flat plate stays flat")
		expect(not State.undo_redo.has_undo(), "a no-op Smooth stroke adds no history")
	)


func _smooth_spike() -> void:
	step("Given a flat plate with a tall spike and the Smooth tool", func():
		_view("top")
		_flat_plate(4)
		for y in range(1, 5):
			frame.set_cell(Vector3i(0, y, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 7
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3(0.0, 4.0, 0.0))
	)
	step("When the user holds on the spike", func():
		_press(press)
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then the spike lowers toward the plate without cutting through", func():
		var height := _column_height(Vector3i(0, 0, 0), 1, 1, 0)
		expect(height < 5, "the spike lowers")
		expect(height >= 1, "the spike never cuts through the plate")
		expect(frame.has(Vector3i(2, 0, 0)), "the plate away from the spike stays")
	)


func _smooth_pit() -> void:
	step("Given a block with a one-cell pit and the Smooth tool", func():
		_view("top")
		for x in range(-4, 5):
			for z in range(-4, 5):
				for y in range(0, 4):
					frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.WHITE))
		for y in range(1, 4):
			frame.set_cell(Vector3i(0, y, 0), VoxelFrame.material(Color.TRANSPARENT))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 7
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3i(0, 0, 0))
	)
	step("When the user holds in the pit", func():
		_press(press)
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then the pit rises toward the surrounding surface", func():
		var height := _column_height(Vector3i(0, 0, 0), 1, 1, 0)
		expect(height > 1, "the pit rises")
		expect(height <= 4, "the pit never overshoots the block")
		expect(frame.has(Vector3i(2, 0, 0)), "the block away from the pit stays")
	)


func _smooth_empty() -> void:
	step("Given the Smooth tool on an empty floor", func():
		_view("top")
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 7
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3.ZERO)
	)
	step("When the user presses and holds", func():
		_press(press)
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then nothing changes and no history is recorded", func():
		expect(frame.count() == 0, "Smooth never seeds an empty sample")
		expect(not State.undo_redo.has_undo(), "the empty stroke adds no history")
		expect(not State.edit_busy(), "the release ends the edit")
	)


func _smooth_controls() -> void:
	step("Given the Smooth tool", func():
		var options: Control = plugin("TerrainPlugin")._options
		var toolbar: MenuButton = plugin("TerrainPlugin")._toolbar
		_settings.tool = _settings.Tools.SMOOTH
		expect(options.get_node("Radius").max_value == 32.0, "the radius control shows the full bound")
		expect(options.get_node("Strength").visible, "the strength control is visible for Smooth")
		expect(not options.get_node("Build").visible, "Smooth has no build direction")
		var popup := toolbar.get_popup()
		expect(popup.item_count == 4, "the terrain menu holds four tools")
		expect(
			popup.get_item_text(0) == "Build" and popup.get_item_text(1) == "Flatten"
			and popup.get_item_text(2) == "Smooth" and popup.get_item_text(3) == "Grab",
			"the menu order is Build, Flatten, Smooth, Grab"
		)
		expect(popup.get_item_id(2) == 3, "the Smooth item keeps its append-only id")
		expect(popup.get_item_id(3) == 2, "the Grab item keeps its append-only id")
	)
	step("When the user selects the menu entries by index", func():
		var toolbar: MenuButton = plugin("TerrainPlugin")._toolbar
		toolbar.get_popup().index_pressed.emit(2)
		expect(_settings.tool == _settings.Tools.SMOOTH, "the third entry selects Smooth")
		toolbar.get_popup().index_pressed.emit(3)
		expect(_settings.tool == _settings.Tools.GRAB, "the fourth entry selects Grab")
		toolbar.get_popup().index_pressed.emit(0)
		expect(_settings.tool == _settings.Tools.BUILD, "the first entry selects Build")
	)


func _smooth_history() -> void:
	step("Given a spike and the Smooth tool", func():
		_view("top")
		_flat_plate(4)
		for y in range(1, 5):
			frame.set_cell(Vector3i(0, y, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 7
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3(0.0, 4.0, 0.0))
	)
	step("When the user smooths and releases", func():
		_press(press)
		tool.advance_stroke(1.0)
		_release(press)
		grown = frame.count()
	)
	step("Then one undo restores the spike and one redo lowers it again", func():
		expect(grown < 85, "the spike loses voxels")
		expect(State.undo_redo.has_undo(), "the stroke records one history action")
		State.undo_redo.undo()
		expect(frame.count() == 85, "one undo restores the spike")
		State.undo_redo.redo()
		expect(frame.count() == grown, "one redo lowers the spike again")
		State.undo_redo.undo()
		State.undo_redo.clear_history()
	)
	step("When the user smooths and presses Escape", func():
		_press(press)
		tool.advance_stroke(1.0)
		_key(KEY_ESCAPE)
	)
	step("Then the stroke rolls back", func():
		expect(frame.count() == 85, "Escape rolls the stroke back")
		expect(not State.undo_redo.has_undo(), "the cancelled stroke adds no history")
	)
	step("When the user smooths and switches tools", func():
		_press(press)
		tool.advance_stroke(1.0)
		activate_tool("Toolbar")
	)
	step("Then the switch commits the stroke as one action", func():
		expect(frame.count() < 85, "the switched stroke keeps its result")
		expect(State.undo_redo.has_undo(), "the switched stroke records one action")
	)
	step("When the user smooths and the document changes", func():
		activate_tool("terrain")
		_press(press)
		tool.advance_stroke(1.0)
		expect(frame.count() < 85, "the held stroke changes voxels")
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
	)
	step("Then the stroke is discarded", func():
		expect(frame.count() == 0, "the document change discards the stroke")
		expect(not State.edit_busy(), "the document change ends the edit")
	)


func _smooth_symmetry() -> void:
	step("Given a mirrored pair of spikes and the Smooth tool", func():
		_view("top")
		_flat_plate(4)
		for y in range(1, 5):
			frame.set_cell(Vector3i(1, y, 0), VoxelFrame.material(Color.WHITE))
			frame.set_cell(Vector3i(-2, y, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3(-0.5, -0.5, -0.5)
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 7
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3(1.0, 4.0, 0.0))
	)
	step("When the user smooths the right spike", func():
		_press(press)
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then both mirrored spikes lower equally", func():
		var right := _column_height(Vector3i(1, 0, 0), 1, 1, 0)
		var left := _column_height(Vector3i(-2, 0, 0), 1, 1, 0)
		expect(right < 5, "the pressed spike lowers")
		expect(right == left, "the mirrored spike lowers equally")
	)


func _smooth_adaptive() -> void:
	step("Given a plate with an off-center spike and the Smooth tool", func():
		_view("top")
		_flat_plate(4)
		for y in range(1, 4):
			frame.set_cell(Vector3i(0, y, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		grown = frame.count()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 7
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3i(1, 0, 0))
	)
	step("When the user presses beside the spike", func():
		var pick := aim(press)
		var before: Vector3 = TerrainFrame.from_surface(frame, pick.hit, pick.entry, _settings.radius,
			TerrainFrame.from_face(pick.hit, pick.entry)).normal
		_press(press)
		var after: Vector3 = tool._stroke_frame.normal
		split_cells = {"before": before, "after": after}
		_release(press)
	)
	step("Then the surface plane follows the changed surface without a flip", func():
		var before: Vector3 = split_cells["before"]
		var after: Vector3 = split_cells["after"]
		expect(_column_height(Vector3i(0, 0, 0), 1, 1, 0) < 4, "the spike lowers")
		expect(not after.is_equal_approx(before), "the plane follows the changed local gradient")
		expect(after.y > 0.0 and before.y > 0.0, "the outward orientation never flips")
	)
	step("Then the adaptation adds no extra history", func():
		expect(State.undo_redo.has_undo(), "the stroke records one action")
		State.undo_redo.undo()
		expect(frame.count() == grown, "one undo restores the whole stroke")
	)


func _smooth_carry() -> void:
	step("Given a spike and the Smooth tool at strength eight", func():
		_view("top")
		_flat_plate(4)
		for y in range(1, 5):
			frame.set_cell(Vector3i(0, y, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 7
		_settings.falloff = 0.0
		_settings.strength = 8
		press = _pos(Vector3(0.0, 4.0, 0.0))
	)
	step("When the user dabs once", func():
		_press(press)
		_release(press)
	)
	await _await_drained()
	step("Then one dab applies its whole passes and keeps no carry", func():
		expect(not frame.has(Vector3i(0, 4, 0)), "one dab rounds the spike top")
		for field in tool._smooth_fields:
			expect(not field.has("carry"), "a field keeps no fractional carry")
	)


func _smooth_materials() -> void:
	step("Given a mixed-material pit and the Smooth tool with a different active color", func():
		_view("top")
		for x in range(-4, 5):
			for z in range(-4, 5):
				for y in range(0, 4):
					frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.RED, Color(0.4, 0.0, 0.0), 0.5, 0.25))
		for y in range(1, 4):
			frame.set_cell(Vector3i(0, y, 0), VoxelFrame.material(Color.TRANSPARENT))
		frame.set_cell(Vector3i(0, 0, 0), VoxelFrame.material(Color.GREEN, Color(0.1, 0.2, 0.3), 0.9, 0.1))
		sync_viewport()
		State.current_color = Color.BLUE
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 7
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3i(0, 0, 0))
	)
	step("When the user holds in the pit", func():
		_press(press)
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then the fill inherits the local material and no surviving cell is repainted", func():
		expect(frame.has(Vector3i(0, 1, 0)), "the pit fills above its floor")
		expect(frame.get_material(Vector3i(0, 1, 0)) == frame.get_material(Vector3i(0, 0, 0)), "the fill inherits the local floor full material")
		expect(frame.get_color(Vector3i(0, 1, 0)) == Color.GREEN, "the fill never uses the active color")
		expect(frame.get_color(Vector3i(2, 3, 0)) == Color.RED, "a surviving cell keeps its color")
		expect(frame.get_material(Vector3i(2, 3, 0)) == frame.get_material(Vector3i(3, 3, 0)), "a surviving cell keeps its full material")
	)
	step("When the user undoes and redoes", func():
		split_cells = _cell_materials(frame)
		State.undo_redo.undo()
		expect(frame.get_color(Vector3i(0, 0, 0)) == Color.GREEN, "undo restores the pit floor")
		State.undo_redo.redo()
	)
	step("Then the redo restores the exact full materials", func():
		expect(_cell_materials(frame) == split_cells, "redo restores every full material")
		expect(frame.get_material(Vector3i(0, 1, 0)) == frame.get_material(Vector3i(0, 0, 0)), "the redo keeps the inherited material")
	)


func _smooth_selection() -> void:
	step("Given a pit whose floor is selected but the fill is not", func():
		_view("top")
		for x in range(-4, 5):
			for z in range(-4, 5):
				for y in range(0, 4):
					frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.RED, Color(0.4, 0.0, 0.0), 0.5, 0.25))
		for y in range(1, 4):
			frame.set_cell(Vector3i(0, y, 0), VoxelFrame.material(Color.TRANSPARENT))
		frame.set_cell(Vector3i(0, 0, 0), VoxelFrame.material(Color.GREEN, Color(0.1, 0.2, 0.3), 0.9, 0.1))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 7
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3i(0, 0, 0))
		State.selection.clear()
		State.selection.add(Vector3i(0, 0, 0))
		State.selection_changed.emit()
	)
	step("When the user holds in the pit", func():
		_press(press)
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then an unselected fill destination is never written", func():
		expect(not frame.has(Vector3i(0, 1, 0)), "the fill stops at the unselected destination")
		expect(frame.get_color(Vector3i(0, 0, 0)) == Color.GREEN, "the selected support keeps its full material")
		expect(frame.get_material(Vector3i(0, 0, 0)) == VoxelFrame.material(Color.GREEN, Color(0.1, 0.2, 0.3), 0.9, 0.1), "the selected support keeps its finish")
	)
	step("Given a spike whose tip is selected but the deeper cell is not", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_view("top")
		_flat_plate(4)
		for y in range(1, 5):
			frame.set_cell(Vector3i(0, y, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 7
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3(0.0, 4.0, 0.0))
		State.selection.clear()
		State.selection.add(Vector3i(0, 4, 0))
		State.selection_changed.emit()
	)
	step("When the user holds on the spike", func():
		_press(press)
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then the removal stops at the first unselected cell", func():
		expect(not frame.has(Vector3i(0, 4, 0)), "the selected outer cell is removed")
		expect(frame.has(Vector3i(0, 3, 0)), "the unselected deeper cell is kept")
		expect(_column_height(Vector3i(0, 0, 0), 1, 1, 0) == 4, "the removal stops after one cell")
	)


func _smooth_orientation() -> void:
	for entry in [["bottom", 1, -1], ["left", 0, -1], ["back", 2, -1], ["top", 1, 1]]:
		var view: String = entry[0]
		var axis: int = entry[1]
		var outward: int = entry[2]
		step("Given a %s spike with interior materials and the Smooth tool" % view, func():
			_view(view)
			_fill_slab(axis, 0, -4, 4)
			for depth in range(1, 7):
				var cell := Vector3i.ZERO
				cell[axis] = outward * depth
				var color := Color.GREEN if depth >= 4 else Color.BLUE
				frame.set_cell(cell, VoxelFrame.material(color, Color(0.1, 0.2, 0.3), 0.9, 0.1))
			sync_viewport()
			split_cells = _cell_materials(frame)
			State.current_color = Color.MAGENTA
			_settings.tool = _settings.Tools.SMOOTH
			_settings.radius = 7
			_settings.falloff = 0.0
			_settings.strength = 2.0
			var tip := Vector3i.ZERO
			tip[axis] = outward * 6
			press = _pos(Vector3(tip))
		)
		step("When the user holds on the spike", func():
			_press(press)
			expect(tool._stroke_frame.normal[axis] * float(outward) > 0.5, "the %s normal points outward" % view)
			tool.advance_stroke(0.5)
			_release(press)
		)
		step("Then the spike shortens outward and interior materials survive", func():
			var tip := Vector3i.ZERO
			tip[axis] = outward * 6
			var interior := Vector3i.ZERO
			interior[axis] = outward * 2
			expect(not frame.has(tip), "the %s spike tip is removed outward" % view)
			expect(frame.has(interior), "the %s interior stays" % view)
			var survivors := true
			for cell in frame.positions():
				if split_cells.has(cell) and frame.get_material(cell) != split_cells[cell]:
					survivors = false
			expect(survivors, "no %s surviving cell is repainted" % view)
		)


func _fill_slab(axis: int, coord: int, lo: int, hi: int) -> void:
	var first := (axis + 1) % 3
	var second := (axis + 2) % 3
	for i in range(lo, hi + 1):
		for j in range(lo, hi + 1):
			var cell := Vector3i.ZERO
			cell[axis] = coord
			cell[first] = i
			cell[second] = j
			frame.set_cell(cell, VoxelFrame.material(Color.RED, Color(0.4, 0.0, 0.0), 0.5, 0.25))


func _smooth_symmetry_axis() -> void:
	step("Given mirrored spikes across the normal axis with different materials", func():
		_view("top")
		for x in range(-4, 5):
			for z in range(-4, 5):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.RED, Color(0.4, 0.0, 0.0), 0.5, 0.25))
				frame.set_cell(Vector3i(x, -1, z), VoxelFrame.material(Color.BLUE, Color(0.0, 0.0, 0.4), 0.25, 0.75))
		for y in range(1, 5):
			frame.set_cell(Vector3i(0, y, 0), VoxelFrame.material(Color.RED, Color(0.4, 0.0, 0.0), 0.5, 0.25))
		for y in range(-5, -1):
			frame.set_cell(Vector3i(0, y, 0), VoxelFrame.material(Color.BLUE, Color(0.0, 0.0, 0.4), 0.25, 0.75))
		sync_viewport()
		State.symmetry_axes = 2
		State.symmetry_origin = Vector3(0.0, -0.5, 0.0)
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 7
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3(0.0, 4.0, 0.0))
		split_cells = _cell_materials(frame)
	)
	step("When the user smooths the upward spike", func():
		_press(press)
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then both mirrored spikes smooth outward and keep their materials", func():
		expect(not frame.has(Vector3i(0, 4, 0)), "the upward spike shortens outward")
		expect(not frame.has(Vector3i(0, -5, 0)), "the downward spike shortens outward")
		expect(frame.get_color(Vector3i(0, 0, 0)) == Color.RED, "the upward side keeps its material")
		expect(frame.get_color(Vector3i(0, -1, 0)) == Color.BLUE, "the downward side keeps its material")
		var survivors := true
		for cell in frame.positions():
			if split_cells.has(cell) and frame.get_material(cell) != split_cells[cell]:
				survivors = false
		expect(survivors, "no mirrored surviving cell is repainted")
	)
	step("Then the mirrored stroke is one history action", func():
		expect(State.undo_redo.has_undo(), "the mirrored stroke records one action")
		State.undo_redo.undo()
		expect(frame.has(Vector3i(0, 4, 0)) and frame.has(Vector3i(0, -5, 0)), "one undo restores both spikes")
	)


func _smooth_reread_stable() -> void:
	step("Given an unchanged ramp and the Smooth tool", func():
		_view("top")
		for x in range(0, 13):
			for y in range(0, x + 1):
				for z in range(-4, 5):
					frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 5
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3i(6, 6, 0))
	)
	step("When the plane re-reads a hundred times on the unchanged ramp", func():
		_press(press)
		var first: Vector3 = tool._stroke_frame.normal
		var drift := 0.0
		for _index in 100:
			tool._smooth_surface_frame()
			drift = maxf(drift, first.angle_to(tool._stroke_frame.normal))
		split_cells = {"first": first, "drift": drift}
		_release(press)
	)
	step("Then the normal is constant within tolerance", func():
		expect(split_cells["drift"] < 0.01, "repeated re-reads of an unchanged ramp do not drift")
	)


func _smooth_reentrant() -> void:
	step("Given a spike and the Smooth tool", func():
		_view("top")
		_flat_plate(4)
		for y in range(1, 5):
			frame.set_cell(Vector3i(0, y, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 7
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3(0.0, 4.0, 0.0))
	)
	step("When a handler swaps the document during the changed signal", func():
		var swapped := [false]
		var handler := func(_frame_index, _affected) -> void:
			if swapped[0]:
				return
			swapped[0] = true
			State.document = VoxelDocument.new()
		State.chunks_changed.connect(handler)
		_press(press)
		State.chunks_changed.disconnect(handler)
		split_cells = {"swapped": swapped[0]}
		frame = State.get_current_voxel_frame()
	)
	step("Then the swap discards the stroke without a stale re-read", func():
		expect(split_cells["swapped"], "the swap handler ran during the changed signal")
		expect(frame.count() == 0, "the swapped document discards the stroke")
		expect(tool._edit == null, "the swap ends the edit")
		expect(not State.edit_busy(), "no operation remains")
	)


# --- Smooth rounding geometry -----------------------------------------------

# Fills the inclusive block from lo to hi.
func _solid(lo: Vector3i, hi: Vector3i, cell_material: PackedFloat32Array) -> void:
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			for z in range(lo.z, hi.z + 1):
				frame.set_cell(Vector3i(x, y, z), cell_material)


func _smooth_round_corner() -> void:
	step("Given a solid block and the Smooth tool on its top corner", func():
		_view("top")
		_solid(Vector3i(-4, 0, -4), Vector3i(4, 4, 4), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 7
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3(4.0, 4.0, 4.0))
	)
	step("When the user holds on the top corner", func():
		_press(press)
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then the corner and its edges round and the faces stay", func():
		expect(not frame.has(Vector3i(4, 4, 4)), "the convex corner cell is rounded away")
		expect(not frame.has(Vector3i(4, 4, 3)), "the top edge beside the corner is softened")
		expect(not frame.has(Vector3i(4, 3, 4)), "the vertical edge beside the corner is softened")
		expect(frame.has(Vector3i(2, 4, 2)), "the top face two cells in from both edges stays")
		expect(frame.has(Vector3i(0, 4, 0)), "the top face center stays")
		expect(frame.has(Vector3i(4, 0, 4)), "the far bottom corner stays")
	)


func _smooth_round_edge() -> void:
	step("Given a solid block and the Smooth tool on its top edge", func():
		_view("top")
		_solid(Vector3i(-4, 0, -4), Vector3i(4, 4, 4), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 7
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3(4.0, 4.0, 0.0))
	)
	step("When the user holds on the middle of the edge", func():
		_press(press)
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then the edge softens along its length and the face stays", func():
		expect(not frame.has(Vector3i(4, 4, 0)), "the pressed edge cell is rounded away")
		expect(not frame.has(Vector3i(4, 4, 2)), "the edge is softened two cells along")
		expect(frame.has(Vector3i(4, 4, 4)), "the edge beyond the brush stays")
		expect(frame.has(Vector3i(3, 4, 0)), "the top face one cell in stays")
		expect(frame.has(Vector3i(0, 4, 0)), "the far top face stays")
	)


func _smooth_round_concave() -> void:
	step("Given an L-shaped block with an inside corner", func():
		_view("top")
		for x in range(-4, 5):
			for y in range(-4, 5):
				for z in range(-4, 5):
					if x <= 0 or y <= 0:
						frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 7
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3(2.0, 0.0, 0.0))
	)
	step("When the user holds near the inside corner", func():
		_press(press)
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then the inside corner fills and the far empty quadrant stays empty", func():
		expect(frame.has(Vector3i(1, 1, 0)), "the concave corner cell is filled")
		expect(frame.has(Vector3i(1, 1, 1)), "the fill spreads along the inside corner")
		expect(not frame.has(Vector3i(3, 3, 0)), "the far empty quadrant stays empty")
		expect(frame.has(Vector3i(-2, -2, 0)), "the block away from the corner stays")
	)


func _smooth_round_vertical() -> void:
	step("Given a solid block and the Smooth tool on a vertical edge", func():
		_view("right")
		_solid(Vector3i(-4, -4, -4), Vector3i(4, 4, 4), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 7
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3(4.0, 0.0, 4.0))
	)
	step("When the user holds on the vertical edge", func():
		_press(press)
		expect(absf(tool._stroke_frame.normal.x) > 0.5, "the surface normal points outward on the side")
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then the vertical edge rounds and the side faces stay", func():
		expect(not frame.has(Vector3i(4, 0, 4)), "the vertical edge cell is rounded away")
		expect(not frame.has(Vector3i(4, 2, 4)), "the vertical edge is softened along its height")
		expect(frame.has(Vector3i(4, 0, 2)), "the side face one cell in stays")
		expect(frame.has(Vector3i(0, 0, 0)), "the block center stays")
	)


func _smooth_round_thick_plate() -> void:
	step("Given a two-cell plate and the Smooth tool", func():
		_view("top")
		_solid(Vector3i(-4, 0, -4), Vector3i(4, 1, 4), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		split_cells = _cell_materials(frame)
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 7
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3(0.0, 1.0, 0.0))
	)
	step("When the user holds on the plate", func():
		_press(press)
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then the two-cell plate is unchanged and adds no history", func():
		expect(_cell_materials(frame) == split_cells, "a two-cell plate stays whole")
		expect(not State.undo_redo.has_undo(), "a no-op Smooth stroke adds no history")
	)


func _smooth_round_staircase() -> void:
	step("Given a coarse staircase and the Smooth tool", func():
		_view("top")
		for x in range(-9, 10):
			var top := -3 * floori(float(x) / 3.0)
			for y in range(-9, top + 1):
				for z in range(-4, 5):
					frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 11
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3(0.0, 0.0, 0.0))
	)
	step("When the user holds on the middle steps", func():
		_press(press)
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then the step corners round and the far steps stay", func():
		expect(frame.has(Vector3i(0, 1, 0)), "the concave step corner fills into a ramp")
		expect(not frame.has(Vector3i(-1, 3, 0)), "the near convex step corner rounds away")
		expect(frame.has(Vector3i(-4, 6, 0)), "the step outside the sphere stays")
		expect(frame.has(Vector3i(-9, 9, 0)), "the far tall step stays")
		expect(frame.has(Vector3i(9, -9, 0)), "the far low step stays")
		expect(not frame.has(Vector3i(-9, 10, 0)), "no cell is added above the far step")
	)


func _smooth_round_split() -> void:
	step("Given a block corner held for one second", func():
		_view("top")
		_solid(Vector3i(-4, 0, -4), Vector3i(4, 4, 4), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 7
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3(4.0, 4.0, 4.0))
		_press(press)
		tool.advance_stroke(1.0)
		_release(press)
		split_cells = _cell_materials(frame)
	)
	step("Given the same corner held as two half-second ticks", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_view("top")
		_solid(Vector3i(-4, 0, -4), Vector3i(4, 4, 4), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 7
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3(4.0, 4.0, 4.0))
		_press(press)
		tool.advance_stroke(0.5)
		tool.advance_stroke(0.5)
		_release(press)
	)
	step("Then both holds round the same cells", func():
		expect(_cell_materials(frame) == split_cells, "a split hold rounds the same cells as one hold")
	)


func _smooth_weighted_falloff() -> void:
	step("Given a plate with a center spike and an edge spike and a strong falloff", func():
		_view("top")
		_flat_plate(6)
		for y in range(1, 5):
			frame.set_cell(Vector3i(0, y, 0), VoxelFrame.material(Color.WHITE))
			frame.set_cell(Vector3i(5, y, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 13
		_settings.falloff = 1.0
		_settings.strength = 8.0
		press = _pos(Vector3(0.0, 4.0, 0.0))
	)
	step("When the user presses once", func():
		_press(press)
		_release(press)
		split_cells = {
			"center": _column_height(Vector3i(0, 0, 0), 1, 1, 0),
			"edge": _column_height(Vector3i(5, 0, 0), 1, 1, 0),
		}
	)
	step("Then the hard center rounds faster than the soft edge", func():
		expect(int(split_cells["center"]) < int(split_cells["edge"]), "the hard center keeps less height than the soft edge")
		expect(int(split_cells["center"]) < 5, "the hard center spike rounds")
		expect(int(split_cells["edge"]) >= 4, "the soft edge spike barely moves in one hold")
	)
	step("Given the same plate with no falloff", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_view("top")
		_flat_plate(6)
		for y in range(1, 5):
			frame.set_cell(Vector3i(0, y, 0), VoxelFrame.material(Color.WHITE))
			frame.set_cell(Vector3i(5, y, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 13
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3(0.0, 4.0, 0.0))
	)
	step("When the user presses once with no falloff", func():
		_press(press)
		_release(press)
	)
	step("Then both spikes round equally", func():
		expect(_column_height(Vector3i(0, 0, 0), 1, 1, 0) == _column_height(Vector3i(5, 0, 0), 1, 1, 0), "no falloff rounds both spikes equally")
		expect(_column_height(Vector3i(0, 0, 0), 1, 1, 0) < 5, "the no-falloff spikes round")
	)


func _smooth_job_cancel() -> void:
	step("Given a Smooth job with a real patch and a cancelled flag", func():
		_view("top")
		_flat_plate(4)
		for y in range(1, 5):
			frame.set_cell(Vector3i(0, y, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		var cells: Array = frame.positions()
		var job = tool.get_script().SmoothJob.new()
		job.edited_frame = frame.copy_frame()
		job.fields = [{"cells": cells, "weights": {}}]
		job.passes = 8
		job.radius = 1
		job.cancel()
		var before := frame.count()
		job.run()
		split_cells = {
			"cancelled": job.cancelled,
			"chunks": job.changed_chunks.size(),
			"before": before,
			"after": frame.count(),
		}
	)
	step("Then the cancelled job computes and publishes nothing", func():
		expect(split_cells["cancelled"], "the job reports its cancellation")
		expect(int(split_cells["chunks"]) == 0, "the cancelled job published no chunk")
		expect(int(split_cells["after"]) == int(split_cells["before"]), "the cancelled job wrote no cell")
	)


# --- Flatten materials ------------------------------------------------------

func _flatten_materials() -> void:
	step("Given columns of different materials below one flat target", func():
		_settings.tool = _settings.Tools.FLATTEN
		_settings.radius = 9
		_settings.falloff = 0.0
		_settings.strength = 30.0
		_view("top")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		for y in range(0, 5):
			frame.set_cell(anchor + Vector3i(0, y, 0), VoxelFrame.material(Color.WHITE, Color(0.1, 0.1, 0.1), 0.2, 0.8))
		for y in range(0, 2):
			frame.set_cell(anchor + Vector3i(2, y, 0), VoxelFrame.material(Color.RED, Color(0.4, 0.0, 0.0), 0.5, 0.25))
			frame.set_cell(anchor + Vector3i(-2, y, 0), VoxelFrame.material(Color.BLUE, Color(0.0, 0.0, 0.4), 0.25, 0.75))
		for y in range(0, 7):
			frame.set_cell(anchor + Vector3i(4, y, 0), VoxelFrame.material(Color.GREEN, Color(0.0, 0.4, 0.0), 0.9, 0.1))
		sync_viewport()
		split_cells = _cell_materials(frame)
		State.current_color = Color.MAGENTA
		press = _pos(Vector3(anchor))
	)
	step("When the user presses the tall column and holds", func():
		_press(press)
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then each raise keeps its own local material and the cut survivor keeps its own", func():
		expect(_column_height(anchor + Vector3i(2, 0, 0), 1, 1, 0) == 5, "the red column fills to the target")
		expect(_column_height(anchor + Vector3i(-2, 0, 0), 1, 1, 0) == 5, "the blue column fills to the target")
		expect(frame.get_material(anchor + Vector3i(2, 4, 0)) == VoxelFrame.material(Color.RED, Color(0.4, 0.0, 0.0), 0.5, 0.25), "the red raise keeps its full local material")
		expect(frame.get_material(anchor + Vector3i(-2, 4, 0)) == VoxelFrame.material(Color.BLUE, Color(0.0, 0.0, 0.4), 0.25, 0.75), "the blue raise keeps its full local material")
		expect(frame.get_color(anchor + Vector3i(2, 4, 0)) != Color.MAGENTA, "a raise never uses the active paint")
		expect(_column_height(anchor + Vector3i(4, 0, 0), 1, 1, 0) == 5, "the green column cuts to the target")
		expect(frame.get_material(anchor + Vector3i(4, 4, 0)) == VoxelFrame.material(Color.GREEN, Color(0.0, 0.4, 0.0), 0.9, 0.1), "the cut survivor keeps its full material")
		expect(frame.get_material(anchor + Vector3i(0, 4, 0)) == VoxelFrame.material(Color.WHITE, Color(0.1, 0.1, 0.1), 0.2, 0.8), "the pressed column is never repainted")
	)
	step("When the user undoes and redoes", func():
		State.undo_redo.undo()
		expect(frame.get_material(anchor + Vector3i(2, 1, 0)) == split_cells[anchor + Vector3i(2, 1, 0)], "undo restores the original short column")
		expect(_column_height(anchor + Vector3i(2, 0, 0), 1, 1, 0) == 2, "undo restores the short column height")
		State.undo_redo.redo()
	)
	step("Then the redo restores the inherited materials", func():
		expect(frame.get_material(anchor + Vector3i(2, 4, 0)) == VoxelFrame.material(Color.RED, Color(0.4, 0.0, 0.0), 0.5, 0.25), "the redo keeps the inherited material")
		expect(frame.get_material(anchor + Vector3i(-2, 4, 0)) == VoxelFrame.material(Color.BLUE, Color(0.0, 0.0, 0.4), 0.25, 0.75), "the redo keeps the mirrored inherited material")
	)
	step("Given a fresh pair of columns and the flatten tool", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_view("top")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		for y in range(0, 5):
			frame.set_cell(anchor + Vector3i(0, y, 0), VoxelFrame.material(Color.WHITE))
		for y in range(0, 2):
			frame.set_cell(anchor + Vector3i(2, y, 0), VoxelFrame.material(Color.RED, Color(0.4, 0.0, 0.0), 0.5, 0.25))
		sync_viewport()
		State.current_color = Color.MAGENTA
		press = _pos(Vector3(anchor))
	)
	step("When the user flattens and presses Escape", func():
		_press(press)
		tool.advance_stroke(1.0)
		_key(KEY_ESCAPE)
	)
	step("Then the raise rolls back", func():
		expect(_column_height(anchor + Vector3i(2, 0, 0), 1, 1, 0) == 2, "Escape restores the short column")
		expect(not State.undo_redo.has_undo(), "the cancelled stroke adds no history")
	)


func _flatten_material_symmetry() -> void:
	step("Given mirrored short columns and the active paint", func():
		_settings.tool = _settings.Tools.FLATTEN
		_settings.radius = 7
		_settings.falloff = 0.0
		_settings.strength = 30.0
		_view("top")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		State.symmetry_axes = 1
		State.symmetry_origin = Vector3(float(anchor.x) - 0.5, float(anchor.y) - 0.5, float(anchor.z) - 0.5)
		for y in range(0, 5):
			frame.set_cell(anchor + Vector3i(0, y, 0), VoxelFrame.material(Color.WHITE))
		for y in range(0, 2):
			frame.set_cell(anchor + Vector3i(1, y, 0), VoxelFrame.material(Color.RED, Color(0.4, 0.0, 0.0), 0.5, 0.25))
			frame.set_cell(anchor + Vector3i(-2, y, 0), VoxelFrame.material(Color.BLUE, Color(0.0, 0.0, 0.4), 0.25, 0.75))
		sync_viewport()
		State.current_color = Color.MAGENTA
		press = _pos(Vector3(anchor))
	)
	step("When the user flattens with X symmetry", func():
		_press(press)
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then each mirrored raise keeps its own local material", func():
		expect(_column_height(anchor + Vector3i(1, 0, 0), 1, 1, 0) == 5, "the pressed raise fills to the target")
		expect(_column_height(anchor + Vector3i(-2, 0, 0), 1, 1, 0) == 5, "the mirrored raise fills to the target")
		expect(frame.get_color(anchor + Vector3i(1, 4, 0)) == Color.RED, "the pressed raise keeps its local material")
		expect(frame.get_color(anchor + Vector3i(-2, 4, 0)) == Color.BLUE, "the mirrored raise keeps its own local material")
	)
	step("Given an empty floor and the active paint", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_view("top")
		State.symmetry_axes = 0
		State.current_color = Color.MAGENTA
		press = _pos(Vector3.ZERO)
		target = aim(press).target
	)
	step("When the user flattens the empty floor", func():
		_press(press)
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then the empty seed uses the active material", func():
		expect(frame.has(target), "the floor seed appears")
		expect(frame.get_color(target) == Color.MAGENTA, "the empty seed uses the active paint")
	)


func _flatten_material_signed() -> void:
	step("Given columns below a flat target seen from below", func():
		_settings.tool = _settings.Tools.FLATTEN
		_settings.radius = 9
		_settings.falloff = 0.0
		_settings.strength = 30.0
		_view("bottom")
		press = _pos(Vector3.ZERO)
		anchor = aim(press).target
		for y in range(0, 5):
			frame.set_cell(anchor - Vector3i(0, y, 0), VoxelFrame.material(Color.WHITE))
		for y in range(0, 2):
			frame.set_cell(anchor - Vector3i(2, y, 0), VoxelFrame.material(Color.RED, Color(0.4, 0.0, 0.0), 0.5, 0.25))
		sync_viewport()
		State.current_color = Color.MAGENTA
		press = _pos(Vector3(anchor))
	)
	step("When the user presses the tall column and holds", func():
		_press(press)
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then the short column fills downward with its own local material", func():
		expect(_column_height(anchor - Vector3i(2, 0, 0), 1, -1, anchor.y) == 5, "the short column fills downward")
		expect(frame.get_material(anchor - Vector3i(2, 4, 0)) == VoxelFrame.material(Color.RED, Color(0.4, 0.0, 0.0), 0.5, 0.25), "the downward raise keeps its full local material")
		expect(frame.get_color(anchor - Vector3i(2, 4, 0)) != Color.MAGENTA, "the downward raise never uses the active paint")
	)


# --- Preview and controls ---------------------------------------------------

func _grab_controls() -> void:
	step("Given the Grab tool with a wide radius", func():
		var options: Control = plugin("TerrainPlugin")._options
		_settings.tool = _settings.Tools.GRAB
		_settings.radius = 72
		expect(_settings.radius == 32, "the Grab keeps the shared radius")
		expect(options.get_node("Radius").max_value == 32.0, "the radius control keeps the shared bound")
		expect(not options.get_node("Strength").visible, "the strength control is hidden for Grab")
	)
	step("When the user switches back to Build", func():
		var options: Control = plugin("TerrainPlugin")._options
		_settings.tool = _settings.Tools.BUILD
		expect(_settings.radius == 32, "the radius survives the tool switch")
		expect(options.get_node("Radius").max_value == 32.0, "the radius control keeps the shared bound")
		expect(options.get_node("Strength").visible, "the strength control returns for Build")
	)


# --- Movement applications --------------------------------------------------

# A solid block with a two-cell spike, so Build, Flatten, and Smooth all change
# the surface in one application.
func _spike_block() -> void:
	for x in range(-4, 1):
		for y in range(-4, 1):
			for z in range(-4, 1):
				frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.WHITE))
	frame.set_cell(Vector3i(-2, 1, -2), VoxelFrame.material(Color.WHITE))
	frame.set_cell(Vector3i(-2, 2, -2), VoxelFrame.material(Color.WHITE))
	sync_viewport()


# Fills a flat plate of half width 4 on the floor plane.
func _build_plate() -> void:
	for x in range(-4, 5):
		for z in range(-4, 5):
			frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
	sync_viewport()


func _strength_per_application() -> void:
	step("Given a flat plate and the Build tool at strength one", func():
		_view("top")
		_build_plate()
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 5
		_settings.falloff = 0.0
		_settings.strength = 1.0
		press = _pos(Vector3.ZERO)
	)
	step("When the user presses once", func():
		_press(press)
		_release(press)
	)
	step("Then every footprint column gains exactly one layer", func():
		var uniform := true
		for entry in TerrainGeometry.disk_offsets(5):
			if _column_height(Vector3i(entry["u"], 0, entry["v"]), 1, 1, 0) != 2:
				uniform = false
		expect(uniform, "strength one applies one layer per application")
	)
	step("Given a fresh plate and the Build tool at strength three", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_view("top")
		_build_plate()
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 5
		_settings.falloff = 0.0
		_settings.strength = 3.0
		press = _pos(Vector3.ZERO)
	)
	step("When the user presses once", func():
		_press(press)
		_release(press)
	)
	step("Then every footprint column gains exactly three layers", func():
		var uniform := true
		for entry in TerrainGeometry.disk_offsets(5):
			if _column_height(Vector3i(entry["u"], 0, entry["v"]), 1, 1, 0) != 4:
				uniform = false
		expect(uniform, "strength three applies three layers per application")
	)


func _falloff_fractional() -> void:
	step("Given a flat plate and the Build tool with a strong falloff", func():
		_view("top")
		_build_plate()
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 9
		_settings.falloff = 1.0
		_settings.strength = 1
		press = _pos(Vector3.ZERO)
	)
	step("When the user presses once", func():
		_press(press)
		expect(_column_height(Vector3i(0, 0, 0), 1, 1, 0) == 2, "the hard center gains one layer")
		expect(_column_height(Vector3i(2, 0, 0), 1, 1, 0) == 2, "a mid-weight cell gains one layer")
		expect(_column_height(Vector3i(3, 0, 0), 1, 1, 0) == 1, "a low-weight cell rounds to no layer")
	)
	step("When the user applies one more dab at the same cell", func():
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then no fraction carries to the next dab", func():
		expect(_column_height(Vector3i(3, 0, 0), 1, 1, 0) == 1, "the low-weight cell still gains nothing")
		expect(_column_height(Vector3i(0, 0, 0), 1, 1, 0) == 3, "the hard center gains one layer per dab")
	)


func _stationary_no_repeat() -> void:
	for operator in [_settings.Tools.BUILD, _settings.Tools.FLATTEN, _settings.Tools.SMOOTH]:
		step("Given a spike block and operator %d" % operator, func():
			State.document = VoxelDocument.new()
			frame = State.get_current_voxel_frame()
			_view("top")
			_spike_block()
			_settings.tool = operator
			_settings.radius = 7
			_settings.falloff = 0.0
			_settings.strength = 1.0
			press = _pos(Vector3i(-2, 2, -2))
			_press(press)
			split_cells = _cell_materials(frame)
		)
		step("When duplicate zero motions arrive with the pointer held", func():
			for _event in 4:
				_motion(press, Vector2.ZERO)
		)
		step("Then the held pointer adds no dab", func():
			expect(_cell_materials(frame) == split_cells, "a held pointer never repeats an application")
			_release(press)
		)


func _worker_dab_burst() -> void:
	step("Given a wide plate and a brush that runs on the worker pool", func():
		_view("top")
		for x in range(-40, 41):
			for z in range(-40, 41):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 72
		_settings.falloff = 0.0
		_settings.strength = 2.0
		press = _pos(Vector3.ZERO)
	)
	step("When the user drags six cells before the worker finishes", func():
		_press(press)
		expect(tool._tick_job != null, "the press dab runs on the worker pool")
		var previous := press
		for index in range(1, 7):
			var pos := _pos(Vector3(float(index), 0.0, 0.0))
			_motion(pos, pos - previous)
			previous = pos
		expect(tool._has_pending(), "the motion queued a dab behind the worker")
		_release(previous)
	)
	await _await_drained()
	step("Then the burst drained into one history action", func():
		expect(not State.edit_busy(), "the worker released its operation")
		expect(State.undo_redo.get_history_count() == 1, "the whole burst records one action")
		split_cells = frame.capture()
	)
	step("Given a fresh plate and the same brush", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_view("top")
		for x in range(-40, 41):
			for z in range(-40, 41):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		press = _pos(Vector3.ZERO)
	)
	step("When the user delivers the same path one cell per frame", func():
		_press(press)
		var previous := press
		for index in range(1, 7):
			await get_tree().process_frame
			var pos := _pos(Vector3(float(index), 0.0, 0.0))
			_motion(pos, pos - previous)
			previous = pos
		_release(previous)
	)
	await _await_drained()
	step("Then the frame-spaced delivery matches the burst exactly", func():
		expect(VoxelEditTransaction._chunks_equal(split_cells, frame.capture()), "the burst and the frame-spaced path give the same voxels")
		expect(State.undo_redo.get_history_count() == 1, "the frame-spaced stroke records one action")
	)


func _cancel_stale_dabs() -> void:
	step("Given a wide plate and a heavy Build stroke on the worker pool", func():
		_view("top")
		for x in range(-40, 41):
			for z in range(-40, 41):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 72
		_settings.falloff = 0.0
		_settings.strength = 2.0
		press = _pos(Vector3.ZERO)
		split_cells = _cell_materials(frame)
	)
	step("When the user drags and then presses Escape", func():
		_press(press)
		expect(tool._tick_job != null, "the press dab runs on the worker pool")
		var pos := _pos(Vector3(6.0, 0.0, 0.0))
		_motion(pos, pos - press)
		expect(tool._has_pending(), "the motion queued a dab behind the worker")
		_key(KEY_ESCAPE)
	)
	step("Then the cancel clears the accepted path and the edit", func():
		expect(tool._edit == null, "Escape closes the edit")
		expect(not tool._has_pending(), "Escape clears the accepted path")
	)
	await _await_drained()
	step("Then the plate is restored and no history is recorded", func():
		expect(_cell_materials(frame) == split_cells, "the cancel restores the plate")
		expect(not State.undo_redo.has_undo(), "the cancelled stroke records no history")
	)
	step("When the user starts a small replacement stroke", func():
		_settings.radius = 1
		_settings.strength = 1.0
		_press(press)
		_release(press)
	)
	await _await_drained()
	step("Then the stale worker cannot touch the replacement", func():
		expect(frame.has(Vector3i(0, 1, 0)), "the replacement stroke applied")
		expect(State.undo_redo.get_history_count() == 1, "the replacement records one action")
	)


func _smooth_move_adaptive() -> void:
	step("Given a ramp that levels off and the Smooth tool", func():
		_view("top")
		for x in range(0, 13):
			var top: int = mini(x / 2, 3)
			for y in range(0, top + 1):
				for z in range(-4, 5):
					frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 5
		_settings.falloff = 0.0
		_settings.strength = 1.0
		press = _pos(Vector3i(2, 1, 0))
	)
	step("When the user presses the slope and drags to the flat top", func():
		_press(press)
		var before: Vector3 = tool._stroke_frame.normal
		var previous := press
		for point in [Vector3i(3, 1, 0), Vector3i(5, 2, 0), Vector3i(7, 3, 0), Vector3i(9, 3, 0), Vector3i(11, 3, 0)]:
			var pos := _pos(Vector3(point))
			_motion(pos, pos - previous)
			previous = pos
		var after: Vector3 = tool._stroke_frame.normal
		split_cells = {"before": before, "after": after}
		_release(previous)
	)
	step("Then the plane follows the gradient at the moved brush", func():
		var before: Vector3 = split_cells["before"]
		var after: Vector3 = split_cells["after"]
		expect(before.y < 0.9, "the slope tilts the plane")
		expect(after.y > 0.9, "the flat top re-reads the plane")
		expect(after.y > 0.0 and before.y > 0.0, "the outward orientation never flips")
	)


# Draws the same six-cell Build path with a fixed number of frame waits per cell.
# A coalesced path delivers the whole segment as one motion.
func _draw_build_path(waits: int, coalesced: bool) -> void:
	var start := press
	_press(start)
	var previous := start
	for index in range(1, 7):
		if coalesced and index != 6:
			continue
		for _wait in waits:
			await get_tree().process_frame
		var pos := _pos(Vector3(float(index), 0.0, 0.0))
		_motion(pos, pos - previous)
		previous = pos
	_release(previous)


func _frame_replay() -> void:
	step("Given a replay of the same Build path at three frame counts", func():
		split_cells = {}
	)
	for entry in [[0, false], [1, false], [4, false], [0, true]]:
		var waits: int = entry[0]
		var coalesced: bool = entry[1]
		var key := "%d:%s" % [waits, str(coalesced)]
		step("Given a fresh floor and a Build path with %d waits and coalesced=%s" % [waits, str(coalesced)], func():
			State.document = VoxelDocument.new()
			frame = State.get_current_voxel_frame()
			_view("top")
			_settings.tool = _settings.Tools.BUILD
			_settings.build_mode = _settings.BuildMode.ADD
			_settings.radius = 5
			_settings.falloff = 0.0
			_settings.strength = 1.0
			press = _pos(Vector3.ZERO)
		)
		step("When the user draws the same polyline", func():
			await _draw_build_path(waits, coalesced)
		)
		await _await_drained()
		split_cells[key] = frame.capture()
	step("Then every engine frame count gives the same voxels", func():
		expect(VoxelEditTransaction._chunks_equal(split_cells["0:false"], split_cells["1:false"]), "one wait per cell matches no wait")
		expect(VoxelEditTransaction._chunks_equal(split_cells["0:false"], split_cells["4:false"]), "four waits per cell match no wait")
		expect(VoxelEditTransaction._chunks_equal(split_cells["0:false"], split_cells["0:true"]), "one coalesced segment matches every crossed cell")
	)


# --- Lazy path scheduler ----------------------------------------------------

func _dab_path_iterator() -> void:
	step("Given straight, diagonal, and negative segments", func():
		var segments := [
			[Vector3i.ZERO, Vector3i(6, 0, 0)],
			[Vector3i.ZERO, Vector3i(6, 2, 0)],
			[Vector3i.ZERO, Vector3i(0, 0, -5)],
			[Vector3i(3, 4, 5), Vector3i(-2, 1, 7)],
			[Vector3i(-4, -4, -4), Vector3i(4, 4, 4)],
		]
		var matches := true
		var connected := true
		var no_repeat := true
		for segment in segments:
			var expected := StrokeLine.cells(segment[0], segment[1])
			var path = StrokeLine.Cursor.new(segment[0], segment[1])
			var produced: Array[Vector3i] = [segment[0]]
			var cell = path.next_cell()
			while cell != null:
				produced.append(cell)
				cell = path.next_cell()
			if produced != expected:
				matches = false
			for index in range(1, produced.size()):
				var step: Vector3i = produced[index] - produced[index - 1]
				if absi(step.x) > 1 or absi(step.y) > 1 or absi(step.z) > 1:
					connected = false
			var seen := {}
			for entry in produced:
				if seen.has(entry):
					no_repeat = false
				seen[entry] = true
		expect(matches, "the lazy cursor yields exactly the shared line path")
		expect(connected, "every cursor step is connected")
		expect(no_repeat, "the cursor never repeats a cell")
	)
	step("Given one long segment", func():
		split_cells = {}
		var path = StrokeLine.Cursor.new(Vector3i(0, 1, 0), Vector3i(6000, 1, 0))
		var count := 0
		var last := Vector3i.ZERO
		var cell = path.next_cell()
		while cell != null:
			last = cell
			count += 1
			cell = path.next_cell()
		expect(count == 6000, "the cursor yields every crossed cell of a long segment")
		expect(last == Vector3i(6000, 1, 0), "the cursor ends on the segment target")
	)


func _giant_jump_drain() -> void:
	step("Given an empty floor and a long Build drag", func():
		_view("top")
		_settings.tool = _settings.Tools.BUILD
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 1
		_settings.falloff = 0.0
		_settings.strength = 1.0
		press = _pos(Vector3.ZERO)
		target = aim(press).target
	)
	step("When one motion crosses three hundred cells", func():
		_press(press)
		var pos := _pos(Vector3(300.0, 0.0, 0.0))
		_motion(pos, pos - press)
		expect(tool._has_pending(), "the long accepted path waits for the bounded drain")
		_release(pos)
	)
	await _await_drained()
	step("Then every crossed center was applied as one action", func():
		var missing := 0
		for index in range(1, 301):
			if not frame.has(target + Vector3i(index, 0, 0)):
				missing += 1
		expect(missing == 0, "every accepted crossed center is applied")
		expect(State.undo_redo.get_history_count() == 1, "the long drag records one action")
	)


func _smooth_first_motion_hold() -> void:
	step("Given a 45 degree ramp and the Smooth tool", func():
		_view("top")
		for x in range(0, 13):
			for y in range(0, x + 1):
				for z in range(-3, 4):
					frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 5
		_settings.falloff = 0.0
		_settings.strength = 2.0
		press = _pos(Vector3i(3, 3, 0))
	)
	step("When the press applies and the first motion repeats the press position", func():
		_press(press)
		split_cells = _cell_materials(frame)
		_motion(press, Vector2.ZERO)
	)
	step("Then the re-read plane cannot add a dab", func():
		expect(_cell_materials(frame) == split_cells, "a first motion at the press position adds no dab")
		_release(press)
	)


func _smooth_slope_replay() -> void:
	step("Given a 45 degree staircase and the Smooth tool", func():
		_view("top")
		_staircase()
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 11
		_settings.falloff = 0.0
		_settings.strength = 1.0
		press = _pos(Vector3i(0, 0, 0))
	)
	step("When the user draws the changing slope in one burst", func():
		_press(press)
		var rise: Vector3 = tool._stroke_frame.normal
		var previous := press
		for point in [Vector3i(2, 0, 0), Vector3i(4, 0, 0), Vector3i(6, 0, 0)]:
			var pos := _pos(Vector3(point))
			_motion(pos, pos - previous)
			previous = pos
		split_cells = {"rise": rise, "fall": tool._stroke_frame.normal}
		_release(previous)
	)
	await _await_drained()
	step("Then the burst changed the slope as one action", func():
		split_cells["burst"] = frame.capture()
		expect((split_cells["rise"] as Vector3).y < 0.9, "the staircase tilts the plane")
		expect((split_cells["rise"] as Vector3).y > 0.0 and (split_cells["fall"] as Vector3).y > 0.0, "the re-read stays outward")
		expect(not frame.has(Vector3i(-1, 3, 0)), "the near step corner rounds away")
		expect(State.undo_redo.get_history_count() == 1, "the burst records one action")
	)
	step("Given a fresh staircase and the same start", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_view("top")
		_staircase()
		sync_viewport()
		press = _pos(Vector3i(0, 0, 0))
	)
	step("When the user draws the same path one motion per frame", func():
		_press(press)
		var previous := press
		for point in [Vector3i(2, 0, 0), Vector3i(4, 0, 0), Vector3i(6, 0, 0)]:
			await get_tree().process_frame
			var pos := _pos(Vector3(point))
			_motion(pos, pos - previous)
			previous = pos
		_release(previous)
	)
	await _await_drained()
	step("Then both deliveries give identical full materials", func():
		expect(VoxelEditTransaction._chunks_equal(split_cells["burst"], frame.capture()), "the burst and the frame-spaced slope match exactly")
		expect(State.undo_redo.get_history_count() == 1, "the frame-spaced slope records one action")
	)


# Fills a coarse 45 degree staircase. Each step rises three cells over three
# cells in x, so the surface normal is 45 degrees with both signs.
func _staircase() -> void:
	for x in range(-9, 10):
		var top := -3 * floori(float(x) / 3.0)
		for y in range(-9, top + 1):
			for z in range(-4, 5):
				frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.WHITE))
