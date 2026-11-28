extends "res://tests/test.gd"


func _ready() -> void:
	test("the timeline shows one layer row", _default_grid, "layer_grid_default")
	test("adding a layer adds a row and selects it", _add_layer, "layer_grid_add")
	test("duplicating a layer copies its cels", _duplicate_layer, "layer_grid_duplicate")
	test("deleting a layer removes its row", _delete_layer, "layer_grid_delete")
	test("clicking a cel selects the layer and frame", _select_cel, "layer_grid_cel")
	test("clicking a frame keeps the active layer", _select_frame, "layer_grid_frame")
	test("a painted cel shows its marker", _filled_marker, "layer_grid_marker")
	test("visibility and lock follow the header buttons", _visibility_and_lock, "layer_grid_state")
	test("the layer toolbar adds and deletes rows", _toolbar_actions, "layer_grid_toolbar")


func _grid() -> Control:
	return main.find_child("FrameGrid", true, false)


func _headers() -> Array[LayerHeaderCell]:
	var out: Array[LayerHeaderCell] = []
	for child in _grid().get_children():
		if child is LayerHeaderCell:
			out.append(child)
	return out


func _cells() -> Array[CelCell]:
	var out: Array[CelCell] = []
	for child in _grid().get_children():
		if child is CelCell:
			out.append(child)
	return out


func _frame_headers() -> Array[AnimationFrame]:
	var out: Array[AnimationFrame] = []
	for child in _grid().get_children():
		if child is AnimationFrame:
			out.append(child)
	return out


func _toolbar() -> LayerToolbarCell:
	for child in _grid().get_children():
		if child is LayerToolbarCell:
			return child
	return null


func _cel(layer: int, frame: int) -> CelCell:
	for cell in _cells():
		if cell.layer_index == layer and cell.frame_index == frame:
			return cell
	return null


func _default_grid() -> void:
	step("Then one layer row and one frame header show", func():
		expect(_headers().size() == 1, "the grid holds one layer header")
		expect(_cells().size() == 1, "the grid holds one cel")
		expect(_frame_headers().size() == 1, "the grid holds one frame header")
		expect(_headers()[0].get_node("%Name").text == "Layer 1", "the header names the layer")
		expect(not _cells()[0].get_node("%Marker").visible, "the empty cel has no marker")
	)


func _add_layer() -> void:
	step("When the user adds a layer", func():
		State.add_layer()
	)
	step("Then a new top row is selected", func():
		expect(State.document.layers.size() == 2, "the document holds two layers")
		expect(_headers().size() == 2, "the grid holds two layer headers")
		expect(_cells().size() == 2, "the grid holds one cel for each layer")
		expect(State.active_layer_index == 1, "the new layer is active")
		expect(_headers()[0].get_node("%Name").text == "Layer 2", "the new layer is the top row")
		expect(_headers()[1].get_node("%Name").text == "Layer 1", "the old layer is below")
		expect(_headers()[0].get_node("%Name").button_pressed, "the active header is pressed")
	)
	step("Then undo removes the row", func():
		State.undo_redo.undo()
		expect(State.document.layers.size() == 1, "one layer remains")
		expect(_headers().size() == 1, "one header remains")
		expect(State.active_layer_index == 0, "the first layer is active")
	)
	step("Then redo restores the row", func():
		State.undo_redo.redo()
		expect(State.document.layers.size() == 2, "two layers return")
		expect(State.active_layer_index == 1, "the new layer is active again")
	)


func _duplicate_layer() -> void:
	step("Given a painted first layer", func():
		State.paint(Vector3i.ZERO, VoxelFrame.material(Color.RED))
	)
	step("When the user duplicates the layer", func():
		State.duplicate_layer(0)
	)
	step("Then the copy is selected and keeps the cel", func():
		expect(State.document.layers.size() == 2, "the document holds two layers")
		expect(State.document.layers[1].name == "Layer 1 copy", "the copy is named after the source")
		expect(State.active_layer_index == 1, "the copy is active")
		var cell := _cel(1, 0)
		expect(cell != null and cell.get_node("%Marker").visible, "the copied cel shows its marker")
	)
	step("Then undo removes the copy", func():
		State.undo_redo.undo()
		expect(State.document.layers.size() == 1, "one layer remains")
	)


