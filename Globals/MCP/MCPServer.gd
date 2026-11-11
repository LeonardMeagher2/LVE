extends Node

## The in-app MCP server.
##
## It listens on the loopback interface and speaks newline-delimited JSON-RPC
## to the LVE bridge. The bridge converts stdio MCP messages to this connection.
## The tools drive the editor as the user: they use the real active tool, the
## current material, the shared selection, and the normal undo history.

## The default loopback port. The bridge uses the same default.
const DEFAULT_PORT := 17373
## The off-screen viewport used for screenshots.
const SCREENSHOT_VIEWPORT := preload("res://Globals/VoxelImageRenderer/RendererViewport.tscn")
## The server log in the shared user directory.
const LOG_PATH := "user://mcp_server.log"
## The largest request line the server accepts.
const MAX_LINE_BYTES := 4 * 1024 * 1024
## The largest cell box that one read scans.
const MAX_BOX_CELLS := 262144
## The default occupied-cell cap of one read.
const MAX_GET_CELLS := 512
## The largest cell count that one write accepts.
const MAX_WRITE_CELLS := 65536

const TOOLS := [
	{
		"name": "get_state",
		"description": "Return the document, active tool, material, selection, symmetry, slice, busy, and undo state.",
		"inputSchema": {"type": "object", "additionalProperties": false},
	},
	{
		"name": "get_cells",
		"description": "Read occupied cells in an inclusive box as x-runs. The default cap is 512 cells. Set max_cells up to 4096.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"min": {"type": "array", "items": {"type": "integer"}, "minItems": 3, "maxItems": 3},
				"max": {"type": "array", "items": {"type": "integer"}, "minItems": 3, "maxItems": 3},
				"max_cells": {
					"type": "integer",
					"minimum": 1,
					"maximum": 4096,
					"description": "Occupied-cell cap. Defaults to 512.",
				},
				"frame": {"type": "integer", "minimum": 0},
			},
			"required": ["min", "max"],
			"additionalProperties": false,
		},
	},
	{
		"name": "screenshot",
		"description": "Save a PNG of one frame. Set inline true to also return the image.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"frame": {"type": "integer", "minimum": 0},
				"size": {"type": "integer", "minimum": 64, "maximum": 1024},
				"view": {"type": "string", "enum": ["isometric", "low", "front", "back", "left", "right", "top", "bottom", "current"]},
				"orthographic": {"type": "boolean"},
				"inline": {"type": "boolean"},
				"focus": {
					"type": "array",
					"items": {"type": "integer"},
					"minItems": 6,
					"maxItems": 6,
					"description": "Inclusive [x0, y0, z0, x1, y1, z1] to frame. Named views only.",
				},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "new_document",
		"description": "Open a new empty document in a new tab and make it current. The current document stays open.",
		"inputSchema": {"type": "object", "additionalProperties": false},
	},
	{
		"name": "save_document",
		"description": "Save the current document as .lve or .lve.png and return its absolute path. A .lve.png file also stores a preview.",
		"inputSchema": {
			"type": "object",
			"properties": {"path": {"type": "string", "description": "A file name or user:// path ending in .lve or .lve.png."}},
			"required": ["path"],
			"additionalProperties": false,
		},
	},
	{
		"name": "open_document",
		"description": "Open a saved .lve or .lve.png document in a new tab and make it current.",
		"inputSchema": {
			"type": "object",
			"properties": {"path": {"type": "string", "description": "A file name or user:// path."}},
			"required": ["path"],
			"additionalProperties": false,
		},
	},
	{
		"name": "add_frame",
		"description": "Add an empty frame after the last frame and make it current.",
		"inputSchema": {"type": "object", "additionalProperties": false},
	},
	{
		"name": "duplicate_frame",
		"description": "Copy the current frame and insert it after the current frame. The copy becomes current.",
		"inputSchema": {"type": "object", "additionalProperties": false},
	},
	{
		"name": "set_frame",
		"description": "Make one frame current.",
		"inputSchema": {
			"type": "object",
			"properties": {"frame": {"type": "integer", "minimum": 0}},
			"required": ["frame"],
			"additionalProperties": false,
		},
	},
	{
		"name": "set_frame_delay",
		"description": "Set one frame duration in milliseconds.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"frame": {"type": "integer", "minimum": 0},
				"ms": {"type": "integer", "minimum": 1, "maximum": 10000},
			},
			"required": ["ms"],
			"additionalProperties": false,
		},
	},
	{
		"name": "set_tag_loop",
		"description": "Set the active tag loop mode and repeat count. Repeats 0 means continuous playback.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"mode": {"type": "string", "enum": ["forward", "reverse", "ping_pong", "ping_pong_reverse"]},
				"repeats": {"type": "integer", "minimum": 0, "maximum": 1000},
			},
			"required": ["mode"],
			"additionalProperties": false,
		},
	},
	{
		"name": "set_playback",
		"description": "Start or stop animation playback.",
		"inputSchema": {
			"type": "object",
			"properties": {"playing": {"type": "boolean"}},
			"required": ["playing"],
			"additionalProperties": false,
		},
	},
	{
		"name": "set_tool",
		"description": "Select the real editor tool and set its options. This changes the user's toolbar and option bar. Use brush, eraser, paint, or fill.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"tool": {"type": "string", "enum": ["brush", "eraser", "paint", "fill"]},
				"diameter": {"type": "integer", "minimum": 1, "maximum": 64},
				"shape": {"type": "string", "enum": ["cube", "sphere"]},
				"pixel_perfect": {"type": "boolean"},
				"connected": {"type": "boolean"},
			},
			"required": ["tool"],
			"additionalProperties": false,
		},
	},
	{
		"name": "set_material",
		"description": "Set the current material. A color keeps the current metallic and roughness. emission adds a glow. A palette_index selects that palette entry. The change is undoable.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"color": {"type": "string", "description": "#rrggbb or #rrggbbaa"},
				"emission": {"type": "string", "description": "#rrggbb or #rrggbbaa"},
				"palette_index": {"type": "integer", "minimum": 0},
				"metallic": {"type": "number", "minimum": 0, "maximum": 1},
				"roughness": {"type": "number", "minimum": 0, "maximum": 1},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "set_cursor",
		"description": "Move the active tool cursor to a cell. Pass null to hide it. This moves the user's cursor.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"cell": {"type": ["array", "null"], "items": {"type": "integer"}, "minItems": 3, "maxItems": 3},
			},
			"required": ["cell"],
			"additionalProperties": false,
		},
	},
	{
		"name": "stroke",
		"description": "Draw with the active brush, paint, or eraser tool through cell centers. Select the tool first. Each call is one undo action.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"points": {
					"type": "array",
					"items": {"type": "array", "items": {"type": "integer"}, "minItems": 3, "maxItems": 3},
					"minItems": 1,
					"maxItems": 4096,
				},
			},
			"required": ["points"],
			"additionalProperties": false,
		},
	},
	{
		"name": "fill",
		"description": "Fill a connected or matching region from an occupied seed cell. Select the fill tool first. The whole region is one undo action.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"seed": {"type": "array", "items": {"type": "integer"}, "minItems": 3, "maxItems": 3},
			},
			"required": ["seed"],
			"additionalProperties": false,
		},
	},
	{
		"name": "write_cells",
		"description": "Write or erase cells with the current material. Provide cells, boxes, or runs. Each call is one undo action.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"cells": {
					"type": "array",
					"items": {"type": "array", "items": {"type": "integer"}, "minItems": 3, "maxItems": 3},
					"minItems": 1,
					"maxItems": 65536,
				},
				"boxes": {
					"type": "array",
					"items": {"type": "array", "items": {"type": "integer"}, "minItems": 6, "maxItems": 6},
					"minItems": 1,
					"maxItems": 1024,
					"description": "Inclusive [x0, y0, z0, x1, y1, z1].",
				},
				"runs": {
					"type": "array",
					"items": {"type": "array", "items": {"type": "integer"}, "minItems": 4, "maxItems": 4},
					"minItems": 1,
					"maxItems": 65536,
					"description": "Inclusive x span [x0, x1, y, z].",
				},
				"erase": {"type": "boolean"},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "sample",
		"description": "Copy the full material of one occupied cell to the current material, like the eyedropper.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"cell": {"type": "array", "items": {"type": "integer"}, "minItems": 3, "maxItems": 3},
			},
			"required": ["cell"],
			"additionalProperties": false,
		},
	},
]

