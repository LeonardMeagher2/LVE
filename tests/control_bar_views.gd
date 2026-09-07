extends "res://tests/test.gd"

var camera_menu_btn: MenuButton


func _ready() -> void:
	test("the camera menu drives views, projection, and shading", _run)


func _popup() -> PopupMenu:
	return camera_menu_btn.get_popup()


func _index_of(text: String) -> int:
	var popup := _popup()
	for i in popup.item_count:
		if str(popup.get_item_text(i)).to_lower() == text:
			return i
	return -1


func _pick(text: String) -> void:
	var i := _index_of(text)
	expect(i >= 0, "the menu holds a %s item" % text)
	if i >= 0:
		_popup().index_pressed.emit(i)


func _run() -> void:
	step("Given the editor control bar and viewport", func():
		editor_viewport()
		camera_menu_btn = camera_menu()
	)

	step("When the user picks Front in the camera menu", func():
		_pick("front")
	)
	step("Then the camera faces the front", func():
		expect(is_equal_approx(camera_rig()._yaw, 0.0), "front view sets yaw 0")
		expect(is_equal_approx(camera_rig()._pitch, 0.0), "front view sets pitch 0")
	)

	step("When the user picks Bottom in the camera menu", func():
		_pick("bottom")
	)
	step("Then the camera moves below", func():
		expect(is_equal_approx(camera_rig()._pitch, deg_to_rad(-89.0)), "bottom view sets pitch -89 degrees")
	)

	step("When the user picks Orthographic in the camera menu", func():
		_pick("orthographic")
	)
	step("Then the camera turns orthographic and the item shows checked", func():
		expect(camera_rig().is_orthogonal, "the camera uses orthogonal projection")
		expect(_popup().is_item_checked(_index_of("orthographic")), "the Orthographic item shows checked")
	)

	step("When the user picks Orthographic again", func():
		_pick("orthographic")
	)
	step("Then the camera returns to perspective", func():
		expect(not camera_rig().is_orthogonal, "the camera uses perspective projection")
		expect(not _popup().is_item_checked(_index_of("orthographic")), "the Orthographic item shows unchecked")
	)

	step("When the user picks Unshaded in the camera menu", func():
		_pick("unshaded")
	)
	step("Then the viewport renders unshaded and the item shows checked", func():
		var svp := editor_viewport() as SubViewport
		expect(svp.debug_draw == Viewport.DEBUG_DRAW_UNSHADED, "the viewport renders unshaded")
		expect(_popup().is_item_checked(_index_of("unshaded")), "the Unshaded item shows checked")
	)
