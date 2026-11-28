extends "res://tests/test.gd"


const MCPServerScript := preload("res://Globals/MCP/MCPServer.gd")

var server: Node


func _ready() -> void:
	timeout = 30.0
	test("layers report their state", _layers_state, "layers_state")
	test("a layer can be selected by index or name", _select_layer, "select_layer")
	test("layers can be added, copied, and deleted", _add_duplicate_delete, "add_duplicate_delete")
	test("layers can be renamed, hidden, and locked", _rename_visibility_lock, "rename_visibility_lock")
	test("layers can be reordered", _move_layer, "move_layer")
	test("a layer can be merged down", _merge_down, "merge_down")
	test("the selection can move to another layer", _move_selection, "move_selection")


func before_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.undo_redo.clear_history()
	State.clear_selection()
	State.current_frame = 0
	State.set_material(VoxelFrame.material(Color.WHITE))
	server = MCPServerScript.new()
	add_child(server)
	var error_value: Variant = server.call("start", 0)
	var error: Error = error_value if error_value is int else ERR_UNAVAILABLE
	expect(error == OK, "the MCP server starts on a free loopback port")


func after_test() -> void:
	if server != null:
		server.call("stop")
		server.queue_free()
		server = null
	if State.active_edit() != null:
		State.cancel_edit(State.active_edit())
	await get_tree().process_frame


func _call(tool_name: String, args: Dictionary) -> Dictionary:
	var response: Variant = await server.call("_call_tool", 1, {"name": tool_name, "arguments": args})
	if not (response is Dictionary):
		return {}
	return response


func _result_data(response: Dictionary) -> Dictionary:
	var result_value: Variant = response.get("result", {})
	if not (result_value is Dictionary):
		return {}
	var result: Dictionary = result_value
	var content_value: Variant = result.get("content", [])
	if not (content_value is Array):
		return {}
	var content: Array = content_value
	if content.is_empty():
		return {}
	var entry_value: Variant = content[0]
	if not (entry_value is Dictionary):
		return {}
	var entry: Dictionary = entry_value
	var text := str(entry.get("text", ""))
	if text.is_empty():
		return {}
	var data: Variant = JSON.parse_string(text)
	return data if data is Dictionary else {}


func _is_error(response: Dictionary) -> bool:
	var result_value: Variant = response.get("result", {})
	if not (result_value is Dictionary):
		return false
	var result: Dictionary = result_value
	return bool(result.get("isError", false))


func _layers_state() -> void:
	var initial := await _call("get_layers", {})
	var initial_data := _result_data(initial)
	step("Then one empty layer is reported", func():
		expect(not _is_error(initial), "get_layers succeeds")
		expect(int(initial_data.get("layers", 0)) == 1, "one layer exists")
		expect(int(initial_data.get("active", -1)) == 0, "the first layer is active")
		var items: Array = initial_data.get("items", [])
		expect(items.size() == 1, "one layer is listed")
		if items.size() == 1:
			var item: Dictionary = items[0]
			expect(str(item.get("name", "")) == "Layer 1", "the layer has its default name")
			expect(bool(item.get("visible", false)), "the layer is visible")
			expect(not bool(item.get("locked", true)), "the layer is unlocked")
			expect(int(item.get("filled", -1)) == 0, "the layer has no filled cels")
			expect(bool(item.get("active", false)), "the layer is active")
	)
	var add := await _call("add_layer", {"name": "Top"})
	var add_data := _result_data(add)
	step("When a named layer is added", func():
		expect(not _is_error(add), "add_layer succeeds")
		expect(int(add_data.get("layer", -1)) == 1, "the new layer is at index 1")
		expect(int(add_data.get("layers", 0)) == 2, "two layers exist")
		expect(str(add_data.get("name", "")) == "Top", "the layer keeps its name")
		expect(State.active_layer_index == 1, "the new layer is active")
	)
	await _call("write_cells", {"cells": [[0, 0, 0]]})
	var listed := await _call("get_layers", {})
	var listed_data := _result_data(listed)
	step("Then the filled count follows the active layer", func():
		var items: Array = listed_data.get("items", [])
		expect(items.size() == 2, "two layers are listed")
		if items.size() == 2:
			expect(int(items[0].get("filled", -1)) == 0, "the bottom layer has no cel")
			expect(int(items[1].get("filled", -1)) == 1, "the top layer has one cel")
			expect(bool(items[1].get("active", false)), "the top layer is active")
	)