const INSTRUCTIONS := "LVE is a voxel editor. Cells are integers and Y is up. Read get_state once per task. write_cells takes cells, boxes, or runs and uses the current material. Each call is one undo action. Retry once when busy."

## One accepted bridge or HTTP client.
class PeerState extends RefCounted:
	var peer: StreamPeerTCP
	var buffer := PackedByteArray()
	var busy := false
	var sse := false
	var last_ping_ms := 0


var _server := TCPServer.new()
var _peers: Array[PeerState] = []
var _http_mode := false
var _port := DEFAULT_PORT


## One direct cell write job. It writes a batch through the edit context.
class WriteJob extends VoxelFrame.EditJob:
	var edited_frame: VoxelFrame
	var changes: Dictionary
	var changed_chunks: Array[Vector3i] = []

	func run() -> void:
		stage("Writing cells", changes.size())
		changed_chunks = apply_cells(edited_frame, changes)


func _ready() -> void:
	set_process(false)


func _exit_tree() -> void:
	stop()


## Starts the loopback server. A port of zero selects a free port. In HTTP mode
## the server accepts Streamable HTTP requests at `/mcp`; otherwise it accepts
## newline-delimited JSON-RPC for the stdio bridge.
func start(port: int = DEFAULT_PORT, http_mode := false) -> Error:
	stop()
	_port = port
	_http_mode = http_mode
	var error := _server.listen(port, "127.0.0.1")
	if error != OK:
		push_warning("LVE MCP: cannot listen on 127.0.0.1:%d: %s" % [port, error_string(error)])
		return error
	print("LVE MCP: listening on 127.0.0.1:%d (%s)" % [_server.get_local_port(), "HTTP" if http_mode else "line"])
	_log("start %d %s" % [_server.get_local_port(), "http" if http_mode else "line"])
	set_process(true)
	return OK


## Stops the server and closes every client connection.
func stop() -> void:
	for state in _peers:
		state.peer.disconnect_from_host()
	_peers.clear()
	if _server.is_listening():
		_server.stop()
	_log("stop")
	set_process(false)


## Returns the port that the server listens on, or zero when it is closed.
func local_port() -> int:
	return _server.get_local_port() if _server.is_listening() else 0


func _process(_delta: float) -> void:
	_accept_all()
	var now := Time.get_ticks_msec()
	for state in _peers.duplicate():
		var peer: StreamPeerTCP = state.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_remove_peer(state)
			continue
		if state.sse:
			if now - state.last_ping_ms >= 15000:
				_send_sse_comment(state)
				state.last_ping_ms = now
			continue
		if not _read_peer_bytes(state):
			continue
		if _http_mode:
			_drain_http(state)
		else:
			_drain_lines(state)


func _accept_all() -> void:
	while _server.is_connection_available():
		var peer := _server.take_connection()
		if peer == null:
			return
		peer.set_no_delay(true)
		var state := PeerState.new()
		state.peer = peer
		_peers.append(state)


func _remove_peer(state: PeerState) -> void:
	_peers.erase(state)
	if state.peer != null:
		state.peer.disconnect_from_host()


func _read_peer_bytes(state: PeerState) -> bool:
	var available := state.peer.get_available_bytes()
	if available <= 0:
		return true
	var result := state.peer.get_partial_data(available)
	if result[0] != OK:
		return true
	var bytes: PackedByteArray = result[1]
	state.buffer.append_array(bytes)
	if state.buffer.size() > MAX_LINE_BYTES:
		# Clear the request before the peer goes, so the same frame cannot
		# dispatch the request that this limit just refused.
		state.buffer.clear()
		if _http_mode:
			_send_http(state, 413, "Payload Too Large", "")
		else:
			_send_raw(state, _error_response(null, -32600, "Request is too large."))
		_remove_peer(state)
		return false
	return true


func _drain_http(state: PeerState) -> void:
	if state.busy:
		return
	var header_end := -1
	for index in range(0, state.buffer.size() - 3):
		if state.buffer[index] == 13 and state.buffer[index + 1] == 10 \
				and state.buffer[index + 2] == 13 and state.buffer[index + 3] == 10:
			header_end = index
			break
	if header_end < 0:
		return
	var header_text := state.buffer.slice(0, header_end).get_string_from_utf8()
	var header_lines := header_text.split("\r\n")
	if header_lines.is_empty():
		state.buffer = state.buffer.slice(header_end + 4)
		return
	var request_line := header_lines[0].split(" ")
	if request_line.size() < 2:
		_send_http(state, 400, "Bad Request", "")
		state.buffer = state.buffer.slice(header_end + 4)
		return
	var method := request_line[0]
	var path := request_line[1]
	var content_length := 0
	var origin := ""
	var content_type := ""
	for line_index in range(1, header_lines.size()):
		var header := header_lines[line_index]
		var separator := header.find(":")
		if separator < 0:
			continue
		var name := header.substr(0, separator).strip_edges().to_lower()
		var value := header.substr(separator + 1).strip_edges()
		if name == "content-length":
			content_length = maxi(0, int(value))
		elif name == "origin":
			origin = value
		elif name == "content-type":
			content_type = value.to_lower()
	var body_start := header_end + 4
	if state.buffer.size() < body_start + content_length:
		return
	var body := state.buffer.slice(body_start, body_start + content_length).get_string_from_utf8()
	state.buffer = state.buffer.slice(body_start + content_length)
	state.busy = true
	_handle_http(state, method, path, body, origin, content_type)


func _handle_http(state: PeerState, method: String, path: String, body: String, origin := "", content_type := "") -> void:
	if path != "/mcp":
		_send_http(state, 404, "Not Found", _error_response(null, -32601, "Unknown endpoint."))
		state.busy = false
		return
	match method:
		"GET":
			_start_sse(state)
			state.busy = false
			return
		"DELETE":
			_send_http(state, 204, "No Content", "")
			state.busy = false
			return
		"OPTIONS":
			_send_http(state, 204, "No Content", "")
			state.busy = false
			return
		"POST":
			pass
		_:
			_send_http(state, 405, "Method Not Allowed", "")
			state.busy = false
			return
	# A browser page can send a simple cross-origin POST without a preflight.
	# Reject browser origins and require JSON, so a visited page cannot drive
	# the editor tools.
	if not origin.is_empty():
		_send_http(state, 403, "Forbidden", _error_response(null, -32600, "Browser origins are not allowed."))
		state.busy = false
		return
	if not content_type.begins_with("application/json"):
		_send_http(state, 415, "Unsupported Media Type", _error_response(null, -32600, "Content-Type must be application/json."))
		state.busy = false
		return
	var request_value: Variant = JSON.parse_string(body)
	if not (request_value is Dictionary):
		_send_http(state, 400, "Bad Request", _error_response(null, -32700, "Parse error."))
		state.busy = false
		return
	var request: Dictionary = request_value
	var response: Variant = await _dispatch_request(request)
	if response is Dictionary:
		_send_http(state, 200, "OK", response)
	else:
		_send_http(state, 202, "Accepted", "")
	state.busy = false


