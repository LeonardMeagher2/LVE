extends "res://tests/test.gd"

# The in-app MCP server. The tests drive the same JSON-RPC calls that the
# bridge sends. One process covers the protocol, the real tool drivers, and the
# loopback transport.

const MCPServerScript := preload("res://Globals/MCP/MCPServer.gd")

var server: Node
var peer: StreamPeerTCP


func _ready() -> void:
	timeout = 30.0
	test("the server reports the current editor state", _state, "state")
	test("set_tool changes the real toolbar and settings", _set_tool, "set_tool")
	test("a driven brush stroke writes cells and one undo action", _stroke, "stroke")
	test("a driven fill uses the current material", _fill, "fill")
	test("write_cells writes boxes and runs", _write, "write_cells")
	test("write_cells accepts per-cell materials", _write_materials, "write_materials")
	test("write_cells writes several frames as one undo", _write_frames, "write_frames")
	test("get_cells returns compact runs", _read, "get_cells")
	test("materials can glow", _emission, "emission")
	test("documents save and open", _save_open, "save_open")
	test("new_document opens a new tab", _new_tab, "new_document")
	test("frames and tags can be driven", _frames, "frames")
	test("frames can be inserted, moved, and removed", _edit_frames, "edit_frames")
	test("tags can be added, renamed, ranged, looped, and removed", _edit_tags, "edit_tags")
	test("a user edit makes an agent action busy", _busy, "busy")
	test("the loopback transport answers MCP requests", _tcp, "tcp")
	test("the HTTP transport answers a POST and opens an SSE stream", _http, "http")
	test("a screenshot saves a file and returns an image on request", _screenshot, "screenshot")
	test("the compact state stays small", _budget, "budget")
	test("inspect_document summarizes frames and islands", _inspect, "inspect_document")
	test("get_regions groups material and frame islands", _regions, "get_regions")
	test("get_slice reads labeled planes", _slice, "get_slice")
	test("get_map reads coarse blocks", _map, "get_map")
	test("get_map falls back to chunk blocks", _chunk_map_fallback, "chunk_map")
	test("get_changes returns the delta", _changes, "get_changes")
	test("get_cells resumes with a cursor", _cursor, "cursor")


func before_test() -> void:
	State.stop()
	State.document = VoxelDocument.new()
	State.undo_redo.clear_history()
	State.clear_selection()
	State.symmetry_axes = 0
	State.slice_enabled = false
	State.floor_axis = Vector3.Axis.AXIS_Y
	State.floor_index = 0
	State.set_material(VoxelFrame.material(Color.WHITE))
	State.undo_redo.clear_history()
	server = MCPServerScript.new()
	add_child(server)
	var error_value: Variant = server.call("start", 0)
	var error: Error = error_value if error_value is int else ERR_UNAVAILABLE
	expect(error == OK, "the MCP server starts on a free loopback port")


func after_test() -> void:
	if peer != null:
		peer.disconnect_from_host()
		peer = null
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
	var text_value: Variant = entry.get("text", "")
	if not (text_value is String):
		return {}
	var text: String = text_value
	var data: Variant = JSON.parse_string(text)
	if data is Dictionary:
		return data
	return {}


func _is_error(response: Dictionary) -> bool:
	var result_value: Variant = response.get("result", {})
	if not (result_value is Dictionary):
		return false
	var result: Dictionary = result_value
	return bool(result.get("isError", false))


func _result_text(response: Dictionary) -> String:
	var result_value: Variant = response.get("result", {})
	if not (result_value is Dictionary):
		return ""
	var result: Dictionary = result_value
	var content_value: Variant = result.get("content", [])
	if not (content_value is Array):
		return ""
	var content: Array = content_value
	if content.is_empty():
		return ""
	var entry_value: Variant = content[0]
	if not (entry_value is Dictionary):
		return ""
	var entry: Dictionary = entry_value
	var text_value: Variant = entry.get("text", "")
	return str(text_value) if text_value is String else ""


func _state() -> void:
	step("Given a red material and an empty document", func():
		State.current_color = Color.RED
		State.undo_redo.clear_history()
	)
	step("When the agent reads the state", func():
		pass
	)
	var response := await _call("get_state", {})
	var data := _result_data(response)
	step("Then the state carries the document, material, and tool", func():
		expect(not _is_error(response), "get_state succeeds")
		var document: Dictionary = data.get("document", {})
		expect(int(document.get("frame", -1)) == 0, "the state names the current frame")
		var material: Dictionary = data.get("material", {})
		var color := Color.from_string(str(material.get("color", "")), Color.BLACK)
		expect(color.r == 1.0 and color.g == 0.0 and color.b == 0.0, "the state carries the current color")
		expect(data.has("active_tool"), "the state carries the active tool")
	)


func _set_tool() -> void:
	step("When the agent selects the brush with new options", func():
		pass
	)
	var brush_response := await _call("set_tool", {"tool": "brush", "diameter": 5, "shape": "sphere", "pixel_perfect": true})
	var brush_data := _result_data(brush_response)
	step("Then the real brush settings and toolbar change", func():
		expect(not _is_error(brush_response), "set_tool succeeds for the brush")
		expect(str(brush_data.get("tool", "")) == "brush", "the state reports the brush")
		var plugin := get_node_or_null("/root/BrushPlugin")
		expect(plugin != null, "the brush plugin exists")
		if plugin != null:
			var settings: BrushToolSettings = plugin.get("_settings")
			var toolbar: BaseButton = plugin.get("_toolbar")
			expect(settings.diameter == 5, "the brush diameter is the requested value")
			expect(settings.shape == StampToolSettings.BrushShape.SPHERE, "the brush shape is the requested value")
			expect(settings.pixel_perfect, "the pixel-perfect option is set")
			expect(toolbar.button_pressed, "the brush toolbar button is pressed")
	)
	step("When the agent selects the fill tool", func():
		pass
	)
	var fill_response := await _call("set_tool", {"tool": "fill", "connected": false})
	var fill_data := _result_data(fill_response)
	step("Then the paint plugin owns the active tool", func():
		expect(not _is_error(fill_response), "set_tool succeeds for fill")
		expect(str(fill_data.get("tool", "")) == "fill", "the state reports fill")
		var paint := get_node_or_null("/root/PaintPlugin")
		var brush := get_node_or_null("/root/BrushPlugin")
		expect(paint != null and brush != null, "both plugins exist")
		if paint != null and brush != null:
			var paint_settings: PaintToolSettings = paint.get("_settings")
			var paint_toolbar: BaseButton = paint.get("_toolbar")
			var brush_toolbar: BaseButton = brush.get("_toolbar")
			expect(paint_settings.tool == PaintToolSettings.Tools.FILL, "the paint settings select fill")
			expect(not paint_settings.connected, "the connected option is set")
			expect(paint_toolbar.button_pressed, "the paint toolbar button is pressed")
			expect(not brush_toolbar.button_pressed, "the brush toolbar button is released")
	)


