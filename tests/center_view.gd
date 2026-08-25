extends "res://tests/test.gd"

var _inst: Node = null
var _bar: ControlBar
var _vp: EditorViewport
var _center := Vector2.ZERO


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("the center button frames the selection or the whole model", _run)


func _press_center() -> void:
	(_bar.get_node("%CenterBtn") as Button).pressed.emit()


func _left_drag(from: Vector2, rel: Vector2) -> void:
	var svp := _vp.get_viewport()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = from
	svp.push_input(press)
	var motion := InputEventMouseMotion.new()
	motion.position = from + rel
	motion.relative = rel
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	svp.push_input(motion)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = from + rel
	svp.push_input(release)


func _run() -> void:
	step("Given an editor with some painted voxels and no selection", func():
		_bar = _inst.get_node("%ControlBar") as ControlBar
		_vp = editor_viewport(_inst)
		var svp := _vp.get_viewport()
		svp.get_parent().stretch = false
		svp.size = Vector2i(800, 500)
		_center = Vector2(400.0, 250.0)
		_left_drag(_center, Vector2(0.0, 40.0))
		expect(State.document.bounds().has_volume(), "the drag painted voxels")
		expect(State.selection.is_empty(), "no selection is active")
	)

	step("When the user presses the center button", func():
		_press_center()
	)

	step("Then the camera frames the whole model", func():
		var box := State.document.bounds()
		var rig := _vp.camera_rig
		expect(rig._target == box.get_center(), "the target is the model center")
		expect(is_equal_approx(rig._dist, maxf(box.size.length(), 16.0) * 1.5), "the distance fits the model")
	)

	step("When the user selects cells far from the paint stroke and presses center again", func():
		State.selection.add(Vector3i(20, 5, -8))
		State.selection.add(Vector3i(22, 6, -8))
		_press_center()
	)

	step("Then the camera frames the selection instead", func():
		var rig := _vp.camera_rig
		var span := AABB(Vector3(20, 5, -8), Vector3.ONE).merge(AABB(Vector3(22, 6, -8), Vector3.ONE))
		expect(rig._target == span.get_center(), "the target is the selection center")
		expect(is_equal_approx(rig._dist, maxf(span.size.length(), 16.0) * 1.5), "the distance fits the selection")
	)

	step("When the user clears the selection and presses center once more", func():
		State.clear_selection()
		_press_center()
	)

	step("Then the camera frames the whole model again", func():
		var box := State.document.bounds()
		expect(_vp.camera_rig._target == box.get_center(), "the target returns to the model center")
	)
