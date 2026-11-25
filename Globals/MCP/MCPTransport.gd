extends RefCounted


const DEFAULT_PORT := 17373
const LOOPBACK_ADDRESS := "127.0.0.1"
const ALL_INTERFACES := "*"
const TAILNET_FIRST_OCTET := 100
const TAILNET_SECOND_OCTET_MIN := 64
const TAILNET_SECOND_OCTET_MAX := 127
const MAX_LINE_BYTES := 4 * 1024 * 1024
const MAX_PEERS := 8
const PEER_IDLE_MS := 30000

var dispatch := Callable()
var log_line := Callable()

var _server := TCPServer.new()
var _http_mode := false


class PeerState extends RefCounted:
	var peer: StreamPeerTCP
	var buffer := PackedByteArray()
	var busy := false
	var sse := false
	var last_ping_ms := 0
	var last_read_ms := 0

var _peers: Array[PeerState] = []


func bind_address() -> String:
	if not OS.has_feature("mobile"):
		return LOOPBACK_ADDRESS
	for address in IP.get_local_addresses():
		if _is_tailnet_address(address):
			return address
	return ALL_INTERFACES


static func _is_tailnet_address(address: String) -> bool:
	var parts := address.split(".")
	if parts.size() != 4:
		return false
	for part in parts:
		if not part.is_valid_int():
			return false
	var second := int(parts[1])
	return int(parts[0]) == TAILNET_FIRST_OCTET and second >= TAILNET_SECOND_OCTET_MIN \
			and second <= TAILNET_SECOND_OCTET_MAX


func start(port: int = DEFAULT_PORT, http_mode := false) -> Error:
	stop()
	_http_mode = http_mode
	var address := bind_address()
	var error := _server.listen(port, address)
	if error != OK:
		push_warning("LVE MCP: cannot listen on %s:%d: %s" % [address, port, error_string(error)])
		return error
	print("LVE MCP: listening on %s:%d (%s)" % [address, _server.get_local_port(), "HTTP" if http_mode else "line"])
	log_line.call("start %d %s %s" % [_server.get_local_port(), "http" if http_mode else "line", address])
	return OK


func stop() -> void:
	for state in _peers:
		state.peer.disconnect_from_host()
	_peers.clear()
	if _server.is_listening():
		_server.stop()
	log_line.call("stop")


func local_port() -> int:
	return _server.get_local_port() if _server.is_listening() else 0


func poll() -> void:
	_accept_all()
	var now := Time.get_ticks_msec()
	for state in _peers.duplicate():
		var peer: StreamPeerTCP = state.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_remove_peer(state)
			continue
		if not state.sse and not state.busy and not state.buffer.is_empty() and now - state.last_read_ms > PEER_IDLE_MS:
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
		if _peers.size() >= MAX_PEERS:
			log_line.call("Refusing an MCP client: the peer limit is reached.")
			peer.disconnect_from_host()
			continue
		peer.set_no_delay(true)
		var state := PeerState.new()
		state.peer = peer
		state.last_read_ms = Time.get_ticks_msec()
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
	state.last_read_ms = Time.get_ticks_msec()
	state.buffer.append_array(bytes)
	if state.buffer.size() > MAX_LINE_BYTES:
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
	var response: Variant = await dispatch.call(request)
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
	var response: Variant = await dispatch.call(request)
	if response is Dictionary:
		_send_raw(state, response)
	state.busy = false


func _send_raw(state: PeerState, response: Dictionary) -> void:
	var line := JSON.stringify(response) + "\n"
	var error := state.peer.put_data(line.to_utf8_buffer())
	if error != OK:
		_remove_peer(state)


static func _error_response(id: Variant, code: int, message: String) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}
