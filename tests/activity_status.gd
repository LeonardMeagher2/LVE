extends "res://tests/test.gd"

var status: EditorStatusBar
var background_id := 0
var foreground_id := 0
var temporary_owner: Node


func _ready() -> void:
	test("the status bar reports delayed activity and keeps the normal status visible", _run)


func _run() -> void:
	State.document = VoxelDocument.new()
	while State.get_activity() != null:
		await get_tree().process_frame
	step("Given the status bar and a short operation", func():
		status = load("res://ui/StatusBar/status_bar.tscn").instantiate()
		main.add_child(status)
		var operation_id := State.begin_operation("Short edit", 10, true, self)
		expect(not status.get_node("Activity").visible, "the short operation starts without an activity display")
		State.finish_operation(operation_id)
	)
	await get_tree().process_frame
	step("Then the short operation has no activity display", func():
		expect(not status.get_node("Activity").visible, "the completed short operation keeps the activity display hidden")
	)
	step("When background work continues past the display delay", func():
		background_id = State.begin_operation("Building surfaces", -1, false, self)
	)
	while State.activity_elapsed_ms() < 250:
		await get_tree().process_frame
	await get_tree().process_frame
	step("Then the status bar shows animated progress and the normal status", func():
		expect(status.get_node("Activity").visible, "long activity is visible")
		expect(status.get_node("Activity/ActivityProgress").indeterminate, "unknown work uses animated progress")
		expect(status.get_node("StatusLeft").text == "#" + State.current_color.to_html(false), "the color status stays visible")
		expect(status.get_node("StatusRight").text.contains("Frame 1/1"), "the frame status stays visible")
		expect(status.get_node("StatusRight").text.contains("0×0×0"), "the empty document shows zero dimensions")
	)
	step("When a measured edit overlaps the background work", func():
		foreground_id = State.begin_operation("Scaling", 100, true, self)
		State.update_operation(foreground_id, 25, 100)
	)
	step("Then the foreground edit shows its percentage", func():
		expect(status.get_node("Activity/ActivityLabel").text.contains("Scaling"), "the foreground edit owns the activity label")
		expect(status.get_node("Activity/ActivityProgress").value == 25, "the measured edit shows twenty-five percent")
		expect(not status.get_node("Activity/ActivityProgress").indeterminate, "measured work uses percentage progress")
	)
	step("When the measured edit completes", func():
		State.finish_operation(foreground_id)
	)
	step("Then the background activity continues without another delay", func():
		expect(status.get_node("Activity").visible, "the remaining activity stays visible")
		expect(status.get_node("Activity/ActivityLabel").text.contains("Building surfaces"), "the background work owns the label again")
		State.finish_operation(background_id)
		expect(not status.get_node("Activity").visible, "completion hides the activity display")
	)
	step("When the operation owner is removed", func():
		temporary_owner = Node.new()
		main.add_child(temporary_owner)
		State.begin_operation("Removed edit", -1, true, temporary_owner)
		temporary_owner.queue_free()
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the removed owner leaves no active edit", func():
		expect(not State.edit_busy(), "the removed owner releases the edit state")
	)
	step("When the document changes during an operation", func():
		State.begin_operation("Old document", -1, true, self)
		State.document = VoxelDocument.new()
	)
	step("Then the new document has no old activity", func():
		expect(State.get_activity() == null, "document replacement clears the old activity")
		expect(not status.get_node("Activity").visible, "document replacement hides the old activity")
	)
