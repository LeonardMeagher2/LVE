extends "res://tests/test.gd"


var _saved_layer_document: VoxelDocument
var _saved_layer_bytes := PackedByteArray()
var _loaded_layer_document: VoxelDocument
var _notices: Array[String] = []
var _layers_events := 0
var _active_layer_events := 0


func _ready() -> void:
	test("a document starts with one visible unlocked layer", _default_layer, "layers_default")
	test("the composite shows higher layers over lower layers", _composite_order, "layers_composite")
	test("hiding a layer removes it from the composite and bounds", _hidden_layer, "layers_hidden")
	test("frame operations keep every layer aligned", _frame_alignment, "layers_frames")
	test("layers save and load with names, state, and delays", _storage_roundtrip, "layers_storage")
	test("a version 4 document loads as one layer", _legacy_load, "layers_legacy")
	test("an empty document sees voxels in any layer", _document_empty, "layers_empty")
	test("a locked layer refuses edits and reports the reason", _locked_guard, "layers_locked")
	test("a hidden layer refuses edits and reports the reason", _hidden_guard, "layers_hidden_guard")
	test("visibility undo and redo restore the layer", _visibility_undo, "layers_visibility_undo")
	test("switching the active layer cancels the open edit", _active_layer_switch, "layers_active_switch")
	test("a multi-layer composite follows an edited chunk", _composite_refresh, "layers_composite_refresh")


func before_test() -> void:
	_notices.clear()
	_layers_events = 0
	_active_layer_events = 0
	if not State.notice.is_connected(_on_notice):
		State.notice.connect(_on_notice)
	if not State.layers_changed.is_connected(_on_layers_changed):
		State.layers_changed.connect(_on_layers_changed)
	if not State.active_layer_changed.is_connected(_on_active_layer_changed):
		State.active_layer_changed.connect(_on_active_layer_changed)


func after_test() -> void:
	if State.notice.is_connected(_on_notice):
		State.notice.disconnect(_on_notice)
	if State.layers_changed.is_connected(_on_layers_changed):
		State.layers_changed.disconnect(_on_layers_changed)
	if State.active_layer_changed.is_connected(_on_active_layer_changed):
		State.active_layer_changed.disconnect(_on_active_layer_changed)


func _on_notice(text: String) -> void:
	_notices.append(text)


func _on_layers_changed() -> void:
	_layers_events += 1


func _on_active_layer_changed() -> void:
	_active_layer_events += 1


func _default_layer() -> void:
	step("Given a new document", func():
		expect(State.document.layers.size() == 1, "the document has one layer")
		var layer := State.document.layers[0]
		expect(layer.name == "Layer 1", "the layer has its default name")
		expect(layer.visible and not layer.locked, "the layer is visible and unlocked")
		expect(State.document.frame_count() == 1, "the document has one frame")
		expect(State.document.frame_delay(0) == 100, "the first frame uses the default delay")
		expect(State.document.cel(0, 0) == State.get_current_voxel_frame(), "the active cel is the first layer and frame")
		expect(State.document.find_cel(State.get_current_voxel_frame()) == Vector2i.ZERO, "the active cel is found")
	)


func _composite_order() -> void:
	step("Given two layers with overlapping cells", func():
		var document := State.document
		document.layers.append(document.make_layer("Top"))
		document.set_cell(0, Vector3i(0, 0, 0), VoxelFrame.material(Color.RED))
		document.set_cell(0, Vector3i(1, 0, 0), VoxelFrame.material(Color.RED))
		document.edit_layer = 1
		document.set_cell(0, Vector3i(0, 0, 0), VoxelFrame.material(Color.BLUE))
		document.invalidate_bounds()
	)
	step("Then the higher layer wins on an overlap", func():
		var composite := State.document.composite_frame(0)
		expect(composite != null, "the frame has a composite")
		expect(composite.get_color(Vector3i(0, 0, 0)) == Color.BLUE, "the top layer colors the overlap")
		expect(composite.get_color(Vector3i(1, 0, 0)) == Color.RED, "the lower layer keeps the uncovered cell")
	)
	step("When the top layer is hidden", func():
		State.document.layers[1].visible = false
		State.document.invalidate_bounds()
	)
	step("Then the lower layer shows alone", func():
		var composite := State.document.composite_frame(0)
		expect(composite == State.document.layers[0].frames[0], "one visible layer returns its cel directly")
		expect(composite.get_color(Vector3i(0, 0, 0)) == Color.RED, "the lower layer returns to view")
	)