func _stroke() -> void:
	step("Given a red brush with a one-cell footprint", func():
		State.current_color = Color.RED
		State.undo_redo.clear_history()
	)
	await _call("set_tool", {"tool": "brush", "diameter": 1, "shape": "cube", "pixel_perfect": false})
	step("When the agent draws a two-cell stroke", func():
		pass
	)
	var response := await _call("stroke", {"points": [[0, 0, 0], [0, 0, 2]]})
	var data := _result_data(response)
	step("Then the cells are painted and one undo action is recorded", func():
		expect(not _is_error(response), "stroke succeeds")
		var frame := State.get_current_voxel_frame()
		expect(frame.has(Vector3i(0, 0, 0)), "the first center is painted")
		expect(frame.has(Vector3i(0, 0, 1)), "the path is connected")
		expect(frame.has(Vector3i(0, 0, 2)), "the last center is painted")
		expect(frame.get_color(Vector3i(0, 0, 1)).r == 1.0 and frame.get_color(Vector3i(0, 0, 1)).g == 0.0, "the cells use the current material")
		expect(State.undo_redo.get_history_count() == 1, "the whole stroke is one history action")
		expect(int(data.get("revision", -1)) >= 0, "the stroke reports a revision")
		expect(int(data.get("changed_chunks", 0)) >= 1, "the stroke reports the changed chunks")
		expect(data.get("changed_bounds") != null, "the stroke reports changed bounds")
	)


func _fill() -> void:
	step("Given a blue floor and a green material", func():
		var frame := State.get_current_voxel_frame()
		for x in range(-1, 2):
			for z in range(-1, 2):
				frame.set_cell(Vector3i(x, 0, z), VoxelFrame.material(Color.BLUE))
		State.document._bounds_dirty = true
		State.current_color = Color.GREEN
		State.undo_redo.clear_history()
	)
	await _call("set_tool", {"tool": "fill", "connected": true})
	var response := await _call("fill", {"seed": [0, 0, 0]})
	var data := _result_data(response)
	step("Then the connected region uses the green material", func():
		expect(not _is_error(response), "fill succeeds")
		var frame := State.get_current_voxel_frame()
		var green := 0
		for x in range(-1, 2):
			for z in range(-1, 2):
				var color := frame.get_color(Vector3i(x, 0, z))
				if color.g == 1.0 and color.r == 0.0:
					green += 1
		expect(green == 9, "the nine connected cells are green")
		expect(State.undo_redo.get_history_count() == 1, "the fill is one history action")
		expect(int(data.get("revision", -1)) >= 0, "the fill reports a revision")
		expect(int(data.get("changed_chunks", 0)) >= 1, "the fill reports the changed chunks")
		expect(data.get("changed_bounds") != null, "the fill reports changed bounds")
	)


func _write() -> void:
	step("Given a blue material", func():
		State.current_color = Color.BLUE
		State.undo_redo.clear_history()
	)
	var box_response := await _call("write_cells", {"boxes": [[-1, 0, -1, 1, 0, 1]]})
	var box_data := _result_data(box_response)
	step("Then a box writes every cell as one action", func():
		expect(not _is_error(box_response), "the box write succeeds")
		var frame := State.get_current_voxel_frame()
		expect(frame.has(Vector3i(-1, 0, -1)), "the box start is written")
		expect(frame.has(Vector3i(0, 0, 0)), "the box center is written")
		expect(frame.has(Vector3i(1, 0, 1)), "the box end is written")
		expect(int(box_data.get("applied", 0)) == 9, "the box writes nine cells")
		expect(not box_data.has("ok"), "the result has no ok echo")
		expect(State.undo_redo.get_history_count() == 1, "the box is one history action")
	)
	var run_response := await _call("write_cells", {"runs": [[2, 4, 0, 0]]})
	step("Then a run writes its x span", func():
		expect(not _is_error(run_response), "the run write succeeds")
		var frame := State.get_current_voxel_frame()
		expect(frame.has(Vector3i(2, 0, 0)), "the run start is written")
		expect(frame.has(Vector3i(4, 0, 0)), "the run end is written")
	)
	var erase_response := await _call("write_cells", {"boxes": [[-1, 0, -1, -1, 0, -1]], "erase": true})
	step("Then a box can erase", func():
		expect(not _is_error(erase_response), "the erase write succeeds")
		var frame := State.get_current_voxel_frame()
		expect(not frame.has(Vector3i(-1, 0, -1)), "the erased cell is gone")
		expect(frame.has(Vector3i(0, 0, 0)), "the other box cells stay")
	)
	var invalid_response := await _call("write_cells", {"boxes": [[1, 0, 0, 0, 0, 0]]})
	step("Then an invalid box writes nothing", func():
		expect(_is_error(invalid_response), "the invalid box reports an error")
	)
	var far_response := await _call("write_cells", {"boxes": [[1100000, 0, 0, 1100001, 0, 0]]})
	step("Then a box outside the cell range is refused", func():
		expect(_is_error(far_response), "the far box reports an error")
	)
	var wide_response := await _call("write_cells", {"boxes": [[0, 0, 0, 70000, 0, 0]]})
	step("Then a box above the cell cap is refused", func():
		expect(_is_error(wide_response), "the wide box reports an error")
	)
	var far_run := await _call("write_cells", {"runs": [[-7000000000000000000, 7000000000000000000, 0, 0]]})
	step("Then a run outside the cell range is refused", func():
		expect(_is_error(far_run), "the far run reports an error")
	)


