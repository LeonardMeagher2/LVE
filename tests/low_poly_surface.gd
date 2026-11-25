extends "res://tests/test.gd"


const TEST_PATH := "user://low_poly_surface_test.lve"

var renderer: VoxelRenderer
var loaded: VoxelDocument


func _ready() -> void:
	timeout = 30.0
	test("the low poly surface replaces the chunk meshes", _run)


func _run() -> void:
	step("Given a document in voxel mode", func():
		State.document = VoxelDocument.new()
		State.document.low_poly = false
		var cells := {}
		var material := VoxelFrame.material(Color(1.0, 0.0, 1.0))
		for x in range(-1, 2):
			for y in range(-1, 2):
				for z in range(-1, 2):
					cells[Vector3i(x, y, z)] = material
		State.get_current_voxel_frame().set_cells(cells)
		State.frames_changed.emit()
		renderer = editor_viewport().get_node("ViewportScene/VoxelRenderer")
	)
	await _settle()
	step("Then the chunk meshes are visible", func():
		expect(renderer._low_poly_instance == null, "the voxel mode has no low poly instance")
		expect(renderer._chunk_instances.size() > 0, "the voxel mode builds chunk meshes")
	)
	step("When the document enables low poly", func():
		State.document.low_poly = true
		State.model_settings_changed.emit()
	)
	await _settle()
	step("Then one low poly mesh replaces the chunks", func():
		expect(renderer._low_poly_instance != null, "the low poly mode builds one mesh")
		var mesh: Mesh = renderer._low_poly_instance.mesh
		expect(mesh != null and mesh.get_surface_count() == 1, "the low poly mesh has one surface")
		expect(mesh != null and mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() > 0, "the low poly mesh has vertices")
		var hidden := true
		for chunk: MeshInstance3D in renderer._chunk_instances.values():
			hidden = hidden and not chunk.visible
		expect(hidden, "the chunk meshes are hidden")
	)
	step("When the document saves with low poly enabled", func():
		State.document.save_file(TEST_PATH)
		loaded = VoxelDocument.load_file(TEST_PATH)
	)
	step("Then the low poly settings return", func():
		expect(loaded != null and loaded.low_poly, "the low poly mode survives save and load")
	)
	step("When the document returns to voxel mode", func():
		State.document.low_poly = false
		State.model_settings_changed.emit()
	)
	await _settle()
	step("Then the chunk meshes return", func():
		expect(renderer._low_poly_instance == null, "the low poly instance is removed")
		var visible := false
		for chunk: MeshInstance3D in renderer._chunk_instances.values():
			visible = visible or chunk.visible
		expect(visible, "the chunk meshes are visible again")
	)
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(TEST_PATH)


func _settle() -> void:
	while not renderer.is_settled():
		await get_tree().process_frame
