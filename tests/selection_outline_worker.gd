extends "res://tests/test.gd"

var preview: MeshInstance3D
var selected: VoxelSelection


func _ready() -> void:
	test("large selection outlines finish in the background and discard stale results", _run)


func _run() -> void:
	step("Given a large rectangular selection", func():
		selected = VoxelSelection.new()
		selected.from_box(Vector3i.ZERO, Vector3i(31, 15, 15))
		preview = load("res://Plugins/Selection/SelectionPreview.tscn").instantiate()
		main.add_child(preview)
		preview.show_selection(selected)
	)
	while not preview.is_settled():
		await get_tree().process_frame
	step("Then the outline contains the twelve exterior edges", func():
		expect(preview.visible, "the completed outline is visible")
		expect(preview.mesh.surface_get_array_len(0) == 24, "the rectangle has twelve merged line segments")
	)
	step("When the user requests another large outline and then clears the selection", func():
		selected.from_box(Vector3i.ZERO, Vector3i(63, 15, 15))
		preview.show_selection(selected)
	)
	await get_tree().create_timer(0.11).timeout
	step("When the user clears the selection before the result is installed", func():
		preview.show_selection(VoxelSelection.new())
	)
	while not preview.is_settled():
		await get_tree().process_frame
	step("Then the stale result leaves the outline hidden", func():
		expect(not preview.visible, "the cleared selection has no visible outline")
	)