func _write_materials() -> void:
	step("Given a black current material", func():
		State.set_material(VoxelFrame.material(Color.BLACK))
		State.undo_redo.clear_history()
	)
	var response := await _call("write_cells", {
		"materials": [{"color": "#ff0000"}, {"color": "#0000ff"}],
		"boxes": [[-1, 0, -1, 1, 0, 1, 0], [3, 0, -1, 5, 0, 1, 1]],
		"label": "Two colors",
	})
	var data := _result_data(response)
	step("Then each box uses its material in one action", func():
		expect(not _is_error(response), "the material write succeeds")
		var frame := State.get_current_voxel_frame()
		var red := frame.get_color(Vector3i(0, 0, 0))
		var blue := frame.get_color(Vector3i(4, 0, 0))
		expect(red.r == 1.0 and red.g == 0.0 and red.b == 0.0, "the first box is red")
		expect(blue.b == 1.0 and blue.r == 0.0 and blue.g == 0.0, "the second box is blue")
		expect(State.current_material == VoxelFrame.material(Color.BLACK), "the current material is unchanged")
		expect(State.undo_redo.get_history_count() == 1, "the write is one history action")
		expect(State.undo_redo.get_action_name(State.undo_redo.get_current_action()) == "Two colors", "the action uses the label")
		expect(int(data.get("applied", 0)) == 18, "the write reports 18 cells")
	)
	var invalid := await _call("write_cells", {"materials": [{"color": "#ff0000"}], "cells": [[0, 0, 0, 2]]})
	step("Then an unknown material index is refused", func():
		expect(_is_error(invalid), "the unknown index reports an error")
	)
	var missing := await _call("write_cells", {"cells": [[0, 0, 0, 0]]})
	step("Then a material index without a table is refused", func():
		expect(_is_error(missing), "the missing table reports an error")
	)


func _write_frames() -> void:
	step("Given three empty frames", func():
		State.add_frame()
		State.add_frame()
		State.current_frame = 0
		State.undo_redo.clear_history()
	)
	var response := await _call("write_cells", {
		"frames": [0, 1, 2],
		"materials": [{"color": "#00ff00"}],
		"boxes": [[0, 0, 0, 1, 0, 1, 0]],
		"label": "Three frames",
	})
	var data := _result_data(response)
	step("Then every frame holds the cells in one action", func():
		expect(not _is_error(response), "the multi-frame write succeeds")
		for index in 3:
			var frame := State.get_voxel_frame(index)
			expect(frame.has(Vector3i(0, 0, 0)) and frame.has(Vector3i(1, 0, 1)), "frame %d holds the cells" % index)
			var color := frame.get_color(Vector3i(0, 0, 0))
			expect(color.g == 1.0 and color.r == 0.0, "frame %d uses the green material" % index)
		expect(State.current_frame == 0, "the current frame stays the same")
		expect(State.undo_redo.get_history_count() == 1, "three frames are one history action")
		expect(State.undo_redo.get_action_name(State.undo_redo.get_current_action()) == "Three frames", "the action uses the label")
		expect(int(data.get("applied", 0)) == 12, "the write reports 12 cells across frames")
		var frames: Array = data.get("frames", [])
		expect(frames.size() == 3, "the response lists three frames")
	)
	step("When the action is undone", func():
		State.undo()
	)
	step("Then every frame is empty", func():
		for index in 3:
			expect(State.get_voxel_frame(index).count() == 0, "frame %d is empty" % index)
	)


func _read() -> void:
	step("Given a solid three-cell box", func():
		State.current_color = Color.BLUE
		State.undo_redo.clear_history()
	)
	await _call("write_cells", {"boxes": [[-1, -1, -1, 1, 1, 1]]})
	var response := await _call("get_cells", {"min": [-1, -1, -1], "max": [1, 1, 1], "max_cells": 100})
	var data := _result_data(response)
	step("Then the read returns x-runs", func():
		expect(not _is_error(response), "get_cells succeeds")
		expect(int(data.get("count", 0)) == 27, "the read reports 27 cells")
		expect(data.has("runs"), "the read carries runs")
		expect(not data.has("cells"), "the read does not carry cells")
		var runs: Array = data.get("runs", [])
		var total := 0
		for value in runs:
			var run: Array = value
			total += int(run[1]) - int(run[0]) + 1
		expect(total == 27, "the runs cover every cell")
		var materials: Array = data.get("materials", [])
		expect(materials.size() == 1, "the read carries one material")
	)
	var truncated_response := await _call("get_cells", {"min": [-1, -1, -1], "max": [1, 1, 1], "max_cells": 5})
	var truncated_data := _result_data(truncated_response)
	step("Then a capped read returns the next cell", func():
		expect(bool(truncated_data.get("truncated", false)), "the read is truncated")
		expect(truncated_data.has("next"), "the read names the next cell")
	)
	var exact_response := await _call("get_cells", {"min": [-1, -1, -1], "max": [1, 1, 1], "max_cells": 27})
	var exact_data := _result_data(exact_response)
	step("Then an exact cap is not truncated", func():
		expect(not bool(exact_data.get("truncated", true)), "the exact read is complete")
		expect(not exact_data.has("next"), "the exact read has no next cell")
	)
	var short_response := await _call("get_cells", {"min": [-1, -1, -1], "max": [1, 1, 1], "max_cells": 26})
	var short_data := _result_data(short_response)
	step("Then a short cap names the first missing cell", func():
		expect(bool(short_data.get("truncated", false)), "the short read is truncated")
		var next: Array = short_data.get("next", [])
		var is_last := next.size() == 3 and int(next[0]) == 1 and int(next[1]) == 1 and int(next[2]) == 1
		expect(is_last, "the next cell is the last cell of the box")
	)


func _budget() -> void:
	var response := await _call("get_state", {})
	var text := _result_text(response)
	var data := _result_data(response)
	step("Then the state is compact", func():
		expect(not _is_error(response), "get_state succeeds")
		expect(text.length() < 800, "the state stays under 800 characters")
		expect(not data.has("camera"), "the state omits the camera")
		expect(not data.has("activity"), "the state omits the activity")
		expect(data.has("document"), "the state carries the document")
		expect(data.has("active_tool"), "the state carries the active tool")
	)


