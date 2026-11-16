extends "res://tests/test.gd"

var renderer: VoxelRenderer
var renderer_count := 0
var detached_frame: VoxelFrame
var plugins: Array[Node] = []
var plugin_nodes: Array[Node] = []
var document_ref: WeakRef
var temporary_state: Node
var temporary_history: UndoRedo


func _ready() -> void:
	test("view and plugin teardown release tools, workers, history, and previous documents", _run)


func _run() -> void:
	step("Given a document with undo history", func():
		State.document = VoxelDocument.new()
		document_ref = weakref(State.document)
		var tx := State.begin_edit()
		State.paint(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.finish_edit(tx, "Paint")
	)
	step("When the user starts another document", func():
		State.document = VoxelDocument.new()
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the previous document and its history are released", func():
		expect(document_ref.get_ref() == null, "the previous document is released")
		expect(not State.undo_redo.has_undo(), "the new document retains no previous edit history")
	)
	step("Given an additional voxel view", func():
		renderer_count = VoxelRenderer._active_renderer_count
		renderer = load("res://ui/Viewport/VoxelRenderer.tscn").instantiate()
		main.add_child(renderer)
	)
	await get_tree().process_frame
	step("When the view is detached and the document changes", func():
		detached_frame = State.get_current_voxel_frame()
		main.remove_child(renderer)
		State.document = VoxelDocument.new()
	)
	step("Then the detached view stops following document changes", func():
		expect(renderer._displayed_frame == detached_frame, "the detached view starts no document rebuild")
		expect(VoxelRenderer._active_renderer_count == renderer_count, "the detached view releases its active renderer registration")
	)
	step("When the user restores the view", func():
		main.add_child(renderer)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the view resumes with one active registration", func():
		expect(VoxelRenderer._active_renderer_count == renderer_count + 1, "the restored view has one active renderer registration")
		expect(renderer._displayed_frame == State.get_current_voxel_frame(), "the restored view displays the current document")
		renderer.queue_free()
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then deleting the view restores the original registration count", func():
		expect(VoxelRenderer._active_renderer_count == renderer_count, "deleting the view restores the original renderer count")
	)
	step("Given a temporary state with its own edit history", func():
		temporary_state = State.get_script().new()
		temporary_history = temporary_state.undo_redo
	)
	step("When the temporary state is deleted", func():
		temporary_state.free()
	)
	step("Then its history object is deleted", func():
		expect(not is_instance_valid(temporary_history), "deleting State frees its UndoRedo object")
	)
	if DisplayServer.get_name() != "headless":
		step("When the user opens Export before unloading its live preview", func():
			State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
			State.document.add_frame()
			State.frames_changed.emit()
			plugin("ExportPlugin")._menu_item.get_node("ExportBtn").button_pressed = true
		)
		while not plugin("ExportPlugin")._preview_running:
			await get_tree().process_frame
	step("Given the editor plugins and their active and parked nodes", func():
		for plugin_name in ["ExportPlugin", "ImageImportPlugin", "ClipboardPlugin", "SymmetryPlugin", "TransformPlugin", "SelectionPlugin", "PlanePlugin", "PaintPlugin", "EyedropperPlugin", "StampPlugin", "BrushPlugin"]:
			var item := plugin(plugin_name)
			plugins.append(item)
			for property in item.get_property_list():
				if str(property.name).begins_with("_"):
					var value: Variant = item.get(property.name)
					if value is Node and not plugin_nodes.has(value):
						plugin_nodes.append(value)
		expect(not plugin_nodes.is_empty(), "the plugins have active and parked editor nodes")
	)
	step("When the plugins are unloaded", func():
		for item in plugins:
			State.remove_plugin(item)
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the plugins and all their editor nodes are freed", func():
		for item in plugins:
			expect(not is_instance_valid(item), "the unloaded plugin is freed")
		for node in plugin_nodes:
			expect(not is_instance_valid(node), "the unloaded plugin's editor node is freed")
		expect(not State.edit_busy(), "unloaded plugins retain no foreground edit")
	)