func _start_sse(state: PeerState) -> void:
	var header := "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n: connected\n\n"
	var error := state.peer.put_data(header.to_utf8_buffer())
	if error != OK:
		_remove_peer(state)
		return
	state.sse = true
	state.last_ping_ms = Time.get_ticks_msec()


func _send_sse_comment(state: PeerState) -> void:
	var error := state.peer.put_data(": ping\n\n".to_utf8_buffer())
	if error != OK:
		_remove_peer(state)


func _send_http(state: PeerState, status: int, reason: String, body: Variant) -> void:
	var text := ""
	if body is Dictionary:
		text = JSON.stringify(body)
	elif body is String:
		text = body
	var payload := text.to_utf8_buffer()
	var header := "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: keep-alive\r\n\r\n" % [status, reason, payload.size()]
	var bytes := header.to_utf8_buffer()
	bytes.append_array(payload)
	var error := state.peer.put_data(bytes)
	if error != OK:
		_remove_peer(state)


func _drain_lines(state: PeerState) -> void:
	if state.busy:
		return
	# Scan past empty lines in one pass. A recursive call per blank line could
	# exhaust the stack, and slicing once per line copies the buffer each time.
	var start := 0
	while true:
		var index := state.buffer.find(10, start)
		if index < 0:
			if start > 0:
				state.buffer = state.buffer.slice(start)
			return
		var line := state.buffer.slice(start, index).get_string_from_utf8().strip_edges()
		start = index + 1
		if line.is_empty():
			continue
		state.buffer = state.buffer.slice(start)
		state.busy = true
		_handle_line(state, line)
		return


func _handle_line(state: PeerState, line: String) -> void:
	var request_value: Variant = JSON.parse_string(line)
	if not (request_value is Dictionary):
		_send_raw(state, _error_response(null, -32700, "Parse error."))
		state.busy = false
		return
	var request: Dictionary = request_value
	var response: Variant = await _dispatch_request(request)
	if response is Dictionary:
		_send_raw(state, response)
	state.busy = false


func _dispatch_request(request: Dictionary) -> Variant:
	var id: Variant = request.get("id", null)
	var method_value: Variant = request.get("method", "")
	if not (method_value is String):
		if id != null:
			return _error_response(id, -32600, "Invalid request.")
		return null
	var method: String = method_value
	if id == null:
		# A notification never gets a response.
		return null
	var params: Dictionary = {}
	var params_value: Variant = request.get("params", {})
	if params_value is Dictionary:
		params = params_value
	match method:
		"initialize":
			return _result_response(id, _initialize(params))
		"tools/list":
			var tool_list := _result_response(id, {"tools": TOOLS})
			_log("tools/list %d bytes" % JSON.stringify(tool_list).length())
			return tool_list
		"tools/call":
			var response: Variant = await _call_tool(id, params)
			_log("tool %s %d bytes" % [str(params.get("name", "")), JSON.stringify(response).length()])
			return response
		"ping":
			return _result_response(id, {})
		_:
			return _error_response(id, -32601, "Unknown method: " + method)


func _initialize(params: Dictionary) -> Dictionary:
	var requested_value: Variant = params.get("protocolVersion", "2025-11-25")
	var requested: String = requested_value if requested_value is String else "2025-11-25"
	var supported := ["2025-06-18", "2025-03-26"]
	var version := requested if supported.has(requested) else "2025-06-18"
	var version_string := str(ProjectSettings.get_setting("application/config/version", "0"))
	if version_string.count(".") < 2:
		version_string += ".0"
	return {
		"protocolVersion": version,
		"capabilities": {"tools": {"listChanged": false}},
		"serverInfo": {"name": "lve", "title": "Leonard's Voxel Editor", "version": version_string},
		"instructions": INSTRUCTIONS,
	}


func _call_tool(id: Variant, params: Dictionary) -> Dictionary:
	var name_value: Variant = params.get("name", "")
	if not (name_value is String):
		return _error_response(id, -32602, "Tool name must be a string.")
	var tool_name: String = name_value
	var args: Dictionary = {}
	var args_value: Variant = params.get("arguments", {})
	if args_value is Dictionary:
		args = args_value
	match tool_name:
		"get_state":
			return _result_response(id, _get_state())
		"get_cells":
			return _result_response(id, _get_cells(args))
		"screenshot":
			return _result_response(id, await _screenshot(args))
		"new_document":
			return _result_response(id, _new_document())
		"save_document":
			return _result_response(id, await _save_document(args))
		"open_document":
			return _result_response(id, _open_document(args))
		"add_frame":
			return _result_response(id, _add_frame())
		"duplicate_frame":
			return _result_response(id, _duplicate_frame())
		"set_frame":
			return _result_response(id, _set_frame(args))
		"set_frame_delay":
			return _result_response(id, _set_frame_delay(args))
		"set_tag_loop":
			return _result_response(id, _set_tag_loop(args))
		"set_playback":
			return _result_response(id, _set_playback(args))
		"set_tool":
			return _result_response(id, _set_tool(args))
		"set_material":
			return _result_response(id, _set_material(args))
		"set_cursor":
			return _result_response(id, _set_cursor(args))
		"stroke":
			return _result_response(id, await _stroke(args))
		"fill":
			return _result_response(id, await _fill(args))
		"write_cells":
			return _result_response(id, await _write_cells(args))
		"sample":
			return _result_response(id, _sample(args))
		_:
			return _error_response(id, -32602, "Unknown tool: " + tool_name)


func _send_raw(state: PeerState, response: Dictionary) -> void:
	var line := JSON.stringify(response) + "\n"
	var error := state.peer.put_data(line.to_utf8_buffer())
	if error != OK:
		_remove_peer(state)


func _result_response(id: Variant, result: Dictionary) -> Dictionary:
	return {"jsonrpc": "2.0", "id": _response_id(id), "result": result}


func _error_response(id: Variant, code: int, message: String) -> Dictionary:
	return {"jsonrpc": "2.0", "id": _response_id(id), "error": {"code": code, "message": message}}


# JSON numbers parse as floats. A whole id goes back as an integer, so a client
# that sent 1 receives 1, not 1.0.
func _response_id(id: Variant) -> Variant:
	if id is float and is_equal_approx(id, roundf(id)):
		id = int(id)
	return id


func _tool_ok(data: Variant) -> Dictionary:
	return {"content": [{"type": "text", "text": JSON.stringify(data)}]}


func _tool_error(message: String) -> Dictionary:
	return {"content": [{"type": "text", "text": message}], "isError": true}


