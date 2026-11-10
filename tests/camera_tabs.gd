extends "res://tests/test.gd"

## Checks that a tab keeps its camera pose and that no other camera overwrites
## the pose of the active document.

var rig: EditorCameraRig
var first: VoxelDocument
var second: VoxelDocument
var target := Vector3.ZERO
var distance := 0.0
var yaw := 0.0
var pitch := 0.0


func _ready() -> void:
	test("the camera pose survives a tab switch", _run, "camera_tabs")


func _run() -> void:
	step("Given two tabs and a moved camera", func():
		State.stop()
		first = VoxelDocument.new()
		first.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color.RED))
		second = VoxelDocument.new()
		second.set_cell(0, Vector3i(4, 0, 0), VoxelFrame.material(Color.RED))
		var documents: Array[VoxelDocument] = [first, second]
		State.set_tabs(documents, 1)
		rig = main.get_node("%Viewport").get_node("%CameraRig")
		State.activate_tab(0)
		rig.orbit(Vector2(100, 40))
		rig.zoom(1.5)
		rig.pan(Vector2(30, 20))
		target = rig._target
		distance = rig._dist
		yaw = rig._yaw
		pitch = rig._pitch
	)
	step("When the user switches away and back", func():
		State.activate_tab(1)
		State.activate_tab(0)
	)
	step("Then the camera returns to the same pose", func():
		expect(rig._target.is_equal_approx(target), "the target is restored")
		expect(is_equal_approx(rig._dist, distance), "the distance is restored")
		expect(is_equal_approx(rig._yaw, yaw), "the yaw is restored")
		expect(is_equal_approx(rig._pitch, pitch), "the pitch is restored")
	)
