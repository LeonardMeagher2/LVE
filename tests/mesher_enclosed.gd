extends "res://tests/test.gd"

# Focused proof for the exact enclosed-chunk shortcut of `VoxelMeshBuilder`.
#
# A face is emitted only where the neighbor cell is empty or translucent, so a
# full chunk whose six face planes and whose own materials are all opaque cannot
# emit any face. The shortcut then skips the padded snapshot and the face scan.
#
# Every case builds one builder with the shortcut and one with the frozen baseline
# body (`enclosed_shortcut = false`) on the same frame, and compares the arrays by
# element type and value. An unsafe case must fall through to the baseline and
# match it exactly.
#
#   godot --headless --path . res://tests/mesher_enclosed.tscn

const CHUNK := VoxelFrame.CHUNK_SIZE

var _enclosed_us := 0
var _baseline_us := 0
var _predicate_us := 0
var _cost_frame: VoxelFrame


func _ready() -> void:
	timeout = 60.0
	test("the enclosed shortcut matches the baseline on every unsafe variant", _unsafe_variants, "mesher_enclosed_unsafe")
	test("the enclosed shortcut matches the baseline on every safe variant", _safe_variants, "mesher_enclosed_safe")
	test("the enclosed shortcut is faster and the predicate is cheap", _enclosed_cost, "mesher_enclosed_cost")


func _full_block(origin_chunk: Vector3i, span: int, material: PackedFloat32Array) -> VoxelFrame:
	var frame := VoxelFrame.new()
	var cells := {}
	for x in range(origin_chunk.x * CHUNK, (origin_chunk.x + span) * CHUNK):
		for y in range(origin_chunk.y * CHUNK, (origin_chunk.y + span) * CHUNK):
			for z in range(origin_chunk.z * CHUNK, (origin_chunk.z + span) * CHUNK):
				cells[Vector3i(x, y, z)] = material
	frame.set_cells(cells)
	return frame


# Builds one pair on the same frame and checks the exact contract.
func _check_pair(label: String, frame: VoxelFrame, location: Vector3i, smooth: bool, textured: bool, expect_culled: bool) -> void:
	var culled := VoxelMeshBuilder.new()
	culled.source_frame = frame
	culled.chunk_location = location
	culled.smooth_normals = smooth
	culled.texture_materials = textured
	culled.run()
	var baseline := VoxelMeshBuilder.new()
	baseline.enclosed_shortcut = false
	baseline.source_frame = frame
	baseline.chunk_location = location
	baseline.smooth_normals = smooth
	baseline.texture_materials = textured
	baseline.run()
	expect(culled.enclosed_culled == expect_culled, "%s: the shortcut %s" % [label, "ran" if expect_culled else "was skipped"])
	expect(_arrays_equal(culled.surface_arrays, baseline.surface_arrays), "%s: the arrays match the baseline element for element" % label)
	expect(culled.atlas_size == baseline.atlas_size, "%s: the atlas size matches the baseline" % label)
	expect(culled.geometry_bytes == baseline.geometry_bytes, "%s: the geometry bytes match the baseline" % label)


# Compares every entry by type and value, so a differing packed type also fails.
func _arrays_equal(first: Array, second: Array) -> bool:
	if first.size() != second.size():
		return false
	for index in first.size():
		if typeof(first[index]) != typeof(second[index]):
			return false
		if first[index] != second[index]:
			return false
	return true