func _get_state() -> Dictionary:
	var document := State.document
	var frame := State.get_current_voxel_frame()
	var info := _active_tool_info()
	var slice: Variant = false
	if State.slice_enabled:
		slice = {
			"axis": _axis_name(State.floor_axis),
			"first": State.slice_first(),
			"count": State.slice_count(),
		}
	return _tool_ok({
		"document": {
			"name": document.get_file_name(),
			"frames": document.frames.size(),
			"frame": State.current_frame,
			"delay_ms": frame.delay_ms if frame != null else 0,
			"palette": document.palette.size(),
			"bounds": _aabb_json(document.bounds()),
		},
		"active_tool": {"id": str(info.get("id", "")), "params": info.get("params", {})},
		"material": _material_json(State.current_material),
		"selection": State.selection.count(),
		"symmetry": State.symmetry_axes,
		"slice": slice,
		"busy": State.edit_busy() or State.active_edit() != null,
		"undo": {"undo": State.undo_redo.has_undo(), "redo": State.undo_redo.has_redo()},
	})


func _get_cells(args: Dictionary) -> Dictionary:
	var min_value: Variant = _parse_cell(args.get("min", null))
	if min_value == null:
		return _tool_error("min must be [x, y, z].")
	var max_value: Variant = _parse_cell(args.get("max", null))
	if max_value == null:
		return _tool_error("max must be [x, y, z].")
	var min_cell: Vector3i = min_value
	var max_cell: Vector3i = max_value
	if min_cell.x > max_cell.x or min_cell.y > max_cell.y or min_cell.z > max_cell.z:
		return _tool_error("min must not exceed max on any axis.")
	var extent := max_cell - min_cell + Vector3i.ONE
	if extent.x > MAX_BOX_CELLS or extent.y > MAX_BOX_CELLS or extent.z > MAX_BOX_CELLS:
		return _tool_error("The box is too large. Scan at most %d cells." % MAX_BOX_CELLS)
	var volume := extent.x * extent.y * extent.z
	if volume > MAX_BOX_CELLS:
		return _tool_error("The box is too large. Scan at most %d cells." % MAX_BOX_CELLS)
	var limit := MAX_GET_CELLS
	var limit_value: Variant = args.get("max_cells", MAX_GET_CELLS)
	if limit_value is int or limit_value is float:
		limit = clampi(int(limit_value), 1, 4096)
	var frame_index := State.current_frame
	var frame_value: Variant = args.get("frame", null)
	if frame_value is int or frame_value is float:
		frame_index = int(frame_value)
	var frame: VoxelFrame = State.get_voxel_frame(frame_index)
	if frame == null:
		return _tool_error("The frame does not exist.")
	var cells: Array = []
	var materials: Array = []
	var material_keys := {}
	var truncated := false
	var full := false
	var done := false
	var next_cell := Vector3i.ZERO
	for z in range(min_cell.z, max_cell.z + 1):
		if done:
			break
		for y in range(min_cell.y, max_cell.y + 1):
			if done:
				break
			for x in range(min_cell.x, max_cell.x + 1):
				var cell := Vector3i(x, y, z)
				if not frame.has(cell):
					continue
				if full:
					# The cap is reached only when one more occupied cell exists.
					truncated = true
					next_cell = cell
					done = true
					break
				var material := frame.get_material(cell)
				var material_index := -1
				if material_keys.has(material):
					material_index = int(material_keys[material])
				else:
					material_index = materials.size()
					material_keys[material] = material_index
					materials.append(_material_json(material))
				cells.append([x, y, z, material_index])
				if cells.size() >= limit:
					full = true
	var runs: Array = []
	for value in cells:
		var cell: Array = value
		var x: int = cell[0]
		var y: int = cell[1]
		var z: int = cell[2]
		var material_index: int = cell[3]
		if not runs.is_empty():
			var last: Array = runs[-1]
			if last[1] + 1 == x and last[2] == y and last[3] == z and last[4] == material_index:
				last[1] = x
				continue
		runs.append([x, x, y, z, material_index])
	var data := {
		"frame": frame_index,
		"count": cells.size(),
		"truncated": truncated,
		"runs": runs,
		"materials": materials,
	}
	if truncated:
		data["next"] = _json_cell(next_cell)
	return _tool_ok(data)


func _screenshot(args: Dictionary) -> Dictionary:
	if DisplayServer.get_name() == "headless":
		return _tool_error("The screenshot needs a visible editor window.")
	var size := 256
	var size_value: Variant = args.get("size", 256)
	if size_value is int or size_value is float:
		size = clampi(int(size_value), 64, 1024)
	var inline := false
	var inline_value: Variant = args.get("inline", false)
	if inline_value is bool:
		inline = inline_value
	var frame_index := State.current_frame
	var frame_value: Variant = args.get("frame", null)
	if frame_value is int or frame_value is float:
		frame_index = int(frame_value)
	var frame: VoxelFrame = State.get_voxel_frame(frame_index)
	if frame == null:
		return _tool_error("The frame does not exist.")
	var bounds := frame.get_bounds()
	var focus_value: Variant = args.get("focus", null)
	if focus_value != null:
		var focus_box: Variant = _parse_box(focus_value)
		if focus_box == null:
			return _tool_error("focus must be [x0, y0, z0, x1, y1, z1] with min <= max.")
		var focus_array: Array = focus_box
		var start: Vector3i = focus_array[0]
		var end: Vector3i = focus_array[1]
		bounds = AABB(Vector3(start) - Vector3(0.5, 0.5, 0.5), Vector3(end - start + Vector3i.ONE))
	var view := "isometric"
	var view_value: Variant = args.get("view", "isometric")
	if view_value is String:
		view = view_value
	var orthographic := true
	var ortho_value: Variant = args.get("orthographic", true)
	if ortho_value is bool:
		orthographic = ortho_value
	if view == "current" and focus_value != null:
		return _tool_error("focus is not supported with the current view.")
	var document := State.document
	var viewport: SubViewport = SCREENSHOT_VIEWPORT.instantiate()
	viewport.size = Vector2i(size, size)
	VoxelImageRenderer.add_child(viewport)
	var renderer: VoxelRenderer = viewport.get_node("%VoxelRenderer")
	renderer.source_frame = frame.copy_frame()
	var camera: Camera3D = viewport.get_node("Node3D/Camera3D")
	var light: DirectionalLight3D = viewport.get_node("Node3D/Light")
	if view == "current":
		var main: Node = get_node_or_null("/root/Main")
		var editor_viewport: Node = null
		if main != null:
			editor_viewport = main.get_node_or_null("%Viewport")
		var editor_camera: Camera3D = null
		if editor_viewport != null:
			editor_camera = editor_viewport.get_node_or_null("%CameraRig") as Camera3D
		if editor_camera == null:
			viewport.free()
			return _tool_error("The editor camera is not available.")
		camera.transform = editor_camera.global_transform
		camera.projection = editor_camera.projection
		camera.fov = editor_camera.fov
		camera.size = editor_camera.size
		camera.near = editor_camera.near
		camera.far = editor_camera.far
	else:
		var angles := Vector2(-45.0, 45.0)
		match view:
			"front":
				angles = Vector2(0.0, 0.0)
			"back":
				angles = Vector2(180.0, 0.0)
			"left":
				angles = Vector2(90.0, 0.0)
			"right":
				angles = Vector2(-90.0, 0.0)
			"top":
				angles = Vector2(0.0, 89.9)
			"bottom":
				angles = Vector2(0.0, -89.9)
			"isometric":
				angles = Vector2(-45.0, 45.0)
			"low":
				angles = Vector2(-35.0, 18.0)
		VoxelImageRenderer.frame_camera(camera, bounds, angles.x, angles.y, orthographic)
	VoxelImageRenderer.apply_directional_shadow(light, camera)
	camera.current = true
	var deadline := Time.get_ticks_msec() + 10000
	while not renderer.is_settled() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if State.document != document:
			viewport.free()
			return _tool_error("The document changed before the screenshot finished.")
	for draw in 2:
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	image.convert(Image.FORMAT_RGBA8)
	var background := Image.create(size, size, false, Image.FORMAT_RGBA8)
	background.fill(Color(0.118, 0.122, 0.133, 1.0))
	background.blend_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), Vector2i.ZERO)
	viewport.free()
	var path := "user://mcp_screenshot.png"
	var error := background.save_png(path)
	if error != OK:
		return _tool_error("The screenshot could not be saved: " + error_string(error))
	var info := {
		"path": ProjectSettings.globalize_path(path),
		"width": size,
		"height": size,
		"frame": frame_index,
	}
	if not inline:
		return _tool_ok(info)
	var png := background.save_png_to_buffer()
	return {
		"content": [
			{"type": "image", "data": Marshalls.raw_to_base64(png), "mimeType": "image/png"},
			{"type": "text", "text": JSON.stringify(info)},
		],
	}


