class_name TestKitCase
extends Node

# The shared test class. A test scene puts a script that extends this class on
# its root node. The class owns the test lifecycle, assertions, timeouts, and
# the report. It knows nothing about a project's main scene or autoloads.
#
# A project can extend this class once and inherit that adapter in every test
# scene. The adapter is the place for the project fixture and common setup.

signal finished(result: Dictionary)

const CORE_PATH := "res://addons/test_kit/test_case.gd"
const ARTIFACT_ROOT := "res://.tests"
const SCENE_SUFFIX := ".test.tscn"
# A test registration must stay on one line for case-name discovery. The first
# string is the description, the method is the callable, and the optional third
# string is the case name. A trailing config dictionary is allowed.
const CASE_CALL := "^[ \\t]*test\\(\\s*\"(?:[^\"\\\\]|\\\\.)*\"\\s*,\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*(?:,\\s*\"((?:[^\"\\\\]|\\\\.)*)\")?\\s*(?:,\\s*\\{.*\\})?\\s*\\)"

var timeout := 10.0
# Frames to wait before each case. A project with a deferred fixture can raise
# this. A pure logic suite can lower it.
var settle_frames := 1
# Standalone scene runs quit with their own exit code. The runner sets this to
# false, awaits `finished`, and frees the scene itself.
var quit_on_finish := true
# The runner sets one of these before adding the scene. An empty request runs
# every registered case.
var requested_cases := PackedStringArray()
var run_all_cases := false

var _name := ""
var _desc := ""
var _test_loc := ""
var _checks: Array = []
var _steps: Array = []
var _current_step := -1
var _snap_seq := 0
var _snap_by_frame := {}
var _finished := false
var _tests: Array = []
var _results: Array = []
var _scheduled := false
var _test_open := false
var _plan := {}


func _init() -> void:
	ready.connect(_arm_deadman)


func _arm_deadman() -> void:
	_plan = selected_budget()
	var budget := float(_plan["budget"])
	var t := get_tree().create_timer(budget + 5.0)
	t.timeout.connect(_deadman_fire)
	if not _scheduled and not _finished:
		_scheduled = true
		_run_tests.call_deferred()


# The selection plan and its total timeout. The per-test watchdog covers one
# case. The deadman covers the whole selected run, including the time between
# cases and a hang in the report path.
func selected_budget() -> Dictionary:
	var requested: Array = _requested_cases()
	var choice := select_cases(requested, _tests)
	var selected: Array = choice["selected"]
	var budget := timeout
	if not selected.is_empty():
		budget = 0.0
		for entry in selected:
			budget += float(entry["timeout"])
	return {"budget": budget, "selected": selected, "unknown": choice["unknown"]}


func _requested_cases() -> Array:
	if run_all_cases:
		return []
	if not requested_cases.is_empty():
		var out: Array = []
		for name in requested_cases:
			out.append(name)
		return out
	var args: Array = []
	for argument in OS.get_cmdline_user_args():
		args.append(argument)
	return args


func _deadman_fire() -> void:
	if _finished:
		return
	_fail_hard("harness did not finish")


func _fail_hard(msg: String) -> void:
	if _finished:
		return
	_finished = true
	if _name == "":
		_name = _scene_name()
	if not _test_open:
		_checks = []
		_steps = []
		_results.append({
			"name": _name,
			"description": _desc,
			"checks": _checks,
			"steps": _steps,
		})
	_checks.append({
		"loc": _test_loc,
		"msg": msg,
		"ok": false,
		"step": _current_step,
		"src": "",
		"img": _screenshot_for(Engine.get_process_frames()),
	})
	for entry in _steps:
		if entry.elapsed_ms < 0.0:
			print("    Time: %.3f ms (interrupted)" % _step_time(entry))
	_write_report()
	print("TEST FAILED: %s -> %s/report.md" % [msg, _dir()])
	_finish({
		"ok": false,
		"checks": _count_all_checks(),
		"failed": maxi(1, _count_all_failed()),
		"report": _dir() + "/report.md",
		"name": _name,
	})


