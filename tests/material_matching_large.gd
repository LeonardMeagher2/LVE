extends "res://tests/test.gd"

const BLOCK := 18
const DISTANT := Vector3i(64, 0, 0)
var fill: Node
var frame: VoxelFrame


func _ready() -> void:
	timeout = 30.0
	test("a worker-sized fill matches the full voxel material", _run)


func _run() -> void:
	step("Given a large metal block and a same-color plain voxel", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		for x in BLOCK:
			for y in BLOCK:
				for z in BLOCK:
					frame.set_cell(Vector3i(x, y, z), _metal_red())
		frame.set_cell(DISTANT, VoxelFrame.material(Color.RED))
		activate_tool("fill")
		fill = plugin("FillPlugin")._tool
		State.current_material = VoxelFrame.material(Color.GREEN)
		State.undo_redo.clear_history()
	)

	step("When the user fills every voxel with that material", func():
		fill._settings.connected = false
		fill._release_pending = true
		fill._queue_seed(Vector3i.ZERO)
		expect(State.edit_busy(), "the large fill reports foreground work")
	)
	await _settle_fill()
	step("Then the block changes in one undo action and the plain voxel keeps its material", func():
		expect(frame.matches(Vector3i(17, 17, 17), VoxelFrame.material(Color.GREEN)), "the last block voxel takes the fill material")
		expect(frame.matches(Vector3i(8, 8, 8), VoxelFrame.material(Color.GREEN)), "a block voxel inside another chunk takes the fill material")
		expect(frame.matches(DISTANT, VoxelFrame.material(Color.RED)), "the same-color voxel with another metallic keeps its material")
		expect(frame.count() == BLOCK * BLOCK * BLOCK + 1, "the fill preserves the voxel count")
		State.undo_redo.undo()
		expect(frame.matches(Vector3i(17, 17, 17), _metal_red()), "one undo restores every block material")
	)


func _settle_fill() -> void:
	while not fill.is_settled() or not fill._search_jobs.is_empty() or State.edit_busy():
		await get_tree().process_frame


func _metal_red() -> PackedFloat32Array:
	return VoxelFrame.material(Color.RED, VoxelFrame.DEFAULT_EMISSION, 0.8, 0.5)