func _new_document() -> Dictionary:
	if State.active_edit() != null or State.edit_busy():
		return _tool_error("The editor is busy with another edit. Retry.")
	var index := State.open_tab(State.new_document())
	if State.active_tab != index:
		return _tool_error("The document opened but could not become current.")
	return _tool_ok({"tab": index, "frames": 1})


func _save_document(args: Dictionary) -> Dictionary:
	if State.active_edit() != null or State.edit_busy():
		return _tool_error("The editor is busy with another edit. Retry.")
	var path := _document_path(args.get("path", ""))
	if path.is_empty():
		return _tool_error("path is required.")
	var extension := path.get_extension().to_lower()
	if extension.is_empty():
		path += ".lve"
		extension = "lve"
	elif extension != "lve" and extension != "png":
		return _tool_error("path must end in .lve or .lve.png.")
	var document := State.document
	var encoded := document.encode_document()
	if encoded.is_empty():
		return _tool_error("The document exceeds the format limits or contains invalid data.")
	var preview: Image = null
	if extension == "png":
		if DisplayServer.get_name() == "headless":
			return _tool_error("The PNG preview needs a visible editor window.")
		var operation := State.begin_operation("Rendering preview", -1, true, self)
		preview = await VoxelImageRenderer.render_document_preview(document)
		State.finish_operation(operation)
		if State.document != document:
			return _tool_error("The document changed before the save finished.")
		if preview == null:
			return _tool_error("The preview could not be rendered.")
	var error := document.save_file(path, preview, encoded)
	if error != OK:
		return _tool_error("The document could not be saved: " + error_string(error))
	State.record_saved(document, path)
	return _tool_ok({"path": ProjectSettings.globalize_path(path)})


func _open_document(args: Dictionary) -> Dictionary:
	if State.active_edit() != null or State.edit_busy():
		return _tool_error("The editor is busy with another edit. Retry.")
	var path := _document_path(args.get("path", ""))
	if path.is_empty():
		return _tool_error("path is required.")
	var document := VoxelDocument.load_file(path)
	if document == null:
		return _tool_error("The document could not be opened.")
	var index := State.open_tab(document)
	if State.active_tab != index:
		return _tool_error("The document opened but could not become current.")
	State.record_opened(document, path)
	return _tool_ok({
		"tab": index,
		"frames": document.frames.size(),
		"path": ProjectSettings.globalize_path(path),
	})


func _document_path(value: Variant) -> String:
	if not (value is String):
		return ""
	var path: String = String(value).strip_edges()
	if path.is_empty():
		return ""
	if path.begins_with("user://") or path.begins_with("res://") or path.is_absolute_path():
		return path
	return "user://" + path


func _add_frame() -> Dictionary:
	State.add_frame()
	return _tool_ok({"frame": State.current_frame, "frames": State.document.frames.size()})


func _duplicate_frame() -> Dictionary:
	State.duplicate_frame()
	return _tool_ok({"frame": State.current_frame, "frames": State.document.frames.size()})


func _set_frame(args: Dictionary) -> Dictionary:
	var index := _int_arg(args, "frame", State.current_frame)
	if index < 0 or index >= State.document.frames.size():
		return _tool_error("The frame does not exist.")
	State.current_frame = index
	return _tool_ok({"frame": index, "delay_ms": State.document.frames[index].delay_ms})


func _set_frame_delay(args: Dictionary) -> Dictionary:
	var index := _int_arg(args, "frame", State.current_frame)
	if index < 0 or index >= State.document.frames.size():
		return _tool_error("The frame does not exist.")
	var ms := _int_arg(args, "ms", State.document.frames[index].delay_ms)
	if ms < 1 or ms > 10000:
		return _tool_error("ms must be between 1 and 10000.")
	State.set_frame_delay(index, ms)
	return _tool_ok({"frame": index, "delay_ms": ms})


func _set_tag_loop(args: Dictionary) -> Dictionary:
	var mode_value: Variant = args.get("mode", "forward")
	var mode := AnimationTag.LoopMode.FORWARD
	match str(mode_value):
		"forward":
			mode = AnimationTag.LoopMode.FORWARD
		"reverse":
			mode = AnimationTag.LoopMode.REVERSE
		"ping_pong":
			mode = AnimationTag.LoopMode.PING_PONG
		"ping_pong_reverse":
			mode = AnimationTag.LoopMode.PING_PONG_REVERSE
		_:
			return _tool_error("mode must be forward, reverse, ping_pong, or ping_pong_reverse.")
	var index := State.active_tag
	if index < 0 and not State.document.tags.is_empty():
		index = 0
	if index < 0:
		return _tool_error("The document has no tag.")
	State.set_tag_loop_mode(index, mode)
	var repeats_value: Variant = args.get("repeats", null)
	if repeats_value is int or repeats_value is float:
		State.set_tag_repeats(index, clampi(int(repeats_value), 0, 1000))
	var tag := State.get_tag(index)
	return _tool_ok({"tag": index, "mode": tag.loop_mode, "repeats": tag.repeats})


func _set_playback(args: Dictionary) -> Dictionary:
	var playing_value: Variant = args.get("playing", false)
	var playing: bool = playing_value if playing_value is bool else false
	State.is_playing = playing
	return _tool_ok({"playing": State.is_playing, "frame": State.current_frame})


func _int_arg(args: Dictionary, key: String, fallback: int) -> int:
	var value: Variant = args.get(key, null)
	if value is int or value is float:
		return int(value)
	return fallback