# Register one test. A file can register several tests. Each test runs in turn
# with its own report section, timeout, and pass or fail result. `config` can
# hold `timeout` and `allow_no_checks`.
func test(description: String, c: Callable, test_name := "", config := {}) -> void:
	var name := test_name
	if name.is_empty():
		name = _method_name(c)
	var loc := _caller_loc(_caller_frame(get_stack()))
	for entry in _tests:
		if entry["name"] == name:
			_test_loc = loc
			_fail_hard("duplicate test name: %s" % name)
			return
	var empty_ok := bool(config.get("allow_no_checks", false))
	var test_timeout := float(config.get("timeout", timeout))
	_tests.append({"name": name, "description": description, "callable": c, "loc": loc, "timeout": test_timeout, "empty_ok": empty_ok})
	if not _scheduled:
		_scheduled = true
		_run_tests.call_deferred()


func _method_name(c: Callable) -> String:
	var method := c.get_method()
	if method.is_empty() or method.begins_with("<"):
		return "test"
	return method.trim_prefix("_")


# Select tests by name. An empty request selects every test. Unknown names are
# reported, so a bad selection never runs silently.
static func select_cases(requested: Array, tests: Array) -> Dictionary:
	if requested.is_empty():
		return {"selected": tests.duplicate(), "unknown": []}
	var selected: Array = []
	var unknown: Array = []
	for name in requested:
		var found := false
		for entry in tests:
			if entry["name"] == name:
				if not selected.has(entry):
					selected.append(entry)
				found = true
				break
		if not found and not unknown.has(name):
			unknown.append(name)
	return {"selected": selected, "unknown": unknown}


func _run_tests() -> void:
	if _finished:
		return
	if _tests.is_empty():
		_fail_hard("no tests registered")
		return
	if _plan.is_empty():
		_plan = selected_budget()
	var unknown: Array = _plan["unknown"]
	if not unknown.is_empty():
		var names := PackedStringArray()
		for name in unknown:
			names.append(str(name))
		_fail_hard("unknown test: %s" % ", ".join(names))
		return
	var selected: Array = _plan["selected"]
	if selected.is_empty():
		_fail_hard("no tests selected")
		return
	for entry in selected:
		_begin_test(entry)
		for i in settle_frames:
			await get_tree().process_frame
			if _finished:
				return
		# The watchdog covers the project hooks and the test body. A fixture
		# that hangs in setup or cleanup then fails with the test name.
		var watchdog := _start_test_watchdog(entry)
		await reset_environment()
		await before_test()
		if _finished:
			return
		var work: Callable = entry["callable"]
		await work.call()
		if _finished:
			return
		await after_test()
		if _finished:
			return
		watchdog.stop()
		watchdog.queue_free()
		# A test body that returns early, or that errors before its first check,
		# otherwise reports success with nothing proved.
		if _checks.is_empty() and not bool(entry["empty_ok"]):
			_fail_hard("test %s recorded no checks" % str(entry["name"]))
			return
		_test_open = false
	_finish_all()


# Start one test. The test owns its checks and steps, so its report section is
# independent of the other tests in the file.
func _begin_test(entry: Dictionary) -> void:
	_checks = []
	_steps = []
	_current_step = -1
	_name = _scene_name()
	_desc = str(entry["description"])
	_test_loc = str(entry["loc"])
	_results.append({
		"name": str(entry["name"]),
		"description": str(entry["description"]),
		"checks": _checks,
		"steps": _steps,
	})
	_test_open = true
	print(_desc)


# Called before every case. The project adapter resets shared state here. The
# suite's `before_test()` runs after it, so a suite hook never needs `super`.
func reset_environment() -> void:
	pass


# Project hooks. A suite overrides these for its own setup and cleanup. A
# project adapter can override them for project-wide defaults. A suite that
# extends such an adapter calls `super.before_test()` first and
# `super.after_test()` last.
func before_test() -> void:
	pass


