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
	test("get_cells returns compact runs", _read, "get_cells")
	test("materials can glow", _emission, "emission")
	test("documents save and open", _save_open, "save_open")
	test("new_document opens a new tab", _new_tab, "new_document")
	test("frames and tags can be driven", _frames, "frames")
	test("a user edit makes an agent action busy", _busy, "busy")
	test("the loopback transport answers MCP requests", _tcp, "tcp")
	test("the HTTP transport answers a POST and opens an SSE stream", _http, "http")
	test("a screenshot saves a file and returns an image on request", _screenshot, "screenshot")
	test("the compact state stays small", _budget, "budget")


func _setup_test() -> void:
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


func _cleanup_test() -> void:
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
	step("Then the cells are painted and one undo action is recorded", func():
		expect(not _is_error(response), "stroke succeeds")
		var frame := State.get_current_voxel_frame()
		expect(frame.has(Vector3i(0, 0, 0)), "the first center is painted")
		expect(frame.has(Vector3i(0, 0, 1)), "the path is connected")
		expect(frame.has(Vector3i(0, 0, 2)), "the last center is painted")
		expect(frame.get_color(Vector3i(0, 0, 1)).r == 1.0 and frame.get_color(Vector3i(0, 0, 1)).g == 0.0, "the cells use the current material")
		expect(State.undo_redo.get_history_count() == 1, "the whole stroke is one history action")
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


func _budget() -> void:
	var response := await _call("get_state", {})
	var text := _result_text(response)
	var data := _result_data(response)
	step("Then the state is compact", func():
		expect(not _is_error(response), "get_state succeeds")
		expect(text.length() < 500, "the state stays under 500 characters")
		expect(not data.has("camera"), "the state omits the camera")
		expect(not data.has("activity"), "the state omits the activity")
		expect(data.has("document"), "the state carries the document")
		expect(data.has("active_tool"), "the state carries the active tool")
	)


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


func _save_open() -> void:
	var path := "user://mcp_save_test.lve"
	step("Given a red cell and a save path", func():
		var frame := State.get_current_voxel_frame()
		frame.set_cell(Vector3i(1, 2, 3), VoxelFrame.material(Color.RED))
		State.document._bounds_dirty = true
		DirAccess.remove_absolute(path)
	)
	var save_response := await _call("save_document", {"path": path})
	var save_data := _result_data(save_response)
	step("Then the document is written", func():
		expect(not _is_error(save_response), "save_document succeeds")
		expect(FileAccess.file_exists(path), "the saved file exists")
		expect(str(save_data.get("path", "")) != "", "the save reports a path")
	)
	var open_response := await _call("open_document", {"path": path})
	step("Then the document opens in a new tab", func():
		expect(not _is_error(open_response), "open_document succeeds")
		expect(int(_result_data(open_response).get("frames", 0)) == 1, "the loaded document has one frame")
		expect(State.get_current_voxel_frame().has(Vector3i(1, 2, 3)), "the loaded document keeps the cell")
		DirAccess.remove_absolute(path)
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


func _busy() -> void:
	var edit := State.begin_edit()
	step("Given an open user edit", func():
		expect(edit != null, "the user edit is open")
	)
	var response := await _call("stroke", {"points": [[0, 0, 0]]})
	step("Then the agent action is refused", func():
		expect(_is_error(response), "the agent stroke reports an error")
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
	var client := StreamPeerTCP.new()
	var connect_error := client.connect_to_host("127.0.0.1", port)
	expect(connect_error == OK, "the HTTP client connects")
	await _wait_client(client)
	var body := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}'
	var request := "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [body.to_utf8_buffer().size(), body]
	client.put_data(request.to_utf8_buffer())
	var response := await _read_http(client)
	expect(response.begins_with("HTTP/1.1 200"), "the HTTP initialize returns 200")
	expect(response.contains("\"name\":\"lve\""), "the HTTP body identifies the server")
	client.disconnect_from_host()
	var sse := StreamPeerTCP.new()
	sse.connect_to_host("127.0.0.1", port)
	await _wait_client(sse)
	sse.put_data("GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n\r\n".to_utf8_buffer())
	var sse_response := await _read_http(sse, true)
	expect(sse_response.contains("text/event-stream"), "the GET opens an SSE stream")
	sse.disconnect_from_host()


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