func _inspect() -> void:
	step("Given two red cells, a blue cell, and a far red cell", func():
		var frame := State.get_current_voxel_frame()
		frame.set_cell(Vector3i(0, 0, 0), VoxelFrame.material(Color.RED))
		frame.set_cell(Vector3i(0, 1, 0), VoxelFrame.material(Color.RED))
		frame.set_cell(Vector3i(1, 0, 0), VoxelFrame.material(Color.BLUE))
		frame.set_cell(Vector3i(4, 0, 0), VoxelFrame.material(Color.RED))
		State.document._bounds_dirty = true
	)
	var response := await _call("inspect_document", {"islands": true, "materials": true, "palette": true})
	var data := _result_data(response)
	step("Then the summary reports the frame, materials, and islands", func():
		expect(not _is_error(response), "inspect_document succeeds")
		expect(int(data.get("revision", -1)) >= 0, "the summary carries a revision")
		expect(data.get("document", {}).has("palette"), "the palette is included on request")
		var frames: Array = data.get("frames", [])
		expect(frames.size() == 1, "the current frame is summarized")
		if frames.size() == 1:
			var frame: Dictionary = frames[0]
			expect(int(frame.get("occupied", 0)) == 4, "the frame reports four cells")
			var bounds: Dictionary = frame.get("bounds", {})
			var min_bound: Array = bounds.get("min", [])
			var max_bound: Array = bounds.get("max", [])
			expect(min_bound.size() == 3 and int(min_bound[0]) == 0 and int(min_bound[1]) == 0 and int(min_bound[2]) == 0, "the bounds start at the origin")
			expect(max_bound.size() == 3 and int(max_bound[0]) == 4 and int(max_bound[1]) == 1 and int(max_bound[2]) == 0, "the bounds cover the far cell")
			var materials: Array = frame.get("materials", [])
			expect(materials.size() == 2, "the summary lists two materials")
			var islands: Array = frame.get("islands", [])
			expect(int(frame.get("island_count", 0)) == 3, "the material scan finds three islands")
			expect(islands.size() == 3, "the island list holds three entries")
			if not islands.is_empty():
				expect(int(islands[0].get("cells", 0)) == 2, "the largest island is the two-cell red run")
	)
	var default_response := await _call("inspect_document", {"islands": false, "materials": false})
	var default_data := _result_data(default_response)
	step("Then the default summary omits the palette", func():
		expect(not default_data.get("document", {}).has("palette"), "the palette is opt-in")
	)
	step("Given a second frame with one blue cell", func():
		State.add_frame()
		var frame := State.get_current_voxel_frame()
		frame.set_cell(Vector3i(5, 0, 0), VoxelFrame.material(Color.BLUE))
		State.document._bounds_dirty = true
	)
	var transition_response := await _call("inspect_document", {"frames": [0, 1], "transitions": true, "islands": false, "materials": false})
	var transition_data := _result_data(transition_response)
	step("Then the transition reports the added and removed cells", func():
		expect(not _is_error(transition_response), "the transition summary succeeds")
		var frames: Array = transition_data.get("frames", [])
		expect(frames.size() == 2, "the summary covers both frames")
		var transitions: Array = transition_data.get("transitions", [])
		expect(transitions.size() == 1, "one transition is returned")
		if transitions.size() == 1:
			var transition: Dictionary = transitions[0]
			expect(int(transition.get("added", 0)) == 1, "the second frame adds one cell")
			expect(int(transition.get("removed", 0)) == 4, "the second frame removes four cells")
	)


func _regions() -> void:
	step("Given adjacent red and blue cells and a far red cell", func():
		var frame := State.get_current_voxel_frame()
		frame.set_cell(Vector3i(0, 0, 0), VoxelFrame.material(Color.RED))
		frame.set_cell(Vector3i(1, 0, 0), VoxelFrame.material(Color.BLUE))
		frame.set_cell(Vector3i(5, 0, 0), VoxelFrame.material(Color.RED))
		State.document._bounds_dirty = true
	)
	var material_response := await _call("get_regions", {"group": "material"})
	var frame_response := await _call("get_regions", {"group": "frame"})
	step("Then material grouping separates the colors and frame grouping merges them", func():
		var material_data := _result_data(material_response)
		var frame_data := _result_data(frame_response)
		expect(not _is_error(material_response), "material regions succeed")
		expect(not _is_error(frame_response), "frame regions succeed")
		expect(int(material_data.get("region_count", 0)) == 3, "material grouping keeps three regions")
		expect(int(frame_data.get("region_count", 0)) == 2, "frame grouping merges the touching cells")
		var regions: Array = frame_data.get("regions", [])
		expect(regions.size() == 2, "frame grouping lists two regions")
		if not regions.is_empty():
			expect(int(regions[0].get("cells", 0)) == 2, "the merged region has two cells")
	)


func _slice() -> void:
	step("Given a red floor row and a blue cell", func():
		var frame := State.get_current_voxel_frame()
		for x in 3:
			frame.set_cell(Vector3i(x, 0, 0), VoxelFrame.material(Color.RED))
		frame.set_cell(Vector3i(0, 0, 1), VoxelFrame.material(Color.BLUE))
		State.document._bounds_dirty = true
	)
	var response := await _call("get_slice", {"axis": "y", "layers": [0], "mode": "materials", "scale": 1})
	var data := _result_data(response)
	step("Then the slice has labeled rows and a legend", func():
		expect(not _is_error(response), "get_slice succeeds")
		expect(str(data.get("columns", "")) == "x", "the columns are x")
		expect(str(data.get("rows", "")) == "z", "the rows are z")
		var slices: Array = data.get("slices", [])
		expect(slices.size() == 1, "one layer is returned")
		if slices.size() == 1:
			var lines: Array = slices[0].get("lines", [])
			expect(lines.size() == 2, "the slice has two rows")
			if lines.size() == 2:
				expect(str(lines[0]) == "###", "the first row is the red floor")
				expect(str(lines[1]) == "+..", "the second row starts with the blue cell")
		var legend: Array = data.get("legend", [])
		expect(legend.size() == 2, "the legend lists two materials")
	)
	var height_response := await _call("get_slice", {"axis": "y", "mode": "height", "scale": 1})
	var height_data := _result_data(height_response)
	step("Then the height projection reports the top cell", func():
		expect(not _is_error(height_response), "the height projection succeeds")
		var values: Array = height_data.get("values", [])
		expect(values.size() == 2, "the projection has two rows")
		if not values.is_empty():
			var first_row: Array = values[0]
			var second_row: Array = values[1]
			expect(first_row.size() == 3 and int(first_row[0]) == 0 and int(first_row[1]) == 0 and int(first_row[2]) == 0, "the first row is at height zero")
			expect(second_row.size() == 3 and int(second_row[0]) == 0 and int(second_row[1]) == -1 and int(second_row[2]) == -1, "the second row only holds the blue column")
	)


func _map() -> void:
	step("Given cells in two 16-cell blocks", func():
		var frame := State.get_current_voxel_frame()
		frame.set_cell(Vector3i(0, 0, 0), VoxelFrame.material(Color.RED))
		frame.set_cell(Vector3i(15, 0, 0), VoxelFrame.material(Color.RED))
		frame.set_cell(Vector3i(16, 0, 0), VoxelFrame.material(Color.BLUE))
		State.document._bounds_dirty = true
	)
	var response := await _call("get_map", {"cell_size": 16})
	var data := _result_data(response)
	step("Then two blocks hold the cells", func():
		expect(not _is_error(response), "get_map succeeds")
		var blocks: Array = data.get("blocks", [])
		expect(int(data.get("block_count", 0)) == 2, "two blocks are non-empty")
		expect(blocks.size() == 2, "two blocks are listed")
		if blocks.size() == 2:
			expect(int(blocks[0][3]) == 2, "the first block holds two cells")
			expect(int(blocks[1][3]) == 1, "the second block holds one cell")
	)


