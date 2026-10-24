extends "res://tests/test.gd"

# One process runs the sculpt tests. The parent registers the sculpt plugin in
# State, so the setup looks the existing plugin up under the scene root. The
# tests drive the real viewport input, the deterministic time hook, and the
# shared geometry helpers.

const FLOOR_AXIS := {"right": 0, "left": 0, "top": 1, "bottom": 1, "front": 2, "back": 2, "isometric": 1}
const VIEW_AXIS := {"right": 0, "left": 0, "top": 1, "bottom": 1, "front": 2, "back": 2, "isometric": 1}

var _settings := preload("res://plugins/Sculpt/settings.tres")

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
var center_height := 0
var edge_height := 0


func _ready() -> void:
	test("grow adds voxels outward on an empty floor", _grow_empty_floor, "grow_empty_floor")
	test("grow remove on an empty floor changes nothing", _grow_remove_empty, "grow_remove_empty")
	test("the pressed face sets the signed outward normal on every axis", _grow_signed_normals, "grow_signed_normals")
	test("grow accumulates over time, keeps falloff, and splits time evenly", _grow_accumulation, "grow_accumulation")
	test("a hard-edge flat patch raises one uniform layer", _grow_uniform_layer, "grow_uniform_layer")
	test("a hard-edge staircase patch raises a coherent layer", _grow_uniform_oblique, "grow_uniform_oblique")
	test("a steep staircase raises one shell per layer", _grow_steep_layer, "grow_steep_layer")
	test("a steep staircase digs one shell per layer", _grow_steep_remove, "grow_steep_remove")
	test("a steep staircase advances every column the same depth", _grow_steep_repeat, "grow_steep_repeat")
	test("reversed sample order writes the same cells", _grow_order_independent, "grow_order_independent")
	test("equal elapsed time at different frame rates matches", _grow_frame_rate, "grow_frame_rate")
	test("an exact step boundary is frame-rate independent", _grow_exact_boundary, "grow_exact_boundary")
	test("smooth falloff makes deterministic nested height bands", _grow_falloff_bands, "grow_falloff_bands")
	test("a revisited sample keeps its fractional progress", _grow_progress_retained, "grow_progress_retained")
	test("a stationary tower grows past the scan depth without overwriting", _grow_deep_tower, "grow_deep_tower")
	test("flatten fills and cuts samples to one surface without overshoot", _flatten_surface, "flatten_surface")
	test("flatten mirrors its target through the symmetry normal", _flatten_symmetry_target, "flatten_symmetry_target")
	test("a fitted plane follows a slope and is not cardinal", _fit_slope, "fit_slope")
	test("a flat plate fits its cardinal normal", _fit_planar, "fit_planar")
	test("an isolated voxel falls back to the clicked face", _fit_degenerate, "fit_degenerate")
	test("a stray voxel keeps the fit near the plate normal", _fit_noise, "fit_noise")
	test("an opposing wall does not tilt the fit", _fit_opposing, "fit_opposing")
	test("a collinear surface falls back to the clicked face", _fit_collinear, "fit_collinear")
	test("the fitted normal matches a known height gradient", _gradient_synthetic, "gradient_synthetic")
	test("the fit samples the full brush disc", _gradient_full_disc, "gradient_full_disc")
	test("grow on a fitted slope adds along the fitted normal", _grow_slope, "grow_slope")
	test("successive steps keep one coherent layer", _oblique_steps, "oblique_steps")
	test("a ray with tied components keeps one path for both signs", _oblique_ties, "oblique_ties")
	test("flatten on a fitted slope cuts toward the fitted plane", _flatten_slope, "flatten_slope")
	test("flatten settles to one slope and does not oscillate", _flatten_converges, "flatten_converges")
	test("a fitted plane mirrors through a symmetry plane", _fit_symmetry, "fit_symmetry")
	test("grab drags on the true camera-facing plane", _grab_oblique, "grab_oblique")
	test("grab stretches voxels, keeps materials, and preserves unrelated geometry", _grab_stretch, "grab_stretch")
	test("grab keeps a source whose destination leaves the selection", _grab_selection_destination, "grab_selection_destination")
	test("grab without a source changes nothing", _grab_empty, "grab_empty")
	test("a large grab runs on the worker pool and publishes once", _grab_worker, "grab_worker")
	test("a queued return to the origin closes the edit", _grab_pending_return, "grab_pending_return")
	test("a cancelled worker cannot touch a replacement stroke", _cancel_repress, "cancel_repress")
	test("a grow stroke supports undo, redo, Escape, a switch, and a context change", _stroke_history, "stroke_history")
	test("a lost left release finishes the stroke", _lost_release, "lost_release")
	test("frame-spaced motion interpolates without amplifying time", _motion_interpolation, "motion_interpolation")
	test("selection and symmetry limit and mirror a grow stroke", _selection_symmetry, "selection_symmetry")
	test("the preview outlines the supporting surface voxels", _preview_ghost, "preview_ghost")
	test("the preview outline follows an uneven surface", _preview_ghost_oblique, "preview_ghost_oblique")
	test("the selection filters the preview destination", _preview_selection_destination, "preview_selection_destination")
	test("the preview refreshes after an edit and a settings change", _preview_refresh, "preview_refresh")
	test("the Grab preview shows only occupied eligible sources", _grab_preview_sources, "grab_preview_sources")
	test("the Grab options show the effective radius and hide strength", _grab_controls, "grab_controls")
	test("Smooth leaves a flat plate unchanged", _smooth_flat, "smooth_flat")
	test("Smooth lowers a spike without cutting through", _smooth_spike, "smooth_spike")
	test("Smooth raises a pit without overshoot", _smooth_pit, "smooth_pit")
	test("Smooth never seeds an empty floor", _smooth_empty, "smooth_empty")
	test("the Smooth controls show radius, strength, and no grow direction", _smooth_controls, "smooth_controls")
	test("a Smooth stroke supports undo, redo, Escape, and a switch", _smooth_history, "smooth_history")
	test("the Smooth preview outlines occupied surface voxels", _smooth_preview, "smooth_preview")
	test("the selection limits a Smooth stroke", _smooth_selection, "smooth_selection")
	test("symmetry mirrors a Smooth stroke", _smooth_symmetry, "smooth_symmetry")
	test("Smooth preserves surviving materials and fills with the local material", _smooth_materials, "smooth_materials")
	test("Smooth re-fits its plane as the surface changes", _smooth_adaptive, "smooth_adaptive")
	test("Smooth keeps the fractional carry across calls", _smooth_carry, "smooth_carry")
	test("Smooth fits the outward sign on every orientation", _smooth_orientation, "smooth_orientation")
	test("Smooth symmetry across the normal axis keeps both sides", _smooth_symmetry_axis, "smooth_symmetry_axis")
	test("repeated Smooth refits of an unchanged ramp do not drift", _smooth_refit_stable, "smooth_refit_stable")
	test("a reentrant document swap during a Smooth signal is safe", _smooth_reentrant, "smooth_reentrant")
	test("Smooth rounds a convex cube corner and keeps the faces", _smooth_round_corner, "smooth_round_corner")
	test("Smooth softens a long convex edge, not only its corners", _smooth_round_edge, "smooth_round_edge")
	test("Smooth fills a concave inside corner", _smooth_round_concave, "smooth_round_concave")
	test("Smooth rounds a vertical edge from a side view", _smooth_round_vertical, "smooth_round_vertical")
	test("Smooth leaves a two-cell plate unchanged", _smooth_round_thick_plate, "smooth_round_thick_plate")
	test("Smooth rounds a staircase into a coherent ramp", _smooth_round_staircase, "smooth_round_staircase")
	test("a hold split across ticks rounds the same cells", _smooth_round_split, "smooth_round_split")
	test("the falloff scales the Smooth rounding rate", _smooth_weighted_falloff, "smooth_weighted_falloff")
	test("a cancelled Smooth job computes and publishes nothing", _smooth_job_cancel, "smooth_job_cancel")
	test("flatten raises each column with its own local material", _flatten_materials, "flatten_materials")
	test("flatten keeps the local material through symmetry and an empty seed", _flatten_material_symmetry, "flatten_material_symmetry")
	test("flatten raises downward with the local material on a signed normal", _flatten_material_signed, "flatten_material_signed")
	test("the strength sets the layer count of one application", _strength_per_application, "strength_per_application")
	test("the falloff keeps a fractional influence across applications", _falloff_fractional, "falloff_fractional")
	test("a held pointer never repeats a Grow, Flatten, or Smooth dab", _stationary_no_repeat, "stationary_no_repeat")
	test("a worker dab burst drains to the frame-spaced result", _worker_dab_burst, "worker_dab_burst")
	test("Escape clears queued dabs and a stale worker cannot touch the next stroke", _cancel_stale_dabs, "cancel_stale_dabs")
	test("Smooth refits its plane on movement", _smooth_move_adaptive, "smooth_move_adaptive")
	test("a replay across different engine frame counts gives the same voxels", _frame_replay, "frame_replay")
	test("the lazy dab cursor yields the shared line path", _dab_path_iterator, "dab_path_iterator")
	test("a giant drag drains every accepted center over bounded frames", _giant_jump_drain, "giant_jump_drain")
	test("a first motion at the press position adds no Smooth dab", _smooth_first_motion_hold, "smooth_first_motion_hold")
	test("a 45 degree Smooth slope replay is delivery independent", _smooth_slope_replay, "smooth_slope_replay")


