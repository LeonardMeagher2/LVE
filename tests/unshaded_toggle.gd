extends "res://tests/test.gd"

var camera_menu_btn: MenuButton


func _ready() -> void:
	test("can render the viewport unshaded and back", _run)


func _debug_draw() -> int:
	return (editor_viewport() as SubViewport).debug_draw


func _pick(text: String) -> void:
	var popup := camera_menu_btn.get_popup()
	for i in popup.item_count:
		if popup.get_item_text(i).to_lower() == text:
			popup.index_pressed.emit(i)
			return


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
