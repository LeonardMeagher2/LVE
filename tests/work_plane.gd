extends "res://tests/test.gd"

var _inst: Node = null
var _vp: EditorViewport
var _center := Vector2.ZERO
var _floor_pick := State.NONE
var _voxel_pick := State.NONE


func _ready() -> void:
	var scene: PackedScene = load("res://ui/main.tscn")
	_inst = scene.instantiate()
	get_tree().root.add_child.call_deferred(_inst)
	test("anchors a drag to the plane through the clicked point", _run)


func _run() -> void:
	step("Given the editor viewport at its default view", func():
		_vp = _inst.get_node("Content/Root/Body/CenterPane/ViewportContainer/Viewport/Editor")
		var svp := _vp.get_viewport()
		var vsize: Vector2i = svp.size
		if vsize.x <= 0 or vsize.y <= 0:
			svp.size = Vector2i(800, 500)
			vsize = svp.size
		_center = Vector2(vsize.x * 0.5, vsize.y * 0.5)
	)

	step("When the user aims at the center of the empty grid", func():
		var req := _vp.pick_request(_center)
		_floor_pick = VoxelPicking.start_pick(req.origin, req.dir, req.cells).target
	)

	step("Then the aim lands on the floor", func():
		expect(_floor_pick != State.NONE, "the aim hits the grid")
		expect(_floor_pick.y == 0, "the aim is on the floor layer")
	)

	step("Given a voxel where the center ray lands", func():
		State.document.frames[0].cells[_floor_pick] = State.document.ensure_color(State.current_color)
		_vp.sync_to(0)
	)

	step("When the user aims at the center of the viewport", func():
		var req := _vp.pick_request(_center)
		_voxel_pick = VoxelPicking.start_pick(req.origin, req.dir, req.cells).target
	)

	step("Then the aim lands on the clicked voxel", func():
		expect(_voxel_pick != State.NONE, "the aim hits the voxel")
		expect(_voxel_pick == _floor_pick, "the aim is the voxel the ray hits")
	)
