extends "res://tests/test.gd"


var _dock_height := 0.0


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
	test("the layer menu renames the active layer", _rename_from_menu, "layer_grid_rename")
	test("dragging a header reorders the layers", _drag_reorder, "layer_grid_reorder")
	test("the layer menu follows lock, order, and visibility", _more_menu, "layer_grid_menu")
	test("the timeline keeps its height and scrolls its rows", _scrolls_rows, "layer_grid_scroll")


func after_test() -> void:
	var dialog: ConfirmationDialog = main.find_child("LayerRenameDialog", true, false)
	if dialog != null and dialog.visible:
		dialog.hide()


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


func _more_popup() -> PopupMenu:
	return _toolbar().get_node("%More").get_popup()


func _rename_dialog() -> ConfirmationDialog:
	return main.find_child("LayerRenameDialog", true, false)


func _rename_from_menu() -> void:
	step("When the user picks rename from the layer menu", func():
		var popup := _more_popup()
		popup.about_to_popup.emit()
		popup.id_pressed.emit(LayerToolbarCell.ACTION_RENAME)
	)
	step("Then the dialog shows the active layer name", func():
		expect(_rename_dialog().visible, "the rename dialog opens")
		expect(_rename_dialog().get_node("%LayerRenameInput").text == "Layer 1", "the dialog shows the layer name")
	)
	step("When the user types a name and confirms", func():
		_rename_dialog().get_node("%LayerRenameInput").text = "Ground"
		_rename_dialog().confirmed.emit()
		_rename_dialog().hide()
	)
	step("Then the header and model take the new name", func():
		expect(_headers()[0].get_node("%Name").text == "Ground", "the header follows the rename")
		expect(State.document.layers[0].name == "Ground", "the layer takes the new name")
	)
	step("When the user undoes the rename", func():
		State.undo_redo.undo()
	)
	step("Then the header returns to the old name", func():
		expect(_headers()[0].get_node("%Name").text == "Layer 1", "undo restores the header name")
	)


func _drag_reorder() -> void:
	step("Given a second layer above the first", func():
		State.add_layer()
		expect(_headers()[0].get_node("%Name").text == "Layer 2", "the second layer is the top row")
	)
	step("When the user drags the top header onto the bottom header", func():
		var data := {"type": LayerHeaderCell.DRAG_TYPE, "from": 1}
		expect(_headers()[1]._can_drop_data(Vector2.ZERO, data), "the header accepts the layer")
		_headers()[1]._drop_data(Vector2.ZERO, data)
	)
	step("Then the layer rows swap", func():
		expect(_headers()[0].get_node("%Name").text == "Layer 1", "the first layer is the top row")
		expect(_headers()[1].get_node("%Name").text == "Layer 2", "the second layer is below")
		expect(State.document.layers[0].name == "Layer 2", "the model order follows the rows")
	)
	step("When the user undoes the reorder", func():
		State.undo_redo.undo()
	)
	step("Then the original order returns", func():
		expect(_headers()[0].get_node("%Name").text == "Layer 2", "the second layer is on top again")
		expect(State.document.layers[0].name == "Layer 1", "the model order returns")
	)


func _more_menu() -> void:
	step("Given a second layer above the first", func():
		State.add_layer()
	)
	step("Then the menu lists rename, merge, and the other layer", func():
		var popup := _more_popup()
		popup.about_to_popup.emit()
		expect(popup.get_item_text(0) == "Rename Layer", "the menu offers rename")
		expect(popup.get_item_text(1) == "Merge Down", "the menu offers merge")
		expect(popup.get_item_text(3) == "Move Selection to Layer 1", "the menu offers the other layer")
		expect(not popup.is_item_disabled(1), "merge is enabled above the bottom layer")
		expect(not popup.is_item_disabled(3), "the move target is enabled")
	)
	step("When the active layer is locked", func():
		State.set_layer_locked(1, true)
	)
	step("Then merge and delete are disabled", func():
		var popup := _more_popup()
		popup.about_to_popup.emit()
		expect(popup.is_item_disabled(1), "merge is disabled on a locked layer")
		expect(_toolbar().get_node("%Delete").disabled, "delete is disabled on a locked layer")
	)
	step("When the active layer is the bottom layer", func():
		State.set_layer_locked(1, false)
		State.active_layer_index = 0
	)
	step("Then merge is disabled", func():
		var popup := _more_popup()
		popup.about_to_popup.emit()
		expect(popup.is_item_disabled(1), "merge is disabled on the bottom layer")
	)
	step("When the other layer is hidden", func():
		State.active_layer_index = 1
		State.set_layer_visible(0, false)
	)
	step("Then the hidden layer is not a move target", func():
		var popup := _more_popup()
		popup.about_to_popup.emit()
		expect(popup.get_item_text(3) == "No other layer", "a hidden layer is not offered")
		expect(popup.is_item_disabled(3), "the empty move item is disabled")
	)


func _scrolls_rows() -> void:
	step("Given a timeline with one layer row", func():
		_dock_height = main.find_child("BottomDock", true, false).size.y
	)
	step("When the user adds ten layers", func():
		for index in 10:
			State.add_layer()
	)
	await get_tree().process_frame
	await get_tree().process_frame
	step("Then the dock keeps its height", func():
		expect(is_equal_approx(main.find_child("BottomDock", true, false).size.y, _dock_height), "the dock height does not change")
		expect(_scroll().get_v_scroll_bar().visible, "the vertical scroll bar shows")
		expect(_scroll().get_v_scroll_bar().max_value > _scroll().size.y, "the rows exceed the view")
		expect(_headers().size() == 11, "every layer row exists")
	)
	step("When the user scrolls down", func():
		_scroll().scroll_vertical = int(_scroll().get_v_scroll_bar().max_value)
	)
	step("Then the grid moves", func():
		expect(_scroll().scroll_vertical > 0, "the grid scrolls")
	)


func _scroll() -> ScrollContainer:
	return _grid().get_parent() as ScrollContainer