func _select_layer() -> void:
	await _call("add_layer", {"name": "Top"})
	var by_index := await _call("select_layer", {"layer": 0})
	var by_index_data := _result_data(by_index)
	step("Then the index selects the bottom layer", func():
		expect(not _is_error(by_index), "select_layer accepts an index")
		expect(State.active_layer_index == 0, "the bottom layer is active")
		expect(str(by_index_data.get("name", "")) == "Layer 1", "the result names the layer")
	)
	var by_name := await _call("select_layer", {"name": "Top"})
	step("Then the name selects the top layer", func():
		expect(not _is_error(by_name), "select_layer accepts a name")
		expect(State.active_layer_index == 1, "the top layer is active")
	)
	var missing := await _call("select_layer", {"name": "Missing"})
	var bad_index := await _call("select_layer", {"layer": 9})
	step("Then an unknown name or index is refused", func():
		expect(_is_error(missing), "an unknown name is refused")
		expect(_is_error(bad_index), "an unknown index is refused")
	)
	await _call("rename_layer", {"layer": 0, "name": "Top"})
	var ambiguous := await _call("select_layer", {"name": "Top"})
	step("Then a duplicate name is refused", func():
		expect(_is_error(ambiguous), "an ambiguous name is refused")
	)
	await _call("set_layer_visible", {"layer": 0, "visible": false})
	await _call("set_layer_locked", {"layer": 0, "locked": true})
	var hidden := await _call("select_layer", {"layer": 0})
	step("Then a hidden locked layer can be selected", func():
		expect(not _is_error(hidden), "selection works on a hidden locked layer")
		expect(State.active_layer_index == 0, "the hidden layer is active")
	)
	await _call("set_layer_visible", {"layer": 0, "visible": true})
	await _call("set_layer_locked", {"layer": 0, "locked": false})
	await _call("select_layer", {"layer": 0})
	await _call("write_cells", {"cells": [[1, 0, 0]]})
	step("Then the edit tools use the selected layer", func():
		expect(State.document.cel(0, 0).has(Vector3i(1, 0, 0)), "the selected layer takes the cell")
		expect(not State.document.cel(1, 0).has(Vector3i(1, 0, 0)), "the other layer stays empty")
	)


func _add_duplicate_delete() -> void:
	var add := await _call("add_layer", {"index": 0, "name": "Base"})
	step("When a layer is inserted at the bottom", func():
		expect(not _is_error(add), "add_layer accepts an index")
		expect(State.document.layers[0].name == "Base", "the named layer is at the bottom")
		expect(State.active_layer_index == 0, "the new layer is active")
	)
	await _call("write_cells", {"cells": [[0, 0, 0]]})
	var duplicate := await _call("duplicate_layer", {"layer": 0})
	var duplicate_data := _result_data(duplicate)
	step("When the layer is copied", func():
		expect(not _is_error(duplicate), "duplicate_layer succeeds")
		expect(int(duplicate_data.get("layer", -1)) == 1, "the copy sits above the source")
		expect(str(duplicate_data.get("name", "")) == "Base copy", "the copy adds a suffix")
		expect(int(duplicate_data.get("layers", 0)) == 3, "the document holds three layers")
		expect(State.document.cel(1, 0).has(Vector3i.ZERO), "the copy keeps the cel")
	)
	var delete := await _call("delete_layer", {"layer": 1})
	var delete_data := _result_data(delete)
	step("When the copy is deleted", func():
		expect(not _is_error(delete), "delete_layer succeeds")
		expect(int(delete_data.get("layers", 0)) == 2, "the document holds two layers")
		expect(int(delete_data.get("layer", -1)) == 0, "the layer below becomes active")
	)
	step("When the delete is undone", func():
		State.undo_redo.undo()
	)
	step("Then the copy returns above the source", func():
		expect(State.document.layers.size() == 3, "three layers return")
		expect(State.document.layers[1].name == "Base copy", "the copy returns")
	)
	await _call("delete_layer", {"layer": 2})
	await _call("delete_layer", {"layer": 1})
	var refused := await _call("delete_layer", {"layer": 0})
	step("Then the last layer cannot be deleted", func():
		expect(_is_error(refused), "delete_layer refuses the last layer")
		expect(State.document.layers.size() == 1, "the document keeps one layer")
	)
	await _call("add_layer", {"name": "Locked"})
	await _call("set_layer_locked", {"layer": 1, "locked": true})
	var locked := await _call("delete_layer", {"layer": 1})
	step("Then a locked layer cannot be deleted", func():
		expect(_is_error(locked), "delete_layer refuses a locked layer")
		expect(State.document.layers.size() == 2, "the locked layer stays")
	)


