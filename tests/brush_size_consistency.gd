extends "res://tests/test.gd"

# Focused checks for the shared voxel brush size.
#
# The size is a voxel width in cells. The checks lock the shared sphere and cube
# masks, the offset order, the reach, and the disk projection to the shipped
# brush geometry. They also lock the common maximum of sixty-four across the
# brush and the paint controls. The file reuses no live tool state for the pure
# checks, so a mask regression reports here before it reaches a tool.

const VoxelBrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")
const StampPatternJob := preload("res://plugins/brush/StampPatternJob.gd")

const SPHERE := 1
const CUBE := 0

var _expected: Array = []
var _actual: Array = []
var _first: Array = []
var _second: Array = []
var _reach_value := 0
var _brush_settings: BrushToolSettings = null
var _paint_settings: PaintToolSettings = null
var _brush_options: Node = null
var _paint_options: Node = null
var _spray_tool: Node = null


func _ready() -> void:
	timeout = 30.0
	test("every brush-like size control shares the range one through sixty-four", _shared_max, "size_shared_max")
	test("a size of one is a single cell", _size_one, "size_one")
	test("the cube mask keeps every cell of the size", _cube_mask, "size_cube")
	test("the sphere mask keeps the shipped cells and order", _sphere_mask, "size_sphere")
	test("the brush stamp job, the helper, and the ground truth agree", _stamp_matches, "size_stamp")
	test("the sphere and the disk span the exact width with no off-by-one", _no_off_by_one, "size_off_by_one")
	test("the disk matches the central projection of the sphere", _disk_projection, "size_disk")
	test("the reach is the longest rounded sphere offset", _reach, "size_reach")
	test("a mirror must reflect the whole even pattern", _mirror_bias, "size_mirror")
	test("each caller owns its own offsets", _caller_isolation, "size_isolation")
	test("the settings clamp before the tree and the legacy radius agrees", _settings_early, "size_settings")
	test("the live spray search mask matches the brush sphere", _spray_mask, "size_spray_mask")


# Each test owns its own settings. The live spray test restores the shared
# settings, so a size check never depends on an earlier test.
func _cleanup_test() -> void:
	if _spray_tool != null:
		_spray_tool._paint_settings.spray_size = 9
		_spray_tool = null


# The shipped stamp formula, kept as the independent ground truth. It is the
# exact code that ran before the helper replaced it.
func _ground_truth(size: int, sphere: bool) -> Array:
	var offsets := []
	var first := -floori(size * 0.5)
	var center := (size - 1) * 0.5
	for x in size:
		for y in size:
			for z in size:
				if not sphere or Vector3(x - center, y - center, z - center).length_squared() <= size * size * 0.25:
					offsets.append(Vector3i(x + first, y + first, z + first))
	return offsets


func _same_order(first: Array, second: Array) -> bool:
	if first.size() != second.size():
		return false
	for i in first.size():
		if first[i] != second[i]:
			return false
	return true


func _same_set(first: Array, second: Array) -> bool:
	if first.size() != second.size():
		return false
	var lookup := {}
	for cell in second:
		lookup[cell] = true
	for cell in first:
		if not lookup.has(cell):
			return false
	return true


func _shared_max() -> void:
	step("Given the shared size range", func():
		expect(VoxelBrushSize.MAX_SIZE == 64, "the shared maximum size is sixty-four")
		expect(VoxelBrushSize.MIN_SIZE == 1, "the shared minimum size is one")
	)
	step("When a value above the maximum is set on each control", func():
		var brush := BrushToolSettings.new()
		var paint := PaintToolSettings.new()
		brush.diameter = 65
		paint.diameter = 65
		paint.spot_diameter = 65
		paint.spray_size = 65
		_expected = [brush.diameter, paint.diameter, paint.spot_diameter, paint.spray_size]
	)
	step("Then every resource clamps to sixty-four", func():
		expect(_expected == [64, 64, 64, 64], "each size resource clamps to sixty-four")
	)
	await get_tree().process_frame
	step("Given the brush and the paint option bars", func():
		_brush_options = plugin("BrushPlugin")._options
		_paint_options = plugin("PaintPlugin")._options
	)
	step("Then every brush-like size control allows one through sixty-four", func():
		expect(_brush_options.get_node("Diameter").max_value == 64.0, "the brush diameter allows sixty-four")
		expect(_brush_options.get_node("Diameter").min_value == 1.0, "the brush diameter starts at one")
		expect(_paint_options.get_node("Brush/Diameter").max_value == 64.0, "the paint brush diameter allows sixty-four")
		expect(_paint_options.get_node("Spray/SpotSize").max_value == 64.0, "the spot size allows sixty-four")
		expect(_paint_options.get_node("Spray/SpotSize").min_value == 1.0, "the spot size starts at one")
		expect(_paint_options.get_node("Spray/SpraySize").max_value == 64.0, "the spray search size allows sixty-four")
		expect(_paint_options.get_node("Spray/SpraySize").min_value == 1.0, "the spray search size starts at one")
		expect(_paint_options.get_node("Spray/Speed").max_value == 64.0, "the speed count stays at sixty-four")
	)