func after_test() -> void:
	pass


# Called by the runner after the result is emitted and before the scene is
# freed. A project adapter uses it to release nodes that outlive the scene,
# such as root-level plugins.
func before_scene_free() -> void:
	pass


func _start_test_watchdog(entry: Dictionary) -> Timer:
	var test_name := str(entry["name"])
	var deadline := float(entry["timeout"])
	var t := Timer.new()
	t.one_shot = true
	t.wait_time = deadline
	t.timeout.connect(func(): _fail_hard("test %s timed out after %.1f s" % [test_name, deadline]))
	add_child(t)
	t.start()
	return t


func _finish_all() -> void:
	_finished = true
	var failed := _count_all_failed()
	_write_report()
	var result := {
		"ok": failed == 0,
		"checks": _count_all_checks(),
		"failed": failed,
		"report": _dir() + "/report.md",
		"name": _name,
	}
	if failed > 0:
		print("TEST FAILED: %d/%d checks failed -> %s/report.md" % [
			failed, _count_all_checks(), _dir()
		])
	else:
		print("TEST OK")
	_finish(result)


# Emit the result for the runner, then quit only for a standalone scene run.
func _finish(result: Dictionary) -> void:
	finished.emit(result)
	if quit_on_finish:
		get_tree().quit(0 if bool(result.get("ok", false)) else 1)


func step(description: String, c: Callable) -> Variant:
	var entry := {"desc": description, "started_us": Time.get_ticks_usec(), "elapsed_ms": -1.0}
	_steps.append(entry)
	_current_step = _steps.size() - 1
	print("  %s" % description)
	var result: Variant = await c.call()
	entry.elapsed_ms = (Time.get_ticks_usec() - int(entry.started_us)) / 1000.0
	print("    Time: %.3f ms" % entry.elapsed_ms)
	return result


func _step_time(entry: Dictionary) -> float:
	return entry.elapsed_ms if entry.elapsed_ms >= 0.0 else (Time.get_ticks_usec() - int(entry.started_us)) / 1000.0


func expect(cond: bool, msg: String) -> void:
	var caller := _caller_frame(get_stack())
	var entry := {
		"loc": _caller_loc(caller),
		"msg": msg,
		"ok": cond,
		"step": _current_step,
	}
	if cond:
		print("    + %s" % msg)
	else:
		print("    x %s" % msg)
		entry["src"] = _line_text(str(caller["source"]), caller["line"])
		entry["img"] = _screenshot_for(Engine.get_process_frames())
	_checks.append(entry)


func _failed_in(checks: Array) -> int:
	var n := 0
	for ch in checks:
		if not ch.ok:
			n += 1
	return n


func _count_all_failed() -> int:
	var n := 0
	for result in _results:
		var checks: Array = result["checks"]
		n += _failed_in(checks)
	return n


func _count_all_checks() -> int:
	var n := 0
	for result in _results:
		var checks: Array = result["checks"]
		n += checks.size()
	return n


# The test scene path. A scene instantiated by the runner has `scene_file_path`
# set. A standalone scene run has it set too. The current scene is only a
# fallback for a test node that lives below the scene root.
func _scene_path() -> String:
	if not scene_file_path.is_empty():
		return scene_file_path
	# A test script on a child node uses the scene root as its owner.
	if owner != null and not owner.scene_file_path.is_empty():
		return owner.scene_file_path
	var parent := get_parent()
	if parent != null and not parent.scene_file_path.is_empty():
		return parent.scene_file_path
	var current := get_tree().current_scene
	if current != null and not current.scene_file_path.is_empty():
		return current.scene_file_path
	return get_script().resource_path.get_basename() + ".tscn"


func _scene_name() -> String:
	return scene_key(_scene_path()).get_file()


