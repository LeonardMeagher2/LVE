extends "res://tests/test.gd"

var rig: EditorCameraRig
var viewport: SubViewport
var _measured: Array = []

const VIEW_KEYS := [
	[KEY_1, "top", 0.0, 89.0],
	[KEY_2, "bottom", 0.0, -89.0],
	[KEY_3, "front", 0.0, 0.0],
	[KEY_4, "back", 180.0, 0.0],
	[KEY_5, "left", -90.0, 0.0],
	[KEY_6, "right", 90.0, 0.0],
	[KEY_7, "isometric", -45.0, 45.0],
]


func _ready() -> void:
	test("can snap the camera to every axis view and switch projection", _run)


func _angles_match(yaw_deg: float, pitch_deg: float) -> bool:
	return is_equal_approx(rig._yaw, deg_to_rad(yaw_deg)) \
		and is_equal_approx(rig._pitch, deg_to_rad(pitch_deg))


func _key(code: Key) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = true
	viewport.push_input(ev)


func _run() -> void:
	step("Given an editor viewport", func():
		rig = camera_rig()
	)

	step("When the user snaps to the back view", func():
		rig.set_view("back")
	)
	step("Then the camera looks along the front axis", func():
		expect(_angles_match(180.0, 0.0), "back view sets yaw 180 and pitch 0")
	)

	step("When the user snaps to the bottom view", func():
		rig.set_view("bottom")
	)
	step("Then the camera looks up from below", func():
		expect(_angles_match(0.0, -89.0), "bottom view sets pitch -89 degrees")
	)

	step("When the user snaps to the left view", func():
		rig.set_view("left")
	)
	step("Then the camera looks from the left side", func():
		expect(_angles_match(-90.0, 0.0), "left view sets yaw -90 and pitch 0")
	)

	step("When the user snaps to the right view", func():
		rig.set_view("right")
	)
	step("Then the camera looks from the right side", func():
		expect(_angles_match(90.0, 0.0), "right view sets yaw 90 and pitch 0")
	)

	step("When the user keeps the legacy side name", func():
		rig.set_view("side")
	)
	step("Then the camera still looks from the right side", func():
		expect(_angles_match(90.0, 0.0), "side stays an alias of right")
	)

	step("When the user presses every number row view key", func():
		viewport = editor_viewport()
		_measured = []
		for entry in VIEW_KEYS:
			_key(entry[0])
			_measured.append([rig._yaw, rig._pitch])
	)
	step("Then each key snaps the camera to its view", func():
		var i := 0
		for entry in VIEW_KEYS:
			var angles: Array = _measured[i]
			expect(is_equal_approx(angles[0], deg_to_rad(entry[2])) \
				and is_equal_approx(angles[1], deg_to_rad(entry[3])),
				"%s selects the %s view" % [OS.get_keycode_string(entry[0]), entry[1]])
			i += 1
	)

	step("When the user switches to orthographic projection", func():
		rig.is_orthogonal = true
	)
	step("Then the camera is orthographic and keeps its framing", func():
		var cam := rig
		expect(cam.projection == Camera3D.PROJECTION_ORTHOGONAL, "the camera uses orthogonal projection")
		var expected := 2.0 * rig._dist * tan(deg_to_rad(cam.fov) / 2.0)
		expect(is_equal_approx(cam.size, expected), "orthographic height matches the perspective framing")
	)

	step("When the user zooms in orthographic mode", func():
		rig.set_zoom_percent(200.0)
	)
	step("Then the view gets closer", func():
		var cam := rig
		var half := rig._init_dist / 2.0
		var expected := 2.0 * half * tan(deg_to_rad(cam.fov) / 2.0)
		expect(is_equal_approx(cam.size, expected), "zoom scales the orthographic height")
	)

	step("When the user switches back to perspective", func():
		rig.is_orthogonal = false
	)
	step("Then the camera uses perspective again", func():
		var cam := rig
		expect(cam.projection == Camera3D.PROJECTION_PERSPECTIVE, "the camera uses perspective projection")
		expect(is_equal_approx(rig.zoom_percent(), 200.0), "zoom level survives the projection switch")
	)
