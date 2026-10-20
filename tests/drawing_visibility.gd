extends "res://tests/test.gd"

var renderer: VoxelRenderer
var kept_visible := true
var edit: VoxelEditTransaction


func _ready() -> void:
	test("drawing keeps completed surfaces visible until replacement meshes are ready", _run)


func _run() -> void:
	step("Given painted voxels on both sides of a chunk boundary", func():
		State.document = VoxelDocument.new()
		State.paint(Vector3i(14, 0, 0), VoxelFrame.material(Color.RED))
		State.paint(Vector3i(17, 0, 0), VoxelFrame.material(Color.RED))
		renderer = load("res://ui/Viewport/VoxelRenderer.tscn").instantiate()
		main.add_child(renderer)
	)
	await _settle()
	step("When the user draws repeatedly across the boundary", func():
		edit = State.begin_edit()
	)
	for x in range(13, 20):
		var cell := Vector3i(x, 0, 0)
		State.paint(cell, VoxelFrame.material(Color.BLUE))
		var affected: Array[Vector3i] = [cell]
		State.cells_changed.emit(0, affected)
		kept_visible = kept_visible and _mesh_at(Vector3.ZERO) != null
		kept_visible = kept_visible and _mesh_at(Vector3(16, 0, 0)) != null
		await get_tree().process_frame
	State.finish_edit(edit)
	step("Then both existing chunks stay visible throughout the stroke", func():
		expect(kept_visible, "both chunks remain visible while replacements are pending")
	)
	await _settle()
	step("Then the completed surfaces display the final brush color", func():
		expect(_all_blue(), "the final surfaces are blue")
	)
	step("When a full refresh is requested for the same frame", func():
		State.paint(Vector3i(13, 0, 0), VoxelFrame.material(Color.GREEN))
		renderer.refresh()
		expect(_mesh_at(Vector3.ZERO) != null, "the same-frame refresh keeps its completed mesh visible")
	)
	await _settle()
	step("When the user switches to another frame with different voxels in the same chunk", func():
		State.document.add_frame()
		State.document.set_cell(1, Vector3i(14, 0, 0), VoxelFrame.material(Color.YELLOW))
		State.current_frame = 1
		expect(_mesh_at(Vector3.ZERO) == null, "the new frame hides the previous frame's geometry")
	)
	await _settle()
	step("Then the new frame displays its own completed surface", func():
		expect(_mesh_at(Vector3.ZERO) != null, "the new frame has a visible surface")
	)
	step("When the user erases the last voxel in the chunk", func():
		State.paint(Vector3i(14, 0, 0), VoxelFrame.material(Color.TRANSPARENT))
		var affected: Array[Vector3i] = [Vector3i(14, 0, 0)]
		State.cells_changed.emit(1, affected)
		expect(_mesh_at(Vector3.ZERO) == null, "the erased chunk disappears immediately")
	)


func _settle() -> void:
	while not renderer.is_settled():
		await get_tree().process_frame


func _mesh_at(position: Vector3) -> Mesh:
	for child in renderer.get_children():
		if child is MeshInstance3D and child.visible and child.position == position:
			return child.mesh
	return null


func _all_blue() -> bool:
	var found := false
	for child in renderer.get_children():
		if child is MeshInstance3D and child.visible:
			found = true
			var arrays: Array = child.mesh.surface_get_arrays(0)
			var material: StandardMaterial3D = child.material_override
			var image := material.albedo_texture.get_image()
			for uv: Vector2 in arrays[Mesh.ARRAY_TEX_UV]:
				if image.get_pixelv(Vector2i(uv * Vector2(image.get_size()))) != Color.BLUE:
					return false
	return found
