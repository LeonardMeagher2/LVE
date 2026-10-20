extends "res://tests/test.gd"

const DOCUMENT_PATH := "user://chunk_materials_test.lve"
const LEGACY_PATH := "user://chunk_materials_legacy.lve"

var frame: VoxelFrame
var loaded: VoxelFrame


func _ready() -> void:
	timeout = 30.0
	test("Cell materials survive saving and loading, and older documents keep their voxels", _run)


func _run() -> void:
	step("Given a plain voxel and a glowing metal voxel", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		frame.set_cell(Vector3i(3, 0, 0), VoxelFrame.material(Color.BLUE, Color(1, 0.5, 0.25), 1.0, 0.25))
		expect(frame.get_metallic(Vector3i(3, 0, 0)) == 1.0, "the metal voxel stores its metallic")
		expect(frame.chunks[Vector3i.ZERO].materials.size() == 2 * VoxelFrame.MATERIAL_STRIDE, "each voxel stores nine material values")
	)
	step("When the document saves and loads", func():
		var document := VoxelDocument.new()
		document.frames.assign([frame])
		expect(document.save_file(DOCUMENT_PATH) == OK, "the document saves")
		var opened := VoxelDocument.load_file(DOCUMENT_PATH)
		loaded = opened.frames[0] if opened else null
		expect(loaded != null, "the document loads")
	)
	step("Then every voxel keeps its color and material", func():
		expect(loaded.get_color(Vector3i(3, 0, 0)) == Color.BLUE, "the metal voxel keeps its color")
		expect(loaded.get_emission(Vector3i(3, 0, 0)) == Color(1, 0.5, 0.25), "the metal voxel keeps its emission color")
		expect(loaded.get_metallic(Vector3i(3, 0, 0)) == 1.0 and loaded.get_roughness(Vector3i(3, 0, 0)) == 0.25, "the metal voxel keeps its metallic and roughness")
		expect(loaded.get_color(Vector3i.ZERO) == Color.RED, "the plain voxel keeps its color")
		expect(loaded.get_emission(Vector3i.ZERO) == Color.BLACK and loaded.get_metallic(Vector3i.ZERO) == 0.0 and loaded.get_roughness(Vector3i.ZERO) == 1.0, "the plain voxel uses the default values")
	)
	step("Then the chunk stores one table for all material values", func():
		var record: Array = loaded.storage_data()[1][0]
		var materials: PackedFloat32Array = record[1]
		expect(loaded.storage_data()[0] == VoxelFrame.STORAGE_VERSION, "the storage uses the current version")
		expect(materials.size() == 3 * VoxelFrame.MATERIAL_STRIDE, "the table holds the empty material and both voxel materials")
		expect(record.size() == 3 and record[2] is PackedInt32Array, "the chunk holds one material table and one octree")
	)
	step("When the user erases the metal voxel", func():
		frame.set_cell(Vector3i(3, 0, 0), VoxelFrame.material(Color.TRANSPARENT))
		expect(not frame.has(Vector3i(3, 0, 0)), "erasing removes the voxel")
		expect(frame.get_color(Vector3i.ZERO) == Color.RED, "the plain voxel keeps its color")
	)
	step("Given a version 1 document with a solid red chunk", func():
		expect(_write_legacy(LEGACY_PATH) == OK, "the version 1 document writes")
	)
	step("When the version 1 document loads", func():
		var opened := VoxelDocument.load_file(LEGACY_PATH)
		loaded = opened.frames[0] if opened else null
		expect(loaded != null, "the version 1 document loads")
		expect(loaded.get_color(Vector3i.ZERO) == Color.RED, "the version 1 voxel keeps its color")
		expect(loaded.get_emission(Vector3i.ZERO) == Color.BLACK and loaded.get_metallic(Vector3i.ZERO) == 0.0 and loaded.get_roughness(Vector3i.ZERO) == 1.0, "the version 1 voxel uses the default values")
	)
	step("Then saving the version 1 frame writes the current version", func():
		expect(loaded.storage_data()[0] == VoxelFrame.STORAGE_VERSION, "the upgraded storage uses the current version")
		expect(VoxelFrame.validate_storage(loaded.storage_data()) == 4096, "the upgraded chunk stores all voxels in the current format")
	)
	step("Given a version 2 frame with a glowing metal chunk", func():
		var chunks := [[Vector3i.ZERO, PackedColorArray([Color.TRANSPARENT, Color.BLUE]), PackedColorArray([Color.RED]), PackedColorArray([Color(0.5, 0.25, 0, 0)]), PackedInt32Array([3])]]
		var storage := [2, chunks]
		expect(VoxelFrame.validate_storage(storage) == 4096, "the version 2 storage is valid")
		loaded = VoxelFrame.new()
		loaded.restore_storage(storage)
		expect(loaded.get_color(Vector3i.ZERO) == Color.BLUE, "the version 2 voxel keeps its color")
		expect(loaded.get_emission(Vector3i.ZERO) == Color.RED and loaded.get_metallic(Vector3i.ZERO) == 0.5 and loaded.get_roughness(Vector3i.ZERO) == 0.25, "the version 2 voxel keeps its material values")
		expect(VoxelFrame.validate_storage(loaded.storage_data()) == 4096, "the version 2 frame saves in the current format")
	)
	step("When erases compact a copied chunk", func():
		frame = VoxelFrame.new()
		for x in 10:
			frame.set_cell(Vector3i(x, 0, 0), VoxelFrame.material(Color.BLUE, Color.RED, x / 10.0, 0.25))
		var copy := frame.copy_frame()
		for x in 7:
			copy.set_cell(Vector3i(x, 0, 0), VoxelFrame.material(Color.TRANSPARENT))
		expect(copy.count() == 3 and frame.count() == 10, "compaction preserves the source frame")
		for x in range(7, 10):
			expect(is_equal_approx(copy.get_metallic(Vector3i(x, 0, 0)), x / 10.0), "each remaining voxel keeps its metallic")
		expect(copy.chunks[Vector3i.ZERO].materials.size() <= 6 * VoxelFrame.MATERIAL_STRIDE, "compaction bounds the unused material space")
	)
	step("When a stroke restores the same voxels with different slots", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		var material := VoxelFrame.material(Color.RED, Color(0.2, 0.4, 0.6), 0.2, 0.4)
		frame.set_cell(Vector3i.ZERO, material)
		frame.set_cell(Vector3i.RIGHT, material)
		State.undo_redo.clear_history()
		var tx := State.begin_edit()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.TRANSPARENT))
		frame.set_cell(Vector3i.ZERO, material)
		State.finish_edit(tx)
		expect(not State.undo_redo.has_undo(), "equal voxel materials create no undo action")
		var revision: int = frame.chunks[Vector3i.ZERO].voxel_revision
		var changed := frame.set_cells({Vector3i.ZERO: material})
		expect(changed.is_empty() and frame.chunks[Vector3i.ZERO].voxel_revision == revision, "a repeated material write preserves the chunk revision")
		expect(is_equal_approx(frame.get_metallic(Vector3i.ZERO), 0.2), "the metallic retains float32 precision")
	)
	step("Then invalid material tables are rejected before loading", func():
		var valid := VoxelFrame.material(Color.TRANSPARENT)
		valid.append_array(VoxelFrame.material(Color.RED))
		var nodes := PackedInt32Array([1])
		var short := valid.slice(0, valid.size() - 1)
		expect(VoxelFrame.validate_storage([3, [[Vector3i.ZERO, short, nodes]]]) == -1, "a material table must contain complete materials")
		var invalid := valid.duplicate()
		invalid[VoxelFrame.MATERIAL_STRIDE + VoxelFrame.MATERIAL_METALLIC] = NAN
		expect(VoxelFrame.validate_storage([3, [[Vector3i.ZERO, invalid, nodes]]]) == -1, "all material values must be finite")
		invalid[VoxelFrame.MATERIAL_STRIDE + VoxelFrame.MATERIAL_METALLIC] = 2.0
		expect(VoxelFrame.validate_storage([3, [[Vector3i.ZERO, invalid, nodes]]]) == -1, "material values must stay within zero and one")
		expect(VoxelFrame.validate_storage([3, [[Vector3i.ZERO, valid, PackedInt32Array([2])]]]) == -1, "every octree material id must exist")
	)
	DirAccess.remove_absolute(DOCUMENT_PATH)
	DirAccess.remove_absolute(LEGACY_PATH)


func _write_legacy(path: String) -> Error:
	var chunks := [[Vector3i.ZERO, PackedColorArray([Color.TRANSPARENT, Color.RED]), PackedInt32Array([1])]]
	var fields := {"palette": PackedColorArray(), "frames": [{"delay_ms": 100, "voxels": [1, chunks]}], "tags": [], "smooth_normals": false, "lighting": {}, "export": {}}
	var payload := var_to_bytes(fields)
	var result := PackedByteArray(VoxelDocument.FILE_SIGNATURE)
	result.resize(16)
	result.encode_u32(4, 1)
	result.encode_u32(8, payload.size())
	result.encode_u32(12, VoxelDocument._crc32(payload))
	result.append_array(payload)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(result)
	file.close()
	return OK