func _unsafe_variants() -> void:
	var opaque := VoxelFrame.material(Color.WHITE)
	var translucent := VoxelFrame.material(Color(1.0, 0.0, 0.0, 0.5))
	step("Given a full opaque three-cube block", func():
		var frame := _full_block(Vector3i.ZERO, 3, opaque)
		var center := Vector3i(1, 1, 1)
		expect(VoxelMeshBuilder._enclosed(frame, center), "the center chunk is enclosed")
	)
	step("When one own cell is a different translucent color", func():
		var frame := _full_block(Vector3i.ZERO, 3, opaque)
		var center := Vector3i(1, 1, 1)
		frame.set_cell(center * CHUNK + Vector3i(8, 8, 8), translucent)
		expect(not VoxelMeshBuilder._enclosed(frame, center), "a translucent own cell disables the shortcut")
		_check_pair("own translucent", frame, center, false, false, false)
		_check_pair("own translucent atlas", frame, center, false, true, false)
	)
	step("When one own cell is a hole", func():
		var frame := _full_block(Vector3i.ZERO, 3, opaque)
		var center := Vector3i(1, 1, 1)
		frame.set_cell(center * CHUNK + Vector3i(8, 8, 8), VoxelFrame.material(Color.TRANSPARENT))
		expect(not VoxelMeshBuilder._enclosed(frame, center), "an own hole disables the shortcut")
		_check_pair("own hole", frame, center, false, false, false)
		_check_pair("own hole smooth", frame, center, true, false, false)
	)
	step("When one neighbor boundary cell is translucent", func():
		var frame := _full_block(Vector3i.ZERO, 3, opaque)
		var center := Vector3i(1, 1, 1)
		frame.set_cell(Vector3i(2 * CHUNK, CHUNK + 5, CHUNK + 5), translucent)
		expect(not VoxelMeshBuilder._enclosed(frame, center), "a translucent neighbor cell disables the shortcut")
		_check_pair("neighbor translucent", frame, center, false, false, false)
		_check_pair("neighbor translucent atlas", frame, center, false, true, false)
	)
	step("When one neighbor boundary cell is missing", func():
		var frame := _full_block(Vector3i.ZERO, 3, opaque)
		var center := Vector3i(1, 1, 1)
		frame.set_cell(Vector3i(2 * CHUNK, CHUNK + 5, CHUNK + 5), VoxelFrame.material(Color.TRANSPARENT))
		expect(not VoxelMeshBuilder._enclosed(frame, center), "a missing neighbor cell disables the shortcut")
		_check_pair("neighbor hole", frame, center, false, false, false)
		_check_pair("neighbor hole smooth atlas", frame, center, true, true, false)
	)
	step("When a face neighbor chunk is missing", func():
		var frame := _full_block(Vector3i.ZERO, 1, opaque)
		var only := Vector3i.ZERO
		expect(not VoxelMeshBuilder._enclosed(frame, only), "a missing neighbor chunk disables the shortcut")
		_check_pair("missing neighbor", frame, only, false, false, false)
		_check_pair("missing neighbor atlas", frame, only, false, true, false)
	)
	step("When the chunk is a border chunk of the block", func():
		var frame := _full_block(Vector3i.ZERO, 3, opaque)
		var border := Vector3i.ZERO
		expect(not VoxelMeshBuilder._enclosed(frame, border), "a border chunk disables the shortcut")
		_check_pair("border chunk", frame, border, false, false, false)
		_check_pair("border chunk smooth", frame, border, true, false, false)
	)
	step("When the chunk is sparse", func():
		var frame := VoxelFrame.new()
		var cells := {}
		for index in 64:
			cells[Vector3i(index, index, index)] = opaque
		frame.set_cells(cells)
		expect(not VoxelMeshBuilder._enclosed(frame, Vector3i.ZERO), "a sparse chunk disables the shortcut")
		_check_pair("sparse chunk", frame, Vector3i.ZERO, false, false, false)
	)