func _set_tool(args: Dictionary) -> Dictionary:
	if State.active_edit() != null:
		return _tool_error("The editor has an open edit. Finish it before switching tools.")
	var tool_value: Variant = args.get("tool", "")
	if not (tool_value is String):
		return _tool_error("tool must be a string.")
	var tool_id: String = tool_value
	if not ["brush", "eraser", "paint", "fill"].has(tool_id):
		return _tool_error("tool must be brush, eraser, paint, or fill.")
	var diameter := -1
	var diameter_value: Variant = args.get("diameter", null)
	if diameter_value is int or diameter_value is float:
		diameter = clampi(int(diameter_value), 1, 64)
	var shape := -1
	var shape_value: Variant = args.get("shape", null)
	if shape_value is String:
		match str(shape_value):
			"cube":
				shape = StampToolSettings.BrushShape.CUBE
			"sphere":
				shape = StampToolSettings.BrushShape.SPHERE
			_:
				return _tool_error("shape must be cube or sphere.")
	var pixel_perfect: Variant = args.get("pixel_perfect", null)
	var connected: Variant = args.get("connected", null)
	if tool_id == "brush" or tool_id == "eraser":
		var plugin: Node = _plugin("BrushPlugin")
		if plugin == null:
			return _tool_error("The brush plugin is not ready.")
		var settings: BrushToolSettings = plugin.get("_settings")
		if settings == null:
			return _tool_error("The brush settings are not ready.")
		settings.mode = BrushToolSettings.BrushMode.ERASER if tool_id == "eraser" else BrushToolSettings.BrushMode.PENCIL
		if diameter > 0:
			settings.diameter = diameter
		if shape >= 0:
			settings.shape = shape
		if pixel_perfect is bool:
			settings.pixel_perfect = pixel_perfect
		_activate_plugin("BrushPlugin")
	else:
		var plugin: Node = _plugin("PaintPlugin")
		if plugin == null:
			return _tool_error("The paint plugin is not ready.")
		var settings: PaintToolSettings = plugin.get("_settings")
		if settings == null:
			return _tool_error("The paint settings are not ready.")
		settings.tool = PaintToolSettings.Tools.FILL if tool_id == "fill" else PaintToolSettings.Tools.PAINTBRUSH
		if diameter > 0:
			settings.diameter = diameter
		if shape >= 0:
			settings.shape = shape
		if pixel_perfect is bool:
			settings.pixel_perfect = pixel_perfect
		if connected is bool:
			settings.connected = connected
		_activate_plugin("PaintPlugin")
	var info := _active_tool_info()
	return _tool_ok({"tool": info.get("id", ""), "params": info.get("params", {})})


func _set_material(args: Dictionary) -> Dictionary:
	if State.active_edit() != null:
		return _tool_error("The editor has an open edit. Finish it before changing the material.")
	var material_value: Variant = _parse_material(args)
	if not (material_value is PackedFloat32Array):
		return _tool_error("Provide a valid color, palette_index, metallic, or roughness.")
	var material: PackedFloat32Array = material_value
	if not VoxelDocument.valid_material(material):
		return _tool_error("The material values must be between 0 and 1.")
	State.set_material(material)
	return _tool_ok({"material": _material_json(material)})


func _set_cursor(args: Dictionary) -> Dictionary:
	if State.active_edit() != null:
		return _tool_error("The editor has an open edit. Finish it before moving the cursor.")
	var info := _active_tool_info()
	var node_value: Variant = info.get("node")
	if not (node_value is VoxelTool):
		return _tool_error("Select a tool first.")
	var tool: VoxelTool = node_value
	var cell_value: Variant = args.get("cell", null)
	if cell_value == null:
		tool.visible = false
		return _tool_ok({"hidden": true})
	var cell: Variant = _parse_cell(cell_value)
	if cell == null:
		return _tool_error("cell must be [x, y, z] or null.")
	var cell_position: Vector3i = cell
	var tool_id := str(info.get("id", ""))
	tool.driver_show_cursor(cell_position, cell_position if tool_id == "paint" else VoxelPicking.NONE)
	return _tool_ok({"cell": _json_cell(cell_position)})


func _stroke(args: Dictionary) -> Dictionary:
	if State.active_edit() != null or State.edit_busy():
		return _tool_error("The editor is busy with another edit. Retry.")
	var points_value: Variant = _parse_cells(args.get("points", null), 4096)
	if not (points_value is Array):
		return _tool_error("points must be an array of [x, y, z] cells.")
	var points: Array = points_value
	if points.is_empty():
		return _tool_error("points must hold at least one cell.")
	var info := _active_tool_info()
	var tool_id := str(info.get("id", ""))
	var node_value: Variant = info.get("node")
	if not (node_value is VoxelTool):
		return _tool_error("Select a tool first.")
	var tool: VoxelTool = node_value
	if tool_id != "brush" and tool_id != "paint" and tool_id != "eraser":
		return _tool_error("Select brush, paint, or eraser first.")
	var first: Vector3i = points[0]
	var hit := first if tool_id == "paint" else VoxelPicking.NONE
	if not tool.driver_begin_stroke(first, hit):
		return _tool_error("The tool could not start a stroke. The editor is busy.")
	for index in range(1, points.size()):
		var point: Vector3i = points[index]
		tool.driver_stroke_to(point)
	tool.driver_end_stroke()
	var completed := await _wait_tool_idle(tool, 30000)
	if not completed:
		return _tool_error("The stroke did not complete within 30 seconds.")
	return _tool_ok({"tool": tool_id, "points": points.size()})


func _fill(args: Dictionary) -> Dictionary:
	if State.active_edit() != null or State.edit_busy():
		return _tool_error("The editor is busy with another edit. Retry.")
	var seed_value: Variant = _parse_cell(args.get("seed", null))
	if seed_value == null:
		return _tool_error("seed must be [x, y, z].")
	var seed: Vector3i = seed_value
	var info := _active_tool_info()
	var tool_id := str(info.get("id", ""))
	var node_value: Variant = info.get("node")
	if tool_id != "fill" or not (node_value is VoxelTool):
		return _tool_error("Select the fill tool first.")
	var tool: VoxelTool = node_value
	var error_value: Variant = tool.call("driver_fill", seed)
	if not (error_value is int):
		return _tool_error("The fill tool is not available.")
	var error: Error = error_value
	if error == ERR_BUSY:
		return _tool_error("The fill tool is busy.")
	if error != OK:
		return _tool_error("The seed cell is empty or invalid.")
	var completed := await _wait_tool_idle(tool, 60000)
	if not completed:
		return _tool_error("The fill did not complete within 60 seconds.")
	return _tool_ok({"seed": _json_cell(seed)})


