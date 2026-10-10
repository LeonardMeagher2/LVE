extends "res://tests/test.gd"

const SAMPLE := "res://Flamingo.lve"

var menu: Node
var session_path := ""
var saved_path := ""


func _ready() -> void:
	test("the editor reopens the last document or the Flamingo sample", _run)


func _run() -> void:
	step("Given a saved copy of a document", func():
		menu = main.get_node("%MenuBar")
		var stamp := Time.get_ticks_usec()
		session_path = "user://startup_document_%s.cfg" % stamp
		saved_path = "user://startup_document_%s.lve" % stamp
		expect(menu.open_document(SAMPLE, false), "the sample document opens")
		var document: VoxelDocument = State.document
		expect(document.save_file(saved_path, null, document.encode_document()) == OK, "the document copy saves")
		State.remember_document(saved_path, session_path)
	)

	step("Then the session stores the document path", func():
		expect(State.last_document_path(session_path) == saved_path, "the saved path is the last document")
	)

	step("When the editor starts with that session", func():
		menu.current_save_path = ""
		main._restore_startup_document(true, session_path)
	)

	step("Then the remembered document opens with its save path", func():
		expect(menu.current_save_path == saved_path, "the remembered document keeps its save path")
	)

	step("When the editor starts without a remembered document", func():
		State.forget_document(session_path)
		expect(State.last_document_path(session_path).is_empty(), "the session has no document")
		menu.current_save_path = ""
		main._restore_startup_document(true, session_path)
	)

	step("Then the Flamingo sample opens as an unsaved document", func():
		expect(State.document.file_path == SAMPLE, "the sample document is open")
		expect(menu.current_save_path.is_empty(), "the sample has no save path")
	)

	for path in [saved_path, session_path]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