func _size_one() -> void:
	step("Then a size of one is the single center cell", func():
		expect(VoxelBrushSize.sphere_offsets(1) == [Vector3i.ZERO], "the sphere of size one is the center alone")
		expect(VoxelBrushSize.contains_sphere(1, Vector3i.ZERO), "the center lies inside the unit sphere")
		expect(not VoxelBrushSize.contains_sphere(1, Vector3i.RIGHT), "the neighbor lies outside the unit sphere")
		expect(VoxelBrushSize.reach(1) == 0, "the unit sphere needs no reach")
		expect(VoxelBrushSize.disk_offsets(1).size() == 1, "the unit disk is the center alone")
	)


func _cube_mask() -> void:
	for size in [1, 2, 3, 4, 31, 64]:
		step("Given the shipped cube of size %d" % size, func():
			_actual.assign(StampPatternJob.build_pattern(size, CUBE).keys())
			_expected = _ground_truth(size, false)
		)
		step("Then the cube keeps every cell of the size in order", func():
			expect(_same_order(_actual, _expected), "the cube of size %d matches the ground truth order" % size)
			expect(_actual.size() == size ** 3, "the cube of size %d has size cubed cells" % size)
		)


func _sphere_mask() -> void:
	for size in [1, 2, 3, 4, 9, 16, 31, 32, 63, 64]:
		step("Given the shipped sphere of size %d" % size, func():
			_actual.assign(VoxelBrushSize.sphere_offsets(size))
			_expected = _ground_truth(size, true)
		)
		step("Then the sphere keeps the shipped cells and order", func():
			expect(_same_order(_actual, _expected), "the helper sphere of size %d matches the ground truth order" % size)
		)


func _stamp_matches() -> void:
	for size in [1, 2, 3, 16, 31, 63, 64]:
		step("Given the brush stamp job of size %d" % size, func():
			_actual.assign(StampPatternJob.build_pattern(size, SPHERE).keys())
			_expected = _ground_truth(size, true)
		)
		step("Then the job, the helper, and the ground truth agree", func():
			expect(_same_order(_actual, _expected), "the job keys of size %d match the ground truth" % size)
			var helper: Array = []
			helper.assign(VoxelBrushSize.sphere_offsets(size))
			expect(_same_order(helper, _actual), "the helper keys of size %d match the job" % size)
		)


func _no_off_by_one() -> void:
	step("Then an odd size reaches the same distance on both sides", func():
		for size in [1, 3, 9, 31, 63]:
			expect(VoxelBrushSize.first_offset(size) == -(size / 2), "the odd size %d starts below zero" % size)
			expect(VoxelBrushSize.last_offset(size) == size / 2, "the odd size %d ends above zero" % size)
			expect(VoxelBrushSize.last_offset(size) - VoxelBrushSize.first_offset(size) + 1 == size, "the odd size %d spans its width" % size)
	)
	step("Then an even size reaches one further on the negative side", func():
		for size in [2, 4, 32, 64]:
			expect(VoxelBrushSize.first_offset(size) == -(size / 2), "the even size %d starts below zero" % size)
			expect(VoxelBrushSize.last_offset(size) == size / 2 - 1, "the even size %d ends one cell lower" % size)
			expect(VoxelBrushSize.last_offset(size) - VoxelBrushSize.first_offset(size) + 1 == size, "the even size %d spans its width" % size)
	)
	step("Then the widest sphere and disk span exactly sixty-four cells", func():
		var sphere_low := 64
		var sphere_high := -64
		for offset in VoxelBrushSize.sphere_offsets(64):
			sphere_low = mini(sphere_low, offset.x)
			sphere_high = maxi(sphere_high, offset.x)
		expect(sphere_low == -32 and sphere_high == 31, "the sphere of size sixty-four spans minus thirty-two through thirty-one")
		var disk_low := 64
		var disk_high := -64
		for entry in VoxelBrushSize.disk_offsets(64):
			disk_low = mini(disk_low, entry["u"])
			disk_high = maxi(disk_high, entry["u"])
		expect(disk_low == -32 and disk_high == 31, "the disk of size sixty-four spans minus thirty-two through thirty-one")
	)