func _delete_layer() -> void:
	step("Given two layers", func():
		State.add_layer()
		expect(State.document.layers.size() == 2, "two layers exist")
	)
	step("When the user deletes the active layer", func():
		State.delete_layer(1)
	)
	step("Then the layer below is selected", func():
		expect(State.document.layers.size() == 1, "one layer remains")
		expect(State.active_layer_index == 0, "the first layer is active")
		expect(_headers().size() == 1, "one header remains")
	)
	step("Then the last layer cannot be deleted", func():
		State.delete_layer(0)
		expect(State.document.layers.size() == 1, "the last layer stays")
	)
	step("Then undo restores the deleted layer", func():
		State.undo_redo.undo()
		expect(State.document.layers.size() == 2, "the deleted layer returns")
		expect(State.active_layer_index == 1, "the deleted layer is active again")
	)


func _select_cel() -> void:
	step("Given two layers and two frames", func():
		State.add_frame()
		State.add_layer()
		expect(_cells().size() == 4, "the grid holds four cels")
	)
	step("When the user clicks the second layer and frame", func():
		var cell := _cel(1, 1)
		expect(cell != null, "the cel exists")
		cell.button_pressed = true
	)
	step("Then the layer and frame follow the cel", func():
		expect(State.active_layer_index == 1, "the second layer is active")
		expect(State.current_frame == 1, "the second frame is current")
		expect(_cel(1, 1).button_pressed, "the clicked cel is pressed")
		expect(_headers()[0].get_node("%Name").button_pressed, "the layer header is pressed")
	)


func _select_frame() -> void:
	step("Given a second active layer", func():
		State.add_frame()
		State.add_layer()
		expect(State.active_layer_index == 1, "the second layer is active")
	)
	step("When the user clicks the first frame header", func():
		_frame_headers()[0].get_node("%Button").button_pressed = true
	)
	step("Then the frame changes and the layer stays", func():
		expect(State.current_frame == 0, "the first frame is current")
		expect(State.active_layer_index == 1, "the second layer stays active")
		expect(_cel(1, 0).button_pressed, "the active cel follows the frame")
	)


func _filled_marker() -> void:
	step("Then an empty cel has no marker", func():
		expect(not _cel(0, 0).get_node("%Marker").visible, "the empty cel has no marker")
	)
	step("When the user paints the active cel", func():
		State.paint(Vector3i.ZERO, VoxelFrame.material(Color.RED))
	)
	step("Then the marker shows", func():
		expect(_cel(0, 0).get_node("%Marker").visible, "the filled cel shows its marker")
	)
	step("When the user erases the cell", func():
		State.paint(Vector3i.ZERO, VoxelFrame.material(Color.TRANSPARENT))
	)
	step("Then the marker hides", func():
		expect(not _cel(0, 0).get_node("%Marker").visible, "the empty cel hides its marker")
	)


func _visibility_and_lock() -> void:
	step("When the user hides the layer", func():
		_headers()[0].get_node("%Eye").button_pressed = false
	)
	step("Then the layer and row follow", func():
		expect(not State.document.layers[0].visible, "the layer is hidden")
		expect(_headers()[0].modulate.a < 1.0, "the hidden row is dimmed")
		expect(not _headers()[0].get_node("%Eye").button_pressed, "the eye shows the hidden state")
	)
	step("When the user undoes the hide", func():
		State.undo_redo.undo()
		expect(State.document.layers[0].visible, "the layer is visible again")
	)
	step("When the user locks the layer", func():
		_headers()[0].get_node("%Lock").button_pressed = true
	)
	step("Then the layer is locked", func():
		expect(State.document.layers[0].locked, "the layer is locked")
		expect(_headers()[0].get_node("%Lock").button_pressed, "the lock shows the locked state")
	)
	step("When the user unlocks it", func():
		State.set_layer_locked(0, false)
		expect(not State.document.layers[0].locked, "the layer is unlocked")
	)


func _toolbar_actions() -> void:
	step("Then delete is disabled with one layer", func():
		var toolbar := _toolbar()
		expect(toolbar != null, "the layer toolbar exists")
		expect(toolbar.get_node("%Delete").disabled, "delete is disabled with one layer")
	)
	step("When the user presses add", func():
		_toolbar().get_node("%Add").pressed.emit()
	)
	step("Then a layer is added and delete enables", func():
		expect(State.document.layers.size() == 2, "the new layer is added")
		expect(not _toolbar().get_node("%Delete").disabled, "delete is enabled with two layers")
	)
	step("When the user presses delete", func():
		_toolbar().get_node("%Delete").pressed.emit()
	)
	step("Then the layer is removed and delete disables", func():
		expect(State.document.layers.size() == 1, "the layer is removed")
		expect(_toolbar().get_node("%Delete").disabled, "delete is disabled again")
	)