func _hidden_layer() -> void:
	step("Given two layers whose cells sit far apart", func():
		var document := State.document
		document.layers.append(document.make_layer("Top"))
		document.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color.RED))
		document.edit_layer = 1
		document.set_cell(0, Vector3i(100, 0, 0), VoxelFrame.material(Color.BLUE))
		document.invalidate_bounds()
	)
	step("Then the bounds cover both visible layers", func():
		var bounds := State.document.bounds()
		expect(bounds.has_volume(), "the document has bounds")
		expect(bounds.end.x >= 100.5, "the bounds reach the top layer cell")
	)
	step("When the top layer is hidden", func():
		State.document.layers[1].visible = false
		State.document.invalidate_bounds()
	)
	step("Then the bounds cover only the visible layer", func():
		var bounds := State.document.bounds()
		expect(is_equal_approx(bounds.end.x, 0.5), "the hidden layer no longer extends the bounds")
	)


func _frame_alignment() -> void:
	step("Given two layers and three frames", func():
		var document := State.document
		document.layers.append(document.make_layer("Top"))
		document.add_frame()
		document.add_frame()
	)
	step("Then every layer has the same frame count", func():
		expect(State.document.frame_count() == 3, "the document has three frames")
		for layer in State.document.layers:
			expect(layer.frames.size() == 3, "the layer has one cel per frame")
	)
	step("When a frame is duplicated and the block moves", func():
		State.document.set_frame_delay(1, 250)
		State.document.duplicate_frame(1)
		State.document.move_frame_block(2, 1, 0)
	)
	step("Then the delays and cels move together", func():
		expect(State.document.frame_count() == 4, "the duplicate added a frame")
		expect(State.document.frame_delay(0) == 250, "the duplicated delay moved first")
		for layer in State.document.layers:
			expect(layer.frames.size() == 4, "the layer keeps one cel per frame")
	)
	step("When a frame is removed", func():
		State.document.remove_frame(0)
	)
	step("Then every layer drops the same frame", func():
		expect(State.document.frame_count() == 3, "one frame remains removed")
		for layer in State.document.layers:
			expect(layer.frames.size() == 3, "the layer dropped the removed frame")
	)


func _storage_roundtrip() -> void:
	step("Given two named layers with different state", func():
		_saved_layer_document = State.document
		var top := _saved_layer_document.make_layer("Hat")
		top.visible = false
		top.locked = true
		_saved_layer_document.layers.append(top)
		_saved_layer_document.set_cell(0, Vector3i(0, 0, 0), VoxelFrame.material(Color.RED))
		_saved_layer_document.edit_layer = 1
		_saved_layer_document.set_cell(0, Vector3i(1, 0, 0), VoxelFrame.material(Color.BLUE))
		_saved_layer_document.add_frame()
		_saved_layer_document.set_frame_delay(1, 250)
		_saved_layer_document.invalidate_bounds()
	)
	step("When the document saves and loads", func():
		_saved_layer_bytes = _saved_layer_document.encode_document()
		expect(not _saved_layer_bytes.is_empty(), "the document encodes")
		_loaded_layer_document = VoxelDocument.decode_document(_saved_layer_bytes)
	)
	step("Then every layer field and delay survives", func():
		expect(_loaded_layer_document != null, "the document decodes")
		if _loaded_layer_document == null:
			return
		expect(_loaded_layer_document.document_data() == _saved_layer_document.document_data(), "the saved fields match the document")
		expect(_loaded_layer_document.layers.size() == 2, "both layers survive")
		expect(_loaded_layer_document.layers[1].name == "Hat", "the layer name survives")
		expect(not _loaded_layer_document.layers[1].visible and _loaded_layer_document.layers[1].locked, "the layer visibility and lock survive")
		expect(_loaded_layer_document.frame_count() == 2, "both frames survive")
		expect(_loaded_layer_document.frame_delay(1) == 250, "the frame delay survives")
		expect(_loaded_layer_document.edit_layer == 1, "the active layer survives")
		expect(_loaded_layer_document.layers[0].frames[0].get_color(Vector3i(0, 0, 0)) == Color.RED, "the lower layer keeps its cell")
		expect(_loaded_layer_document.layers[1].frames[0].get_color(Vector3i(1, 0, 0)) == Color.BLUE, "the top layer keeps its cell")
	)