func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.current_color = Color.from_rgba8(200, 60, 60)
	State.floor_index = 0
	_settings.tool = _settings.Tools.GROW
	_settings.grow_mode = _settings.GrowMode.ADD
	_settings.radius = 2
	_settings.strength = 8.0
	_settings.falloff = 0.0
	viewport = editor_viewport()
	viewport.get_parent().stretch = false
	viewport.size = Vector2i(800, 500)
	camera_rig().is_orthogonal = true
	frame = State.get_current_voxel_frame()
	await _ensure_plugin()
	activate_tool("sculpt")
	plugin("SculptPlugin").activate_tool()
	tool = plugin("SculptPlugin")._tool
	tool.set_process(true)
	await get_tree().process_frame


func _cleanup_test() -> void:
	if tool != null and tool._edit != null:
		tool.finish_on_switch()
	State.stop()


func _ensure_plugin() -> void:
	# The parent registers the plugin in State. Wait for the deferred add.
	for _frame in 5:
		if plugin("SculptPlugin") != null:
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


# Waits for the hover preview controller to publish its result and for the cursor
# mesh to settle. The hover fit and the footprint map run on the worker, so a test
# that reads the published cells waits here.
func _settle_preview() -> void:
	for index in 600:
		await get_tree().process_frame
		if tool == null:
			return
		if tool._preview.is_settled() and tool.get_node("Cursor").is_settled():
			return


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
	var fitted := SculptFrame.fit(source, hit, entry, radius, SculptFrame.from_face(hit, entry))
	var samples := []
	for off in SculptGeometry.disk_offsets(radius):
		var point: Vector3 = fitted.origin + float(off["u"]) * fitted.tangent_u + float(off["v"]) * fitted.tangent_v
		samples.append({
			"anchor": SculptGeometry.cell_at(point),
			"point": point,
			"normal": fitted.normal,
			"plane_origin": fitted.origin,
			"surface": SculptGeometry.surface_along(source, point, fitted.normal, 16, {}),
			"steps": 1,
		})
	return samples


func _run_job(source: VoxelFrame, samples: Array) -> Array:
	var job = tool.get_script().SculptTickJob.new()
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


# --- Grow and flatten -------------------------------------------------------

