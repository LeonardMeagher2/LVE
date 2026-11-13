extends "res://tests/test.gd"

# One fixed white ring is the whole terrain cursor. Every tool poses it with its
# own radius. It snaps to cell centers, steps whole cells, and stays neutral
# white in every state.

const ProbeScript := preload("./terrain_stroke_input_probe.gd")

var _settings := preload("res://plugins/Terrain/settings.tres")
var _viewport: SubViewport
var _tool
var _frame: VoxelFrame


func _ready() -> void:
	timeout = 30.0
	test("every tool poses the one white ring with its own radius", _ring_per_tool, "ring_per_tool")
	test("the ring snaps to cell centers and steps whole cells", _snapped_pose, "snapped_pose")
	test("a press keeps one white ring through every state", _press_states, "press_states")
	test("a motion runs no job and caches the ring per radius", _motion_cache, "motion_cache")
	test("a document change hides the ring at once", _document_change, "document_change")
	test("the ring shows the orientation the press will use", _hover_orientation, "hover_orientation")
	test("the ring of an empty floor lies on the floor grid", _empty_floor_pose, "empty_floor_pose")
	test("the Smooth ring stays on the cell under the pointer", _smooth_ring_follows, "smooth_ring_follows")
	test("a move inside one voxel keeps one ring pose", _steady_hover, "steady_hover")


func before_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = 0
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	State._apply_material(VoxelFrame.material(Color.CYAN))
	_settings.tool = _settings.Tools.BUILD
	_settings.build_mode = _settings.BuildMode.ADD
	_settings.radius = 9
	_settings.strength = 1.0
	_settings.falloff = 0.5
	_viewport = editor_viewport()
	_viewport.get_parent().stretch = false
	_viewport.size = Vector2i(800, 500)
	activate_tool("terrain")
	var terrain := plugin("TerrainPlugin")
	terrain.activate_tool()
	terrain.deactivate_tool()
	_tool = preload("res://plugins/Terrain/TerrainTool.tscn").instantiate()
	_tool.set_script(ProbeScript)
	if _tool._settings == null:
		_tool._settings = _settings
	terrain.add_editor_node(_tool)
	_tool.set_process(true)
	_frame = State.get_current_voxel_frame()
	camera_rig().is_orthogonal = true
	camera_rig().set_view("top")
	await get_tree().process_frame


func after_test() -> void:
	if is_instance_valid(_tool):
		if _tool._edit != null:
			_tool.finish_on_switch()
		await _wait_idle()
		plugin("TerrainPlugin").remove_editor_node(_tool)
		_tool.free()
	_tool = null


# --- Fixtures and input -------------------------------------------------------

# A wide flat plate on the floor plane.
func _plate() -> void:
	State.document = VoxelDocument.new()
	_frame = State.get_current_voxel_frame()
	var changes := {}
	var material := VoxelFrame.material(Color.WHITE)
	for x in range(-40, 41):
		for z in range(-40, 41):
			changes[Vector3i(x, 0, z)] = material
	_frame.set_cells(changes)
	sync_viewport()
	_view(AABB(Vector3(-44, -6, -44), Vector3(88, 24, 88)))
	camera_rig().set_view("top")
	camera_rig().is_orthogonal = true


# A one-step ramp. Columns with x below 2 hold one cell, and columns with x at
# or above 2 hold two. The top surface steps up one cell at the x boundary, so
# the surface read around a cell on the raised step tilts toward -x.
func _ramp() -> void:
	State.document = VoxelDocument.new()
	_frame = State.get_current_voxel_frame()
	var changes := {}
	var material := VoxelFrame.material(Color.WHITE)
	for x in range(-40, 41):
		for z in range(-40, 41):
			changes[Vector3i(x, 0, z)] = material
			if x >= 2:
				changes[Vector3i(x, 1, z)] = material
	_frame.set_cells(changes)
	sync_viewport()
	_view(AABB(Vector3(-44, -6, -44), Vector3(88, 24, 88)))


func _view(box: AABB) -> void:
	camera_rig().set_view("top")
	camera_rig().is_orthogonal = true
	camera_rig().center_on(box)


func _screen(world: Vector3) -> Vector2:
	return camera_rig().unproject_position(world)