func _write_cells(args: Dictionary) -> Dictionary:
	if State.active_edit() != null or State.edit_busy():
		return _tool_error("The editor is busy with another edit. Retry.")
	var cells_value: Variant = _parse_cells(args.get("cells", null), MAX_WRITE_CELLS)
	if args.has("cells") and not (cells_value is Array):
		return _tool_error("cells must be an array of [x, y, z] cells.")
	var cells: Array = []
	if cells_value is Array:
		cells = cells_value
	var boxes: Array = []
	var boxes_value: Variant = args.get("boxes", null)
	if boxes_value != null:
		if not (boxes_value is Array):
			return _tool_error("boxes must be an array of [x0, y0, z0, x1, y1, z1].")
		var box_list: Array = boxes_value
		for index in range(box_list.size()):
			var box_value: Variant = _parse_box(box_list[index])
			if box_value == null:
				return _tool_error("boxes[%d] must be [x0, y0, z0, x1, y1, z1] with min <= max." % index)
			boxes.append(box_value)
	var runs: Array = []
	var runs_value: Variant = args.get("runs", null)
	if runs_value != null:
		if not (runs_value is Array):
			return _tool_error("runs must be an array of [x0, x1, y, z].")
		var run_list: Array = runs_value
		for index in range(run_list.size()):
			var run_value: Variant = _parse_run(run_list[index])
			if run_value == null:
				return _tool_error("runs[%d] must be [x0, x1, y, z] with x0 <= x1." % index)
			runs.append(run_value)
	if cells.is_empty() and boxes.is_empty() and runs.is_empty():
		return _tool_error("Provide cells, boxes, or runs.")
	var erase := false
	var erase_value: Variant = args.get("erase", false)
	if erase_value is bool:
		erase = erase_value
	var material := VoxelFrame.material(Color.TRANSPARENT) if erase else State.current_material
	var changes := {}
	for value in cells:
		var cell: Vector3i = value
		changes[cell] = material
	for value in boxes:
		var box: Array = value
		var start: Vector3i = box[0]
		var end: Vector3i = box[1]
		var extent := end - start + Vector3i.ONE
		# Check each axis before the product, so a wide box cannot overflow the
		# cell cap and enter the write loops.
		if extent.x > MAX_WRITE_CELLS or extent.y > MAX_WRITE_CELLS or extent.z > MAX_WRITE_CELLS:
			return _tool_error("The write exceeds %d cells." % MAX_WRITE_CELLS)
		var volume := extent.x * extent.y * extent.z
		if changes.size() + volume > MAX_WRITE_CELLS:
			return _tool_error("The write exceeds %d cells." % MAX_WRITE_CELLS)
		for x in range(start.x, end.x + 1):
			for y in range(start.y, end.y + 1):
				for z in range(start.z, end.z + 1):
					changes[Vector3i(x, y, z)] = material
	for value in runs:
		var run: Array = value
		var first: int = run[0]
		var last: int = run[1]
		var y: int = run[2]
		var z: int = run[3]
		var length := last - first + 1
		if length > MAX_WRITE_CELLS:
			return _tool_error("The write exceeds %d cells." % MAX_WRITE_CELLS)
		if changes.size() + length > MAX_WRITE_CELLS:
			return _tool_error("The write exceeds %d cells." % MAX_WRITE_CELLS)
		for x in range(first, last + 1):
			changes[Vector3i(x, y, z)] = material
	var tx := State.begin_edit()
	if tx == null:
		return _tool_error("The editor is busy with another edit. Retry.")
	var frame := State.get_current_voxel_frame()
	if frame == null:
		State.cancel_edit(tx)
		return _tool_error("The document has no current frame.")
	var job := WriteJob.new()
	job.edit_context = tx.edit_context
	job.edited_frame = VoxelFrame.job_frame(frame)
	job.changes = changes
	job.applied_uniform = material
	if changes.size() <= 4096:
		job.run()
	else:
		var operation := State.begin_operation("Writing cells", changes.size(), true, self, job.cancel)
		await State.run_edit_job(job, operation, "MCP write")
		State.finish_operation(operation)
	if State.active_edit() != tx:
		return _tool_error("The edit was cancelled or the document changed.")
	frame.apply_published(job.changed_chunks, job.edited_frame)
	State.document._bounds_dirty = true
	if not job.changed_chunks.is_empty():
		State.chunks_changed.emit(State.current_frame, job.changed_chunks)
	State.finish_edit(tx, "Write Cells")
	return _tool_ok({
		"applied": job.applied_cells.size(),
		"chunks": job.changed_chunks.size(),
	})


func _sample(args: Dictionary) -> Dictionary:
	if State.active_edit() != null:
		return _tool_error("The editor has an open edit. Finish it before sampling a material.")
	var cell_value: Variant = _parse_cell(args.get("cell", null))
	if cell_value == null:
		return _tool_error("cell must be [x, y, z].")
	var cell: Vector3i = cell_value
	if not State.has_cell(cell):
		return _tool_error("The cell is empty.")
	var frame := State.get_current_voxel_frame()
	if frame == null:
		return _tool_error("The document has no current frame.")
	var material := frame.get_material(cell)
	State.set_material(material)
	return _tool_ok({"material": _material_json(material)})


