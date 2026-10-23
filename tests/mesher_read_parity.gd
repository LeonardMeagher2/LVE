extends "res://tests/test.gd"

# Differential proof for the rewritten chunk read path of [VoxelMeshBuilder].
#
# The builder now walks the padded snapshot and the face scan with a strided
# index and copies only each neighbor's overlap. This test builds every case
# twice: once through the production builder and once through the frozen old
# body in `tests/mesher_read_reference.gd`. The arrays, the atlas size, and the
# geometry bytes must match element for element, so the rewrite changes no output.
#
#   godot --headless --path . res://tests/mesher_read_parity.tscn

const REF := preload("res://tests/mesher_read_reference.gd")
const CHUNK := VoxelFrame.CHUNK_SIZE

var _cases: Array = []


func _ready() -> void:
	timeout = 120.0
	test("the rewritten read path matches the frozen body on every case", _parity, "mesher_read_parity")


func _parity() -> void:
	step("Given dense, mixed, translucent, holed, negative, multichunk, and sparse cases", func():
		_cases = _build_cases()
		expect(_cases.size() >= 7, "the case set covers the required shapes")
	)
	step("Then the padded snapshot matches the frozen snapshot on every case", func():
		for case in _cases:
			for smooth in [false, true]:
				var current := VoxelMeshBuilder._snapshot(case.frame, case.locations[0], smooth)
				var frozen := REF.snapshot(case.frame, case.locations[0], smooth)
				expect(
					current[0] == frozen[0] and current[1] == frozen[1] and current[2] == frozen[2] and current[3] == frozen[3],
					"%s smooth=%s: the padded snapshot matches" % [case.name, str(smooth)]
				)
	)
	step("Then the builder arrays, atlas, and bytes match the frozen body", func():
		for case in _cases:
			for location: Vector3i in case.locations:
				for smooth in [false, true]:
					for texture in [false, true]:
						_check(case.name, case.frame, location, smooth, texture)
	)


# Builds one chunk with the production builder and one with the frozen body, and
# compares every array by element type and value, then the atlas and the bytes.
func _check(name: String, frame: VoxelFrame, location: Vector3i, smooth: bool, texture: bool) -> void:
	var builder := VoxelMeshBuilder.new()
	# The enclosed shortcut is orthogonal to the read path. Turning it off makes
	# an enclosed chunk run the full read path on both sides.
	builder.enclosed_shortcut = false
	builder.source_frame = frame
	builder.chunk_location = location
	builder.smooth_normals = smooth
	builder.texture_materials = texture
	builder.run()
	var frozen: Dictionary = REF.build(frame, location, smooth, texture)
	var label := "%s %s smooth=%s texture=%s" % [name, str(location), str(smooth), str(texture)]
	expect(_arrays_equal(builder.surface_arrays, frozen.arrays), "%s: every array matches by element type and value" % label)
	expect(builder.atlas_size == frozen.atlas_size, "%s: the atlas size matches" % label)
	expect(builder.geometry_bytes == frozen.geometry_bytes, "%s: the geometry bytes match" % label)


func _arrays_equal(first: Array, second: Array) -> bool:
	if first.size() != second.size():
		return false
	for index in first.size():
		if typeof(first[index]) != typeof(second[index]):
			return false
		if first[index] != second[index]:
			return false
	return true


# --- Cases -------------------------------------------------------------------

