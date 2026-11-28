extends "res://tests/test.gd"


const TerrainGeometryScript := preload("res://plugins/Terrain/TerrainGeometry.gd")

const EXHAUSTIVE_NAME := "exhaustive"
const EXHAUSTIVE_TIMEOUT := 240.0
const HOVER_SIDE_TIMEOUT := 20.0
const MAXIMUM_NAME := "worst_case_hover"
@export var maximum_only := false
const HOVER_VIEWS := ["top", "front", "left", "right", "back"]
const HOVER_RADII := [3, 4, 5, 6, 8]
const HOVER_ANCHORS := [
	Vector3(-9.0, 4.0, 0.0),
	Vector3(-3.5, 4.0, 0.0),
	Vector3(-0.5, 4.0, 0.0),
	Vector3(0.0, 4.0, 0.0),
	Vector3(0.5, 4.0, 0.0),
	Vector3(4.0, 4.0, 0.0),
	Vector3(9.0, 4.0, 0.0),
	Vector3(0.5, 4.0, -6.0),
	Vector3(0.5, 4.0, 6.0),
]

var _settings := preload("res://plugins/Terrain/TerrainSettings.tres")
var _tool
var _frame: VoxelFrame
var _viewport: SubViewport
var _sweeps := 0
var _total_hovers := 0
var _posed := 0
var _inconsistent := 0


func _ready() -> void:
	if maximum_only or _maximum_requested():
		timeout = 240.0
		test("a maximum-radius symmetric hover over dense and sparse models stays exact", _worst_case_hover, MAXIMUM_NAME)
		return
	test("synthetic candidates keep a unique anchor and claim", _synthetic_collisions, "synthetic")
	test("a reversed order gives the same rows for non-overwriting anchors", _reversed_order, "reversed")
	test("a tilted disc on a slope keeps the ownership consistent", _tilted_disc, "tilted")
	if _exhaustive_requested():
		timeout = EXHAUSTIVE_TIMEOUT
		test("the exhaustive side hover sweep never aborts the preview", _exhaustive_hover_side, EXHAUSTIVE_NAME)
	else:
		timeout = HOVER_SIDE_TIMEOUT
		test("a hover on the side of a grown slope never aborts the preview", _hover_side, "hover_side")
	timeout = 10.0
	test("a hover reads a raw write and a signalled write", _hover_invalidation, "hover_invalidation")


func _exhaustive_requested() -> bool:
	return OS.get_cmdline_user_args().has(EXHAUSTIVE_NAME)


func _maximum_requested() -> bool:
	return OS.get_cmdline_user_args().has(MAXIMUM_NAME)


func before_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.clear_selection()
	State.undo_redo.clear_history()
	State.symmetry_axes = 0
	State.symmetry_origin = State.DEFAULT_SYMMETRY_ORIGIN
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	_settings.tool = _settings.Tools.SMOOTH
	_settings.build_mode = _settings.BuildMode.ADD
	_settings.radius = 9
	_settings.strength = 1.0
	_settings.falloff = 0.5
	_viewport = editor_viewport()
	_viewport.get_parent().stretch = false
	_viewport.size = Vector2i(800, 500)
	activate_tool("terrain")
	plugin("TerrainPlugin").activate_tool()
	_tool = plugin("TerrainPlugin")._tool
	_tool.set_process(true)
	_frame = State.get_current_voxel_frame()
	camera_rig().is_orthogonal = true
	camera_rig().set_view("top")
	_sweeps = 0
	_total_hovers = 0
	_posed = 0
	_inconsistent = 0
	await get_tree().process_frame


func after_test() -> void:
	if _tool != null and _tool._edit != null:
		_tool.finish_on_switch()
		while _tool._edit != null:
			await get_tree().process_frame


