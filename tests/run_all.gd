extends SceneTree

const TEST_TIMEOUT_S := 30.0
# Drain verbose child output promptly so a full pipe does not stall its tests.
const POLL_INTERVAL_S := 0.01
const MAX_FAILURES := 3
const TEST_SCREEN := 0
# `draw_latency` runs visible maximum-diameter strokes on the second monitor, so
# it needs its own deadline. Every other scene keeps the default.
const DRAW_LATENCY_PATH := "res://tests/draw_latency.tscn"
const DRAW_LATENCY_TIMEOUT_S := 125.0
# A child prints the sum of its selected test timeouts as `TEST BUDGET: N`.
# The runner allows that budget plus a small margin, capped for a hung child.
const BUDGET_PREFIX := "TEST BUDGET:"
const DECLARED_BUDGET_MARGIN_S := 10.0
const MAX_SCENE_TIMEOUT_S := 1800.0
# A grouped scene runs several named tests in one process. The runner reads each
# scene's case names from the `test()` calls in its script, so a named run needs
# no hand-kept table. The pattern matches a literal description, a plain method
# as the callable, and an optional literal name.
const CASE_CALL := "^[ \t]*test\\(\\s*\"[^\"]*\"\\s*,\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*(?:,\\s*\"([^\"]*)\")?\\s*\\)"

var _failed := 0
var _pending := {}
var _saw_ok := false
var _saw_error := false
var _timings: Array = []
var _declared_budget_s := 0.0


func _init() -> void:
	# The coordinator has no Main scene. Only its child scenes need the editor
	# autoloads. These in-memory settings do not change the child project.
	ProjectSettings.set_setting("autoload/State", null)
	ProjectSettings.set_setting("autoload/VoxelImageRenderer", null)


func _initialize() -> void:
	await _run_all()
	print("")
	print("TEST SUITE: %s" % ("OK" if _failed == 0 else "FAILED (%d test(s))" % _failed))
	quit(1 if _failed > 0 else 0)


func _run_all() -> void:
	var entries := _test_entries()
	if entries.is_empty():
		print("NO TESTS SELECTED")
		_failed = 1
		return
	var started := Time.get_ticks_msec()
	for entry in entries:
		if _failed >= MAX_FAILURES:
			print("STOPPED after %d failures" % _failed)
			break
		var path: String = entry["path"]
		var result := await _run_one(entry)
		var seconds := float(result["seconds"])
		_timings.append({"path": path, "seconds": seconds})
		if result["code"] == 0:
			print("PASS %s (%.1f s)" % [path, seconds])
		else:
			_failed += 1
			var note: String = result["note"]
			if note == "":
				note = "exit %d" % result["code"]
			print("FAIL %s (%s) (%.1f s)" % [path, note, seconds])
	_print_timing(Time.get_ticks_msec() - started)


# Report the wall clock and the slowest scenes. A slow scene is visible in every
# run, so a regression shows in the output, not only in the total.
func _print_timing(total_ms: int) -> void:
	if _timings.is_empty():
		return
	print("")
	print("SUITE TIME: %.1f min over %d scene(s)" % [total_ms / 60000.0, _timings.size()])
	var slowest := _timings.duplicate()
	slowest.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["seconds"]) > float(b["seconds"])
	)
	var parts := PackedStringArray()
	for i in mini(5, slowest.size()):
		parts.append("%s %.1f s" % [str(slowest[i]["path"]).get_file().get_basename(), float(slowest[i]["seconds"])])
	print("SLOWEST: %s" % ", ".join(parts))


# One entry per scene to run. An entry holds the scene path and the case names
# to pass to a grouped scene. A named run resolves the name against the scenes
# and their cases. An unknown name stops the run instead of running nothing.
func _test_entries() -> Array:
	var base: String = get_script().resource_path.get_base_dir()
	var dir := DirAccess.open(base)
	if dir == null:
		return []
	var scenes := {}
	for f in dir.get_files():
		if f.ends_with(".tscn"):
			var scene_name := f.get_basename()
			scenes[scene_name] = _scene_cases("%s/%s.gd" % [base, scene_name])
	var only := _requested()
	if only.is_empty():
		var names := scenes.keys()
		names.sort()
		var all: Array = []
		for name in names:
			all.append({"path": "%s/%s.tscn" % [base, name], "cases": []})
		return all
	var requested_names := only.keys()
	var result := build_entries(requested_names, scenes)
	var unknown: Array = result["unknown"]
	if not unknown.is_empty():
		var unknown_names := PackedStringArray()
		for name in unknown:
			unknown_names.append(str(name))
		print("UNKNOWN SELECTION: %s" % ", ".join(unknown_names))
		return []
	var out: Array = []
	var entries: Array = result["entries"]
	for entry in entries:
		out.append({"path": "%s/%s.tscn" % [base, str(entry["path"])], "cases": entry["cases"]})
	return out


# The case names a scene registers. Read them from the `test()` calls instead of
# booting the scene, so selection stays cheap and needs no alias table. A name
# that is computed at run time cannot be read here and stays reachable by its
# scene name.
static func _scene_cases(script_path: String) -> Array:
	var names: Array = []
	if not FileAccess.file_exists(script_path):
		return names
	var re := RegEx.new()
	if re.compile(CASE_CALL) != OK:
		return names
	for line in FileAccess.get_file_as_string(script_path).split("\n"):
		var found := re.search(line)
		if found == null:
			continue
		var explicit := found.get_string(2)
		# `Test.test` falls back to the method name without its leading underscore.
		var case_name := explicit if not explicit.is_empty() else found.get_string(1).trim_prefix("_")
		if not names.has(case_name):
			names.append(case_name)
	return names


