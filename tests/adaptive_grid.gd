extends "res://tests/test.gd"

var viewport: SubViewport
var grid: MeshInstance3D
var grid_mesh: Mesh
var near_images: Array
var far_images: Array
var near_row := 0
var far_row := 0


func _ready() -> void:
	timeout = 30.0
	test("the grid keeps voxel alignment and readable divisions when zoomed out", _run)


func _run() -> void:
	step("Given a large document and the floor grid", func():
		viewport = editor_viewport()
		viewport.get_parent().stretch = false
		viewport.size = Vector2i(800, 500)
		grid = viewport.get_node("ViewportScene/Grid")
		State.document = VoxelDocument.new()
		State.paint(Vector3i(-128, 0, -128), VoxelFrame.material(Color.RED))
		State.paint(Vector3i(128, 0, 128), VoxelFrame.material(Color.RED))
		State.floor_axis = Vector3.Axis.AXIS_Y
		State.floor_index = 0
		grid.rebuild()
		grid_mesh = grid.mesh
	)
	step("Then the grid covers the document with a constant amount of geometry", func():
		expect(grid_mesh.surface_get_array_len(0) == 4, "a large grid uses four vertices")
		expect(grid_mesh.surface_get_array_index_len(0) == 6, "a large grid uses two triangles")
		var vertices: PackedVector3Array = grid_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		expect(vertices.has(Vector3(259, 0, 259)), "the grid covers the document bounds and margins")
		expect(grid.position == Vector3(-129.5, -0.5, -129.5), "the grid retains voxel-face alignment")
	)
	step("When the user changes the floor axis and layer", func():
		State.floor_axis = Vector3.Axis.AXIS_X
		State.floor_index = 4
	)
	step("Then the grid follows the new floor plane", func():
		expect(grid.position.x == 3.5, "the grid lies under the chosen X layer")
		var planar := true
		for vertex in grid.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
			planar = planar and vertex.x == 0.0
		expect(planar, "the grid lies on the X floor plane")
		State.floor_axis = Vector3.Axis.AXIS_Y
		State.floor_index = 0
		grid_mesh = grid.mesh
	)
	step("When the user changes zoom and projection", func():
		camera_rig().is_orthogonal = true
		camera_rig().set_view("top")
		camera_rig().center_on(AABB(Vector3(-10, -0.5, -10), Vector3(20, 1, 20)))
		camera_rig().zoom(8.0)
		camera_rig().is_orthogonal = false
	)
	step("Then changing the view reuses the grid geometry", func():
		expect(grid.mesh == grid_mesh, "zoom and projection changes reuse the grid mesh")
		viewport_scene()._on_grid_toggle_toggled(false)
		expect(not grid.visible, "the grid toggle hides the adaptive grid")
		viewport_scene()._on_grid_toggle_toggled(true)
		expect(grid.visible, "the grid toggle shows the adaptive grid")
	)
	if DisplayServer.get_name() == "headless":
		return
	step("Given a top view with visible voxel divisions", func():
		viewport.get_node("ViewportScene/VoxelRenderer").visible = false
		camera_rig().is_orthogonal = true
		camera_rig().center_on(AABB(Vector3(-10, -0.5, -10), Vector3(20, 1, 20)))
		near_row = roundi(camera_rig().unproject_position(Vector3(0, -0.5, 5)).y)
	)
	near_images = await _capture_grid()
	step("When the user zooms out over the large document", func():
		camera_rig().zoom(8.0)
		far_row = roundi(camera_rig().unproject_position(Vector3(0, -0.5, 5)).y)
	)
	far_images = await _capture_grid()
	step("Then larger divisions remain readable instead of dense voxel lines", func():
		var near_lines := _line_count(near_images, near_row)
		var far_lines := _line_count(far_images, far_row)
		print("Grid line groups: %s close, %s zoomed out" % [near_lines, far_lines])
		expect(near_lines >= 10 and near_lines < 80, "the close view shows distinct voxel divisions")
		expect(far_lines >= 5 and far_lines < 80, "the zoomed-out view shows sparse larger divisions")
		near_images[0].save_png(_dir() + "/Near.png")
		far_images[0].save_png(_dir() + "/Far.png")
	)


func _capture_grid() -> Array:
	grid.visible = true
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var with_grid := viewport.get_texture().get_image()
	grid.visible = false
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var without_grid := viewport.get_texture().get_image()
	grid.visible = true
	return [with_grid, without_grid]


func _line_count(images: Array, row: int) -> int:
	var count := 0
	var previous := false
	for x in range(200, 600):
		var visible_color: Color = images[0].get_pixel(x, row)
		var background_color: Color = images[1].get_pixel(x, row)
		var difference := visible_color - background_color
		var line := maxf(absf(difference.r), maxf(absf(difference.g), absf(difference.b))) > 0.04
		if line and not previous:
			count += 1
		previous = line
	return count
