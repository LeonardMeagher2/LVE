extends "res://tests/test.gd"

var renderer: VoxelRenderer
var large: VoxelFrame
var frame_us := 0
var undo_us := 0
var redo_us := 0
var cold_ms := 0
var meshes := []


func _ready() -> void:
	timeout = 30.0
	test("a large solid frame reuses its surfaces after frame switching and history restoration", _run)


func _run() -> void:
	step("Given a quarter-million-voxel frame", func():
		State.document = VoxiDocument.new()
		State.paint(Vector3i.ZERO, Color.RED)
		State.begin_stroke()
		var colors := {}
		for z in 64:
			for y in 64:
				for x in 64:
					colors[Vector3i(x, y, z)] = Color.RED
		State.get_current_voxel_frame().set_cells(colors)
		State.end_stroke()
		State.selection_changed.emit()
		large = State.get_current_voxel_frame()
		renderer = load("res://ui/Viewport/VoxelRenderer.tscn").instantiate()
		main.add_child(renderer)
	)
	var started := Time.get_ticks_msec()
	await _settle()
	cold_ms = Time.get_ticks_msec() - started
	step("Then only exterior surfaces are rendered", func():
		var quads := 0
		for child in renderer.get_children():
			if child is MeshInstance3D and child.visible:
				quads += child.mesh.surface_get_array_index_len(0) / 6
				meshes.append(child.mesh)
		expect(large.count() == 262144, "the frame keeps all quarter-million voxels")
		expect(quads == 96, "the large solid frame uses ninety-six exterior quads")
	)
	step("When the user switches to an empty frame and back", func():
		State.document.add_frame()
		State.current_frame = 1
		var begin := Time.get_ticks_usec()
		State.current_frame = 0
		frame_us = Time.get_ticks_usec() - begin
	)
	await _settle()
	step("Then frame switching reuses the existing meshes", func():
		expect(_meshes_reused(), "the cached frame uses its existing mesh resources")
	)
	step("When the user undoes and redoes the large edit", func():
		var begin := Time.get_ticks_usec()
		State.undo_redo.undo()
		undo_us = Time.get_ticks_usec() - begin
		expect(large.count() == 1, "undo restores the single original voxel")
		begin = Time.get_ticks_usec()
		State.undo_redo.redo()
		redo_us = Time.get_ticks_usec() - begin
	)
	await _settle()
	step("Then redo reuses the large frame's geometry", func():
		expect(large.count() == 262144, "redo restores all quarter-million voxels")
		expect(_meshes_reused(), "redo uses the existing mesh resources")
		print("Large frame: cold %s ms, switch %s us, undo %s us, redo %s us" % [cold_ms, frame_us, undo_us, redo_us])
	)


func _settle() -> void:
	while not renderer.is_settled():
		await get_tree().process_frame


func _meshes_reused() -> bool:
	var found := 0
	for child in renderer.get_children():
		if child is MeshInstance3D and child.visible:
			if not meshes.has(child.mesh):
				return false
			found += 1
	return found == meshes.size()
