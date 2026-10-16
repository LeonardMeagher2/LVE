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
		frame.set_cell(Vector3i.ZERO, Color.RED)
		frame.set_cell(Vector3i(3, 0, 0), Color.BLUE)
		frame.set_materials({Vector3i(3, 0, 0): {"emission": Color(1, 0.5, 0.25), "metallic": 1.0, "roughness": 0.25}})
		expect(frame.get_material(Vector3i(3, 0, 0)).metallic == 1.0, "the metal voxel stores its metallic")
		expect(not frame.chunks[Vector3i.ZERO].cell_materials.has(Vector3i.ZERO), "the plain voxel stores no material")
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
		var material: Dictionary = loaded.get_material(Vector3i(3, 0, 0))
		expect(material.emission == Color(1, 0.5, 0.25), "the metal voxel keeps its emission color")
		expect(material.metallic == 1.0 and material.roughness == 0.25, "the metal voxel keeps its metallic and roughness")
		expect(loaded.get_color(Vector3i.ZERO) == Color.RED, "the plain voxel keeps its color")
		expect(loaded.get_material(Vector3i.ZERO) == VoxelFrame.DEFAULT_MATERIAL, "the plain voxel uses the default material")
	)
	step("Then the chunk stores one material table entry", func():
		var record: Array = loaded.storage_data()[1][0]
		var emissions: PackedColorArray = record[2]
		var finishes: PackedColorArray = record[3]
		expect(loaded.storage_data()[0] == VoxelFrame.STORAGE_VERSION, "the storage uses the current version")
		expect(emissions.size() == 1 and emissions[0] == Color(1, 0.5, 0.25), "the chunk stores the emission color once")
		expect(finishes.size() == 1 and finishes[0] == Color(1.0, 0.25, 0.0, 0.0), "the chunk stores the metallic and roughness once")
	)
	step("When the user erases the metal voxel", func():
		frame.set_cell(Vector3i(3, 0, 0), Color.TRANSPARENT)
		expect(not frame.chunks[Vector3i.ZERO].cell_materials.has(Vector3i(3, 0, 0)), "erasing removes the stored material")
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
		expect(loaded.get_material(Vector3i.ZERO) == VoxelFrame.DEFAULT_MATERIAL, "the version 1 voxel uses the default material")
		expect(loaded.chunks[Vector3i.ZERO].cell_materials.is_empty(), "the version 1 voxel stores no material entry")
	)
	step("Then saving the version 1 frame writes the current version", func():
		expect(loaded.storage_data()[0] == VoxelFrame.STORAGE_VERSION, "the upgraded storage uses the current version")
		expect((loaded.storage_data()[1][0][2] as PackedColorArray).is_empty(), "the upgraded chunk stores no material table")
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
