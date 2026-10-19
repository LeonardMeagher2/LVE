extends SceneTree

const TEST_TIMEOUT_S := 30.0
const POLL_INTERVAL_S := 0.1
const MAX_FAILURES := 3
const TEST_SCREEN := 1
# `draw_latency` runs visible maximum-diameter strokes on the second monitor, so
# it needs its own deadline. Every other scene keeps the default.
const DRAW_LATENCY_PATH := "res://tests/draw_latency.tscn"
const DRAW_LATENCY_TIMEOUT_S := 125.0

var _failed := 0
var _pending := {}
var _saw_ok := false


func _initialize() -> void:
	await _run_all()
	print("")
	print("TEST SUITE: %s" % ("OK" if _failed == 0 else "FAILED (%d test(s))" % _failed))
	quit(1 if _failed > 0 else 0)


func _run_all() -> void:
	var paths := _test_paths()
	for path in paths:
		if _failed >= MAX_FAILURES:
			print("STOPPED after %d failures" % _failed)
			break
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
	var only := _requested()
	for f in dir.get_files():
		if not f.ends_with(".tscn"):
			continue
		if not only.is_empty() and not only.has(f.get_basename()):
			continue
		out.append("%s/%s" % [base, f])
	out.sort()
	return out


# The test scenes named after `--`, or every scene when none are named. Name a
# batch to run only those scenes, still in this one process:
#
#   godot --headless --path . -s res://tests/run_all.gd -- paint line brush_modes
func _requested() -> Dictionary:
	var names := {}
	for argument in OS.get_cmdline_user_args():
		names[argument] = true
	return names


# The deadline for one scene. A named scene can need longer than the default.
func _timeout_for(path: String) -> float:
	return DRAW_LATENCY_TIMEOUT_S if path == DRAW_LATENCY_PATH else TEST_TIMEOUT_S


func _run_one(path: String) -> Dictionary:
	_saw_ok = false
	_wipe_dir(_artifact_dir(path))
	# Select the deadline once, so the wait and the note agree.
	var timeout_s: float = _timeout_for(path)
	# Godot numbers screens from zero. Open test windows on the second screen.
	var args := PackedStringArray(["--screen", str(TEST_SCREEN), "--path", ProjectSettings.globalize_path("res://"), path])
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
		if (Time.get_ticks_msec() - started) / 1000.0 >= timeout_s:
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
		return {"code": 1, "note": "timed out after %.0f s" % timeout_s}
	var code := OS.get_process_exit_code(pid)
	if code == 0 and not _saw_ok:
		return {"code": 1, "note": "exit 0 but no pass marker"}
	return {"code": code, "note": ""}


func _artifact_dir(path: String) -> String:
	var name := path.get_file().get_basename()
	return "%s/artifacts/%s" % [get_script().resource_path.get_base_dir(), name]


func _wipe_dir(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)
	for d in dir.get_directories():
		_wipe_dir(path + "/" + d)
	DirAccess.remove_absolute(path)


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
	if line.strip_edges() == "TEST OK":
		_saw_ok = true
	print(line)


func _is_engine_banner(line: String) -> bool:
	return line.begins_with("Godot Engine") or line.begins_with("Vulkan ")