func _chunk_map_fallback() -> void:
	step("Given two cells in different chunks", func():
		var frame := State.get_current_voxel_frame()
		frame.set_cell(Vector3i(0, 0, 0), VoxelFrame.material(Color.RED))
		frame.set_cell(Vector3i(16, 0, 0), VoxelFrame.material(Color.RED))
		State.document._bounds_dirty = true
	)
	var response: Variant = server.call("_chunk_map", State.get_current_voxel_frame(), 0, Vector3i(-1, -1, -1), Vector3i(20, 20, 20), 512)
	step("Then the fallback lists chunk blocks", func():
		expect(response is Dictionary, "the fallback returns a tool result")
		if response is Dictionary:
			var result: Dictionary = response
			var content: Array = result.get("content", [])
			var data: Variant = null
			if not content.is_empty():
				var entry: Dictionary = content[0]
				data = JSON.parse_string(str(entry.get("text", "")))
			expect(data is Dictionary, "the fallback returns JSON")
			if data is Dictionary:
				expect(bool(data.get("chunk_aligned", false)), "the map is chunk aligned")
				expect(int(data.get("cell_size", 0)) == 16, "the chunk size is 16")
				expect(int(data.get("block_count", 0)) == 2, "two chunks are listed")
				var blocks: Array = data.get("blocks", [])
				expect(blocks.size() == 2, "two blocks are returned")
				if blocks.size() == 2:
					expect(int(blocks[0][3]) == 1 and int(blocks[1][3]) == 1, "each chunk holds one cell")
	)


func _changes() -> void:
	var write_response := await _call("write_cells", {"cells": [[0, 0, 0], [1, 0, 0]]})
	var write_data := _result_data(write_response)
	var revision := int(write_data.get("revision", -1))
	step("When the agent writes two cells", func():
		expect(not _is_error(write_response), "write_cells succeeds")
		expect(revision >= 0, "the write reports a revision")
		var changed_bounds: Dictionary = write_data.get("changed_bounds", {})
		var min_bound: Array = changed_bounds.get("min", [])
		var max_bound: Array = changed_bounds.get("max", [])
		expect(min_bound.size() == 3 and int(min_bound[0]) == 0 and int(min_bound[1]) == 0 and int(min_bound[2]) == 0, "the write reports its start bounds")
		expect(max_bound.size() == 3 and int(max_bound[0]) == 1 and int(max_bound[1]) == 0 and int(max_bound[2]) == 0, "the write reports its end bounds")
	)
	var second_response := await _call("write_cells", {"cells": [[5, 0, 0]]})
	var second_data := _result_data(second_response)
	var changes_response := await _call("get_changes", {"since": revision})
	var changes_data := _result_data(changes_response)
	step("Then get_changes returns only the later cell", func():
		expect(not _is_error(changes_response), "get_changes succeeds")
		expect(not bool(changes_data.get("full_refresh", true)), "the delta is available")
		expect(int(changes_data.get("count", 0)) == 1, "one cell changed")
		var changed: Array = _run_cells(changes_data.get("cells", []))
		expect(changed == [Vector3i(5, 0, 0)], "the delta names the new cell")
	)
	var none_response := await _call("get_changes", {"since": int(second_data.get("revision", -1))})
	var none_data := _result_data(none_response)
	step("Then a current revision has no changes", func():
		expect(int(none_data.get("count", -1)) == 0, "no cells changed after the last revision")
		expect(not bool(none_data.get("full_refresh", true)), "the current revision is not stale")
	)
	var stale_response := await _call("get_changes", {"since": 999999})
	var stale_data := _result_data(stale_response)
	step("Then an impossible revision asks for a full read", func():
		expect(bool(stale_data.get("full_refresh", false)), "the stale revision reports full_refresh")
	)
	var undone := State.undo()
	var undo_response := await _call("get_changes", {"since": int(second_data.get("revision", -1))})
	var undo_data := _result_data(undo_response)
	step("Then an undo asks for a full read", func():
		expect(undone, "the undo succeeds")
		expect(bool(undo_data.get("full_refresh", false)), "the undo reports full_refresh")
	)


func _cursor() -> void:
	var cells := []
	for z in 3:
		for y in 3:
			for x in 3:
				cells.append([x, y, z])
	var write_response := await _call("write_cells", {"cells": cells})
	expect(not _is_error(write_response), "the nine cells are written")
	var all_response := await _call("get_cells", {})
	var all_data := _result_data(all_response)
	expect(int(all_data.get("count", 0)) == 27, "the default read covers the frame")
	var collected := {}
	var cursor: Variant = null
	var pages := 0
	while pages < 20:
		var args := {"min": [0, 0, 0], "max": [2, 2, 2], "max_cells": 2}
		if cursor != null:
			args["cursor"] = cursor
		var response := await _call("get_cells", args)
		var data := _result_data(response)
		expect(not _is_error(response), "a page succeeds")
		for cell in _run_cells(data.get("runs", [])):
			collected[cell] = true
		if not bool(data.get("truncated", false)):
			break
		cursor = data.get("next", null)
		expect(cursor is Array, "a truncated page returns a cursor")
		pages += 1
	step("Then the cursor pages cover every cell once", func():
		expect(pages > 0, "the read used more than one page")
		expect(collected.size() == 27, "all 27 cells are read")
	)


func _run_cells(runs: Array) -> Array:
	var cells := []
	for run in runs:
		var x0: int = run[0]
		var x1: int = run[1]
		var y: int = run[2]
		var z: int = run[3]
		for x in range(x0, x1 + 1):
			cells.append(Vector3i(x, y, z))
	return cells


func _emission() -> void:
	var response := await _call("set_material", {"color": "#ff7a1a", "emission": "#ff7a1a", "metallic": 0.0, "roughness": 0.4})
	var data := _result_data(response)
	step("Then the material carries a glow", func():
		expect(not _is_error(response), "set_material succeeds")
		var material: Dictionary = data.get("material", {})
		expect(str(material.get("emission", "")) == "#ff7a1a", "the material reports its emission")
	)
	var write_response := await _call("write_cells", {"cells": [[0, 0, 0]]})
	step("Then a written cell keeps the emission", func():
		expect(not _is_error(write_response), "write_cells succeeds")
		var frame := State.get_current_voxel_frame()
		var emission := frame.get_emission(Vector3i.ZERO)
		expect(emission.r > 0.9 and emission.g > 0.4, "the cell glows orange")
	)
	var clear_response := await _call("set_material", {"color": "#00ff00"})
	var clear_data := _result_data(clear_response)
	step("Then a new color clears the glow", func():
		expect(not _is_error(clear_response), "the color change succeeds")
		var material: Dictionary = clear_data.get("material", {})
		expect(not material.has("emission"), "the material has no emission")
	)
	var invalid_response := await _call("set_material", {"color": [2.0, 0.0, 0.0]})
	step("Then an out-of-range material is refused", func():
		expect(_is_error(invalid_response), "the invalid material reports an error")
	)