func _rename_visibility_lock() -> void:
	await _call("write_cells", {"cells": [[0, 0, 0]]})
	var rename := await _call("rename_layer", {"layer": 0, "name": "  Hat  "})
	var rename_data := _result_data(rename)
	step("Then the name is trimmed", func():
		expect(not _is_error(rename), "rename_layer succeeds")
		expect(str(rename_data.get("name", "")) == "Hat", "the layer takes the trimmed name")
	)
	var empty := await _call("rename_layer", {"layer": 0, "name": "   "})
	step("Then an empty name is refused", func():
		expect(_is_error(empty), "rename_layer refuses an empty name")
		expect(State.document.layers[0].name == "Hat", "the name stays")
	)
	var hide := await _call("set_layer_visible", {"layer": 0, "visible": false})
	step("When the layer is hidden", func():
		expect(not _is_error(hide), "set_layer_visible succeeds")
		expect(not State.document.layers[0].visible, "the layer is hidden")
		var composite := State.get_composite_voxel_frame(0)
		expect(composite == null or composite.count() == 0, "the hidden cel leaves the composite")
	)
	step("When the hide is undone", func():
		State.undo_redo.undo()
	)
	step("Then the layer shows again", func():
		expect(State.document.layers[0].visible, "the layer is visible")
		expect(State.get_composite_voxel_frame(0).count() == 1, "the composite returns")
	)
	var lock := await _call("set_layer_locked", {"layer": 0, "locked": true})
	step("When the layer is locked", func():
		expect(not _is_error(lock), "set_layer_locked succeeds")
		expect(State.document.layers[0].locked, "the layer is locked")
		expect(State.begin_edit() == null, "an edit is refused")
	)
	var rename_locked := await _call("rename_layer", {"layer": 0, "name": "Locked"})
	step("Then a locked layer can still be renamed", func():
		expect(not _is_error(rename_locked), "rename_layer works on a locked layer")
		expect(State.document.layers[0].name == "Locked", "the locked layer takes the name")
	)
	var bad_visible := await _call("set_layer_visible", {"layer": 0, "visible": "yes"})
	var bad_locked := await _call("set_layer_locked", {"layer": 0, "locked": 1})
	step("Then a non-boolean state is refused", func():
		expect(_is_error(bad_visible), "set_layer_visible refuses a string")
		expect(_is_error(bad_locked), "set_layer_locked refuses a number")
	)


func _move_layer() -> void:
	await _call("add_layer", {"name": "Middle"})
	await _call("add_layer", {"name": "Top"})
	await _call("select_layer", {"layer": 0})
	var moved := await _call("move_layer", {"from": 0, "to": 2})
	var moved_data := _result_data(moved)
	step("Then the layer moves to the top", func():
		expect(not _is_error(moved), "move_layer succeeds")
		expect(State.document.layers[0].name == "Middle", "Middle is now the bottom layer")
		expect(State.document.layers[2].name == "Layer 1", "Layer 1 is now the top layer")
		expect(int(moved_data.get("layer", -1)) == 2, "the moved layer is active")
		var order: Array = moved_data.get("order", [])
		expect(order == ["Middle", "Top", "Layer 1"], "the result reports the bottom-to-top order")
	)
	step("When the move is undone", func():
		State.undo_redo.undo()
	)
	step("Then the order returns", func():
		expect(State.document.layers[0].name == "Layer 1", "Layer 1 is below again")
		expect(State.active_layer_index == 0, "the moved layer is active again")
	)
	var bad := await _call("move_layer", {"from": 9, "to": 0})
	step("Then an unknown index is refused", func():
		expect(_is_error(bad), "move_layer refuses an unknown index")
	)