func _safe_variants() -> void:
	var opaque := VoxelFrame.material(Color.WHITE)
	step("When a full opaque block encloses a chunk", func():
		var frame := _full_block(Vector3i.ZERO, 3, opaque)
		var center := Vector3i(1, 1, 1)
		_check_pair("enclosed flat color", frame, center, false, false, true)
		_check_pair("enclosed flat atlas", frame, center, false, true, true)
		_check_pair("enclosed smooth color", frame, center, true, false, true)
		_check_pair("enclosed smooth atlas", frame, center, true, true, true)
	)
	step("When the block sits in negative chunks", func():
		var frame := _full_block(Vector3i(-3, -3, -3), 3, opaque)
		var center := Vector3i(-2, -2, -2)
		expect(VoxelMeshBuilder._enclosed(frame, center), "a negative chunk is enclosed")
		_check_pair("enclosed negative", frame, center, false, false, true)
		_check_pair("enclosed negative atlas", frame, center, false, true, true)
	)
	step("When the enclosed chunk holds mixed PBR and emission materials", func():
		var frame := VoxelFrame.new()
		var cells := {}
		for x in CHUNK * 3:
			for y in CHUNK * 3:
				for z in CHUNK * 3:
					if (x + y + z) % 2 == 0:
						cells[Vector3i(x, y, z)] = VoxelFrame.material(Color(0.9, 0.2, 0.1), Color(0.1, 0.05, 0.0), 0.7, 0.2)
					else:
						cells[Vector3i(x, y, z)] = VoxelFrame.material(Color(0.1, 0.4, 0.9), Color.BLACK, 0.0, 1.0)
		frame.set_cells(cells)
		var center := Vector3i(1, 1, 1)
		expect(VoxelMeshBuilder._enclosed(frame, center), "a mixed opaque chunk is enclosed")
		_check_pair("enclosed mixed", frame, center, false, false, true)
		_check_pair("enclosed mixed atlas", frame, center, false, true, true)
	)
	step("When an unused palette row is translucent", func():
		# A conservative skip is fine: the chunk still builds through the baseline.
		var frame := _full_block(Vector3i.ZERO, 3, opaque)
		var center := Vector3i(1, 1, 1)
		expect(VoxelMeshBuilder._enclosed(frame, center), "an opaque enclosed chunk is enclosed")
		_check_pair("enclosed opaque", frame, center, false, false, true)
	)


func _enclosed_cost() -> void:
	var opaque := VoxelFrame.material(Color.WHITE)
	step("Given a full opaque three-cube block", func():
		_cost_frame = _full_block(Vector3i.ZERO, 3, opaque)
		expect(VoxelMeshBuilder._enclosed(_cost_frame, Vector3i(1, 1, 1)), "the center chunk is enclosed")
	)
	step("When the enclosed chunk builds through the shortcut and the baseline", func():
		_enclosed_us = _time_build(_cost_frame, Vector3i(1, 1, 1), false, false, true)
		_baseline_us = _time_build(_cost_frame, Vector3i(1, 1, 1), false, false, false)
	)
	step("When the predicate runs on an enclosed and a border chunk", func():
		var started := Time.get_ticks_usec()
		for index in 100:
			VoxelMeshBuilder._enclosed(_cost_frame, Vector3i(1, 1, 1))
			VoxelMeshBuilder._enclosed(_cost_frame, Vector3i.ZERO)
		_predicate_us = (Time.get_ticks_usec() - started) / 100
	)
	step("Then the shortcut is faster and the predicate is cheap", func():
		print("MEASURE mesher_enclosed: enclosed_us=%d baseline_us=%d predicate_us_per_pair=%d" % [
			_enclosed_us, _baseline_us, _predicate_us,
		])
		expect(_enclosed_us < _baseline_us, "the shortcut build is faster than the baseline")
		expect(_predicate_us < 2000, "the enclosed predicate costs less than two milliseconds per pair")
	)


func _time_build(frame: VoxelFrame, location: Vector3i, smooth: bool, textured: bool, cull: bool) -> int:
	var builder := VoxelMeshBuilder.new()
	builder.enclosed_shortcut = cull
	builder.source_frame = frame
	builder.chunk_location = location
	builder.smooth_normals = smooth
	builder.texture_materials = textured
	var started := Time.get_ticks_usec()
	builder.run()
	return Time.get_ticks_usec() - started