func _save_open() -> void:
	var path := "user://mcp_save_test.lve"
	var png_path := "user://mcp_save_test.lve.png"
	step("Given a red cell and a save path", func():
		var frame := State.get_current_voxel_frame()
		frame.set_cell(Vector3i(1, 2, 3), VoxelFrame.material(Color.RED))
		State.document._bounds_dirty = true
		State.document.edit_dirty = true
		DirAccess.remove_absolute(path)
		DirAccess.remove_absolute(png_path)
	)
	var save_response := await _call("save_document", {"path": path, "copy": false})
	var save_data := _result_data(save_response)
	step("Then the document is written and the tab is marked saved", func():
		expect(not _is_error(save_response), "save_document succeeds")
		expect(FileAccess.file_exists(path), "the saved file exists")
		expect(str(save_data.get("path", "")) != "", "the save reports a path")
		expect(State.document.edit_save_path == path, "the save records the save path")
		expect(State.document.file_path == path, "the document records the file path")
		expect(not State.document.edit_dirty, "the save clears the unsaved mark")
	)
	var copy_path := "user://mcp_copy_test.lve"
	step("Given the saved document is edited again", func():
		State.document.edit_dirty = true
		DirAccess.remove_absolute(copy_path)
	)
	var copy_response := await _call("save_document", {"path": copy_path})
	var copy_data := _result_data(copy_response)
	step("Then a copy save keeps the main path and unsaved mark", func():
		expect(not _is_error(copy_response), "the copy save succeeds")
		expect(FileAccess.file_exists(copy_path), "the copy file exists")
		expect(bool(copy_data.get("copy", false)), "the result reports a copy")
		expect(State.document.edit_save_path == path, "the main save path is unchanged")
		expect(State.document.edit_dirty, "the unsaved mark stays")
		DirAccess.remove_absolute(copy_path)
	)
	var open_response := await _call("open_document", {"path": path})
	step("Then the document opens in a new tab", func():
		expect(not _is_error(open_response), "open_document succeeds")
		expect(int(_result_data(open_response).get("frames", 0)) == 1, "the loaded document has one frame")
		expect(State.get_current_voxel_frame().has(Vector3i(1, 2, 3)), "the loaded document keeps the cell")
		expect(State.document.edit_save_path == path, "the open document records the save path")
		DirAccess.remove_absolute(path)
	)
	var png_response := await _call("save_document", {"path": png_path})
	step("Then a PNG document saves with a preview", func():
		expect(not _is_error(png_response), "the PNG save succeeds")
		expect(FileAccess.file_exists(png_path), "the PNG file exists")
	)
	var png_open := await _call("open_document", {"path": png_path})
	step("Then the PNG document opens", func():
		expect(not _is_error(png_open), "the PNG open succeeds")
		expect(int(_result_data(png_open).get("frames", 0)) == 1, "the PNG document has one frame")
		DirAccess.remove_absolute(png_path)
	)


func _new_tab() -> void:
	var before := State.tabs.size()
	var previous := State.document
	var response := await _call("new_document", {})
	step("Then the new document is active in its own tab", func():
		expect(not _is_error(response), "new_document succeeds")
		expect(State.tabs.size() == before + 1, "the tab count grows")
		expect(State.document != previous, "the active document changes")
		expect(int(_result_data(response).get("frames", 0)) == 1, "the new document has one frame")
	)


func _frames() -> void:
	var add_response: Dictionary = await _call("add_frame", {})
	var add_data := _result_data(add_response)
	step("Then an empty frame follows the first frame", func():
		expect(not _is_error(add_response), "add_frame succeeds")
		expect(int(add_data.get("frames", 0)) == 2, "the document holds two frames")
		expect(int(add_data.get("frame", -1)) == 1, "the new frame is current")
	)
	step("Given one cell in the new frame", func():
		var frame := State.get_current_voxel_frame()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.document._bounds_dirty = true
	)
	var duplicate_response: Dictionary = await _call("duplicate_frame", {})
	var duplicate_data := _result_data(duplicate_response)
	step("Then the duplicate copies the cell", func():
		expect(not _is_error(duplicate_response), "duplicate_frame succeeds")
		expect(int(duplicate_data.get("frames", 0)) == 3, "the document holds three frames")
		expect(State.get_current_voxel_frame().has(Vector3i.ZERO), "the duplicate keeps the cell")
	)
	var delay_response: Dictionary = await _call("set_frame_delay", {"frame": 1, "ms": 120})
	step("Then the frame delay is set", func():
		expect(not _is_error(delay_response), "set_frame_delay succeeds")
		expect(State.document.frames[1].delay_ms == 120, "the frame delay is 120 ms")
	)
	var loop_response: Dictionary = await _call("set_tag_loop", {"mode": "ping_pong", "repeats": 0})
	step("Then the active tag loops both ways", func():
		expect(not _is_error(loop_response), "set_tag_loop succeeds")
		var tag := State.get_tag(State.active_tag)
		expect(tag.loop_mode == AnimationTag.LoopMode.PING_PONG, "the tag uses ping-pong")
	)


func _edit_frames() -> void:
	var insert_response := await _call("add_frame", {"index": 0})
	var insert_data := _result_data(insert_response)
	step("When an empty frame is inserted at the start", func():
		expect(not _is_error(insert_response), "add_frame accepts an index")
		expect(int(insert_data.get("frames", 0)) == 2, "the document holds two frames")
		expect(int(insert_data.get("frame", -1)) == 0, "the inserted frame is current")
	)
	var move_response := await _call("move_frame", {"from": 0, "to": 1})
	var move_data := _result_data(move_response)
	step("When the frame moves to the end", func():
		expect(not _is_error(move_response), "move_frame succeeds")
		expect(int(move_data.get("frame", -1)) == 1, "the moved frame is current")
	)
	var add_response := await _call("add_frame", {})
	step("When another empty frame is added", func():
		expect(not _is_error(add_response), "add_frame succeeds without an index")
		expect(State.document.frames.size() == 3, "the document holds three frames")
	)
	var remove_response := await _call("remove_frame", {"frame": 1})
	var remove_data := _result_data(remove_response)
	step("When a middle frame is removed", func():
		expect(not _is_error(remove_response), "remove_frame succeeds")
		expect(int(remove_data.get("frames", 0)) == 2, "one frame is gone")
	)
	var last_remove := await _call("remove_frame", {"frame": 0})
	step("When the second frame is removed", func():
		expect(not _is_error(last_remove), "the second removal succeeds")
		expect(State.document.frames.size() == 1, "one frame remains")
	)
	var refused := await _call("remove_frame", {"frame": 0})
	step("Then the last frame cannot be removed", func():
		expect(_is_error(refused), "remove_frame refuses the last frame")
		expect(State.document.frames.size() == 1, "the document keeps one frame")
	)