func _merge_down() -> void:
	await _call("add_frame", {})
	State.document.edit_layer = 0
	State.document.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color.RED))
	State.document.set_cell(1, Vector3i.RIGHT, VoxelFrame.material(Color.GREEN))
	await _call("add_layer", {"name": "Top"})
	State.document.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color.BLUE))
	State.document.set_cell(0, Vector3i(2, 0, 0), VoxelFrame.material(Color.BLUE))
	State.document.set_cell(1, Vector3i.RIGHT, VoxelFrame.material(Color.YELLOW))
	State.document.invalidate_bounds()
	var merge := await _call("merge_layer_down", {"layer": 1})
	var merge_data := _result_data(merge)
	step("Then the layer merges into the layer below", func():
		expect(not _is_error(merge), "merge_layer_down succeeds")
		expect(int(merge_data.get("layers", 0)) == 1, "one layer remains")
		expect(int(merge_data.get("layer", -1)) == 0, "the target layer is active")
		var layer := State.document.layers[0]
		expect(layer.name == "Layer 1", "the target keeps its name")
		expect(layer.frames[0].get_color(Vector3i.ZERO) == Color.BLUE, "the upper cell wins")
		expect(layer.frames[0].get_color(Vector3i(2, 0, 0)) == Color.BLUE, "the upper cell joins the target")
		expect(layer.frames[1].get_color(Vector3i.RIGHT) == Color.YELLOW, "the second frame merges")
	)
	step("When the merge is undone", func():
		State.undo_redo.undo()
	)
	step("Then both layers return", func():
		expect(State.document.layers.size() == 2, "two layers return")
		expect(State.document.layers[1].frames[0].get_color(Vector3i.ZERO) == Color.BLUE, "the source returns")
	)
	var bottom := await _call("merge_layer_down", {"layer": 0})
	step("Then the bottom layer cannot merge down", func():
		expect(_is_error(bottom), "the bottom layer is refused")
	)
	await _call("set_layer_locked", {"layer": 0, "locked": true})
	var locked := await _call("merge_layer_down", {"layer": 1})
	step("Then a locked target refuses the merge", func():
		expect(_is_error(locked), "the locked target is refused")
		expect(State.document.layers.size() == 2, "both layers stay")
	)


func _move_selection() -> void:
	State.document.edit_layer = 0
	State.document.set_cell(0, Vector3i.ZERO, VoxelFrame.material(Color.RED))
	State.document.set_cell(0, Vector3i.RIGHT, VoxelFrame.material(Color.GREEN))
	await _call("add_layer", {"name": "Target"})
	await _call("select_layer", {"layer": 0})
	State.selection.add(Vector3i.ZERO)
	State.selection_changed.emit()
	var move := await _call("move_selection_to_layer", {"target": 1})
	var move_data := _result_data(move)
	step("Then the selected cell moves to the target", func():
		expect(not _is_error(move), "move_selection_to_layer succeeds")
		expect(int(move_data.get("moved", 0)) == 1, "one cell moves")
		expect(not State.document.cel(0, 0).has(Vector3i.ZERO), "the source loses the cell")
		expect(State.document.cel(0, 0).has(Vector3i.RIGHT), "the source keeps the rest")
		expect(State.document.cel(1, 0).get_color(Vector3i.ZERO) == Color.RED, "the target takes the cell")
		expect(State.active_layer_index == 0, "the source stays active")
	)
	step("When the move is undone", func():
		State.undo_redo.undo()
	)
	step("Then both cels return", func():
		expect(State.document.cel(0, 0).get_color(Vector3i.ZERO) == Color.RED, "the source cell returns")
		expect(State.document.cel(1, 0).count() == 0, "the target is empty again")
	)
	step("Given an empty selection", func():
		State.clear_selection()
		State.selection_changed.emit()
	)
	var whole := await _call("move_selection_to_layer", {"target": 1})
	step("Then the whole cel moves", func():
		expect(not _is_error(whole), "the whole cel moves")
		expect(State.document.cel(0, 0).count() == 0, "the source cel is empty")
		expect(State.document.cel(1, 0).count() == 2, "the target holds both cells")
	)
	var same := await _call("move_selection_to_layer", {"target": 0})
	step("Then the source layer is not a target", func():
		expect(_is_error(same), "the active layer is refused")
	)
	await _call("set_layer_visible", {"layer": 1, "visible": false})
	var hidden := await _call("move_selection_to_layer", {"target": 1})
	step("Then a hidden target is refused", func():
		expect(_is_error(hidden), "the hidden target is refused")
	)
	await _call("set_layer_visible", {"layer": 1, "visible": true})
	await _call("set_layer_locked", {"layer": 1, "locked": true})
	var locked := await _call("move_selection_to_layer", {"target": 1})
	step("Then a locked target is refused", func():
		expect(_is_error(locked), "the locked target is refused")
	)
