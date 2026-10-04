extends "res://tests/test.gd"

var camera_menu_btn: MenuButton


func _ready() -> void:
	test("adjacent camera-menu radio items share one rendering mode", _run)


func _debug_draw() -> int:
	return (editor_viewport() as SubViewport).debug_draw


func _pick(text: String) -> void:
	var popup := camera_menu_btn.get_popup()
	for i in popup.item_count:
		if popup.get_item_text(i).to_lower() == text:
			popup.index_pressed.emit(i)
			return


func _checked(text: String) -> bool:
	var popup := camera_menu_btn.get_popup()
	for i in popup.item_count:
		if popup.get_item_text(i).to_lower() == text:
			return popup.is_item_checked(i)
	return false


func _run() -> void:
	step("Given an editor viewport with shaded voxels", func():
		camera_menu_btn = camera_menu()
		expect(_debug_draw() == Viewport.DEBUG_DRAW_DISABLED, "the viewport starts shaded")
	)

	step("When the user enables the unshaded mode", func():
		_pick("unshaded")
	)
	step("Then the viewport renders without shading", func():
		expect(_debug_draw() == Viewport.DEBUG_DRAW_UNSHADED, "the viewport renders unshaded")
	)

	step("When the user disables the unshaded mode", func():
		_pick("unshaded")
	)
	step("Then the viewport shades again", func():
		expect(_debug_draw() == Viewport.DEBUG_DRAW_DISABLED, "the viewport renders shaded")
	)
	step("When the user enables orthographic projection and switches from unshaded to wireframe", func():
		_pick("orthographic")
		_pick("unshaded")
		_pick("wireframe")
	)
	step("Then wireframe owns the rendering mode and projection stays independent", func():
		expect(_debug_draw() == Viewport.DEBUG_DRAW_WIREFRAME, "the viewport renders wireframe")
		expect(_checked("wireframe"), "the wireframe radio item is checked")
		expect(not _checked("unshaded"), "the unshaded radio item is cleared")
		expect(_checked("orthographic"), "the orthographic checkbox stays checked")
		expect(camera_rig().is_orthogonal, "the camera stays orthographic")
	)
	step("When the user switches back to unshaded", func():
		_pick("unshaded")
	)
	step("Then unshaded owns the rendering mode", func():
		expect(_debug_draw() == Viewport.DEBUG_DRAW_UNSHADED, "the viewport renders unshaded again")
		expect(_checked("unshaded"), "the unshaded radio item is checked")
		expect(not _checked("wireframe"), "the wireframe radio item is cleared")
	)
	step("When the user disables the selected rendering mode", func():
		_pick("unshaded")
	)
	step("Then normal shading returns with the rendering group cleared", func():
		expect(_debug_draw() == Viewport.DEBUG_DRAW_DISABLED, "the viewport returns to normal shading")
		expect(not _checked("unshaded") and not _checked("wireframe"), "both rendering radio items are cleared")
		expect(_checked("orthographic"), "the separate projection checkbox stays checked")
	)
