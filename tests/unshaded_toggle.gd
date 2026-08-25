extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("can render the viewport unshaded and back", _run)


func _debug_draw() -> int:
	return (_vp.get_node("%Viewport") as SubViewport).debug_draw


func _run() -> void:
	step("Given an editor viewport with shaded voxels", func():
		_vp = editor_viewport(_inst)
		expect(_debug_draw() == Viewport.DEBUG_DRAW_DISABLED, "the viewport starts shaded")
	)

	step("When the user enables the unshaded mode", func():
		_vp.set_unshaded(true)
	)
	step("Then the viewport renders without shading", func():
		expect(_debug_draw() == Viewport.DEBUG_DRAW_UNSHADED, "the viewport renders unshaded")
	)

	step("When the user disables the unshaded mode", func():
		_vp.set_unshaded(false)
	)
	step("Then the viewport shades again", func():
		expect(_debug_draw() == Viewport.DEBUG_DRAW_DISABLED, "the viewport renders shaded")
	)