func _dir() -> String:
	var dir := artifact_dir(_scene_path())
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func _screenshot_for(frame: int) -> String:
	if _snap_by_frame.has(frame):
		return _snap_by_frame[frame]
	var file := ""
	if DisplayServer.get_name() != "headless":
		RenderingServer.force_draw()
		var img := get_tree().root.get_texture().get_image()
		if img.get_width() > 0 and img.get_height() > 0:
			_snap_seq += 1
			file = "fail_%02d.png" % _snap_seq
			img.save_png(_dir() + "/" + file)
	_snap_by_frame[frame] = file
	return file


func _write_report() -> void:
	var lines := PackedStringArray()
	lines.append("# Test: %s" % _name)
	lines.append("")
	var multiple := _tests.size() > 1
	for result in _results:
		var checks: Array = result["checks"]
		var steps: Array = result["steps"]
		if multiple:
			lines.append("## %s" % result["name"])
			lines.append("")
		lines.append("%s" % result["description"])
		lines.append("")
		lines.append("**Ran:** %s · **Checks:** %d · **Failed:** %d" % [
			Time.get_datetime_string_from_system(), checks.size(), _failed_in(checks)
		])
		lines.append("")
		_append_test_lines(lines, steps, checks)
	_write_file(_dir() + "/report.md", "\n".join(lines) + "\n")


func _append_test_lines(lines: PackedStringArray, steps: Array, checks: Array) -> void:
	var intro_written := false
	for step_id in range(-1, steps.size()):
		if step_id >= 0:
			var entry: Dictionary = steps[step_id]
			lines.append("### %s" % entry.desc)
			lines.append("")
			lines.append("**Time:** %.3f ms%s" % [_step_time(entry), " (interrupted)" if entry.elapsed_ms < 0.0 else ""])
			lines.append("")
		for ch in checks:
			if ch.step != step_id:
				continue
			if step_id == -1 and not intro_written:
				lines.append("### Intro")
				lines.append("")
				intro_written = true
			var label: String = ch.msg
			if ch.ok:
				lines.append("- ✅ %s: %s" % [label, _loc_link(ch.loc)])
			else:
				lines.append("- ❌ %s: %s" % [label, _loc_link(ch.loc)])
				if ch.src != "":
					lines.append("  ```gdscript")
					lines.append("  %s" % ch.src)
					lines.append("  ```")
				if ch.img != "":
					lines.append("  ![screenshot](%s)" % ch.img)
		lines.append("")


func _loc_link(loc: String) -> String:
	var idx := loc.rfind(":")
	if idx == -1:
		return loc
	var src := loc.substr(0, idx).trim_prefix("res://")
	var up := ""
	for i in _dir().trim_prefix("res://").split("/").size():
		up += "../"
	return "[%s](%s%s)" % [loc, up, src]


func _caller_loc(caller: Dictionary) -> String:
	if caller.is_empty():
		return ""
	return "%s:%d" % [caller["source"], caller["line"]]


# The shared class and the suite's direct base are framework frames. Skip them
# so a failure points at the test, not at the harness or the project adapter.
func _framework_scripts() -> PackedStringArray:
	var out := PackedStringArray([CORE_PATH])
	var base: Script = get_script().get_base_script()
	if base != null and not out.has(base.resource_path):
		out.append(base.resource_path)
	return out


func _caller_frame(stack: Array) -> Dictionary:
	var skip := _framework_scripts()
	for sf in stack:
		var f := sf as Dictionary
		if not skip.has(str(f["source"])):
			return f
	return {}


