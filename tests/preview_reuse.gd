extends "res://tests/test.gd"

var preview: MeshInstance3D
var other: MeshInstance3D
var pattern := {}
var selected: VoxelSelection
var solid_mesh: Mesh
var outline: Mesh
var started_us := 0


func _ready() -> void:
	timeout = 30.0
	test("voxel previews reuse geometry for movement, color changes, and repeated shapes", _run)


func _run() -> void:
	step("Given a large solid preview", func():
		preview = _new_preview()
		selected = VoxelSelection.new()
		selected.from_box(Vector3i.ZERO, Vector3i(31, 31, 31))
		for cell_position in selected.all_cells():
			pattern[cell_position] = Color.TRANSPARENT
		pattern.make_read_only()
		started_us = Time.get_ticks_usec()
		_show_pattern(preview, Color.RED)
	)
	while not preview.is_settled():
		await get_tree().process_frame
	print("First solid preview: %.2f ms" % ((Time.get_ticks_usec() - started_us) / 1000.0))
	step("Then the preview represents the complete voxel volume", func():
		solid_mesh = preview.mesh
		expect(preview.visible and solid_mesh.get_aabb().size == Vector3.ONE * 32, "the solid preview contains the full volume")
	)
	started_us = Time.get_ticks_usec()
	for index in 8:
		step("When the user moves the preview and changes its color", func():
			preview.position = Vector3(index * 10, 0, 0)
			_show_pattern(preview, Color.BLUE if index % 2 else Color.GREEN)
		)
		while not preview.is_settled():
			await get_tree().process_frame
		step("Then the preview reuses the solid geometry", func():
			expect(preview.mesh == solid_mesh, "movement and display color reuse the completed solid mesh")
			expect(preview.position == Vector3(index * 10, 0, 0), "the reused preview retains its current position")
			expect((preview.material_override.get_shader_parameter("cursor_color") as Color) == (Color.BLUE if index % 2 else Color.GREEN), "the reused preview has the current display color")
		)
	print("Eight preview moves and color changes: %.2f ms" % ((Time.get_ticks_usec() - started_us) / 1000.0))
	step("When another tool requests the same solid shape", func():
		other = _new_preview()
		_show_pattern(other, Color.YELLOW)
	)
	while not other.is_settled():
		await get_tree().process_frame
	step("Then both tools share geometry with independent colors", func():
		expect(other.mesh == solid_mesh, "tools reuse the same completed solid mesh")
		expect(other.material_override != preview.material_override, "each tool has its own display material")
	)
	step("When the user switches to an outline of that volume", func():
		preview.show_selection(selected)
	)
	while not preview.is_settled():
		await get_tree().process_frame
	step("Then the outline contains only the twelve exterior edges", func():
		outline = preview.mesh
		expect(outline.surface_get_array_len(0) == 24, "the outline contains twelve merged edges")
	)
	step("When the user switches back to the solid and then the outline", func():
		_show_pattern(preview, Color.RED)
		expect(preview.mesh == solid_mesh and preview.is_settled(), "the solid shape returns from the cache immediately")
		preview.show_selection(selected)
		expect(preview.mesh == outline and preview.is_settled(), "the outline shape returns from the cache immediately")
	)
	step("When the user requests two colored source voxels", func():
		preview.show_voxels({Vector3i.ZERO: Color.RED, Vector3i.RIGHT: Color.BLUE}, Color.WHITE)
	)
	while not preview.is_settled():
		await get_tree().process_frame
	step("Then the colored preview retains both source colors", func():
		var colors: PackedColorArray = preview.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
		expect(colors.has(Color.RED) and colors.has(Color.BLUE), "the solid preview keeps both voxel colors")
		expect((preview.material_override.get_shader_parameter("cursor_color") as Color) == Color.WHITE, "the colored preview keeps a neutral material tint")
	)
	step("When the source dictionary changes after a preview request", func():
		var mutable := {Vector3i.ZERO: Color.TRANSPARENT, Vector3i(0, 2, 0): Color.TRANSPARENT}
		preview.show_voxels(mutable, Color.GREEN, false, 0, false)
		mutable.erase(Vector3i.ZERO)
	)
	while not preview.is_settled():
		await get_tree().process_frame
	step("Then the worker uses the complete requested snapshot", func():
		expect(preview.mesh.get_aabb().size == Vector3(1, 3, 1), "the preview retains both cells from its input snapshot")
	)
	step("When the user clears a new solid preview before it finishes", func():
		var changed := pattern.duplicate()
		changed[Vector3i(32, 0, 0)] = Color.TRANSPARENT
		preview.show_voxels(changed, Color.RED, false, 0, false)
		preview.show_selection(null)
	)
	while not preview.is_settled():
		await get_tree().process_frame
	step("Then the old solid result leaves the preview hidden", func():
		expect(not preview.visible, "the cleared preview stays hidden after its worker finishes")
	)


func _new_preview() -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.set_script(load("res://plugins/brush/BrushPreview.gd"))
	main.add_child(instance)
	return instance


func _show_pattern(instance: MeshInstance3D, color: Color) -> void:
	instance.show_voxels(pattern, color, false, 0, false)
