extends "res://tests/test.gd"

var far_pick := VoxelPicking.NONE
var ray_frame: VoxelFrame
var ray_hit: PickResult
var ray_place: PickResult


func _ready() -> void:
	test("the canvas is unbounded", _run)


func _run() -> void:
	step("When the user paints a cell beyond the original 16x16 extent", func():
		State.document.paint(0, Vector3i(20, 0, 20), VoxelFrame.material(State.current_color))
	)

	step("Then the cell persists and the bounds expand", func():
		var frame: VoxelFrame = State.document.frames[0]
		expect(frame.has(Vector3i(20, 0, 20)), "the far cell is stored")
		var b := State.document.bounds()
		expect(b.has_volume(), "the bounds cover the content")
		expect(int(b.end.x) == 20, "the bounds reach the painted column")
	)

	step("When the user box-selects a region with negative coordinates", func():
		State.selection.from_box(Vector3i(-2, 0, -3), Vector3i(1, 2, 1))
	)

	step("Then the selection keeps the out-of-bounds cells", func():
		expect(State.selection.contains(Vector3i(-2, 0, -3)), "the selection has the negative corner")
		expect(State.selection.contains(Vector3i(1, 2, 1)), "the selection has the positive corner")
	)

	step("When the user aims at the floor past the original grid", func():
		far_pick = VoxelPicking.ground_pick(Vector3(30, 10, 30), Vector3(0, -1, 0), Vector3(0, -1, 0)).target
	)

	step("Then the pick lands on the far floor cell", func():
		expect(far_pick == Vector3i(30, 0, 30), "the pick reaches beyond the old grid")
	)

	step("Given a voxel far beyond the old 512-unit reach", func():
		ray_frame = VoxelFrame.new()
		ray_frame.set_cell(Vector3i(600, 0, 0), VoxelFrame.material(State.current_color))
	)

	step("When the user aims at it from 700 units away", func():
		ray_hit = VoxelPicking.ray_voxel(Vector3(-100, 0, 0), Vector3(1, 0, 0), ray_frame)
	)

	step("Then the ray reaches the far voxel through its near face", func():
		expect(ray_hit.hit == Vector3i(600, 0, 0), "the far voxel is picked from 700 units away")
		expect(ray_hit.entry == Vector3i(-1, 0, 0), "the hit records the near face")
	)

	step("When the user aims at the same voxel from the far side", func():
		ray_hit = VoxelPicking.ray_voxel(Vector3(700, 0, 0), Vector3(-1, 0, 0), ray_frame)
	)

	step("Then the ray reaches it from the other direction", func():
		expect(ray_hit.hit == Vector3i(600, 0, 0), "the far voxel is picked from the other side")
		expect(ray_hit.entry == Vector3i(1, 0, 0), "the hit records the opposite face")
	)

	step("When the user places against the far voxel", func():
		ray_place = VoxelPicking.start_pick(Vector3(-100, 0, 0), Vector3(1, 0, 0), ray_frame, Vector3(1, 0, 0))
	)

	step("Then the placement lands on the adjacent near cell", func():
		expect(ray_place.target == Vector3i(600, 0, 0), "the placement keeps the hit as the target")
		expect(ray_place.add_target == Vector3i(599, 0, 0), "the placement lands on the near face")
	)

	step("When the user aims beside the far voxel", func():
		ray_hit = VoxelPicking.ray_voxel(Vector3(-100, 5, 0), Vector3(1, 0, 0), ray_frame)
	)

	step("Then the offset ray misses", func():
		expect(ray_hit.hit == VoxelPicking.NONE, "an offset ray misses the far voxel")
	)

	step("When the user aims away from the far voxel", func():
		ray_hit = VoxelPicking.ray_voxel(Vector3(700, 0, 0), Vector3(1, 0, 0), ray_frame)
	)

	step("Then the ray that points away misses", func():
		expect(ray_hit.hit == VoxelPicking.NONE, "a ray that points away misses")
	)

	step("When the ray direction is zero", func():
		ray_hit = VoxelPicking.ray_voxel(Vector3(-100, 0, 0), Vector3.ZERO, ray_frame)
	)

	step("Then the zero ray misses", func():
		expect(ray_hit.hit == VoxelPicking.NONE, "a zero-length ray misses")
	)

	step("When the frame is empty", func():
		ray_hit = VoxelPicking.ray_voxel(Vector3(-100, 0, 0), Vector3(1, 0, 0), VoxelFrame.new())
	)

	step("Then the empty frame misses", func():
		expect(ray_hit.hit == VoxelPicking.NONE, "an empty frame has no voxel to pick")
	)

	step("When the frame is missing", func():
		ray_hit = VoxelPicking.ray_voxel(Vector3(-100, 0, 0), Vector3(1, 0, 0), null)
	)

	step("Then the missing frame misses", func():
		expect(ray_hit.hit == VoxelPicking.NONE, "a missing frame has no voxel to pick")
	)

	step("Given two voxels with the camera between them", func():
		ray_frame = VoxelFrame.new()
		var material := VoxelFrame.material(State.current_color)
		ray_frame.set_cell(Vector3i(0, 0, 0), material)
		ray_frame.set_cell(Vector3i(6, 0, 0), material)
	)

	step("When the camera sits inside the bounds and looks along the axis", func():
		ray_hit = VoxelPicking.ray_voxel(Vector3(3, 0, 0), Vector3(1, 0, 0), ray_frame)
	)

	step("Then the inside ray reaches the voxel ahead", func():
		expect(ray_hit.hit == Vector3i(6, 0, 0), "an inside origin reaches the voxel ahead")
		expect(ray_hit.entry == Vector3i(-1, 0, 0), "the hit records the near face")
	)

	step("When the camera sits inside a voxel", func():
		ray_hit = VoxelPicking.ray_voxel(Vector3(0, 0, 0), Vector3(1, 0, 0), ray_frame)
	)

	step("Then the ray reports the origin voxel with no entry face", func():
		expect(ray_hit.hit == Vector3i(0, 0, 0), "the origin voxel is the hit")
		expect(ray_hit.entry == Vector3i.ZERO, "an origin hit has no entry face")
	)

	step("When the camera looks backward along the axis", func():
		ray_hit = VoxelPicking.ray_voxel(Vector3(3, 0, 0), Vector3(-1, 0, 0), ray_frame)
	)

	step("Then the ray reaches the voxel behind", func():
		expect(ray_hit.hit == Vector3i(0, 0, 0), "the backward ray reaches the voxel behind")
		expect(ray_hit.entry == Vector3i(1, 0, 0), "the hit records the far face")
	)

	step("Given a voxel on the diagonal of a single-cell frame", func():
		ray_frame = VoxelFrame.new()
		ray_frame.set_cell(Vector3i(5, 5, 5), VoxelFrame.material(State.current_color))
	)

	step("When the camera aims along the diagonal", func():
		ray_hit = VoxelPicking.ray_voxel(Vector3(0.2, 0.3, 0.4), Vector3(1, 1, 1).normalized(), ray_frame)
	)

	step("Then the diagonal ray reaches the voxel", func():
		expect(ray_hit.hit == Vector3i(5, 5, 5), "the diagonal ray reaches the voxel")
	)

	step("Given two voxels more than the old iteration cap apart", func():
		ray_frame = VoxelFrame.new()
		var material := VoxelFrame.material(State.current_color)
		ray_frame.set_cell(Vector3i(0, 4, 0), material)
		ray_frame.set_cell(Vector3i(2000, 0, 0), material)
	)

	step("When the camera aims along the long empty span", func():
		ray_hit = VoxelPicking.ray_voxel(Vector3(-10, 0, 0), Vector3(1, 0, 0), ray_frame)
	)

	step("Then the ray crosses the span and reaches the far voxel", func():
		expect(ray_hit.hit == Vector3i(2000, 0, 0), "the ray crosses 2000 cells and reaches the voxel")
	)

	step("Given the camera on the near face of a voxel", func():
		ray_frame = VoxelFrame.new()
		ray_frame.set_cell(Vector3i(0, 0, 0), VoxelFrame.material(State.current_color))
	)

	step("When the camera sits exactly on the voxel face", func():
		ray_hit = VoxelPicking.ray_voxel(Vector3(-0.5, 0, 0), Vector3(1, 0, 0), ray_frame)
	)

	step("Then the ray reaches the voxel at the face", func():
		expect(ray_hit.hit == Vector3i(0, 0, 0), "a ray from the face reaches the voxel")
	)