func _grow_empty_floor() -> void:
	step("Given the Grow tool in Add mode on an empty floor", func():
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
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
	step("When the user presses and holds the Grow tool", func():
		_press(press)
		expect(tool._edit != null, "the press opens an edit")
		expect(tool._stroke_seed_empty, "the stroke starts on the empty floor")
		tool.advance_stroke(0.5)
		_release(press)
	)
	step("Then the floor grows outward from the press plane", func():
		expect(frame.has(target), "the seed cell appears on the floor")
		expect(frame.has(target + Vector3i(0, 1, 0)), "the growth continues outward")
		expect(State.undo_redo.has_undo(), "the stroke records one history action")
	)


func _grow_remove_empty() -> void:
	step("Given the Grow tool in Remove mode on an empty floor", func():
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.REMOVE
		_settings.radius = 2
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


func _grow_signed_normals() -> void:
	for view in ["front", "right", "top", "bottom"]:
		step("Given a single voxel seen from the %s" % view, func():
			State.document = VoxelDocument.new()
			frame = State.get_current_voxel_frame()
			_view(view)
			_settings.tool = _settings.Tools.GROW
			_settings.grow_mode = _settings.GrowMode.ADD
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


func _grow_accumulation() -> void:
	step("Given Grow with falloff on an empty floor", func():
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.radius = 4
		_settings.falloff = 0.5
		_settings.strength = 4.0
		_view("top")
		press = _pos(Vector3.ZERO)
		target = aim(press).target
	)
	step("When the user holds for half a second in two steps", func():
		_press(press)
		tool.advance_stroke(0.25)
		tool.advance_stroke(0.25)
		_release(press)
		split_cells = _cell_colors(frame)
		center_height = _column_height(target, 1, 1, 0)
		edge_height = _column_height(target + Vector3i(4, 0, 0), 1, 1, 0)
	)
	step("Then the center grows more than the edge", func():
		expect(center_height > 0, "the center column grows")
		expect(center_height > edge_height, "the falloff decreases the edge growth")
	)
	step("When the user repeats the same hold in one step", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_view("top")
		press = _pos(Vector3.ZERO)
		target = aim(press).target
		_press(press)
		tool.advance_stroke(0.5)
		_release(press)
	)
	step("Then the frame is identical", func():
		expect(_cell_colors(frame) == split_cells, "splitting the elapsed time is equivalent")
	)


func _grow_uniform_layer() -> void:
	step("Given a flat plate and the Grow tool with no falloff", func():
		_view("top")
		for x in range(-4, 5):
			for z in range(-4, 5):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.radius = 2
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
		for entry in SculptGeometry.disk_offsets(2):
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
		for entry in SculptGeometry.disk_offsets(2):
			if _column_height(Vector3i(entry["u"], 0, entry["v"]), 1, 1, 0) != 5:
				uniform = false
		expect(uniform, "repeated presses keep a uniform depth")
	)


func _grow_uniform_oblique() -> void:
	step("Given a gentle staircase and the Grow tool with no falloff", func():
		_view("top")
		for x in range(0, 10):
			for y in range(0, x / 2 + 1):
				for z in range(-4, 5):
					frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		split_cells = _cell_colors(frame)
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.radius = 2
		_settings.falloff = 0.0
		_settings.strength = 1.0
		press = _pos(Vector3(4.0, 2.0, 0.0))
	)
	step("When the user presses once", func():
		_press(press)
		expect(tool._stroke_frame.fitted and tool._stroke_frame.normal.x < -0.2, "the stroke follows the staircase slope")
		grown = tool._samples.size()
		_release(press)
	)
	step("Then every footprint column gains one cell with no holes", func():
		var added := 0
		var rests_on_surface := true
		for cell in frame.positions():
			if split_cells.has(cell):
				continue
			added += 1
			if not frame.has(cell - Vector3i(0, 1, 0)):
				rests_on_surface = false
		expect(grown > 0, "the stroke has a footprint")
		expect(added == grown, "the stroke adds one cell per footprint column")
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


func _grow_steep_layer() -> void:
	step("Given a slope-two staircase and the Grow tool", func():
		_view("top")
		_steep_cells(2)
		sync_viewport()
		split_cells = _cell_colors(frame)
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.radius = 2
		_settings.falloff = 0.0
		_settings.strength = 1.0
		press = _pos(Vector3(6.0, 12.0, 0.0))
	)
	step("When the user presses once", func():
		_press(press)
		expect(tool._stroke_frame.fitted and tool._stroke_frame.normal.x < -0.5, "the stroke fits the steep slope")
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


func _grow_steep_remove() -> void:
	step("Given a slope-two staircase and the Grow tool in Remove mode", func():
		_view("top")
		_steep_cells(2)
		sync_viewport()
		split_cells = _cell_colors(frame)
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.REMOVE
		_settings.radius = 2
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


func _grow_steep_repeat() -> void:
	step("Given a slope-two staircase and the Grow tool", func():
		_view("top")
		_steep_cells(2)
		sync_viewport()
		split_cells = _cell_colors(frame)
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.radius = 2
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


func _grow_order_independent() -> void:
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


func _grow_frame_rate() -> void:
	step("Given a flat plate and the Grow tool", func():
		_view("top")
		for x in range(-4, 5):
			for z in range(-4, 5):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.radius = 2
		_settings.falloff = 0.0
		_settings.strength = 6.0
		press = _pos(Vector3.ZERO)
	)
	step("When the first stroke runs at sixty hertz for 0.8 seconds", func():
		_press(press)
		for _tick in 48:
			tool.advance_stroke(1.0 / 60.0)
		_release(press)
		split_cells = _cell_colors(frame)
	)
	step("When a second stroke runs at fifteen hertz for 0.8 seconds", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_view("top")
		for x in range(-4, 5):
			for z in range(-4, 5):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		press = _pos(Vector3.ZERO)
		_press(press)
		for _tick in 12:
			tool.advance_stroke(1.0 / 15.0)
		_release(press)
	)
	step("Then both frame rates reach the same cells", func():
		expect(_cell_colors(frame) == split_cells, "the elapsed time, not the tick count, sets the growth")
	)


func _grow_exact_boundary() -> void:
	step("Given a flat plate and the Grow tool at six steps per second", func():
		_view("top")
		for x in range(-4, 5):
			for z in range(-4, 5):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.radius = 2
		_settings.falloff = 0.0
		_settings.strength = 6.0
		press = _pos(Vector3.ZERO)
	)
	step("When the first stroke runs sixty ticks of one sixtieth", func():
		_press(press)
		for _tick in 60:
			tool.advance_stroke(1.0 / 60.0)
		_release(press)
		split_cells = _cell_colors(frame)
	)
	step("When a second stroke runs fifteen ticks of one fifteenth", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_view("top")
		for x in range(-4, 5):
			for z in range(-4, 5):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		press = _pos(Vector3.ZERO)
		_press(press)
		for _tick in 15:
			tool.advance_stroke(1.0 / 15.0)
		_release(press)
	)
	step("Then both splits apply exactly twelve layers", func():
		expect(_cell_colors(frame) == split_cells, "the exact boundary is split independent")
		expect(_column_height(Vector3i(0, 0, 0), 1, 1, 0) == 13, "the center column rises the full twelve layers plus the press layer")
	)


func _grow_falloff_bands() -> void:
	step("Given a flat plate and the Grow tool with falloff", func():
		_view("top")
		for x in range(-5, 6):
			for z in range(-5, 6):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.radius = 4
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
		for entry in SculptGeometry.disk_offsets(4):
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


func _grow_progress_retained() -> void:
	step("Given a Grow stroke with a partial influence", func():
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.radius = 1
		_settings.falloff = 0.0
		_settings.strength = 1.0
		_view("top")
		press = _pos(Vector3.ZERO)
		target = aim(press).target
		_press(press)
		tool.advance_stroke(0.4)
		expect(_column_height(target, 1, 1, 0) == 1, "the partial influence adds no voxel yet")
	)
	step("When the user leaves and returns", func():
		var far := _pos(Vector3(8.0, 0.0, 0.0))
		_motion(far, far - press)
		_motion(press, press - far)
	)
	step("Then the revisited sample keeps its progress", func():
		var best := 0.0
		for value in tool._progress.values():
			best = maxf(best, float(value))
		expect(best > 0.3, "the revisited column keeps its fractional progress")
	)


func _grow_deep_tower() -> void:
	step("Given the Grow tool in Add mode on an empty floor", func():
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
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
		expect(frame.count() == height * 5, "every footprint sample grows the same clean column")
	)
	step("Given a tall tower and the Grow tool in Remove mode", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_view("top")
		anchor = aim(_pos(Vector3.ZERO)).target
		for y in range(0, 40):
			frame.set_cell(anchor + Vector3i(0, y, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		camera_rig().center_on(AABB(Vector3(-2, -2, -2), Vector3(4, 50, 4)))
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.REMOVE
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
		_settings.radius = 4
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
		expect(tool._stroke_frame.origin.y > 4.0, "the fitted plane sits on the pressed face")
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


# --- Fitted plane -----------------------------------------------------------

func _fit_slope() -> void:
	step("Given a ramp that rises two cells per step", func():
		_view("top")
		_fill_ramp(5, 2, -2, 2)
		sync_viewport()
		_settings.tool = _settings.Tools.GROW
		_settings.radius = 2
		_settings.falloff = 0.0
		_settings.strength = 10.0
		press = _pos(Vector3(2.0, 4.0, 0.0))
		anchor = aim(press).target
		expect(anchor == Vector3i(2, 4, 0), "the press lands on the ramp top")
	)
	step("When the user presses the ramp", func():
		_press(press)
	)
	step("Then the fitted plane follows the slope and is not cardinal", func():
		expect(tool._stroke_frame.fitted, "the plane is fitted, not a cube face")
		expect(tool._stroke_frame.normal.x < -0.5, "the fitted normal tilts along the slope")
		expect(absf(tool._stroke_frame.normal.y) > 0.3, "the fitted normal still faces outward")
		expect(SculptGeometry.next_cell(anchor, tool._stroke_frame.normal) == Vector3i(1, 4, 0), "the normal steps down the slope")
		_release(press)
	)


func _fit_planar() -> void:
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
	step("Then the fitted normal is the plate normal", func():
		expect(tool._stroke_frame.fitted, "the plane is fitted")
		expect(tool._stroke_frame.normal.dot(Vector3.UP) > 0.99, "the fitted normal is the plate normal")
		_release(press)
	)


func _fit_degenerate() -> void:
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
		expect(not tool._stroke_frame.fitted, "a single voxel falls back")
		expect(tool._stroke_frame.normal == Vector3.UP, "the fallback uses the clicked face normal")
		_release(press)
	)


func _fit_noise() -> void:
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
	step("Then the fit stays near the plate normal", func():
		expect(tool._stroke_frame.fitted, "the plane is fitted")
		expect(tool._stroke_frame.normal.dot(Vector3.UP) > 0.9, "the stray voxel does not tilt the fit")
		_release(press)
	)


func _fit_opposing() -> void:
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
	step("Then the walls do not tilt the fit", func():
		expect(tool._stroke_frame.fitted, "the plane is fitted")
		expect(tool._stroke_frame.normal.dot(Vector3.UP) > 0.9, "the opposing walls stay out of the fit")
		_release(press)
	)


# The channel floor is three cells wide. A one-cell floor gives only collinear
# height samples, so the gradient is undefined and the frame falls back. The
# wider floor gives a real fit and still tests the symmetric walls.
func _fit_collinear() -> void:
	step("Given a one-cell-wide strip", func():
		var strip := VoxelFrame.new()
		for z in range(-4, 5):
			strip.set_cell(Vector3i(0, 0, z), VoxelFrame.material(Color.WHITE))
		var points := SculptGeometry.surface_points(strip, Vector3i.ZERO, Vector3i(0, 1, 0), 3)
		expect(points.size() >= 3, "the strip supplies several height samples")
		expect(not SculptGeometry.fit_surface_gradient(points, Vector3.UP)["ok"], "collinear heights cannot define a gradient")
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
		var fit := SculptGeometry.fit_surface_gradient(points, Vector3.UP)
		expect(fit["ok"], "the known plane fits")
		var normal: Vector3 = fit["normal"]
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
		var normal: Vector3 = SculptGeometry.fit_surface_gradient(points, Vector3.UP)["normal"]
		expect(normal.x > 0.0 and normal.z < 0.0, "each slope sign flips its normal component")
	)


func _gradient_full_disc() -> void:
	step("Given a wide flat plate", func():
		var plate := VoxelFrame.new()
		for x in range(-6, 7):
			for z in range(-6, 7):
				plate.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		expect(SculptGeometry.surface_points(plate, Vector3i.ZERO, Vector3i(0, 1, 0), 2).size() == 13, "a radius 2 disc samples its 13 columns")
		expect(SculptGeometry.surface_points(plate, Vector3i.ZERO, Vector3i(0, 1, 0), 5).size() == 81, "a radius 5 disc samples its 81 columns")
	)
	step("Given a plate that stays flat inside radius 3 and rises beyond it", func():
		var ground := VoxelFrame.new()
		for x in range(-3, 4):
			for z in range(-6, 7):
				ground.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		for x in range(4, 7):
			for y in range(0, 4 * (x - 3)):
				for z in range(-6, 7):
					ground.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.WHITE))
		var near := SculptGeometry.fit_surface_gradient(SculptGeometry.surface_points(ground, Vector3i.ZERO, Vector3i(0, 1, 0), 3), Vector3.UP)
		var far := SculptGeometry.fit_surface_gradient(SculptGeometry.surface_points(ground, Vector3i.ZERO, Vector3i(0, 1, 0), 5), Vector3.UP)
		expect(near["ok"] and far["ok"], "both fits succeed")
		expect(absf((near["normal"] as Vector3).x) < 0.02, "the radius 3 fit stays flat")
		expect((far["normal"] as Vector3).x < -0.2, "the radius 5 fit follows the rise beyond radius 3")
	)


func _grow_slope() -> void:
	step("Given a ramp and the Grow tool", func():
		_view("top")
		_fill_ramp(5, 2, -2, 2)
		sync_viewport()
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.radius = 1
		_settings.falloff = 0.0
		_settings.strength = 20.0
		press = _pos(Vector3(2.0, 4.0, 0.0))
	)
	step("When the user grows the slope", func():
		_press(press)
		expect(tool._stroke_frame.fitted, "the stroke uses the fitted plane")
		tool.advance_stroke(0.2)
		_release(press)
	)
	step("Then the growth follows the fitted normal down the slope", func():
		expect(frame.has(Vector3i(1, 4, 0)), "the added voxel steps along the fitted normal")
	)


func _oblique_steps() -> void:
	step("Given an oblique ray through one voxel", func():
		var origin := Vector3.ZERO
		var normal := Vector3(-2.0, 1.0, 0.0).normalized()
		var path := SculptGeometry.march_cells(origin, normal, 12)
		var cell := path[0]
		var matches := true
		for index in range(1, path.size()):
			cell = SculptGeometry.next_cell(cell, normal, origin)
			matches = matches and cell == path[index]
		expect(matches, "successive steps match one continuous oblique ray")
		expect(cell.x < -4 and cell.y > 2, "growth advances on both slope axes")
	)
	step("When a sculpt job grows several layers", func():
		var job = tool.get_script().SculptTickJob.new()
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
			var path := SculptGeometry.march_cells(origin, direction, 16)
			var cell := path[0]
			var matches := true
			for index in range(1, path.size()):
				cell = SculptGeometry.next_cell(cell, direction, origin)
				matches = matches and cell == path[index]
			expect(matches, "the stepped cells match one ray for %v" % direction)
	)
	step("Given a fixed ray origin away from a cell center", func():
		var origin := Vector3(0.25, 0.25, 0.25)
		var direction := Vector3(-2.0, 1.0, 0.0).normalized()
		var path := SculptGeometry.march_cells(origin, direction, 12)
		var cell := path[0]
		for index in range(1, path.size()):
			cell = SculptGeometry.next_cell(cell, direction, origin)
		expect(cell == path[path.size() - 1], "the fixed origin keeps the ray coherent")
	)


func _flatten_slope() -> void:
	step("Given a ramp with a bump on its surface", func():
		_view("top")
		_fill_ramp(5, 2, -2, 2)
		frame.set_cell(Vector3i(2, 5, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.FLATTEN
		_settings.radius = 2
		_settings.falloff = 0.0
		_settings.strength = 30.0
		press = _pos(Vector3(3.0, 6.0, 0.0))
	)
	step("When the user flattens the slope", func():
		_press(press)
		expect(tool._stroke_frame.fitted, "the flatten uses the fitted plane")
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then the bump is cut toward the fitted plane", func():
		expect(not frame.has(Vector3i(2, 5, 0)), "the bump above the fitted plane is removed")
	)


func _flatten_converges() -> void:
	step("Given a ramp with a tall bump and the Flatten tool", func():
		_view("top")
		_fill_ramp(6, 2, -2, 2)
		for y in range(5, 9):
			frame.set_cell(Vector3i(2, y, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.FLATTEN
		_settings.radius = 2
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


func _fit_symmetry() -> void:
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
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.radius = 1
		_settings.falloff = 0.0
		_settings.strength = 20.0
		press = _pos(Vector3(2.0, 6.0, 0.0))
		split_cells = _cell_colors(frame)
	)
	step("When the user grows the slope", func():
		_press(press)
		expect(tool._stroke_frame.fitted, "the stroke uses the fitted plane")
		tool.advance_stroke(0.2)
		_release(press)
	)
	step("Then the mirrored slope grows along its own fitted normal", func():
		var added := 0
		var mirrored := true
		for cell in frame.positions():
			if split_cells.has(cell):
				continue
			added += 1
			mirrored = mirrored and frame.has(Vector3i(-1 - cell.x, cell.y, cell.z))
		expect(added > 0, "the fitted slope gains voxels")
		expect(mirrored, "every added voxel has its reflected counterpart")
	)


# --- Grab -------------------------------------------------------------------

func _grab_oblique() -> void:
	step("Given a voxel seen from an isometric view", func():
		_settings.tool = _settings.Tools.GRAB
		_settings.radius = 2
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
		_settings.radius = 4
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
		_settings.radius = 4
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
		_settings.radius = 12
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


func _grab_pending_return() -> void:
	step("Given a wide plate and a far worker drag", func():
		_settings.tool = _settings.Tools.GRAB
		_settings.radius = 12
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
		_settings.radius = 12
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
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
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
		activate_tool("sculpt")
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
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
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
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
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
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.radius = 2
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
		_settings.radius = 3
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
		_settings.radius = 3
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
		_settings.radius = 3
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
		_settings.radius = 3
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
		var options: Control = plugin("SculptPlugin")._options
		var toolbar: MenuButton = plugin("SculptPlugin")._toolbar
		_settings.tool = _settings.Tools.SMOOTH
		expect(options.get_node("Radius").max_value == 32.0, "the radius control shows the full bound")
		expect(options.get_node("Strength").visible, "the strength control is visible for Smooth")
		expect(not options.get_node("Grow").visible, "Smooth has no grow direction")
		var popup := toolbar.get_popup()
		expect(popup.item_count == 4, "the sculpt menu holds four tools")
		expect(
			popup.get_item_text(0) == "Grow" and popup.get_item_text(1) == "Flatten"
			and popup.get_item_text(2) == "Smooth" and popup.get_item_text(3) == "Grab",
			"the menu order is Grow, Flatten, Smooth, Grab"
		)
		expect(popup.get_item_id(2) == 3, "the Smooth item keeps its append-only id")
		expect(popup.get_item_id(3) == 2, "the Grab item keeps its append-only id")
	)
	step("When the user selects the menu entries by index", func():
		var toolbar: MenuButton = plugin("SculptPlugin")._toolbar
		toolbar.get_popup().index_pressed.emit(2)
		expect(_settings.tool == _settings.Tools.SMOOTH, "the third entry selects Smooth")
		toolbar.get_popup().index_pressed.emit(3)
		expect(_settings.tool == _settings.Tools.GRAB, "the fourth entry selects Grab")
		toolbar.get_popup().index_pressed.emit(0)
		expect(_settings.tool == _settings.Tools.GROW, "the first entry selects Grow")
	)


func _smooth_history() -> void:
	step("Given a spike and the Smooth tool", func():
		_view("top")
		_flat_plate(4)
		for y in range(1, 5):
			frame.set_cell(Vector3i(0, y, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 3
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
		activate_tool("sculpt")
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


func _smooth_preview() -> void:
	step("Given a plate with the Smooth tool", func():
		_view("top")
		_flat_plate(4)
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 2
		_settings.falloff = 0.0
		press = _pos(Vector3.ZERO)
	)
	step("When the user hovers", func():
		_hover(press)
		tool._rebuild_preview()
	)
	await _settle_preview()
	step("Then the wireframe outlines only occupied surface voxels", func():
		expect(not tool._preview_cells.is_empty(), "the preview outlines the surface")
		var empty := 0
		for cell in tool._preview_cells:
			if not frame.has(cell):
				empty += 1
		expect(empty == 0, "Smooth never outlines an empty seed")
	)
	step("When the selection covers one support", func():
		State.selection.clear()
		State.selection.add(Vector3i(0, 0, 0))
		State.selection_changed.emit()
		_hover(press)
		tool._rebuild_preview()
	)
	await _settle_preview()
	step("Then the preview outlines only the allowed support", func():
		expect(tool._preview_cells.has(Vector3i(0, 0, 0)), "the allowed support is outlined")
		expect(tool._preview_cells.size() == 1, "an unallowed support is hidden")
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
		_settings.radius = 3
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
		for y in range(1, 7):
			frame.set_cell(Vector3i(0, y, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		grown = frame.count()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 3
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3i(1, 0, 0))
	)
	await step("When the user hovers and then presses beside the spike", func():
		_hover(press)
		tool._rebuild_preview()
		await _settle_preview()
		var before: Vector3 = tool._hover_frame.normal
		_press(press)
		var after: Vector3 = tool._stroke_frame.normal
		split_cells = {"before": before, "after": after}
		_release(press)
	)
	step("Then the fitted plane follows the changed surface without a flip", func():
		var before: Vector3 = split_cells["before"]
		var after: Vector3 = split_cells["after"]
		expect(_column_height(Vector3i(0, 0, 0), 1, 1, 0) < 7, "the spike lowers")
		expect(not after.is_equal_approx(before), "the plane follows the changed local gradient")
		expect(after.y > 0.0 and before.y > 0.0, "the outward orientation never flips")
	)
	step("Then the adaptation adds no extra history", func():
		expect(State.undo_redo.has_undo(), "the stroke records one action")
		State.undo_redo.undo()
		expect(frame.count() == grown, "one undo restores the whole stroke")
	)


func _smooth_carry() -> void:
	step("Given a spike and the Smooth tool at eight passes per second", func():
		_view("top")
		_flat_plate(4)
		for y in range(1, 5):
			frame.set_cell(Vector3i(0, y, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 3
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3(0.0, 4.0, 0.0))
	)
	step("When the user holds for a fraction of a pass", func():
		_press(press)
		tool.advance_stroke(0.06)
		expect(tool._smooth_fields[0]["carry"] > 0.4 and tool._smooth_fields[0]["carry"] < 0.5, "the sub-pass time is kept")
	)
	step("When the user holds for another fraction", func():
		tool.advance_stroke(0.06)
		expect(tool._smooth_fields[0]["carry"] > 0.9, "the carry accumulates across calls")
	)
	step("When the total reaches a pass", func():
		tool.advance_stroke(0.02)
		expect(tool._smooth_fields[0]["carry"] < 0.2, "the pass consumes the carry")
		_release(press)
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
		_settings.radius = 3
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
		_settings.radius = 3
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
		_settings.radius = 3
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
			_settings.radius = 3
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
		_settings.radius = 3
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


func _smooth_refit_stable() -> void:
	step("Given an unchanged ramp and the Smooth tool", func():
		_view("top")
		for x in range(0, 13):
			for y in range(0, x + 1):
				for z in range(-4, 5):
					frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 2
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3i(6, 6, 0))
	)
	step("When the plane re-fits a hundred times on the unchanged ramp", func():
		_press(press)
		var first: Vector3 = tool._stroke_frame.normal
		var drift := 0.0
		for _index in 100:
			tool._refit_smooth_frame()
			drift = maxf(drift, first.angle_to(tool._stroke_frame.normal))
		split_cells = {"first": first, "drift": drift}
		_release(press)
	)
	step("Then the normal is constant within tolerance", func():
		expect(split_cells["drift"] < 0.01, "repeated refits of an unchanged ramp do not drift")
	)


func _smooth_reentrant() -> void:
	step("Given a spike and the Smooth tool", func():
		_view("top")
		_flat_plate(4)
		for y in range(1, 5):
			frame.set_cell(Vector3i(0, y, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 3
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
	step("Then the swap discards the stroke without a stale refit", func():
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
		_settings.radius = 3
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
		_settings.radius = 3
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
		_settings.radius = 3
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
		_settings.radius = 3
		_settings.falloff = 0.0
		_settings.strength = 8.0
		press = _pos(Vector3(4.0, 0.0, 4.0))
	)
	step("When the user holds on the vertical edge", func():
		_press(press)
		expect(absf(tool._stroke_frame.normal.x) > 0.5, "the fitted normal points outward on the side")
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
		_settings.radius = 3
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
		_settings.radius = 5
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
		expect(not frame.has(Vector3i(-4, 6, 0)), "the convex step corner rounds away")
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
		_settings.radius = 3
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
		_settings.radius = 3
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
		_settings.radius = 6
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
		expect(int(split_cells["edge"]) == 5, "the soft edge spike barely moves in one hold")
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
		_settings.radius = 6
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
		job.fields = [{"cells": cells, "weights": {}, "credits": {}, "carry": 0.0}]
		job.seconds = 1.0
		job.rate = 8.0
		job.radius = 1
		job.cancel()
		var before := frame.count()
		job.run()
		split_cells = {
			"cancelled": job.cancelled,
			"carries": job.carries.size(),
			"credits": job.credits.size(),
			"chunks": job.changed_chunks.size(),
			"before": before,
			"after": frame.count(),
		}
	)
	step("Then the cancelled job computes and publishes nothing", func():
		expect(split_cells["cancelled"], "the job reports its cancellation")
		expect(int(split_cells["carries"]) == 0, "the cancelled job ran no field")
		expect(int(split_cells["credits"]) == 0, "the cancelled job stored no credit")
		expect(int(split_cells["chunks"]) == 0, "the cancelled job published no chunk")
		expect(int(split_cells["after"]) == int(split_cells["before"]), "the cancelled job wrote no cell")
	)


# --- Flatten materials ------------------------------------------------------

func _flatten_materials() -> void:
	step("Given columns of different materials below one flat target", func():
		_settings.tool = _settings.Tools.FLATTEN
		_settings.radius = 4
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
		_settings.radius = 3
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
		_settings.radius = 4
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

func _preview_ghost() -> void:
	step("Given a flat plate with the Grow tool in Add mode", func():
		_view("top")
		for x in range(-3, 4):
			for z in range(-3, 4):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.radius = 2
		_settings.falloff = 0.0
		press = _pos(Vector3.ZERO)
	)
	step("When the user hovers over the plate", func():
		_hover(press)
		tool._rebuild_preview()
	)
	await _settle_preview()
	step("Then the wireframe outlines every supporting surface voxel", func():
		var expected := {}
		for entry in SculptGeometry.disk_offsets(2):
			expected[Vector3i(entry["v"], 0, entry["u"])] = true
		expect(_same_cells(tool._preview_cells, expected), "the outline marks every support voxel")
		expect(not tool._preview_cells.has(Vector3i(0, 1, 0)), "an empty cell above the plate is not outlined")
	)
	step("When the user switches to Remove", func():
		_settings.grow_mode = _settings.GrowMode.REMOVE
		_hover(press)
		tool._rebuild_preview()
	)
	await _settle_preview()
	step("Then the preview outlines the occupied removal targets", func():
		expect(tool._preview_cells.has(Vector3i(0, 0, 0)), "the surface voxel is a removal target")
		expect(not tool._preview_cells.has(Vector3i(0, 1, 0)), "an empty cell is not a removal target")
	)


func _preview_ghost_oblique() -> void:
	step("Given a two-level step with the Grow tool in Add mode", func():
		_view("top")
		for x in range(-4, 1):
			for z in range(-2, 3):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		for x in range(1, 5):
			for z in range(-2, 3):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
				frame.set_cell(Vector3i(x, 1, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.radius = 3
		_settings.falloff = 0.0
		press = _pos(Vector3.ZERO)
	)
	step("When the user hovers over the step edge", func():
		_hover(press)
		tool._rebuild_preview()
	)
	await _settle_preview()
	step("Then the outline follows the uneven surface", func():
		expect(tool._hover_frame != null and tool._hover_frame.fitted, "the hover fits the step surface")
		expect(not tool._preview_cells.is_empty(), "the preview outlines a support region")
		var lower := 0
		var upper := 0
		var occupied_ok := true
		for cell in tool._preview_cells:
			if not frame.has(cell):
				occupied_ok = false
			if cell.y == 0:
				lower += 1
			if cell.y == 1:
				upper += 1
		expect(occupied_ok, "every outlined cell is an occupied support")
		expect(lower > 0 and upper > 0, "the outline follows both terraces, not one flat layer")
	)


func _preview_selection_destination() -> void:
	step("Given a flat plate with the selection over one destination cell", func():
		_view("top")
		for x in range(-3, 4):
			for z in range(-3, 4):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.radius = 2
		_settings.falloff = 0.0
		press = _pos(Vector3.ZERO)
		State.selection.clear()
		State.selection.add(Vector3i(0, 1, 0))
		State.selection_changed.emit()
	)
	step("When the user hovers", func():
		_hover(press)
		tool._rebuild_preview()
	)
	await _settle_preview()
	step("Then only the support of the allowed destination is outlined", func():
		expect(tool._preview_cells.has(Vector3i(0, 0, 0)), "the support of the allowed destination is outlined")
		expect(tool._preview_cells.size() == 1, "the supports of the blocked destinations are hidden")
		expect(not tool._preview_cells.has(Vector3i(0, 1, 0)), "the empty destination cell is never outlined")
	)


func _preview_refresh() -> void:
	await step("Given a flat plate and a radius 1 hover", func():
		_view("top")
		for x in range(-3, 4):
			for z in range(-3, 4):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.radius = 1
		_settings.falloff = 0.0
		press = _pos(Vector3.ZERO)
		_hover(press)
		tool._rebuild_preview()
		await _settle_preview()
		grown = tool._preview_cells.size()
		expect(grown == 5, "a radius 1 outline marks five support voxels")
	)
	step("When a voxel appears above the center", func():
		frame.set_cell(Vector3i(0, 1, 0), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_hover(press)
		tool._rebuild_preview()
	)
	await _settle_preview()
	step("Then the outline follows the new top", func():
		expect(tool._preview_cells.has(Vector3i(0, 1, 0)), "the new top is outlined")
		expect(not tool._preview_cells.has(Vector3i(0, 0, 0)), "the buried cell is no longer the support")
	)
	step("When the user widens the radius", func():
		_settings.radius = 3
		_hover(press)
		tool._rebuild_preview()
	)
	await _settle_preview()
	step("Then the outline grows with the settings", func():
		expect(tool._preview_cells.size() > grown, "the wider radius outlines more support voxels")
	)


func _grab_preview_sources() -> void:
	step("Given a plate with the Grab tool", func():
		_settings.tool = _settings.Tools.GRAB
		_settings.radius = 2
		_settings.falloff = 0.0
		_view("top")
		for x in range(-4, 5):
			for z in range(-4, 5):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		press = _pos(Vector3.ZERO)
	)
	step("When the user hovers", func():
		_hover(press)
		tool._rebuild_preview()
	)
	await _settle_preview()
	step("Then the preview shows only occupied eligible sources", func():
		expect(not tool._preview_cells.is_empty(), "the preview shows the source region")
		var empty := 0
		for cell in tool._preview_cells:
			if not frame.has(cell):
				empty += 1
		expect(empty == 0, "an empty cell is never a grab source")
	)
	step("Given the X symmetry plane", func():
		State.symmetry_axes = 1
		State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
		_hover(press)
		tool._rebuild_preview()
	)
	await _settle_preview()
	step("Then the mirrored sources appear", func():
		expect(tool._preview_cells.has(Vector3i(0, 0, 0)), "the pressed side is a source")
		expect(tool._preview_cells.has(Vector3i(-1, 0, 0)), "the mirrored side is a source")
	)


func _grab_controls() -> void:
	step("Given the Grab tool with a wide radius", func():
		var options: Control = plugin("SculptPlugin")._options
		_settings.tool = _settings.Tools.GRAB
		_settings.radius = 32
		expect(_settings.radius == 12, "the Grab radius clamps to the effective bound")
		expect(options.get_node("Radius").max_value == 12.0, "the radius control shows the Grab bound")
		expect(not options.get_node("Strength").visible, "the strength control is hidden for Grab")
	)
	step("When the user switches back to Grow", func():
		var options: Control = plugin("SculptPlugin")._options
		_settings.tool = _settings.Tools.GROW
		expect(options.get_node("Radius").max_value == 32.0, "the radius control shows the full bound")
		expect(options.get_node("Strength").visible, "the strength control returns for Grow")
	)


# --- Movement applications --------------------------------------------------

# A solid block with a two-cell spike, so Grow, Flatten, and Smooth all change
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
func _grow_plate() -> void:
	for x in range(-4, 5):
		for z in range(-4, 5):
			frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
	sync_viewport()


func _strength_per_application() -> void:
	step("Given a flat plate and the Grow tool at strength one", func():
		_view("top")
		_grow_plate()
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.radius = 2
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
		for entry in SculptGeometry.disk_offsets(2):
			if _column_height(Vector3i(entry["u"], 0, entry["v"]), 1, 1, 0) != 2:
				uniform = false
		expect(uniform, "strength one applies one layer per application")
	)
	step("Given a fresh plate and the Grow tool at strength three", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		_view("top")
		_grow_plate()
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.radius = 2
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
		for entry in SculptGeometry.disk_offsets(2):
			if _column_height(Vector3i(entry["u"], 0, entry["v"]), 1, 1, 0) != 4:
				uniform = false
		expect(uniform, "strength three applies three layers per application")
	)


func _falloff_fractional() -> void:
	step("Given a flat plate and the Grow tool with a soft edge", func():
		_view("top")
		_grow_plate()
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.radius = 4
		_settings.falloff = 0.5
		_settings.strength = 1.0
		press = _pos(Vector3.ZERO)
	)
	step("When the user presses once", func():
		_press(press)
		expect(_column_height(Vector3i(0, 0, 0), 1, 1, 0) == 2, "the hard center gains one layer")
		expect(_column_height(Vector3i(3, 0, 0), 1, 1, 0) == 1, "the soft edge keeps a fractional influence")
	)
	step("When the user applies one more application at the same cell", func():
		tool.advance_stroke(1.0)
		_release(press)
	)
	step("Then the carried influence raises the edge", func():
		expect(_column_height(Vector3i(3, 0, 0), 1, 1, 0) == 2, "two applications complete the edge layer")
		expect(_column_height(Vector3i(0, 0, 0), 1, 1, 0) == 3, "the hard center gains one layer per application")
	)


func _stationary_no_repeat() -> void:
	for operator in [_settings.Tools.GROW, _settings.Tools.FLATTEN, _settings.Tools.SMOOTH]:
		step("Given a spike block and operator %d" % operator, func():
			State.document = VoxelDocument.new()
			frame = State.get_current_voxel_frame()
			_view("top")
			_spike_block()
			_settings.tool = operator
			_settings.radius = 3
			_settings.falloff = 0.0
			_settings.strength = 1.0
			press = _pos(Vector3i(-2, 2, -2))
			_press(press)
			split_cells = _cell_materials(frame)
		)
		step("When the frame loop runs with large deltas and duplicate motions", func():
			for _tick in 8:
				tool._process(0.5)
			tool._process(10.0)
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
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.radius = 32
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
	step("Given a wide plate and a heavy Grow stroke on the worker pool", func():
		_view("top")
		for x in range(-40, 41):
			for z in range(-40, 41):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.WHITE))
		sync_viewport()
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
		_settings.radius = 32
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
		_settings.radius = 2
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
		expect(after.y > 0.9, "the flat top refits the plane")
		expect(after.y > 0.0 and before.y > 0.0, "the outward orientation never flips")
	)


# Draws the same six-cell Grow path with a fixed number of frame waits per cell.
# A coalesced path delivers the whole segment as one motion.
func _draw_grow_path(waits: int, coalesced: bool) -> void:
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
	step("Given a replay of the same Grow path at three frame counts", func():
		split_cells = {}
	)
	for entry in [[0, false], [1, false], [4, false], [0, true]]:
		var waits: int = entry[0]
		var coalesced: bool = entry[1]
		var key := "%d:%s" % [waits, str(coalesced)]
		step("Given a fresh floor and a Grow path with %d waits and coalesced=%s" % [waits, str(coalesced)], func():
			State.document = VoxelDocument.new()
			frame = State.get_current_voxel_frame()
			_view("top")
			_settings.tool = _settings.Tools.GROW
			_settings.grow_mode = _settings.GrowMode.ADD
			_settings.radius = 2
			_settings.falloff = 0.0
			_settings.strength = 1.0
			press = _pos(Vector3.ZERO)
		)
		step("When the user draws the same polyline", func():
			await _draw_grow_path(waits, coalesced)
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
			var path = tool.get_script().DabPath.new(segment[0], segment[1])
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
		var path = tool.get_script().DabPath.new(Vector3i(0, 1, 0), Vector3i(6000, 1, 0))
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
	step("Given an empty floor and a long Grow drag", func():
		_view("top")
		_settings.tool = _settings.Tools.GROW
		_settings.grow_mode = _settings.GrowMode.ADD
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
		_settings.radius = 2
		_settings.falloff = 0.0
		_settings.strength = 2.0
		press = _pos(Vector3i(3, 3, 0))
	)
	step("When the press applies and the first motion repeats the press position", func():
		_press(press)
		split_cells = _cell_materials(frame)
		_motion(press, Vector2.ZERO)
	)
	step("Then the refit plane cannot add a dab", func():
		expect(_cell_materials(frame) == split_cells, "a first motion at the press position adds no dab")
		_release(press)
	)


func _smooth_slope_replay() -> void:
	step("Given a 45 degree staircase and the Smooth tool", func():
		_view("top")
		_staircase()
		sync_viewport()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 5
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
		expect((split_cells["rise"] as Vector3).y > 0.0 and (split_cells["fall"] as Vector3).y > 0.0, "the refit stays outward")
		expect(not frame.has(Vector3i(-4, 6, 0)), "the step corner rounds away")
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
# cells in x, so the fitted normal is 45 degrees with both signs.
func _staircase() -> void:
	for x in range(-9, 10):
		var top := -3 * floori(float(x) / 3.0)
		for y in range(-9, top + 1):
			for z in range(-4, 5):
				frame.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.WHITE))