func _line_text(source: String, line: int) -> String:
	var f := FileAccess.open(source, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	var lines := text.split("\n")
	if line < 1 or line > lines.size():
		return ""
	return lines[line - 1].strip_edges()


func _write_file(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(text)
		f.close()


# A scene path without `res://`, without the `.test.tscn` suffix, and without a
# leading `tests/`. This key names the scene in the runner and in `.tests`.
static func scene_key(scene_path: String) -> String:
	var rel := scene_path.trim_prefix("res://").trim_suffix(SCENE_SUFFIX)
	if rel.begins_with("tests/"):
		rel = rel.trim_prefix("tests/")
	return rel


static func artifact_dir(scene_path: String) -> String:
	return ARTIFACT_ROOT + "/" + scene_key(scene_path)


# The case names a test scene registers. The root script may be external or
# inline. If it cannot be read, the scene still runs; it is only selectable by
# scene name.
static func scan_cases(scene_path: String) -> Array[String]:
	return scan_cases_text(script_source_for_scene(scene_path))


static func scan_cases_text(text: String) -> Array[String]:
	var names: Array[String] = []
	if text.is_empty():
		return names
	var re := RegEx.new()
	if re.compile(CASE_CALL) != OK:
		return names
	for line in text.split("\n"):
		var found := re.search(line)
		if found == null:
			continue
		var explicit := found.get_string(2)
		var case_name := explicit if not explicit.is_empty() else found.get_string(1).trim_prefix("_")
		if not names.has(case_name):
			names.append(case_name)
	return names


# Read the script on the test scene's root node. An external script is read from
# disk. An inline GDScript is unescaped from the scene's sub-resource.
static func script_source_for_scene(scene_path: String) -> String:
	var text := FileAccess.get_file_as_string(scene_path)
	if text.is_empty():
		return ""
	var lines := text.split("\n")
	var node_index := -1
	for i in lines.size():
		if lines[i].begins_with("[node "):
			node_index = i
			break
	if node_index == -1:
		return ""
	var script_ref := ""
	for i in range(node_index, lines.size()):
		var line := lines[i].strip_edges()
		if i > node_index and line.begins_with("["):
			break
		if line.begins_with("script = ExtResource("):
			script_ref = "ext:" + _quoted_id(line, "ExtResource")
			break
		if line.begins_with("script = SubResource("):
			script_ref = "sub:" + _quoted_id(line, "SubResource")
			break
	if script_ref.is_empty():
		return ""
	var kind := script_ref.get_slice(":", 0)
	var id := script_ref.get_slice(":", 1)
	if kind == "ext":
		var path := ""
		var uid := ""
		for line in lines:
			if not line.begins_with("[ext_resource "):
				continue
			if not line.contains("id=\"%s\"" % id):
				continue
			path = _attr(line, "path")
			uid = _attr(line, "uid")
			break
		if not path.is_empty():
			return FileAccess.get_file_as_string(path)
		if not uid.is_empty():
			var resolved := ResourceUID.get_id_path(ResourceUID.text_to_id(uid))
			if not resolved.is_empty():
				return FileAccess.get_file_as_string(resolved)
		return ""
	for i in lines.size():
		if not lines[i].begins_with("[sub_resource "):
			continue
		if not lines[i].contains("id=\"%s\"" % id):
			continue
		for j in range(i + 1, lines.size()):
			var line := lines[j].strip_edges()
			if line.begins_with("["):
				break
			if line.begins_with("script/source = "):
				var value := line.trim_prefix("script/source = ").strip_edges()
				return value.trim_prefix("\"").trim_suffix("\"").c_unescape()
	return ""


static func _attr(line: String, key: String) -> String:
	var token := key + "=\""
	var start := line.find(token)
	if start == -1:
		return ""
	start += token.length()
	var end := line.find("\"", start)
	if end == -1:
		return ""
	return line.substr(start, end - start)


static func _quoted_id(line: String, func_name: String) -> String:
	var token := func_name + "(\""
	var start := line.find(token)
	if start == -1:
		return ""
	start += token.length()
	var end := line.find("\"", start)
	if end == -1:
		return ""
	return line.substr(start, end - start)


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
	if not unknown.is_empty():
		return {"entries": [], "unknown": unknown}
	var entries: Array = []
	for scene_name in order:
		var cases: Array = by_scene[scene_name]
		cases.sort()
		entries.append({"path": scene_name, "cases": cases})
	return {"entries": entries, "unknown": unknown}
