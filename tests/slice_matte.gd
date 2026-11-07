extends "res://tests/test.gd"

const MATTE_SCRIPT := preload("res://ui/Viewport/SliceMatte.gd")
const SLICE_CELL := Vector3i(2, 0, 0)
const ABOVE := Vector3i(1, 2, 1)
const BELOW := Vector3i(5, -3, 5)
const EMPTY_CELL := Vector3i(9, 2, 9)

var matte: MeshInstance3D
var builds := 0


func _ready() -> void:
	timeout = 30.0
	test("the slice matte projects the off-slice model onto the slice plane", _run, "slice_matte")


func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.slice_enabled = false
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	State.clear_selection()
	matte = null
	builds = 0
	await get_tree().process_frame


func _cleanup_test() -> void:
	if is_instance_valid(matte):
		matte.free()
	matte = null
	State.slice_enabled = false
	await get_tree().process_frame


func _run() -> void:
	step("Given cells on the slice layer and outside it", func():
		State.get_current_voxel_frame().set_cells({
			SLICE_CELL: VoxelFrame.material(Color.RED),
			ABOVE: VoxelFrame.material(Color.RED),
			BELOW: VoxelFrame.material(Color.RED),
		})
		State.document._bounds_dirty = true
		State.floor_index = 0
		State.slice_enabled = true
		matte = MATTE_SCRIPT.new()
		main.add_child(matte)
	)
	await _settle()
	step("Then the off-slice columns are covered and the slice layer is clear", func():
		expect(matte.visible, "the matte is visible")
		expect(matte.coverage_at(ABOVE) > 0.0, "a cell above the slice is covered")
		expect(matte.coverage_at(BELOW) > 0.0, "a cell below the slice is covered")
		expect(matte.coverage_at(SLICE_CELL) == 0.0, "a slice-layer cell leaves its column clear")
		expect(matte.coverage_at(EMPTY_CELL) == 0.0, "an empty column is clear")
		expect(is_equal_approx(matte.plane_coordinate, State.slice_level() - MATTE_SCRIPT.SLICE_GAP), "the matte sits on the slice plane")
		expect(matte.resolution.x > 0 and matte.resolution.y > 0, "the matte holds a texture")
	)
	step("When the slice layer changes", func():
		builds = matte.build_count
		var layer_cells: Array[Vector3i] = [SLICE_CELL, Vector3i(3, 0, 3)]
		State.cells_changed.emit(State.current_frame, layer_cells)
	)
	await _idle()
	step("Then the matte does not rebuild", func():
		expect(matte.build_count == builds, "a slice-layer change leaves the matte alone")
	)
	step("When a cell outside the slice changes", func():
		State.get_current_voxel_frame().set_cell(Vector3i(7, 4, 7), VoxelFrame.material(Color.RED))
		var changed_cells: Array[Vector3i] = [Vector3i(7, 4, 7)]
		State.cells_changed.emit(State.current_frame, changed_cells)
	)
	await _settle()
	step("Then the matte rebuilds and covers the new column", func():
		expect(matte.build_count > builds, "an off-slice change rebuilds the matte")
		expect(matte.coverage_at(Vector3i(7, 4, 7)) > 0.0, "the new off-slice cell is covered")
	)
	step("When the slice moves to a new layer", func():
		State.floor_index = 2
	)
	await _settle()
	step("Then the matte moves and skips the new slice layer", func():
		expect(is_equal_approx(matte.plane_coordinate, State.slice_level() - MATTE_SCRIPT.SLICE_GAP), "the matte follows the slice plane")
		expect(matte.coverage_at(ABOVE) == 0.0, "a cell on the new slice layer leaves its column clear")
	)
	step("When the slice turns off", func():
		State.slice_enabled = false
	)
	await _idle()
	step("Then the matte hides", func():
		expect(not matte.visible, "the matte hides with the slice")
	)


func _settle() -> void:
	var guard := 0
	while not matte.is_settled():
		await get_tree().process_frame
		guard += 1
		if guard > 600:
			break


func _idle() -> void:
	for frame in 4:
		await get_tree().process_frame