func _edit_tags() -> void:
	for index in range(2):
		await _call("add_frame", {})
	var add_response := await _call("add_tag", {"name": "Laugh", "from": 1, "to": 2, "mode": "ping_pong", "repeats": 0})
	var add_data := _result_data(add_response)
	step("When a two-frame tag is added", func():
		expect(not _is_error(add_response), "add_tag succeeds")
		expect(State.document.tags.size() == 2, "the document holds two tags")
		expect(State.active_tag == 1, "the new tag is active")
		expect(str(add_data.get("name", "")) == "Laugh", "the tag keeps its name")
		expect(int(add_data.get("from", -1)) == 1 and int(add_data.get("to", -1)) == 2, "the tag keeps its range")
		expect(State.get_tag(1).loop_mode == AnimationTag.LoopMode.PING_PONG, "the tag loops ping-pong")
	)
	var rename_response := await _call("rename_tag", {"tag": 1, "name": "Joy"})
	step("When the tag is renamed", func():
		expect(not _is_error(rename_response), "rename_tag succeeds")
		expect(State.get_tag(1).name == "Joy", "the tag name changes")
	)
	var range_response := await _call("set_tag_range", {"tag": 1, "from": 0, "to": 2})
	step("When the tag range is widened", func():
		expect(not _is_error(range_response), "set_tag_range succeeds")
		expect(State.get_tag(1).from == 0 and State.get_tag(1).to == 2, "the tag covers all frames")
	)
	var loop_response := await _call("set_tag_loop", {"tag": 1, "mode": "forward", "repeats": 2})
	step("When the tag loop changes", func():
		expect(not _is_error(loop_response), "set_tag_loop accepts a tag")
		expect(State.get_tag(1).loop_mode == AnimationTag.LoopMode.FORWARD, "the tag loops forward")
		expect(State.get_tag(1).repeats == 2, "the tag repeats twice")
	)
	var select_response := await _call("set_active_tag", {"tag": 0})
	step("When the first tag is selected", func():
		expect(not _is_error(select_response), "set_active_tag succeeds")
		expect(State.active_tag == 0, "the first tag is active")
	)
	var state_response := await _call("get_state", {})
	var state_data := _result_data(state_response)
	var tags: Array = state_data.get("tags", [])
	var names := []
	for entry in tags:
		if entry is Dictionary:
			names.append(str(entry.get("name", "")))
	step("Then the state lists both tags", func():
		expect(int(state_data.get("active_tag", -1)) == 0, "the state names the active tag")
		expect(names.has("Joy"), "the state lists the renamed tag")
		expect(int(tags.size()) == 2, "the state lists two tags")
	)
	var clear_response := await _call("set_active_tag", {"tag": -1})
	step("When the tag selection is cleared", func():
		expect(not _is_error(clear_response), "set_active_tag accepts -1")
		expect(State.active_tag == -1, "no tag is active")
	)
	await _call("set_active_tag", {"tag": 1})
	var remove_response := await _call("remove_tag", {"tag": 1})
	step("When the second tag is removed", func():
		expect(not _is_error(remove_response), "remove_tag succeeds")
		expect(State.document.tags.size() == 1, "one tag remains")
	)
	var refused := await _call("remove_tag", {"tag": 0})
	step("Then the last tag cannot be removed", func():
		expect(_is_error(refused), "remove_tag refuses the last tag")
		expect(State.document.tags.size() == 1, "the document keeps one tag")
	)


func _busy() -> void:
	var edit := State.begin_edit()
	step("Given an open user edit", func():
		expect(edit != null, "the user edit is open")
	)
	var response := await _call("stroke", {"points": [[0, 0, 0]]})
	step("Then the agent stroke is refused", func():
		expect(_is_error(response), "the agent stroke reports an error")
	)
	var new_response := await _call("new_document", {})
	step("Then a new document is refused", func():
		expect(_is_error(new_response), "new_document reports busy")
	)
	var open_response := await _call("open_document", {"path": "res://Flamingo.lve"})
	step("Then opening a document is refused", func():
		expect(_is_error(open_response), "open_document reports busy")
	)
	var save_response := await _call("save_document", {"path": "user://mcp_busy_save.lve"})
	step("Then a save is refused", func():
		expect(_is_error(save_response), "save_document reports busy")
		expect(not FileAccess.file_exists("user://mcp_busy_save.lve"), "the busy save writes no file")
	)
	step("Then the user edit is cancelled", func():
		State.cancel_edit(edit)
	)


