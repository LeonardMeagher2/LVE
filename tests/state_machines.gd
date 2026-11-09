extends "res://tests/test.gd"

# Regression tests for the state machines in docs/agents/STATE_MACHINES.md.
#
# Each case locks one invariant that a transition, a retry, or a concurrent
# worker could otherwise break. The cases run in one process.
#
#   godot --path . res://tests/state_machines.tscn
#   godot --path . res://tests/state_machines.tscn -- undo_open_edit

var _playback: AnimationPlayback
var _playback_document: VoxelDocument
var _frame: VoxelFrame
var _edit: VoxelEditTransaction
var _menu_bar: Node
var _undo_button: Button


func _ready() -> void:
	timeout = 30.0
	test("undo and redo are refused while an edit owns the frame", _undo_open_edit, "undo_open_edit")
	test("the menu history buttons disable while an edit is open", _history_buttons_open_edit, "history_buttons_open_edit")
	test("playback catches up to the elapsed time instead of dropping it", _playback_catch_up, "playback_catch_up")
	test("a finite single-frame tag stops playing", _playback_single_stop, "playback_single_stop")
	test("removing a tag without an active tag changes nothing", _remove_tag_without_active, "remove_tag_without_active")


func _setup_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.undo_redo.clear_history()
	State.clear_selection()
	_playback = null
	_playback_document = null
	_frame = null
	_edit = null
	_menu_bar = null
	_undo_button = null
	await get_tree().process_frame


func _cleanup_test() -> void:
	State.stop()
	if _edit != null:
		State.cancel_edit(_edit)
		_edit = null
	State.cancel_edit(State.active_edit())
	State.undo_redo.clear_history()
	await get_tree().process_frame


# An open edit captures the frame before the history action it would follow. A
# history change in that window makes the captured start snapshot describe a
# state that the linear history no longer contains, so a later commit records
# the wrong before/after pair. The guard is to refuse the history change.
func _undo_open_edit() -> void:
	step("Given one committed action and a newer open edit", func():
		_frame = State.get_current_voxel_frame()
		var first := State.begin_edit()
		_frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.finish_edit(first)
		_edit = State.begin_edit()
		_frame.set_cell(Vector3i(1, 0, 0), VoxelFrame.material(Color.BLUE))
	)
	step("When undo runs while the edit is open", func():
		var undone := State.undo()
		expect(not undone, "undo is refused while an edit owns the frame")
		expect(_frame.has(Vector3i.ZERO), "the committed action stays")
		expect(_frame.has(Vector3i(1, 0, 0)), "the open edit keeps its change")
		expect(State.undo_redo.has_undo(), "the history stack is unchanged")
	)
	step("Then the edit closes and the same undo succeeds", func():
		State.cancel_edit(_edit)
		_edit = null
		expect(State.undo(), "undo succeeds after the edit closes")
		expect(not _frame.has(Vector3i.ZERO), "the committed action is undone")
	)
	step("When a newer edit opens before redo", func():
		_edit = State.begin_edit()
		var redone := State.redo()
		expect(not redone, "redo is refused while an edit owns the frame")
		expect(not _frame.has(Vector3i.ZERO), "the undone action stays undone")
	)
	step("Then the edit closes and the same redo succeeds", func():
		State.cancel_edit(_edit)
		_edit = null
		expect(State.redo(), "redo succeeds after the edit closes")
		expect(_frame.has(Vector3i.ZERO), "the committed action returns")
	)


# The menu path must show the same refusal. The button is disabled while an
# edit is open, so a pointer or shortcut press cannot reach State.undo.
func _history_buttons_open_edit() -> void:
	step("Given a committed action and an enabled undo button", func():
		_menu_bar = main.get_node("Content/VBoxContainer/MenuBar")
		_undo_button = _menu_bar.get_node("UndoBtn")
		var first := State.begin_edit()
		State.get_current_voxel_frame().set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.finish_edit(first)
		await get_tree().process_frame
		expect(not _undo_button.disabled, "undo is enabled after a committed action")
	)
	step("When an edit opens", func():
		_edit = State.begin_edit()
		await get_tree().process_frame
	)
	step("Then the undo button is disabled and the edit keeps its state", func():
		expect(_undo_button.disabled, "undo is disabled while an edit is open")
		_menu_bar._on_undo_btn_pressed()
		expect(State.get_current_voxel_frame().has(Vector3i.ZERO), "the committed action stays")
		expect(State.active_edit() == _edit, "the open edit is still active")
		State.cancel_edit(_edit)
		_edit = null
		await get_tree().process_frame
		expect(not _undo_button.disabled, "undo is enabled again after the edit closes")
	)


# A long frame must advance every elapsed step. Dropping the remainder makes the
# playback speed depend on the render frame rate.
func _playback_catch_up() -> void:
	step("Given a three-frame loop with a ten millisecond delay", func():
		_playback_document = VoxelDocument.new()
		_playback_document.frames[0].delay_ms = 10
		for index in 2:
			_playback_document.add_frame()
			_playback_document.frames[index + 1].delay_ms = 10
		_playback_document.add_tag("Loop", 0, 2)
		_playback = AnimationPlayback.new()
		_playback.document = _playback_document
		_playback.active_tag = 0
		_playback.is_playing = true
	)
	step("When one frame elapses 485 milliseconds", func():
		_playback.update(0.485)
	)
	step("Then the playback advances forty-eight steps", func():
		expect(_playback.current_frame == 0, "48 steps of a three-frame loop end on frame 0")
		expect(_playback.is_playing, "a continuous loop stays playing")
	)


# A finite repeat counts as one pass on a one-frame tag as well. A tag that
# never advances otherwise stays "playing" forever.
func _playback_single_stop() -> void:
	step("Given a one-frame tag with one repeat", func():
		_playback_document = VoxelDocument.new()
		_playback_document.frames[0].delay_ms = 100
		_playback_document.add_tag("Once", 0, 0, AnimationTag.LoopMode.FORWARD, 1)
		_playback = AnimationPlayback.new()
		_playback.document = _playback_document
		_playback.active_tag = 0
		_playback.is_playing = true
	)
	step("When one frame duration elapses", func():
		_playback.update(0.1)
	)
	step("Then the finite playback stops", func():
		expect(not _playback.is_playing, "the one-frame one-repeat tag stops")
		expect(_playback.current_frame == 0, "the frame stays on the only frame")
	)


# remove_tag assumes the active tag index. The public deselect path sets it to
# -1, so the guard must refuse the removal instead of indexing the array.
func _remove_tag_without_active() -> void:
	step("Given two tags and no active tag", func():
		State.document.tags.clear()
		State.document.add_tag("First", 0, 0)
		State.document.add_tag("Second", 0, 0)
		State.deselect_tag()
		expect(State.active_tag == -1, "the tag selection is empty")
		expect(State.document.tags.size() == 2, "two tags are present")
	)
	step("When remove_tag runs", func():
		State.remove_tag()
	)
	step("Then the tag list is unchanged", func():
		expect(State.document.tags.size() == 2, "no tag is removed")
		expect(State.document.get_tag(0).name == "First", "the first tag keeps its identity")
		expect(State.document.get_tag(1).name == "Second", "the second tag keeps its identity")
		expect(not State.undo_redo.has_undo(), "the refused removal adds no history")
	)