func _disk_projection() -> void:
	for size in [1, 2, 3, 4, 9, 32, 63, 64]:
		step("Then the disk of size %d matches the central projection of its sphere" % size, func():
			var projected := {}
			for offset in VoxelBrushSize.sphere_offsets(size):
				projected[Vector2i(offset.x, offset.z)] = true
			var disk := {}
			for entry in VoxelBrushSize.disk_offsets(size):
				disk[Vector2i(entry["u"], entry["v"])] = true
			expect(_same_set(disk.keys(), projected.keys()), "the disk of size %d projects the sphere exactly" % size)
		)


func _reach() -> void:
	for size in [1, 2, 3, 4, 9, 16, 31, 32, 63, 64]:
		step("Given the sphere of size %d" % size, func():
			var longest := 0
			for offset in VoxelBrushSize.sphere_offsets(size):
				longest = maxi(longest, offset.length_squared())
			_reach_value = ceili(sqrt(float(longest)))
		)
		step("Then the reach covers every sphere offset", func():
			expect(VoxelBrushSize.reach(size) == _reach_value, "the reach of size %d is the longest rounded offset" % size)
		)


func _mirror_bias() -> void:
	var even: Array = []
	var odd: Array = []
	step("Given an even sphere and an odd sphere", func():
		even.assign(VoxelBrushSize.sphere_offsets(64))
		odd.assign(VoxelBrushSize.sphere_offsets(9))
	)
	step("Then the even shape is not its own mirror", func():
		var mirrored := {}
		for offset in even:
			mirrored[Vector3i(-offset.x, offset.y, offset.z)] = true
		expect(mirrored.size() == even.size(), "the mirrored even shape keeps every offset")
		expect(not _same_set(mirrored.keys(), even), "the even half-cell center mirrors to a shifted shape")
		var twice := {}
		for offset in mirrored:
			twice[Vector3i(-offset.x, offset.y, offset.z)] = true
		expect(_same_set(twice.keys(), even), "a second mirror restores the even shape")
	)
	step("Then the odd shape mirrors to itself", func():
		var mirrored := {}
		for offset in odd:
			mirrored[Vector3i(-offset.x, offset.y, offset.z)] = true
		expect(_same_set(mirrored.keys(), odd), "the odd centered shape mirrors to itself")
	)
	step("Then a full mirror of the even shape also shifts the half-cell center", func():
		var mirrored := {}
		for offset in even:
			mirrored[Vector3i(-offset.x, -offset.y, -offset.z)] = true
		expect(mirrored.size() == even.size(), "the full mirror of the even shape keeps every offset")
		expect(not _same_set(mirrored.keys(), even), "the full mirror of the even shape is a shifted shape")
	)
	step("Then reflecting every even pattern cell is not the unmirrored shape", func():
		var anchor := Vector3i(10, 0, 0)
		var correct := {}
		var naive := {}
		for offset in even:
			correct[Vector3i(-(anchor.x + offset.x), anchor.y + offset.y, anchor.z + offset.z)] = true
			naive[Vector3i(-anchor.x + offset.x, anchor.y + offset.y, anchor.z + offset.z)] = true
		expect(correct.size() == even.size(), "the reflected even pattern keeps every cell")
		expect(not _same_set(correct.keys(), naive.keys()), "the reflected pattern is not the unmirrored shape at the mirrored anchor")
	)
	step("Then reflecting every odd pattern cell matches the unmirrored shape", func():
		var anchor := Vector3i(10, 7, -3)
		var correct := {}
		var naive := {}
		for offset in odd:
			correct[Vector3i(-(anchor.x + offset.x), -(anchor.y + offset.y), -(anchor.z + offset.z))] = true
			naive[Vector3i(-anchor.x + offset.x, -anchor.y + offset.y, -anchor.z + offset.z)] = true
		expect(_same_set(correct.keys(), naive.keys()), "the odd centered pattern mirrors to the unmirrored shape")
	)