func _button(pressed: bool, position: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.pressed = pressed
	event.position = position
	_viewport.push_input(event)


func _motion(position: Vector2, pressed := false) -> void:
	var event := InputEventMouseMotion.new()
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.position = position
	_viewport.push_input(event)


func _wait_idle() -> void:
	for _index in 1200:
		if _tool._edit == null and not _tool._busy() and not _tool._has_pending():
			await get_tree().process_frame
			return
		await get_tree().process_frame


# Waits for the idle surface read to finish. A Surface hover reads the surface on the worker pool,
# so a test waits before it reads the ring pose. The controller owns the
# surface read job, so its settled state is the wait condition.
func _wait_ring_ready() -> void:
	for _index in 1200:
		if _tool._preview == null or _tool._preview.is_settled():
			return
		await get_tree().process_frame


# --- Cases --------------------------------------------------------------------

func _ring_per_tool() -> void:
	step("Given a plate and each terrain tool in turn", func() -> void:
		_plate()
	)
	for tool_index in [_settings.Tools.BUILD, _settings.Tools.FLATTEN, _settings.Tools.SMOOTH]:
		var label := str(tool_index)
		step("When the pointer hovers the plate with tool %s" % label, func() -> void:
			_settings.tool = tool_index
			_motion(_screen(Vector3(0.25, 0.5, 0.25)))
			await get_tree().process_frame
		)
		var footprint := _tool.get_node("Footprint") as MeshInstance3D
		var material := footprint.material_override as StandardMaterial3D
		var mesh := footprint.mesh as ArrayMesh
		step("Then the ring of tool %s is the one white neutral ring" % label, func() -> void:
			expect(footprint.is_visible_in_tree(), "the ring of %s is visible" % label)
			expect(material.albedo_color == Color.WHITE, "the ring of %s keeps the fixed white color" % label)
			expect(material.no_depth_test, "the ring of %s skips the depth test" % label)
			var aabb := mesh.get_aabb()
			expect(absf(aabb.size.x - 9.0) <= 1e-6 and absf(aabb.size.y - 9.0) <= 1e-6, "the ring of %s spans its own radius" % label)
		)
		_motion(_screen(Vector3(-0.25, 0.5, -0.25)))
		await get_tree().process_frame


func _snapped_pose() -> void:
	step("Given a plate and one hover on its center cell", func() -> void:
		_plate()
		_motion(_screen(Vector3(0.25, 0.5, 0.25)))
		await get_tree().process_frame
	)
	var footprint := _tool.get_node("Footprint") as MeshInstance3D
	var origin := footprint.global_transform.origin
	step("Then the ring snaps to the top face of cell (0, 0, 0)", func() -> void:
		expect(origin.distance_to(Vector3(0.0, 0.5, 0.0)) <= 1e-3, "the ring center is the cell center on the surface")
	)
	step("When the pointer moves inside the same cell", func() -> void:
		_motion(_screen(Vector3(0.4, 0.5, 0.1)))
		await get_tree().process_frame
	)
	step("Then the pose keeps the same cell center", func() -> void:
		expect(footprint.global_transform.origin == origin, "a move inside one cell keeps the pose")
	)
	step("When the pointer crosses to the next cell", func() -> void:
		_motion(_screen(Vector3(1.25, 0.5, 0.25)))
		await get_tree().process_frame
	)
	step("Then the ring steps one whole cell", func() -> void:
		expect(footprint.global_transform.origin.distance_to(Vector3(1.0, 0.5, 0.0)) <= 1e-3, "the ring center is the next cell center")
	)


func _press_states() -> void:
	step("Given a plate, a worker press, and one white ring", func() -> void:
		_plate()
		_tool.force_worker = true
		_button(true, _screen(Vector3(0.25, 0.5, 0.25)))
		await get_tree().process_frame
	)
	var footprint := _tool.get_node("Footprint") as MeshInstance3D
	var material := footprint.material_override as StandardMaterial3D
	step("Then the pressed ring stays white", func() -> void:
		expect(footprint.is_visible_in_tree(), "the pressed ring is visible")
		expect(material.albedo_color == Color.WHITE, "the pressed ring is white")
	)
	step("When the pointer crosses another cell while the worker runs", func() -> void:
		_motion(_screen(Vector3(2.25, 0.5, 0.25)), true)
		await get_tree().process_frame
	)
	step("Then the pending ring stays white", func() -> void:
		expect(footprint.is_visible_in_tree(), "the pending ring is visible")
		expect(material.albedo_color == Color.WHITE, "the pending ring is white")
	)
	step("When the pointer releases", func() -> void:
		_button(false, _screen(Vector3(2.25, 0.5, 0.25)))
	)
	step("Then the drain finishes and the ring hides", func() -> void:
		await _wait_idle()
		expect(_tool._edit == null, "the stroke is finished")
		expect(not footprint.is_visible_in_tree(), "the finished ring is hidden")
	)


func _motion_cache() -> void:
	step("Given a plate and one size-nine hover", func() -> void:
		_plate()
		_motion(_screen(Vector3(0.25, 0.5, 0.25)))
		await get_tree().process_frame
	)
	var footprint := _tool.get_node("Footprint") as MeshInstance3D
	var mesh := footprint.mesh as ArrayMesh
	step("Then the size-nine mesh is cached", func() -> void:
		expect(is_same(_tool._footprint_meshes.get(_settings.radius), mesh), "the live mesh is the current size cache entry")
	)
	step("When the pointer crosses cells with no press", func() -> void:
		_motion(_screen(Vector3(1.25, 0.5, 0.25)))
		_motion(_screen(Vector3(2.25, 0.5, 0.25)))
		await get_tree().process_frame
	)
	step("Then no job runs and the same mesh is reused", func() -> void:
		expect(not _tool._busy(), "a motion runs no job")
		expect(_tool._edit == null, "a motion opens no stroke")
		expect(is_same(_tool.get_node("Footprint").mesh, mesh), "the mesh is reused across cells")
	)
	step("When the size grows to sixteen and the pointer hovers again", func() -> void:
		_settings.radius = 16
		_motion(_screen(Vector3(0.25, 0.5, 0.25)))
		await get_tree().process_frame
	)
	step("Then the ring uses a wider mesh for the wider size", func() -> void:
		var wide := footprint.mesh as ArrayMesh
		expect(not is_same(wide, mesh), "a new size builds a new mesh")
		expect(is_same(_tool._footprint_meshes.get(16), wide), "the size-sixteen mesh is cached")
		var aabb := wide.get_aabb()
		expect(aabb.size.x > mesh.get_aabb().size.x, "the wider size covers a wider footprint")
		expect(absf(aabb.size.x - 16.0) <= 1e-6, "the ring spans the brush size")
	)


func _empty_floor_pose() -> void:
	step("Given a small plate and a hover on the empty floor", func():
		State.document = VoxelDocument.new()
		_frame = State.get_current_voxel_frame()
		var changes := {}
		var material := VoxelFrame.material(Color.WHITE)
		for x in range(-4, 5):
			for z in range(-4, 5):
				changes[Vector3i(x, 0, z)] = material
		_frame.set_cells(changes)
		sync_viewport()
		_view(AABB(Vector3(-20, -6, -20), Vector3(40, 24, 40)))
		_motion(_screen(Vector3(10.0, 0.5, 10.0)))
	)
	await get_tree().process_frame
	await _wait_ring_ready()
	step("Then the ring lies on the floor grid, not a cell above it", func():
		var footprint := _tool.get_node("Footprint") as MeshInstance3D
		var origin := footprint.global_transform.origin
		var plane := float(State.floor_index) - 0.5
		expect(absf(origin.x - 10.0) <= 1e-3 and absf(origin.z - 10.0) <= 1e-3, "the ring center is on the empty cell")
		expect(absf(origin.y - plane) <= 1e-3, "the ring sits on the floor grid (y %.3f)" % origin.y)
	)


func _steady_hover() -> void:
	step("Given a raised step in an isometric view and one settled hover", func():
		_ramp()
		camera_rig().set_view("isometric")
		camera_rig().is_orthogonal = true
		_motion(_screen(Vector3(4.0, 1.5, 0.0)))
	)
	await get_tree().process_frame
	await _wait_ring_ready()
	var footprint := _tool.get_node("Footprint") as MeshInstance3D
	var pose := footprint.global_transform
	var hit: Vector3i = _tool._last_pick.hit
	step("When the pointer moves inside the same voxel", func():
		for point in [Vector3(3.8, 1.5, -0.2), Vector3(4.2, 1.5, 0.2), Vector3(4.1, 1.5, -0.3), Vector3(3.9, 1.5, 0.1)]:
			_motion(_screen(point))
	)
	await get_tree().process_frame
	await _wait_ring_ready()
	step("Then the ring keeps one pose", func():
		expect(_tool._last_pick.hit == hit, "the pointer stays on the same voxel")
		expect(footprint.global_transform.is_equal_approx(pose), "the ring keeps one pose inside the cell")
	)


func _smooth_ring_follows() -> void:
	step("Given a step ramp and the Smooth tool", func():
		_ramp()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.radius = 9
	)
	step("When the user drags the Smooth brush up the step", func():
		_button(true, _screen(Vector3(0.0, 0.5, 0.0)))
		_motion(_screen(Vector3(6.0, 1.5, 0.0)), true)
	)
	for _index in 600:
		if not _tool._has_pending():
			break
		await get_tree().process_frame
	var footprint := _tool.get_node("Footprint") as MeshInstance3D
	step("Then the ring stays on the cell under the pointer", func():
		var pick = _tool._last_pick
		var normal := footprint.global_transform.basis.z
		expect(pick.hit != VoxelPicking.NONE, "the drag resolved a hit")
		expect(footprint.global_transform.origin.distance_to(Vector3(pick.hit) + normal * 0.5) <= 1e-3, "the ring center is the hovered cell")
		_button(false, _screen(Vector3(6.0, 1.5, 0.0)))
	)
	await _wait_ring_ready()


func _document_change() -> void:
	step("Given a plate and one visible ring", func() -> void:
		_plate()
		_motion(_screen(Vector3(0.25, 0.5, 0.25)))
	)
	# The Surface hover reads the surface on the worker pool, so wait for the pose
	# before the document change.
	await get_tree().process_frame
	await _wait_ring_ready()
	var footprint := _tool.get_node("Footprint") as MeshInstance3D
	step("Then the ring is visible", func() -> void:
		expect(footprint.is_visible_in_tree(), "the ring is visible")
	)
	step("When the document changes", func() -> void:
		var document := VoxelDocument.new()
		State.document = document
		_frame = State.get_current_voxel_frame()
		var changes := {}
		changes[Vector3i(0, 0, 0)] = VoxelFrame.material(Color.WHITE)
		_frame.set_cells(changes)
		await get_tree().process_frame
	)
	step("Then the ring hides at once", func() -> void:
		expect(not footprint.is_visible_in_tree(), "the ring hides on a document change")
	)


func _hover_orientation() -> void:
	# The picking DDA works in cell space, where a coordinate ending in 0.5
	# sits on a cell boundary. Hover the open interior of the raised step.
	var hover := Vector3(2.25, 1.5, 0.25)
	step("Given a step ramp and a hover on the raised step", func() -> void:
		_ramp()
		_motion(_screen(hover))
	)
	# The Surface hover reads the surface on the worker pool, so wait before reading the
	# ring normal.
	await get_tree().process_frame
	await _wait_ring_ready()
	var pick := aim(_screen(hover))
	var footprint := _tool.get_node("Footprint") as MeshInstance3D
	var ring_normal := footprint.global_transform.basis.z
	var expected := TerrainFrame.from_surface(
		State.get_current_voxel_frame(),
		pick.hit,
		pick.entry,
		4,
		TerrainFrame.from_face(pick.hit, pick.entry)
	)
	step("Then the ring shows the cardinal axis of the surface frame", func() -> void:
		expect(pick.hit == Vector3i(2, 1, 0), "the hover picks the raised step cell")
		expect(pick.entry == Vector3i(0, 1, 0), "the hover enters the top face")
		expect(ring_normal.is_equal_approx(TerrainFrame.cardinal(expected).normal), "the ring normal is the action axis")
		expect(ring_normal.is_equal_approx(Vector3.UP), "the ring normal is the dominant surface axis")
	)
	step("When the user presses the same point", func() -> void:
		_button(true, _screen(hover))
		await get_tree().process_frame
	)
	step("Then the stroke captures the same action axis", func() -> void:
		expect(_tool._stroke_frame != null, "the press opens a stroke frame")
		expect(_tool._stroke_frame.follows_surface, "the press frame is a surface frame")
		expect(TerrainFrame.cardinal(_tool._stroke_frame).normal.distance_to(ring_normal) < 1e-5, "the press action axis is the ring normal")
	)
	step("When the user releases the stroke", func() -> void:
		_button(false, _screen(hover))
		await _wait_idle()
	)
	step("When the pointer hovers the same point with the Face source", func() -> void:
		_settings.tool = _settings.Tools.BUILD
		_motion(_screen(hover))
		await get_tree().process_frame
	)
	step("Then the ring keeps the exact picked face", func() -> void:
		expect(footprint.is_visible_in_tree(), "the Face source ring is visible")
		expect(footprint.global_transform.basis.z == Vector3.UP, "the Face source ring keeps the picked face normal")
	)