func _candidate(anchor: Vector3i, claim: Vector3i, weight: float) -> Dictionary:
	return {
		"anchor": anchor, "point": Vector3(anchor), "normal": Vector3.UP,
		"plane_origin": Vector3(anchor), "weight": weight,
		"surface": claim, "claim": claim,
	}


func _assert_owner_invariant(built: Dictionary) -> void:
	var claims := {}
	for anchor in built:
		var row: Dictionary = built[anchor]
		expect((row["anchor"] as Vector3i) == anchor, "every row is keyed by its own anchor")
		var claim: Vector3i = row["claim"]
		expect(not claims.has(claim), "no two rows claim the same cell")
		claims[claim] = anchor


func _synthetic_collisions() -> void:
	var a1 := Vector3i(1, 0, 0)
	var a2 := Vector3i(2, 0, 0)
	var a3 := Vector3i(3, 0, 0)
	var a4 := Vector3i(4, 0, 0)
	var s1 := Vector3i(0, 5, 0)
	var s2 := Vector3i(0, 6, 0)
	step("Given candidates that share an anchor and a claim in a replacement chain", func():
		var candidates := [
			_candidate(a1, s1, 0.4),
			_candidate(a1, s2, 0.5),
			_candidate(a3, s1, 0.9),
			_candidate(a4, s2, 0.1),
		]
		var built := TerrainGeometryScript.resolve_samples(candidates)
		_assert_owner_invariant(built)
		expect(built.size() == 2, "the chain keeps two rows")
		expect((built[a3]["claim"] as Vector3i) == s1, "the strongest claim keeps its cell")
		expect((built[a1]["claim"] as Vector3i) == s2, "the overwritten anchor keeps its live claim")
	)
	step("Given two anchors that claim one surface", func():
		var built := TerrainGeometryScript.resolve_samples([_candidate(a1, s1, 0.9), _candidate(a2, s1, 0.5)])
		_assert_owner_invariant(built)
		expect(built.size() == 1 and built.has(a1), "the stronger anchor keeps the shared surface")
	)
	step("Given two equal-weight candidates on one anchor", func():
		var built := TerrainGeometryScript.resolve_samples([_candidate(a1, s2, 0.5), _candidate(a1, s1, 0.5)])
		_assert_owner_invariant(built)
		expect(built.size() == 1 and (built[a1]["claim"] as Vector3i) == s1, "one equal-weight row keeps the anchor")
	)


func _reversed_order() -> void:
	var a1 := Vector3i(1, 0, 0)
	var a2 := Vector3i(2, 0, 0)
	var a3 := Vector3i(3, 0, 0)
	var s1 := Vector3i(0, 5, 0)
	var s2 := Vector3i(0, 6, 0)
	var forward := [_candidate(a1, s2, 0.5), _candidate(a2, s1, 0.9), _candidate(a3, s1, 0.3)]
	var reversed := [_candidate(a3, s1, 0.3), _candidate(a2, s1, 0.9), _candidate(a1, s2, 0.5)]
	step("When the same candidates arrive in the opposite order", func():
		var first := TerrainGeometryScript.resolve_samples(forward)
		var second := TerrainGeometryScript.resolve_samples(reversed)
		_assert_owner_invariant(first)
		expect(first.keys().size() == second.keys().size(), "the two orders keep the same row count")
		for anchor in first:
			expect(second.has(anchor), "the two orders keep the same anchor")
			expect((second[anchor]["claim"] as Vector3i) == (first[anchor]["claim"] as Vector3i), "the two orders keep the same claim")
	)


