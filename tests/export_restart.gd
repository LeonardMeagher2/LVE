extends "res://tests/test.gd"

const CANCELED_PATH := "user://export_canceled_test.glb"
const FINAL_PATH := "user://export_restarted_test.glb"
var exporter: RefCounted
var canceled_result := ERR_BUSY
var final_result := ERR_BUSY


func _ready() -> void:
	timeout = 30.0
	test("a canceled export cannot change its replacement after a scene preparation yield", _run)


func _run() -> void:
	step("Given an export with enough frames to yield during scene preparation", func():
		State.document = VoxelDocument.new()
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		for index in 159:
			State.document.add_frame(0)
		exporter = plugin("ExportPlugin")._gltf
		for path in [CANCELED_PATH, FINAL_PATH]:
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(path)
	)
	_start_canceled_export()
	while exporter._export_root == null and canceled_result == ERR_BUSY:
		await get_tree().process_frame
	step("When the user cancels during scene preparation and starts another export", func():
		expect(exporter._export_root != null, "the first export yields while preparing its scene")
		exporter.cancel()
		State.document = VoxelDocument.new()
		State.get_current_voxel_frame().set_cell(Vector3i.RIGHT, VoxelFrame.material(Color.BLUE))
	)
	_start_final_export()
	while canceled_result == ERR_BUSY or final_result == ERR_BUSY:
		await get_tree().process_frame
	step("Then only the replacement export writes a complete asset", func():
		expect(canceled_result == ERR_UNAVAILABLE, "the old coroutine returns cancellation")
		expect(final_result == OK, "the replacement export completes")
		expect(not FileAccess.file_exists(CANCELED_PATH), "the canceled export writes no file")
		var document := GLTFDocument.new()
		var state := GLTFState.new()
		expect(document.append_from_file(FINAL_PATH, state) == OK, "the replacement GLB imports")
		expect(state.get_meshes().size() == 1, "the replacement retains only its own frame")
		expect(exporter._export_root == null and exporter._export_job == null, "the export releases its scene and worker state")
	)
	for path in [CANCELED_PATH, FINAL_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func _start_canceled_export() -> void:
	canceled_result = await exporter.export_gltf(CANCELED_PATH)


func _start_final_export() -> void:
	final_result = await exporter.export_gltf(FINAL_PATH)