# Map requested names to the scenes and case names to run. A scene name selects
# every case of that scene, so it dominates that scene's case names in any
# order. A case name selects the scenes that register it. Unknown names are
# reported instead of silently running nothing.
static func build_entries(requested_names: Array, scenes: Dictionary) -> Dictionary:
	var order: Array[String] = []
	var by_scene := {}
	var whole := {}
	var unknown: Array[String] = []
	var sorted_names := requested_names.duplicate()
	sorted_names.sort()
	for name in sorted_names:
		var token := str(name)
		if scenes.has(token):
			if not by_scene.has(token):
				order.append(token)
			by_scene[token] = []
			whole[token] = true
			continue
		var holders: Array[String] = []
		for scene_name in scenes:
			var names: Array = scenes[scene_name]
			if names.has(token):
				holders.append(str(scene_name))
		if holders.is_empty():
			unknown.append(token)
			continue
		holders.sort()
		for scene_name in holders:
			if not by_scene.has(scene_name):
				order.append(scene_name)
				by_scene[scene_name] = []
			if whole.has(scene_name):
				continue
			var cases: Array = by_scene[scene_name]
			if not cases.has(token):
				cases.append(token)
	# An unknown name stops the run, so the helper builds no plan then.
	if not unknown.is_empty():
		return {"entries": [], "unknown": unknown}
	var entries: Array = []
	for scene_name in order:
		var cases: Array = by_scene[scene_name]
		cases.sort()
		entries.append({"path": scene_name, "cases": cases})
	return {"entries": entries, "unknown": unknown}


# The test scenes named after `--`, or every scene when none are named. Name a
# batch to run only those scenes, still in this one process:
#
#   godot --headless --path . -s res://tests/run_all.gd -- paint line brush_modes
func _requested() -> Dictionary:
	var names := {}
	for argument in OS.get_cmdline_user_args():
		names[argument] = true
	return names


# The static deadline for one scene. A child-declared budget can extend it.
func _timeout_for(path: String) -> float:
	return DRAW_LATENCY_TIMEOUT_S if path == DRAW_LATENCY_PATH else TEST_TIMEOUT_S


# Returns the declared budget from a child line, or zero when the line is not a
# budget line.
static func parse_budget(line: String) -> float:
	var text := line.strip_edges()
	if not text.begins_with(BUDGET_PREFIX):
		return 0.0
	var value := text.trim_prefix(BUDGET_PREFIX).strip_edges()
	if not value.is_valid_float():
		return 0.0
	return float(value)


# Returns the scene deadline for a static deadline and a child-declared budget.
# The margin lets the child report its own failure before the runner kills it.
static func extended_timeout(base: float, declared: float) -> float:
	if declared <= 0.0:
		return base
	return minf(MAX_SCENE_TIMEOUT_S, maxf(base, declared + DECLARED_BUDGET_MARGIN_S))


func _run_one(entry: Dictionary) -> Dictionary:
	_saw_ok = false
	_saw_error = false
	_declared_budget_s = 0.0
	var begin_ms := Time.get_ticks_msec()
	var path: String = entry["path"]
	_wipe_dir(_artifact_dir(path))
	# Select the deadline once, so the wait and the note agree.
	var timeout_s: float = _timeout_for(path)
	# Godot numbers screens from zero. Open test windows on the second screen.
	var args := PackedStringArray(["--screen", str(TEST_SCREEN), "--path", ProjectSettings.globalize_path("res://"), path])
	# A grouped scene reads its case names from the user arguments after `--`.
	var cases: Array = entry["cases"]
	if not cases.is_empty():
		args.append("--")
		for case_name in cases:
			args.append(str(case_name))
	var proc := OS.execute_with_pipe(OS.get_executable_path(), args, false)
	if proc.is_empty():
		return {"code": 1, "note": "could not start", "seconds": 0.0}
	var pid: int = proc["pid"]
	var out: FileAccess = proc["stdio"]
	var err_out: FileAccess = proc["stderr"]
	var started := Time.get_ticks_msec()
	var timed_out := false
	while OS.is_process_running(pid):
		_pump(out)
		_pump(err_out)
		timeout_s = extended_timeout(timeout_s, _declared_budget_s)
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
	_pending.erase(out)
	_pending.erase(err_out)
	if timed_out:
		return {"code": 1, "note": "timed out after %.0f s" % timeout_s, "seconds": (Time.get_ticks_msec() - begin_ms) / 1000.0}
	var code := OS.get_process_exit_code(pid)
	if code == 0 and _saw_error:
		return {"code": 1, "note": "child reported an engine or script error", "seconds": (Time.get_ticks_msec() - begin_ms) / 1000.0}
	if code == 0 and not _saw_ok:
		return {"code": 1, "note": "exit 0 but no pass marker", "seconds": (Time.get_ticks_msec() - begin_ms) / 1000.0}
	return {"code": code, "note": "", "seconds": (Time.get_ticks_msec() - begin_ms) / 1000.0}


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
	var budget := parse_budget(line)
	if budget > 0.0:
		_declared_budget_s = budget
		return
	if line.strip_edges() == "TEST OK":
		_saw_ok = true
	if is_engine_error(line):
		_saw_error = true
	print(line)


static func is_engine_error(line: String) -> bool:
	var text := line.strip_edges()
	# The Windows clipboard can be locked by another process. Godot prints this
	# platform error, and the clipboard poll retries on its next tick. The scene
	# did not fail, so it must not fail the child run.
	if text.begins_with("ERROR: Unable to open clipboard."):
		return false
	return text.begins_with("SCRIPT ERROR:") or text.begins_with("ERROR:")


func _is_engine_banner(line: String) -> bool:
	return line.begins_with("Godot Engine") or line.begins_with("Vulkan ")