func _tcp() -> void:
	var port_value: Variant = server.call("local_port")
	var port: int = int(port_value) if port_value is int else 0
	step("Given the loopback server and a TCP client", func():
		peer = StreamPeerTCP.new()
		var error := peer.connect_to_host("127.0.0.1", port)
		expect(error == OK, "the client connects")
	)
	await _wait_connected()
	step("When the client initializes", func():
		expect(peer.get_status() == StreamPeerTCP.STATUS_CONNECTED, "the client is connected")
		_send_request({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}})
	)
	var initialize_line := await _read_line()
	var initialize: Variant = JSON.parse_string(initialize_line)
	step("Then the server identifies itself", func():
		expect(initialize is Dictionary, "the initialize response is JSON")
		if initialize is Dictionary:
			var response: Dictionary = initialize
			var result: Dictionary = response.get("result", {})
			var info: Dictionary = result.get("serverInfo", {})
			expect(str(info.get("name", "")) == "lve", "the server name is lve")
	)
	step("When the client lists the tools", func():
		_send_request({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
	)
	var tools_line := await _read_line()
	var tools: Variant = JSON.parse_string(tools_line)
	step("Then the tool list holds the state and stroke tools", func():
		expect(tools is Dictionary, "the tools response is JSON")
		if tools is Dictionary:
			var response: Dictionary = tools
			var result: Dictionary = response.get("result", {})
			var entries: Array = result.get("tools", [])
			var names := []
			for entry in entries:
				if entry is Dictionary:
					names.append(str(entry.get("name", "")))
			expect(names.has("get_state"), "get_state is listed")
			expect(names.has("stroke"), "stroke is listed")
	)


func _http() -> void:
	server.call("stop")
	var start_value: Variant = server.call("start", 0, true)
	var start_error: Error = start_value if start_value is int else ERR_UNAVAILABLE
	expect(start_error == OK, "the HTTP server starts")
	var port_value: Variant = server.call("local_port")
	var port: int = int(port_value) if port_value is int else 0
	var body := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}'
	var response := await _http_post(port, "Content-Type: application/json\r\n", body)
	expect(response.begins_with("HTTP/1.1 200"), "the HTTP initialize returns 200")
	expect(response.contains("\"name\":\"lve\""), "the HTTP body identifies the server")
	var origin_response := await _http_post(port, "Origin: http://evil.example\r\nContent-Type: application/json\r\n", body)
	expect(origin_response.begins_with("HTTP/1.1 403"), "a browser origin is refused")
	var plain_response := await _http_post(port, "Content-Type: text/plain\r\n", body)
	expect(plain_response.begins_with("HTTP/1.1 415"), "a non-JSON content type is refused")
	var sse := StreamPeerTCP.new()
	sse.connect_to_host("127.0.0.1", port)
	await _wait_client(sse)
	sse.put_data("GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n\r\n".to_utf8_buffer())
	var sse_response := await _read_http(sse, true)
	expect(sse_response.contains("text/event-stream"), "the GET opens an SSE stream")
	sse.disconnect_from_host()


func _http_post(port: int, headers: String, body: String) -> String:
	var client := StreamPeerTCP.new()
	var connect_error := client.connect_to_host("127.0.0.1", port)
	expect(connect_error == OK, "the HTTP client connects")
	await _wait_client(client)
	var request := "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n%sContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [headers, body.to_utf8_buffer().size(), body]
	client.put_data(request.to_utf8_buffer())
	var response := await _read_http(client)
	client.disconnect_from_host()
	return response


func _screenshot() -> void:
	step("Given one red cell in the current frame", func():
		var frame := State.get_current_voxel_frame()
		frame.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		State.document._bounds_dirty = true
	)
	var response := await _call("screenshot", {"size": 64, "view": "isometric"})
	var data := _result_data(response)
	step("Then the default result saves a file without an image", func():
		expect(not _is_error(response), "the screenshot succeeds")
		var result: Dictionary = response.get("result", {})
		var content: Array = result.get("content", [])
		expect(content.size() == 1, "the default result holds one text entry")
		if content.size() == 1:
			var entry: Dictionary = content[0]
			expect(str(entry.get("type", "")) == "text", "the entry is text")
		expect(FileAccess.file_exists(str(data.get("path", ""))), "the screenshot file exists")
	)
	var inline_response := await _call("screenshot", {"size": 64, "inline": true})
	step("Then inline true returns the image", func():
		expect(not _is_error(inline_response), "the inline screenshot succeeds")
		var result: Dictionary = inline_response.get("result", {})
		var content: Array = result.get("content", [])
		expect(content.size() >= 2, "the inline result holds an image and text")
		if content.size() >= 1:
			var image_entry: Dictionary = content[0]
			expect(str(image_entry.get("type", "")) == "image", "the first entry is an image")
			expect(str(image_entry.get("mimeType", "")) == "image/png", "the image is a PNG")
			expect(not str(image_entry.get("data", "")).is_empty(), "the image has data")
	)
	var current_focus := await _call("screenshot", {"view": "current", "focus": [0, 0, 0, 0, 0, 0]})
	step("Then focus with the current view is refused", func():
		expect(_is_error(current_focus), "the current view rejects focus")
	)
	step("Given a second frame with a blue cell", func():
		State.add_frame()
		var frame := State.get_current_voxel_frame()
		frame.set_cell(Vector3i(4, 4, 4), VoxelFrame.material(Color.BLUE))
		State.document._bounds_dirty = true
	)
	var views_response := await _call("screenshot", {"views": ["isometric", "front", "right", "top"], "size": 64})
	var views_data := _result_data(views_response)
	step("Then the contact sheet holds four tiles", func():
		expect(not _is_error(views_response), "the contact sheet succeeds")
		expect(int(views_data.get("columns", 0)) == 2, "the contact sheet uses two columns")
		expect(int(views_data.get("rows", 0)) == 2, "the contact sheet uses two rows")
		expect(int(views_data.get("width", 0)) == 132, "the contact sheet width includes the gap")
		var views: Array = views_data.get("views", [])
		expect(views.size() == 4, "the contact sheet names four views")
	)
	var story_response := await _call("screenshot", {"frames": [0, 1], "view": "isometric", "size": 64})
	var story_data := _result_data(story_response)
	step("Then the storyboard holds both frames", func():
		expect(not _is_error(story_response), "the storyboard succeeds")
		var frames: Array = story_data.get("frames", [])
		expect(frames.size() == 2, "the storyboard names two frames")
		expect(int(story_data.get("columns", 0)) == 2, "the storyboard uses two columns")
		expect(int(story_data.get("rows", 0)) == 1, "the storyboard uses one row")
	)


func _wait_client(client: StreamPeerTCP) -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while client.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() < deadline:
		client.poll()
		await get_tree().process_frame
	client.poll()


func _read_http(client: StreamPeerTCP, headers_only := false) -> String:
	var buffer := PackedByteArray()
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		var text := buffer.get_string_from_utf8()
		var header_end := text.find("\r\n\r\n")
		if header_end >= 0:
			var length := _http_content_length(text.substr(0, header_end))
			if headers_only or text.length() >= header_end + 4 + length:
				return text
		var available := client.get_available_bytes()
		if available > 0:
			var result := client.get_partial_data(available)
			if result[0] == OK:
				buffer.append_array(result[1])
		client.poll()
		await get_tree().process_frame
	return buffer.get_string_from_utf8()


func _http_content_length(headers: String) -> int:
	for line in headers.split("\r\n"):
		var separator := line.find(":")
		if separator < 0:
			continue
		if line.substr(0, separator).strip_edges().to_lower() == "content-length":
			return maxi(0, int(line.substr(separator + 1).strip_edges()))
	return 0


func _wait_connected() -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() < deadline:
		peer.poll()
		await get_tree().process_frame
	peer.poll()


func _send_request(request: Dictionary) -> void:
	peer.put_data((JSON.stringify(request) + "\n").to_utf8_buffer())


func _read_line() -> String:
	var buffer := PackedByteArray()
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		var index := buffer.find(10)
		if index >= 0:
			return buffer.slice(0, index).get_string_from_utf8().strip_edges()
		var available := peer.get_available_bytes()
		if available > 0:
			var result := peer.get_partial_data(available)
			if result[0] == OK:
				buffer.append_array(result[1])
		peer.poll()
		await get_tree().process_frame
	return ""
