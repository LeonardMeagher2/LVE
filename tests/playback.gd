extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("can play the voxel animation", _run)


func _run() -> void:
	step("Given a document with two distinct frames", func():
		_vp = _inst.get_node("Content/Root/Body/CenterPane/ViewportContainer/Viewport/Editor")
		State.document.add_frame()
		State.document.frames[1].cells[Vector3i(9, 0, 9)] = State.document.ensure_color(State.current_color)
		State.document.frames[0].delay_ms = 250
		State.document.frames[1].delay_ms = 250
		_vp.sync_to(0)
	)

	step("When the user plays the animation", func():
		State.playback.set_playing(true)
	)

	step("Then the displayed frame advances over time", func():
		var seen := {}
		for i in 30:
			await get_tree().process_frame
			seen[_vp.frame_index] = true
		expect(seen.size() > 1, "the displayed frame changes while playing")
		State.playback.set_playing(false)
	)
