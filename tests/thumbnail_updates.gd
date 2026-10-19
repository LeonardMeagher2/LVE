extends "res://tests/test.gd"

var renders := 0
var watched: VoxelFrame


func _ready() -> void:
	test("thumbnail requests coalesce and render the final document state", _run)


func _run() -> void:
	State.document = VoxelDocument.new()
	watched = State.get_current_voxel_frame()
	VoxelImageRenderer.frame_rendered.connect(_rendered)
	step("When the user repeatedly edits one frame", func():
		for x in 32:
			State.paint(Vector3i(x, 0, 0), VoxelFrame.material(Color.BLUE))
			VoxelImageRenderer.request_frame_render(0)
	)
	await get_tree().create_timer(0.1).timeout
	step("Then the thumbnail waits for the edit burst to finish", func():
		expect(renders == 0, "the edit burst has no intermediate thumbnail")
	)
	while renders == 0:
		await get_tree().process_frame
	step("Then the final thumbnail is rendered once", func():
		expect(renders == 1, "the burst produces one thumbnail")
		expect(watched.count() == 32, "the final document keeps all edited cells")
	)
	step("When the user edits the same frame again", func():
		State.paint(Vector3i(32, 0, 0), VoxelFrame.material(Color.RED))
		VoxelImageRenderer.request_frame_render(0)
	)
	while renders < 2:
		await get_tree().process_frame
	step("Then the thumbnail refreshes after the next edit", func():
		expect(renders == 2, "the next edit produces another thumbnail")
		expect(watched.get_color(Vector3i(32, 0, 0)) == Color.RED, "the new voxel keeps its red color")
	)


func _rendered(index: int, _texture: ImageTexture) -> void:
	if index == 0 and State.get_voxel_frame(index) == watched:
		renders += 1