func _wait_tool_idle(tool: VoxelTool, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while is_instance_valid(tool) and tool.driver_is_busy():
		if Time.get_ticks_msec() >= deadline:
			return false
		await get_tree().process_frame
	return is_instance_valid(tool)


func _active_tool_info() -> Dictionary:
	var brush: Node = _plugin("BrushPlugin")
	if brush != null and _toolbar_pressed(brush):
		var settings: BrushToolSettings = brush.get("_settings")
		var tool_node: Node3D = brush.get("_tool")
		if settings != null and tool_node != null:
			var tool_id := "brush"
			if settings.mode == BrushToolSettings.BrushMode.ERASER:
				tool_id = "eraser"
			elif settings.mode == BrushToolSettings.BrushMode.LINE:
				tool_id = "line"
			return {
				"id": tool_id,
				"node": tool_node,
				"params": {
					"diameter": settings.diameter,
					"shape": "sphere" if settings.shape == StampToolSettings.BrushShape.SPHERE else "cube",
					"pixel_perfect": settings.pixel_perfect,
				},
			}
	var paint: Node = _plugin("PaintPlugin")
	if paint != null and _toolbar_pressed(paint):
		var settings: PaintToolSettings = paint.get("_settings")
		var tool_node: Node3D = paint.get("_tool")
		if settings != null and tool_node != null:
			var tool_id := "paint"
			if settings.tool == PaintToolSettings.Tools.FILL:
				tool_id = "fill"
			elif settings.tool == PaintToolSettings.Tools.SPRAY:
				tool_id = "spray"
			return {
				"id": tool_id,
				"node": tool_node,
				"params": {
					"diameter": settings.diameter,
					"shape": "sphere" if settings.shape == StampToolSettings.BrushShape.SPHERE else "cube",
					"pixel_perfect": settings.pixel_perfect,
					"connected": settings.connected,
					"spot_diameter": settings.spot_diameter,
					"spray_size": settings.spray_size,
					"speed": settings.speed,
				},
			}
	var terrain: Node = _plugin("TerrainPlugin")
	if terrain != null and _toolbar_pressed(terrain):
		return {"id": "terrain", "node": terrain.get("_tool"), "params": {}}
	var selection: Node = _plugin("SelectionPlugin")
	if selection != null and _toolbar_pressed(selection):
		return {"id": "select", "node": selection.get("_current_tool"), "params": {}}
	var transform: Node = _plugin("TransformPlugin")
	if transform != null and _toolbar_pressed(transform):
		return {"id": "transform", "node": transform.get("_current_tool"), "params": {}}
	var eyedropper: Node = _plugin("EyedropperPlugin")
	if eyedropper != null and _toolbar_pressed(eyedropper):
		return {"id": "eyedropper", "node": eyedropper.get("_tool"), "params": {}}
	return {"id": "", "node": null, "params": {}}


func _activate_plugin(name: String) -> void:
	for other in ["BrushPlugin", "PaintPlugin", "TerrainPlugin", "SelectionPlugin", "TransformPlugin", "EyedropperPlugin"]:
		if other == name:
			continue
		var plugin: Node = _plugin(other)
		if plugin != null and _toolbar_pressed(plugin):
			var toolbar: BaseButton = plugin.get("_toolbar")
			if toolbar != null:
				toolbar.button_pressed = false
	var target: Node = _plugin(name)
	if target == null:
		return
	var target_toolbar: BaseButton = target.get("_toolbar")
	if target_toolbar == null:
		return
	if target_toolbar.button_pressed:
		target.call("activate_tool")
		return
	target_toolbar.button_pressed = true
	if not target_toolbar.button_pressed:
		target.call("activate_tool")


func _plugin(plugin_name: String) -> Node:
	return get_node_or_null("/root/" + plugin_name)


func _toolbar_pressed(plugin: Node) -> bool:
	var toolbar: BaseButton = plugin.get("_toolbar")
	return toolbar != null and toolbar.button_pressed


func _parse_material(args: Dictionary) -> Variant:
	var material: PackedFloat32Array = State.current_material
	var color_changed := false
	var palette_value: Variant = args.get("palette_index", null)
	if palette_value != null:
		if not (palette_value is int or palette_value is float):
			return null
		var index := int(palette_value)
		var palette := State.get_palette()
		if index < 0 or index >= palette.size():
			return null
		material = palette[index]
	var color_value: Variant = args.get("color", null)
	if color_value != null:
		var color_value_parsed: Variant = _parse_color(color_value)
		if not (color_value_parsed is Color):
			return null
		var color: Color = color_value_parsed
		material[0] = color.r
		material[1] = color.g
		material[2] = color.b
		material[3] = color.a
		color_changed = true
	var metallic_value: Variant = args.get("metallic", null)
	if metallic_value != null:
		if not (metallic_value is int or metallic_value is float):
			return null
		material[VoxelFrame.MATERIAL_METALLIC] = clampf(float(metallic_value), 0.0, 1.0)
	var roughness_value: Variant = args.get("roughness", null)
	if roughness_value != null:
		if not (roughness_value is int or roughness_value is float):
			return null
		material[VoxelFrame.MATERIAL_ROUGHNESS] = clampf(float(roughness_value), 0.0, 1.0)
	var emission_value: Variant = args.get("emission", null)
	if emission_value != null:
		var emission_parsed: Variant = _parse_color(emission_value)
		if not (emission_parsed is Color):
			return null
		var emission: Color = emission_parsed
		material[VoxelFrame.MATERIAL_EMISSION] = emission.r
		material[VoxelFrame.MATERIAL_EMISSION + 1] = emission.g
		material[VoxelFrame.MATERIAL_EMISSION + 2] = emission.b
	elif color_changed:
		# A new color is not glowing unless the caller asks for it.
		material[VoxelFrame.MATERIAL_EMISSION] = 0.0
		material[VoxelFrame.MATERIAL_EMISSION + 1] = 0.0
		material[VoxelFrame.MATERIAL_EMISSION + 2] = 0.0
	return material


func _parse_color(value: Variant) -> Variant:
	if value is String:
		var text: String = value
		if not Color.html_is_valid(text):
			return null
		return Color.html(text)
	if value is Array:
		var components: Array = value
		if components.size() < 3 or components.size() > 4:
			return null
		for component in components:
			if not (component is int or component is float):
				return null
		var alpha := 1.0
		if components.size() == 4:
			alpha = float(components[3])
		return Color(float(components[0]), float(components[1]), float(components[2]), alpha)
	return null


func _parse_cell(value: Variant) -> Variant:
	if not (value is Array):
		return null
	var components: Array = value
	if components.size() != 3:
		return null
	for component in components:
		if not (component is int or component is float):
			return null
	var x := int(components[0])
	var y := int(components[1])
	var z := int(components[2])
	if not _cell_in_range(x, y, z):
		return null
	return Vector3i(x, y, z)


## Returns [code]true[/code] when one cell coordinate is inside the storage limit.
func _cell_in_range(x: int, y: int, z: int) -> bool:
	var limit := VoxelFrame.MAX_CHUNK_COORDINATE * VoxelFrame.CHUNK_SIZE
	return (
		x >= -limit and x <= limit
		and y >= -limit and y <= limit
		and z >= -limit and z <= limit
	)


func _parse_cells(value: Variant, max_count: int) -> Variant:
	if not (value is Array):
		return null
	var source: Array = value
	if source.is_empty() or source.size() > max_count:
		return null
	var cells: Array[Vector3i] = []
	for item in source:
		var cell: Variant = _parse_cell(item)
		if cell == null:
			return null
		var cell_position: Vector3i = cell
		cells.append(cell_position)
	return cells


func _parse_box(value: Variant) -> Variant:
	if not (value is Array):
		return null
	var components: Array = value
	if components.size() != 6:
		return null
	for component in components:
		if not (component is int or component is float):
			return null
	var sx := int(components[0])
	var sy := int(components[1])
	var sz := int(components[2])
	var ex := int(components[3])
	var ey := int(components[4])
	var ez := int(components[5])
	if sx > ex or sy > ey or sz > ez:
		return null
	if not _cell_in_range(sx, sy, sz) or not _cell_in_range(ex, ey, ez):
		return null
	return [Vector3i(sx, sy, sz), Vector3i(ex, ey, ez)]


func _parse_run(value: Variant) -> Variant:
	if not (value is Array):
		return null
	var components: Array = value
	if components.size() != 4:
		return null
	for component in components:
		if not (component is int or component is float):
			return null
	var first := int(components[0])
	var last := int(components[1])
	if first > last:
		return null
	var y := int(components[2])
	var z := int(components[3])
	if not _cell_in_range(first, y, z) or not _cell_in_range(last, y, z):
		return null
	return [first, last, y, z]


func _axis_name(axis: int) -> String:
	match axis:
		Vector3.AXIS_X:
			return "x"
		Vector3.AXIS_Z:
			return "z"
	return "y"


func _material_json(material: PackedFloat32Array) -> Dictionary:
	var color := VoxelFrame.material_color(material)
	var emission := Color(
		material[VoxelFrame.MATERIAL_EMISSION],
		material[VoxelFrame.MATERIAL_EMISSION + 1],
		material[VoxelFrame.MATERIAL_EMISSION + 2]
	)
	var data := {
		"color": _hex_color(color),
		"metallic": snappedf(material[VoxelFrame.MATERIAL_METALLIC], 0.001),
		"roughness": snappedf(material[VoxelFrame.MATERIAL_ROUGHNESS], 0.001),
	}
	if emission != Color.BLACK:
		data["emission"] = _hex_color(emission)
	return data


func _hex_color(color: Color) -> String:
	if color.a < 0.999:
		return "#" + color.to_html(true)
	return "#" + color.to_html(false)


func _aabb_json(box: AABB) -> Dictionary:
	return {"position": _vector_json(box.position), "size": _vector_json(box.size)}


func _vector_json(value: Vector3) -> Array:
	return [_number_json(value.x), _number_json(value.y), _number_json(value.z)]


func _number_json(value: float) -> Variant:
	if is_equal_approx(value, roundf(value)):
		return int(roundf(value))
	return snappedf(value, 0.001)


func _json_cell(cell: Vector3i) -> Array:
	return [cell.x, cell.y, cell.z]


## Appends one diagnostic line to the server log.
func _log(message: String) -> void:
	var file := FileAccess.open(LOG_PATH, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.seek_end()
	file.store_line("%s %s" % [Time.get_datetime_string_from_system(), message])
