extends SceneTree

const TEST_TIMEOUT_S := 30.0
const POLL_INTERVAL_S := 0.1

var _failed := 0
var _pending := {}


func _initialize() -> void:
	await _run_all()
	print("")
	print("TEST SUITE: %s" % ("OK" if _failed == 0 else "FAILED (%d test(s))" % _failed))
	quit(1 if _failed > 0 else 0)


func _run_all() -> void:
	var paths := _test_paths()
	for path in paths:
		var result := await _run_one(path)
		if result["code"] == 0:
			print("PASS %s" % path)
		else:
			_failed += 1
			var note: String = result["note"]
			if note == "":
				note = "exit %d" % result["code"]
			print("FAIL %s (%s)" % [path, note])


func _test_paths() -> Array[String]:
	var out: Array[String] = []
	var base: String = get_script().resource_path.get_base_dir()
	var dir := DirAccess.open(base)
	if dir == null:
		return out
	for f in dir.get_files():
		if f.ends_with(".tscn"):
			out.append("%s/%s" % [base, f])
	out.sort()
	return out


func _run_one(path: String) -> Dictionary:
	var args := PackedStringArray(["--path", ProjectSettings.globalize_path("res://"), path])
	var proc := OS.execute_with_pipe(OS.get_executable_path(), args, false)
	if proc.is_empty():
		return {"code": 1, "note": "could not start"}
	var pid: int = proc["pid"]
	var out: FileAccess = proc["stdio"]
	var err_out: FileAccess = proc["stderr"]
	var started := Time.get_ticks_msec()
	var timed_out := false
	while OS.is_process_running(pid):
		_pump(out)
		_pump(err_out)
		if (Time.get_ticks_msec() - started) / 1000.0 >= TEST_TIMEOUT_S:
			timed_out = true
			OS.kill(pid)
			await _await_exit(pid)
			break
		await create_timer(POLL_INTERVAL_S).timeout
	_pump(out)
	_pump(err_out)
	_flush(out)
	_flush(err_out)
	if timed_out:
		return {"code": 1, "note": "timed out after %.0f s" % TEST_TIMEOUT_S}
	return {"code": OS.get_process_exit_code(pid), "note": ""}


func _await_exit(pid: int) -> void:
	var started := Time.get_ticks_msec()
	while OS.is_process_running(pid) and Time.get_ticks_msec() - started < 2000:
		await create_timer(0.05).timeout


func _pump(f: FileAccess) -> void:
	if f == null:
		return
	var b: PackedByteArray = _pending.get(f, PackedByteArray())
	while true:
		var chunk := f.get_buffer(4096)
		if chunk.size() == 0:
			break
		b.append_array(chunk)
	while true:
		var nl := b.find(10)
		if nl == -1:
			break
		_print_line(b.slice(0, nl))
		b = b.slice(nl + 1)
	_pending[f] = b


func _flush(f: FileAccess) -> void:
	if f == null:
		return
	var b: PackedByteArray = _pending.get(f, PackedByteArray())
	if b.size() > 0:
		_pending[f] = PackedByteArray()
		_print_line(b)


func _print_line(raw: PackedByteArray) -> void:
	var line := raw.get_string_from_utf8().trim_suffix("\r")
	if line.strip_edges() == "" or _is_engine_banner(line):
		return
	print(line)


func _is_engine_banner(line: String) -> bool:
	return line.begins_with("Godot Engine") or line.begins_with("Vulkan ")
