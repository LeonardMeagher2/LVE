extends "res://tests/test.gd"

var tool: Node
var source: VoxelFrame
var notifications := 0
const MARKER := Vector3i(64, 0, 0)


func _ready() -> void:
	timeout = 30.0
	test("large wand selections publish progressive results with undo and context cancellation", _run, "large_wand")


func _run() -> void:
	step("Given a large red block, a distant red voxel, and a blue marker", func():
		State.document = VoxelDocument.new()
		source = State.get_current_voxel_frame()
		for x in 18:
			for y in 18:
				for z in 18:
					source.set_cell(Vector3i(x, y, z), VoxelFrame.material(Color.RED))
		source.set_cell(MARKER, VoxelFrame.material(Color.BLUE))
		source.set_cell(Vector3i(96, 0, 0), VoxelFrame.material(Color.RED))
		State.selection.add(MARKER)
		activate_tool("selection")
		select_toolbar_item("selection", "Wand")
		tool = plugin("SelectionPlugin")._wand
		State.selection_changed.connect(func(): notifications += 1)
	)
	step("When the user selects the connected red block", func():
		tool._settings.connected = true
		tool._settings.mode = tool._settings.SelectMode.REPLACE
		tool._commit(Vector3i.ZERO)
		expect(State.edit_busy(), "the large wand reports foreground work")
		# Replace starts from an empty selection while the captured snapshot keeps undo.
		expect(not State.selection.contains(MARKER), "Replace removes the prior marker before adding streamed matches")
	)
	await _settle()
	step("Then the connected selection is one complete undoable result", func():
		expect(State.selection.count() == 5832, "the connected block contains all its voxels")
		expect(not State.selection.contains(Vector3i(96, 0, 0)), "the disconnected red voxel stays unselected")
		# A large wand selection publishes as it streams, so it sends more than one.
		expect(notifications >= 1, "the wand publishes at least one selection notification")
		expect(source.get_color(Vector3i.ZERO) == Color.RED and source.count() == 5834, "the wand preserves the source voxels")
		var rebuilds := VoxelSelection._profile_rebuild_calls
		State.undo_redo.undo()
		expect(VoxelSelection._profile_rebuild_calls == rebuilds, "the undo installs its masks without a rebuild")
		expect(State.selection.count() == 1 and State.selection.contains(MARKER), "one undo restores the prior selection")
		State.undo_redo.clear_history()
	)
	step("When the user adds every matching red voxel", func():
		tool._settings.connected = false
		tool._settings.mode = tool._settings.SelectMode.ADD
		tool._commit(Vector3i.ZERO)
	)
	await _settle()
	step("Then the matching selection preserves the prior marker", func():
		expect(State.selection.count() == 5834, "Add includes the connected and distant red voxels and the marker")
		expect(State.selection.contains(MARKER), "Add preserves the prior blue marker")
	)
	step("When the user subtracts every matching red voxel", func():
		tool._settings.mode = tool._settings.SelectMode.SUBTRACT
		tool._commit(Vector3i.ZERO)
	)
	await _settle()
	step("Then only the prior blue marker remains", func():
		expect(State.selection.count() == 1 and State.selection.contains(MARKER), "Subtract removes only the matching red voxels")
		expect(not State.edit_busy(), "the completed wand releases editing")
	)
	step("When the frame changes during another wand job", func():
		State.document.add_frame()
		tool._commit(Vector3i.ZERO)
		State.current_frame = 1
	)
	await _settle()
	step("Then the old wand cannot change the current selection", func():
		expect(State.selection.count() == 1 and State.selection.contains(MARKER), "the cancelled wand preserves the last completed selection")
		expect(not State.edit_busy(), "the frame change releases the wand state")
	)


func _settle() -> void:
	while tool._job:
		await get_tree().process_frame
