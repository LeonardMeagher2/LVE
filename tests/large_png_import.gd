extends "res://tests/test.gd"

var importer: Node
var clipboard: Node
var frame: VoxelFrame
var image_path := ""
var cancelled_result: Error = OK
var cancelled_done := false


func _ready() -> void:
	timeout = 30.0
	test("large PNG images open as complete documents and cancel on document changes", _run)


func _run() -> void:
	step("Given an opaque PNG with sixteen thousand pixels", func():
		importer = plugin("ImageImportPlugin")
		clipboard = plugin("ClipboardPlugin")
		var image := Image.create(128, 128, false, Image.FORMAT_RGBA8)
		image.fill(Color.RED)
		image_path = "user://voxi_png_large_%s.png" % Time.get_ticks_usec()
		expect(image.save_png(image_path) == OK, "the large PNG fixture is saved")
		State.document = VoxiDocument.new()
		frame = State.get_current_voxel_frame()
		State.floor_axis = Vector3.Axis.AXIS_Y
		camera_rig().set_view("top")
		camera_rig().is_orthogonal = true
	)
	var error: Error = await importer.import_image(image_path)
	step("Then the complete image opens directly with its palette", func():
		expect(error == OK, "the large PNG is loaded")
		frame = State.get_current_voxel_frame()
		expect(frame.count() == 16384, "all opaque PNG pixels become voxels")
		expect(frame.get_bounds().size == Vector3(128, 1, 128), "the image is one voxel thick on the floor plane")
		expect(State.document.palette == [Color.RED], "the image contributes one unique red color")
		expect(not State.edit_busy(), "the imported image releases editing")
		expect(not clipboard._paste_tool._active, "opening the large PNG creates no placement step")
		expect(not State.undo_redo.has_undo(), "opening the large PNG starts a new edit history")
	)
	step("When the user changes documents while another PNG is loading", func():
		_start_cancelled_import()
		expect(State.edit_busy(), "PNG loading reports foreground work")
		State.document = VoxiDocument.new()
	)
	while not cancelled_done:
		await get_tree().process_frame
	step("Then the old image cannot change the new document", func():
		expect(cancelled_result == ERR_BUSY, "the old PNG load is cancelled")
		expect(State.get_current_voxel_frame().count() == 0, "the new document stays empty")
		expect(State.document.palette.is_empty(), "the new palette stays empty")
		expect(not clipboard._paste_tool._active, "the cancelled PNG creates no placement")
		expect(not State.edit_busy(), "the cancelled PNG load releases editing")
	)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(image_path))


func _start_cancelled_import() -> void:
	cancelled_result = await importer.import_image(image_path)
	cancelled_done = true
