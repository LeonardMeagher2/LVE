extends "res://tests/test.gd"

# The shared worker-job helper pumps a job's progress into its operation and
# always joins the worker. These tests drive real palette imports, not a
# stand-in job.
#
# Each test builds its own PalettePanel, so the editor's shared panel is never
# detached or freed. Every test then runs alone or in any order.

const PALETTE_PANEL_SCENE := preload("res://ui/PalettePanel/PalettePanel.tscn")
const IMAGE_SIDE := 1024

var panel: PalettePanel
var image_path := ""
var import_done := false
var import_error: Error = OK


func _ready() -> void:
	timeout = 30.0
	# The detach runs first, so a normal run proves the isolation before the
	# other tests reuse the fixture pattern.
	test("a palette import joins its worker after the caller detaches", _detached_caller, "worker_detached_caller")
	test("a palette import reports its operation and clears it when it finishes", _operation_lifecycle, "worker_operation_lifecycle")
	test("a palette import completes after its operation is removed", _removed_operation, "worker_removed_operation")


func _setup_test() -> void:
	import_done = false
	import_error = OK
	State.document = VoxelDocument.new()
	# Own fixture: a fresh panel keeps the editor's shared panel out of these tests.
	panel = PALETTE_PANEL_SCENE.instantiate()
	add_child(panel)
	while State.get_activity() != null:
		State.finish_operation(State.get_activity().id)
	await get_tree().process_frame


func _cleanup_test() -> void:
	while State.get_activity() != null:
		State.finish_operation(State.get_activity().id)
	if not image_path.is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(image_path))
		image_path = ""
	# Cancel and join this test's own worker, then free the fixture. A detach in
	# the test already joined it through `_exit_tree`. Two frames let a pending
	# thumbnail draw return before the node is deleted.
	if is_instance_valid(panel):
		if panel.get_parent() != null:
			panel.get_parent().remove_child(panel)
		await get_tree().process_frame
		await get_tree().process_frame
		panel.free()
		panel = null
	await get_tree().process_frame


func _import_palette(path: String) -> void:
	import_error = await panel.import_palette(path)
	import_done = true


func _save_red_image(prefix: String) -> void:
	image_path = "user://worker_coord_%s_%s.png" % [prefix, Time.get_ticks_usec()]
	var image := Image.create(IMAGE_SIDE, IMAGE_SIDE, false, Image.FORMAT_RGBA8)
	image.fill(Color.RED)
	expect(image.save_png(image_path) == OK, "the palette image is saved")


func _operation_lifecycle() -> void:
	step("Given a large palette image", func():
		_save_red_image("lifecycle")
	)
	step("When the panel imports it", func():
		_import_palette(image_path)
	)
	step("Then the import owns a foreground operation", func():
		var activity := State.get_activity()
		expect(activity != null, "the running import owns an operation")
		expect(activity != null and activity.foreground, "the import operation is foreground")
	)
	var observed_total := 0
	while not import_done and observed_total == 0:
		var activity := State.get_activity()
		if activity != null and activity.total > 0:
			observed_total = activity.total
		await get_tree().process_frame
	step("Then the operation reports the image progress", func():
		expect(observed_total == IMAGE_SIDE * IMAGE_SIDE, "the operation reports the image pixel count")
	)
	while not import_done:
		await get_tree().process_frame
	step("Then the finished import clears its operation", func():
		expect(import_error == OK, "the palette import completes")
		expect(State.get_palette() == [VoxelFrame.material(Color.RED)], "the import applies its result")
		expect(State.get_activity() == null, "the finished import leaves no activity")
		expect(not State.edit_busy(), "the finished import releases editing")
	)


func _removed_operation() -> void:
	step("Given a running palette import", func():
		_save_red_image("removed")
		_import_palette(image_path)
		expect(State.get_activity() != null, "the import owns an operation")
	)
	step("When the operation is removed while the worker runs", func():
		State.finish_operation(State.get_activity().id)
		expect(State.get_activity() == null, "the import operation is removed")
	)
	while not import_done:
		await get_tree().process_frame
	step("Then the import completes and applies its result", func():
		expect(import_error == OK, "the import completes without its operation")
		expect(State.get_palette() == [VoxelFrame.material(Color.RED)], "the import applies its complete result")
		expect(State.get_activity() == null, "no activity remains after the removed operation")
		expect(not State.edit_busy(), "the removed operation releases editing")
	)


func _detached_caller() -> void:
	step("Given a running palette import", func():
		_save_red_image("detached")
		_import_palette(image_path)
		expect(State.get_activity() != null, "the import owns an operation")
	)
	step("When the panel leaves the tree while the worker runs", func():
		panel.get_parent().remove_child(panel)
	)
	while not import_done:
		await get_tree().process_frame
	step("Then the import joins the worker once and clears its operation", func():
		expect(import_error == ERR_BUSY, "the detached import is cancelled")
		expect(State.get_activity() == null, "the detached import clears its operation")
		expect(not State.edit_busy(), "the detached import releases editing")
	)