func _legacy_load() -> void:
	step("Given a version 4 payload with one frame", func():
		var document := State.document
		document.set_cell(0, Vector3i(2, 0, 0), VoxelFrame.material(Color.GREEN))
		document.set_frame_delay(0, 123)
		var legacy := document.document_data().duplicate(true)
		legacy.erase("layers")
		legacy.erase("edit_layer")
		legacy.frames = []
		for index in document.frame_count():
			legacy.frames.append({"delay_ms": document.frame_delay(index), "voxels": document.cel(0, index).storage_data()})
		var loaded := VoxelDocument.decode_document(_wrap(legacy, 4))
		expect(loaded != null, "the version 4 document loads")
		if loaded == null:
			return
		expect(loaded.layers.size() == 1, "the old document becomes one layer")
		expect(loaded.layers[0].name == "Layer 1", "the layer gets a default name")
		expect(loaded.edit_layer == 0, "the first layer is active")
		expect(loaded.frame_delay(0) == 123, "the frame delay survives")
		expect(loaded.cel(0, 0).get_color(Vector3i(2, 0, 0)) == Color.GREEN, "the voxels survive")
	)


func _document_empty() -> void:
	step("Then a new document is empty", func():
		expect(State.document.is_empty(), "the document reports no voxels")
	)
	step("When a hidden layer holds a voxel", func():
		var document := State.document
		document.layers.append(document.make_layer("Hidden"))
		document.edit_layer = 1
		document.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color.RED))
		document.layers[1].visible = false
	)
	step("Then the document still sees the voxel", func():
		expect(not State.document.is_empty(), "the document sees voxels in hidden layers")
	)