func _build_cases() -> Array:
	var opaque := VoxelFrame.material(Color.from_rgba8(90, 160, 220))
	var second := VoxelFrame.material(Color.from_rgba8(220, 120, 70), Color(0.2, 0.1, 0.0), 0.8, 0.2)
	var third := VoxelFrame.material(Color(0.1, 0.4, 0.9), Color.BLACK, 0.0, 1.0)
	var translucent := VoxelFrame.material(Color(1.0, 0.0, 0.0, 0.5))
	var cases: Array = []

	var dense := VoxelFrame.new()
	_fill_box(dense, Vector3i.ZERO, Vector3i.ONE * (CHUNK - 1), opaque)
	cases.append({"name": "dense opaque", "frame": dense, "locations": [Vector3i.ZERO]})

	# A mixed chunk with full PBR and emission, one material per plane diagonal.
	var mixed := VoxelFrame.new()
	var mixed_cells := {}
	for z in CHUNK:
		for y in CHUNK:
			for x in CHUNK:
				match (x + y + z) % 3:
					0: mixed_cells[Vector3i(x, y, z)] = opaque
					1: mixed_cells[Vector3i(x, y, z)] = second
					_: mixed_cells[Vector3i(x, y, z)] = third
	mixed.set_cells(mixed_cells)
	cases.append({"name": "mixed PBR", "frame": mixed, "locations": [Vector3i.ZERO]})

	var holed := VoxelFrame.new()
	var hole_cells := {}
	for z in CHUNK:
		for y in CHUNK:
			for x in CHUNK:
				if y == 0 and not (x == 7 and z == 8):
					hole_cells[Vector3i(x, y, z)] = opaque
	holed.set_cells(hole_cells)
	cases.append({"name": "holed plate", "frame": holed, "locations": [Vector3i.ZERO]})

	# One own translucent cell must emit its internal face on both sides.
	var own_translucent := VoxelFrame.new()
	_fill_box(own_translucent, Vector3i.ZERO, Vector3i.ONE * (CHUNK - 1), opaque)
	own_translucent.set_cell(Vector3i(8, 8, 8), translucent)
	cases.append({"name": "own translucent", "frame": own_translucent, "locations": [Vector3i.ZERO]})

	# A two-chunk block whose shared boundary holds a translucent cell.
	var neighbor_translucent := VoxelFrame.new()
	_fill_box(neighbor_translucent, Vector3i.ZERO, Vector3i(CHUNK * 2 - 1, CHUNK - 1, CHUNK - 1), opaque)
	neighbor_translucent.set_cell(Vector3i(CHUNK, 5, 5), translucent)
	cases.append({"name": "neighbor translucent", "frame": neighbor_translucent, "locations": [Vector3i.ZERO, Vector3i(1, 0, 0)]})

	var sparse := VoxelFrame.new()
	var sparse_cells := {}
	for index in 96:
		sparse_cells[Vector3i(index % 4 + index, (index * 5) % 16, (index * 7) % 16)] = opaque
	sparse.set_cells(sparse_cells)
	cases.append({"name": "sparse", "frame": sparse, "locations": [Vector3i.ZERO]})

	var negative := VoxelFrame.new()
	_fill_box(negative, Vector3i(-CHUNK, -CHUNK, -CHUNK), Vector3i(-1, -1, -1), second)
	cases.append({"name": "negative coords", "frame": negative, "locations": [Vector3i(-1, -1, -1)]})

	# A two-cube block, so several chunks read each other's border.
	var multichunk := VoxelFrame.new()
	var multi_cells := {}
	for z in CHUNK * 2:
		for y in CHUNK * 2:
			for x in CHUNK * 2:
				multi_cells[Vector3i(x, y, z)] = second if (x + y + z) % 2 == 0 else third
	multichunk.set_cells(multi_cells)
	var multi_locations: Array[Vector3i] = []
	for cz in 2:
		for cy in 2:
			for cx in 2:
				multi_locations.append(Vector3i(cx, cy, cz))
	cases.append({"name": "multichunk", "frame": multichunk, "locations": multi_locations})

	return cases


func _fill_box(frame: VoxelFrame, min_cell: Vector3i, max_cell: Vector3i, material: PackedFloat32Array) -> void:
	var cells := {}
	for z in range(min_cell.z, max_cell.z + 1):
		for y in range(min_cell.y, max_cell.y + 1):
			for x in range(min_cell.x, max_cell.x + 1):
				cells[Vector3i(x, y, z)] = material
	frame.set_cells(cells)
