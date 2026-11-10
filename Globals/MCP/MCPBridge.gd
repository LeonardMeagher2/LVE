extends RefCounted

## The stdio-to-TCP bridge for MCP.
##
## The same LVE binary runs this mode with
## [code]--headless --no-header -- --mcp-bridge[/code]. It reads
## newline-delimited JSON-RPC from stdin and forwards each message to the
## running editor. Responses go to stdout with [method @GlobalScope.printraw].
## Diagnostics go to stderr, so stdout holds MCP messages alone.

const MAX_LINE_BYTES := 4 * 1024 * 1024
const CONNECT_TIMEOUT_MS := 10000
const RESPONSE_TIMEOUT_MS := 120000
## The idle wait before a closed pipe is treated as EOF.
const IDLE_EXIT_MS := 600000
## The bridge log in the shared user directory.
const LOG_PATH := "user://mcp_bridge.log"

var _peer := StreamPeerTCP.new()
var _buffer := PackedByteArray()
var _stdin_buffer := PackedByteArray()


## Connects to the running editor and proxies stdio until stdin closes.
## Returns a process exit code.
func run(port: int) -> int:
	_log("start stdin=%d" % OS.get_stdin_type())
	var error := _peer.connect_to_host("127.0.0.1", port)
	if error != OK:
		_log("connect error %s" % error_string(error))
		printerr("LVE MCP bridge: cannot connect to 127.0.0.1:%d: %s" % [port, error_string(error)])
		return 1
	var deadline := Time.get_ticks_msec() + CONNECT_TIMEOUT_MS
	while _peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() < deadline:
		_peer.poll()
		OS.delay_msec(10)
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_log("not listening on %d" % port)
		printerr("LVE MCP bridge: the editor is not listening on 127.0.0.1:%d." % port)
		return 1
	_log("connected")
	_peer.set_no_delay(true)
	while true:
		var line := _read_stdin_line()
		if line.is_empty():
			break
		var request: Variant = JSON.parse_string(line)
		if not (request is Dictionary) or not ((request as Dictionary).get("method", null) is String):
			# A stdio client can run the server in a terminal that echoes the
			# server's own output back to stdin. A response has no method, so it
			# is not a request for the editor.
			continue
		var expects_response := (request as Dictionary).has("id")
		var send_error := _peer.put_data((line + "\n").to_utf8_buffer())
		if send_error != OK:
			printerr("LVE MCP bridge: the editor connection closed.")
			break
		if not expects_response:
			continue
		var response := _read_line(RESPONSE_TIMEOUT_MS)
		if response.is_empty():
			printerr("LVE MCP bridge: no response from the editor.")
			break
		printraw(response + "\n")
	_peer.disconnect_from_host()
	_log("exit")
	return 0


## Appends one diagnostic line to the bridge log.
func _log(message: String) -> void:
	var file := FileAccess.open(LOG_PATH, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.seek_end()
	file.store_line("%s %s" % [Time.get_datetime_string_from_system(), message])


## Reads one newline-delimited line from stdin. A pipe can deliver several
## lines at once, so the remainder stays buffered. A pipe also returns no bytes
## while the writer stays open, so an empty read is not EOF for a pipe.
func _read_stdin_line() -> String:
	var idle_since := Time.get_ticks_msec()
	while true:
		var index := _stdin_buffer.find(10)
		if index >= 0:
			var line := _stdin_buffer.slice(0, index).get_string_from_utf8().strip_edges()
			_stdin_buffer = _stdin_buffer.slice(index + 1)
			if line.is_empty():
				# A client can send an extra newline after a message. It is not
				# EOF, so read the next line.
				continue
			return line
		var chunk := OS.read_buffer_from_stdin(4096)
		if chunk.is_empty():
			if OS.get_stdin_type() == OS.STD_HANDLE_FILE:
				if _stdin_buffer.is_empty():
					return ""
				var last := _stdin_buffer.get_string_from_utf8().strip_edges()
				_stdin_buffer = PackedByteArray()
				return last
			if Time.get_ticks_msec() - idle_since >= IDLE_EXIT_MS:
				return ""
			OS.delay_msec(10)
			continue
		idle_since = Time.get_ticks_msec()
		_stdin_buffer.append_array(chunk)
		if _stdin_buffer.size() > MAX_LINE_BYTES:
			_stdin_buffer = PackedByteArray()
			printerr("LVE MCP bridge: request line is too large.")
			return ""
	return ""


func _read_line(timeout_ms: int) -> String:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var index := _buffer.find(10)
		if index >= 0:
			var line := _buffer.slice(0, index).get_string_from_utf8().strip_edges()
			_buffer = _buffer.slice(index + 1)
			return line
		var available := _peer.get_available_bytes()
		if available > 0:
			var result := _peer.get_partial_data(available)
			if result[0] == OK:
				_buffer.append_array(result[1])
		_peer.poll()
		if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return ""
		OS.delay_msec(1)
	return ""