func _caller_isolation() -> void:
	step("Given two callers ask for the same size", func():
		_first = VoxelBrushSize.sphere_offsets(4)
		_second = VoxelBrushSize.sphere_offsets(4)
	)
	step("When one caller changes its copy", func():
		_first.append(Vector3i(99, 99, 99))
		_first.clear()
	)
	step("Then the other caller and a fresh read are unchanged", func():
		var expected := _ground_truth(4, true)
		var again: Array = []
		again.assign(VoxelBrushSize.sphere_offsets(4))
		expect(_same_order(again, expected), "a fresh read of size four is unchanged")
		expect(_same_order(_second, expected), "the second caller keeps its own cells")
	)
	step("Then several sizes read in one pass keep their own shape", func():
		var counts := {}
		for size in [1, 4, 9, 64, 9, 1]:
			var offsets: Array = []
			offsets.assign(VoxelBrushSize.sphere_offsets(size))
			counts[size] = offsets.size()
		var ok := true
		for size in [1, 4, 9, 64]:
			ok = ok and counts[size] == _ground_truth(size, true).size()
		expect(ok, "each size keeps its own sphere count across interleaved reads")
	)


func _settings_early() -> void:
	step("Given fresh brush and paint settings outside the tree", func():
		_brush_settings = BrushToolSettings.new()
		_paint_settings = PaintToolSettings.new()
	)
	step("When a value outside the range is set before any Ready", func():
		_brush_settings.diameter = 0
		_paint_settings.spot_diameter = 100
		_paint_settings.spray_size = 0
		_paint_settings.spray_radius = 40
	)
	step("Then every setter clamps to the shared range", func():
		expect(_brush_settings.diameter == 1, "the brush clamps the small diameter to one")
		expect(_paint_settings.spot_diameter == 64, "the paint clamps the large spot to sixty-four")
		expect(_paint_settings.spray_size == 64, "the paint clamps the large search size to sixty-four")
		expect(_paint_settings.spray_radius == 31, "the legacy radius maps back to the span-equivalent radius")
	)
	step("Then the legacy radius and the canonical size never disagree", func():
		_paint_settings.spray_radius = 4
		expect(_paint_settings.spray_size == 9, "the legacy radius four maps to the size nine")
		expect(_paint_settings.spray_radius == 4, "the size nine maps back to the radius four")
	)


func _spray_mask() -> void:
	await get_tree().process_frame
	step("Given the live spray at the maximum search size", func():
		_spray_tool = plugin("PaintPlugin")._spray_tool
		_spray_tool._paint_settings.spray_size = 64
	)
	step("When the live spray filters a full cube of offsets", func():
		var local: Array[Vector3i] = []
		var low := VoxelBrushSize.first_offset(64)
		var high := VoxelBrushSize.last_offset(64)
		for x in range(low, high + 1):
			for y in range(low, high + 1):
				for z in range(low, high + 1):
					local.append(Vector3i(x, y, z))
		_actual.assign(_spray_tool._candidates(Vector3i.ZERO, local))
	)
	step("Then the search mask equals the brush sphere", func():
		var sphere: Array = []
		sphere.assign(VoxelBrushSize.sphere_offsets(64))
		expect(_actual.size() == sphere.size(), "the search mask holds every brush sphere cell")
		expect(_same_set(_actual, sphere), "the full-cube search mask matches the brush sphere")
	)
	step("Then the live spot of size sixty-four matches the brush stamp", func():
		var tool_offsets: Array = []
		tool_offsets.assign(_spray_tool._spot_offsets(64))
		var job: Array = []
		job.assign(StampPatternJob.build_pattern(64, SPHERE).keys())
		expect(tool_offsets.size() == job.size(), "the live spot of size sixty-four holds every stamp cell")
		expect(_same_order(tool_offsets, job), "the live spot of size sixty-four matches the brush stamp in order")
	)