func _tilted_frame(normal: Vector3, center: Vector3) -> TerrainFrame:
	var frame := TerrainFrame.new()
	var n := normal.normalized()
	frame.normal = n
	var seed := Vector3.UP if absf(n.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	frame.tangent_u = n.cross(seed).normalized()
	frame.tangent_v = n.cross(frame.tangent_u).normalized()
	frame.origin = center
	frame.axis = TerrainGeometryScript.dominant_axis(n)
	frame.sign = 1
	return frame


func _tilted_disc() -> void:
	step("Given a slope and tilted discs at many anchors", func():
		_grown_slope()
	)
	await _pump()
	var normals := [Vector3(0.7071, 0.7071, 0.0), Vector3(0.5, 0.7071, 0.5), Vector3(0.6, 0.8, 0.0)]
	var centers := [
		Vector3(0.6, 0.4, 0.0), Vector3(0.4, 0.6, 0.0), Vector3(0.5, 0.5, 0.0),
		Vector3(1.6, 0.4, 0.0), Vector3(-0.4, 0.6, 0.0), Vector3(0.6, -0.4, 0.0),
		Vector3(-3.5, 2.0, 0.0), Vector3(-3.5, 1.75, -0.25), Vector3(-3.5, 1.5, -0.5),
		Vector3(4.0, 4.0, 0.5), Vector3(4.0, 3.75, 0.25),
	]
	step("When every disc resolves its footprint", func():
		_sweeps = 0
		for normal in normals:
			for radius in [3, 4, 5, 6, 8]:
				for center in centers:
					var built: Dictionary = _tool._sample_map(_tilted_frame(normal, center), center, radius, 0.5)
					_sweeps += 1
					var claims := {}
					var bad_keys := []
					var duplicate_claims := []
					for anchor in built:
						var row: Dictionary = built[anchor]
						if (row["anchor"] as Vector3i) != anchor:
							bad_keys.append("%s -> %s" % [anchor, row["anchor"]])
						var claim: Vector3i = row["surface"] if row["surface"] != VoxelPicking.NONE else anchor
						if claims.has(claim):
							duplicate_claims.append("%s by %s and %s" % [claim, claims[claim], anchor])
						claims[claim] = anchor
					var disc_case := "normal %s radius %d center %s" % [normal, radius, center]
					var key_message := "%s keyed every row by its anchor" % disc_case
					if not bad_keys.is_empty():
						key_message += ": %s" % str(bad_keys)
					expect(bad_keys.is_empty(), key_message)
					var claim_message := "%s claimed every cell once" % disc_case
					if not duplicate_claims.is_empty():
						claim_message += ": %s" % str(duplicate_claims)
					expect(duplicate_claims.is_empty(), claim_message)
	)
	step("Then every disc resolved", func():
		expect(_sweeps >= 45, "the disc sweep ran every case")
	)


func _grown_slope() -> void:
	var changes := {}
	var material := VoxelFrame.material(Color.from_rgba8(40, 40, 40))
	for x in range(-14, 15):
		for z in range(-14, 15):
			var top := 0
			if x >= 0:
				top = int(x / 2)
			if z >= 8:
				top += 3
			top = clampi(top, 0, 10)
			for y in range(-2, top + 1):
				changes[Vector3i(x, y, z)] = material
	State.document = VoxelDocument.new()
	_frame = State.get_current_voxel_frame()
	_frame.set_cells(changes)


func _hover(world: Vector3) -> void:
	var event := InputEventMouseMotion.new()
	event.position = camera_rig().unproject_position(world)
	_viewport.push_input(event)


func _ring() -> MeshInstance3D:
	return _tool.get_node("Footprint")


func _settle_hover() -> void:
	await get_tree().process_frame


func _wait_ring_ready() -> void:
	for _index in 1200:
		if _tool._preview == null or _tool._preview.is_settled():
			return
		await get_tree().process_frame


func _pick_has_target() -> bool:
	return _tool._last_pick != null and _tool._last_pick.target != VoxelPicking.NONE


func _sweep_hover(anchors: Array) -> void:
	_sweeps = 0
	for point in anchors:
		_hover(point)
		await _settle_hover()
		_sweeps += 1
		_total_hovers += 1
		var target := _pick_has_target()
		if _ring().is_visible_in_tree():
			_posed += 1
		if _ring().is_visible_in_tree() != target:
			_inconsistent += 1


func _hover_side() -> void:
	await _hover_side_sweep(HOVER_ANCHORS)


func _exhaustive_hover_side() -> void:
	await _hover_side_sweep(_exhaustive_anchors())


func _exhaustive_anchors() -> Array:
	var anchors := []
	for i in range(-18, 19):
		for j in range(-4, 5):
			anchors.append(Vector3(float(i) * 0.5, 4.0, float(j) * 1.5))
	return anchors


func _hover_side_sweep(anchors: Array) -> void:
	step("Given a slope grown from the floor and the Surface Smooth tool", func():
		_grown_slope()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.falloff = 0.5
	)
	await _pump()
	_total_hovers = 0
	_posed = 0
	_inconsistent = 0
	for view in HOVER_VIEWS:
		for radius in HOVER_RADII:
			await step("When the user hovers the side from %s at radius %d with no button" % [view, radius], func():
				camera_rig().set_view(view)
				_settings.radius = radius
				await _sweep_hover(anchors)
			)
			await _pump()
	step("Then the ring matched every pick and left no edit", func():
		expect(_total_hovers == anchors.size() * HOVER_VIEWS.size() * HOVER_RADII.size(), "the hover sweep ran every view, radius, and anchor")
		expect(_posed > 0, "the hover sweep posed the ring on a support pick")
		expect(_inconsistent == 0, "the ring showed exactly when the pick had a target")
		expect(_tool._edit == null, "no hover opens an edit")
		expect(not State.undo_redo.has_undo(), "no hover records history")
		expect(not State.edit_busy(_tool), "a hover leaves no activity behind")
	)


func _worst_case_hover() -> void:
	step("Given a dense grown slope at the maximum radius with symmetry and Smooth", func():
		_grown_slope()
		_settings.tool = _settings.Tools.SMOOTH
		_settings.build_mode = _settings.BuildMode.ADD
		_settings.radius = 72
		_settings.falloff = 0.5
		State.symmetry_axes = 7
	)
	await _pump()
	var dense_anchors := []
	for i in range(-2, 3):
		dense_anchors.append(Vector3(float(i) * 6.0, 4.0, 0.0))
	_posed = 0
	_inconsistent = 0
	for view in ["top", "right", "front"]:
		await step("When the user hovers the maximum radius disc from %s" % view, func():
			camera_rig().set_view(view)
			await _sweep_hover(dense_anchors)
		)
		await _pump()
	step("Then the maximum radius symmetric hover matched every pick and touched no document state", func():
		expect(_sweeps == 5, "the maximum radius hover sweep ran")
		expect(_posed > 0, "the maximum radius hover posed the ring")
		expect(_inconsistent == 0, "the ring showed exactly when the pick had a target")
		expect(_tool._edit == null, "the hover opened no edit")
		expect(not State.undo_redo.has_undo(), "the hover recorded no history")
		expect(not State.edit_busy(_tool), "the hover left no activity behind")
	)
	step("Given a sparse model with many missing chunks", func():
		State.symmetry_axes = 0
		_sparse()
		_settings.radius = 72
	)
	await _pump()
	var sparse_anchors := [
		Vector3(Vector3i.ZERO),
		Vector3(Vector3i(48, 0, 0)),
		Vector3(Vector3i(-48, 0, 48)),
		Vector3(Vector3i(0, 6, -64)),
	]
	_posed = 0
	_inconsistent = 0
	await step("When the user hovers across the sparse model", func():
		camera_rig().set_view("top")
		await _sweep_hover(sparse_anchors)
	)
	step("Then the sparse maximum radius hover posed the ring", func():
		expect(_sweeps == 4, "the sparse hover sweep ran")
		expect(_posed == 4, "every sparse hover posed the ring")
		expect(_inconsistent == 0, "the ring showed exactly when the pick had a target")
		expect(not State.edit_busy(_tool), "the sparse hover left no activity behind")
	)


func _sparse() -> void:
	var changes := {}
	var material := VoxelFrame.material(Color.from_rgba8(120, 90, 60))
	for cell in [Vector3i.ZERO, Vector3i(48, 0, 0), Vector3i(-48, 0, 48), Vector3i(0, 6, -64), Vector3i(30, -5, 20)]:
		for lift in range(0, 3):
			changes[cell + Vector3i(0, lift, 0)] = material
	State.document = VoxelDocument.new()
	_frame = State.get_current_voxel_frame()
	_frame.set_cells(changes)


func _hover_invalidation() -> void:
	step("Given a settled hover on the grown slope top", func():
		_grown_slope()
		camera_rig().set_view("top")
		_settings.radius = 5
		_hover(Vector3(4, 2, 0))
	)
	await _settle_hover()
	await _pump()
	await _wait_ring_ready()
	var baseline := _ring().global_transform
	var hit: Vector3i = _tool._last_pick.hit
	step("Given the hover picked a support cell and read the ring", func():
		expect(hit != VoxelPicking.NONE, "the hover hits the slope")
		expect(hit == Vector3i(4, 2, 0), "the hover picks the column top")
		expect(_ring().is_visible_in_tree(), "the hover posed the ring")
		expect(_tool._idle_pose_frame != null and _tool._idle_pose_frame.follows_surface, "the hover read the surface")
	)
	step("When a raw write raises the neighbor column and the pointer moves", func():
		_frame.set_cell(Vector3i(5, 3, 0), VoxelFrame.material(Color.WHITE))
		_hover(Vector3(4.1, 2.0, 0.0))
	)
	await _settle_hover()
	await _wait_ring_ready()
	step("Then the same cell keeps its center and reads the raw write", func():
		expect(_tool._last_pick.hit == Vector3i(4, 2, 0), "the pick keeps the hovered cell")
		var ring_origin := _ring().global_transform.origin
		var normal: Vector3 = _tool._idle_pose_frame.normal
		var offset := ring_origin - Vector3(hit)
		var across := offset - normal * offset.dot(normal)
		expect(across.length() <= 1e-3, "the same cell keeps the ring centered on it")
		expect(_tool._idle_pose_frame.normal != baseline.basis.z, "the raw write moves the surface normal")
		expect(_tool._idle_pose_frame.follows_surface, "the cached pose is the surface frame")
	)
	step("When the pointer moves to a new cell beside the raw write", func():
		_hover(Vector3(6.0, 3.0, 0.0))
	)
	await _settle_hover()
	await _wait_ring_ready()
	var surface_frame: TerrainFrame = _tool._idle_pose_frame
	step("Then the new cell reads the live frame with the raw write", func():
		expect(surface_frame != null and surface_frame.follows_surface, "the new cell read the surface")
		expect(surface_frame.normal != Vector3.UP, "the slope tilts the surface normal")
	)
	step("When the pointer returns to the first cell", func():
		_hover(Vector3(4.0, 2.0, 0.0))
	)
	await _settle_hover()
	await _wait_ring_ready()
	var return_frame: TerrainFrame = _tool._idle_pose_frame
	step("Then the re-read reads the neighbor write", func():
		expect(return_frame != null and return_frame.follows_surface, "the return hover read the surface")
		expect(return_frame.normal != Vector3.UP, "the re-read tilts with the neighbor write")
	)
	step("When the model changes through the frame signal", func():
		var bump := Vector3i(5, 4, 0)
		_frame.set_cell(bump, VoxelFrame.material(Color.WHITE))
		var cells: Array[Vector3i] = [bump]
		State.cells_changed.emit(State.active_layer_index, State.current_frame, cells)
	)
	await _settle_hover()
	await _wait_ring_ready()
	step("Then the signalled write moves the slope", func():
		expect(_tool._idle_pose_frame.normal != return_frame.normal, "the signalled write changes the surface normal")
	)


func _pump() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