func _locked_guard() -> void:
	step("Given a locked active layer", func():
		State.set_layer_locked(0, true)
		expect(State.document.layers[0].locked, "the layer is locked")
		expect(_layers_events >= 1, "the lock reports a layer change")
	)
	step("When an edit starts and a cell is painted", func():
		expect(State.begin_edit() == null, "the edit is refused")
		State.paint(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		expect(State.document.cel(0, 0).count() == 0, "the paint writes no cell")
	)
	step("Then the status notice names the lock", func():
		expect(_notices.has("The active layer is locked."), "the lock notice appears")
	)
	step("When the lock is undone", func():
		State.undo_redo.undo()
	)
	step("Then the layer edits again", func():
		expect(not State.document.layers[0].locked, "the layer is unlocked")
		var tx := State.begin_edit()
		expect(tx != null, "the edit opens")
		if tx != null:
			State.cancel_edit(tx)
	)


func _hidden_guard() -> void:
	step("Given a hidden active layer", func():
		State.set_layer_visible(0, false)
		expect(not State.document.layers[0].visible, "the layer is hidden")
	)
	step("When an edit starts", func():
		expect(State.begin_edit() == null, "the edit is refused")
	)
	step("Then the status notice names the hidden layer", func():
		expect(_notices.has("The active layer is hidden."), "the hidden notice appears")
	)


func _visibility_undo() -> void:
	step("Given two layers with a cell on the top layer", func():
		var document := State.document
		document.layers.append(document.make_layer("Top"))
		document.edit_layer = 1
		document.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color.BLUE))
		document.invalidate_bounds()
		var composite := document.composite_frame(0)
		expect(composite.get_color(Vector3i.ZERO) == Color.BLUE, "the top layer shows")
	)
	step("When the top layer is hidden", func():
		State.set_layer_visible(1, false)
		expect(not State.document.layers[1].visible, "the layer is hidden")
		expect(State.document.composite_frame(0).get_color(Vector3i.ZERO) == Color.TRANSPARENT, "the hidden cell leaves the composite")
	)
	step("Then undo shows it again", func():
		State.undo_redo.undo()
		expect(State.document.layers[1].visible, "the layer is visible again")
		expect(State.document.composite_frame(0).get_color(Vector3i.ZERO) == Color.BLUE, "the cell returns")
	)
	step("Then redo hides it again", func():
		State.undo_redo.redo()
		expect(not State.document.layers[1].visible, "the layer is hidden again")
		expect(State.document.composite_frame(0).get_color(Vector3i.ZERO) == Color.TRANSPARENT, "the cell leaves again")
	)


func _active_layer_switch() -> void:
	step("Given two layers and an open edit on the first", func():
		var document := State.document
		document.layers.append(document.make_layer("Top"))
		document.edit_layer = 0
		expect(State.begin_edit() != null, "the edit opens")
	)
	step("When the active layer changes", func():
		State.active_layer_index = 1
	)
	step("Then the edit closes and the active layer moves", func():
		expect(State.active_edit() == null, "the switch cancels the open edit")
		expect(State.document.edit_layer == 1, "the second layer is active")
		expect(_active_layer_events == 1, "the switch reports the active layer")
	)


func _composite_refresh() -> void:
	step("Given two visible layers with overlapping cells", func():
		var document := State.document
		document.layers.append(document.make_layer("Top"))
		document.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color.RED))
		document.edit_layer = 1
		document.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color.BLUE))
		document.invalidate_bounds()
		var composite := document.composite_frame(0)
		expect(composite.get_color(Vector3i.ZERO) == Color.BLUE, "the top layer shows first")
	)
	step("When the top cel changes", func():
		State.document.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color.GREEN))
		var composite := State.document.composite_frame(0)
		expect(composite.get_color(Vector3i.ZERO) == Color.GREEN, "the cached composite refreshes")
	)
	step("When the bottom cel changes under the top", func():
		State.document.edit_layer = 0
		State.document.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var composite := State.document.composite_frame(0)
		expect(composite.get_color(Vector3i.ZERO) == Color.GREEN, "the top layer still wins")
	)
	step("When the top layer hides", func():
		State.set_layer_visible(1, false)
		var composite := State.document.composite_frame(0)
		expect(composite == State.document.layers[0].frames[0], "the sole visible layer returns its cel")
		expect(composite.get_color(Vector3i.ZERO) == Color.RED, "the bottom layer shows")
	)
	step("When the top layer shows again", func():
		State.set_layer_visible(1, true)
		var composite := State.document.composite_frame(0)
		expect(composite.get_color(Vector3i.ZERO) == Color.GREEN, "the top layer returns")
	)


func _wrap(payload: Dictionary, version: int) -> PackedByteArray:
	var bytes := var_to_bytes(payload)
	var result := PackedByteArray(VoxelDocument.FILE_SIGNATURE)
	result.resize(16)
	result.encode_u32(4, version)
	result.encode_u32(8, bytes.size())
	result.encode_u32(12, VoxelDocument._checksum(bytes))
	result.append_array(bytes)
	return result
