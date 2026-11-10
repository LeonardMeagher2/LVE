class_name Test
extends Node

const MAIN_SCENE := "res://Main.tscn"

var main: Node
var timeout := 10.0
# A probe that prints its result has no checks. Set this to true before `test()`
# to register one such case. `test()` clears it again, so each probe opts in
# alone. A normal test must record at least one check.
var allow_no_checks := false
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


func _enter_tree() -> void:
	main = add_main()


func add_main() -> Node:
	var scene: PackedScene = load(MAIN_SCENE)
	var inst := scene.instantiate()
	get_tree().root.add_child.call_deferred(inst)
	return inst


func _arm_deadman() -> void:
	_plan = selected_budget()
	var budget := float(_plan["budget"])
	# The runner reads this line and allows the declared budget for the scene.
	# The default scene deadline is shorter than a slow benchmark.
	print("TEST BUDGET: %.3f" % budget)
	var t := get_tree().create_timer(budget + 5.0)
	t.timeout.connect(_deadman_fire)
	if not _scheduled and not _finished:
		_scheduled = true
		_run_tests.call_deferred()


# The selection plan and its total timeout. The runner gives the scene the same
# budget, so a per-test timeout is a real deadline, not only a local watchdog.
func selected_budget() -> Dictionary:
	var requested: Array = []
	for argument in OS.get_cmdline_user_args():
		requested.append(argument)
	var choice := select_tests(requested, _tests)
	var selected: Array = choice["selected"]
	var budget := timeout
	if not selected.is_empty():
		budget = 0.0
		for entry in selected:
			budget += float(entry["timeout"])
	return {"budget": budget, "selected": selected, "unknown": choice["unknown"]}


func _deadman_fire() -> void:
	if _finished:
		return
	_fail_hard("harness did not finish")


func _fail_hard(msg: String) -> void:
	_finished = true
	if _name == "":
		_name = get_script().resource_path.get_file().get_basename()
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
	get_tree().quit(1)


# Register one test. A file can register several tests. Each test runs in turn
# with its own report section, timeout, and pass or fail result. The command
# line user arguments after `--` name the tests to run. With no names, every
# registered test runs. `config` can hold `timeout` and `allow_no_checks`; they
# default to the harness properties.
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
	var empty_ok := bool(config.get("allow_no_checks", allow_no_checks))
	allow_no_checks = false
	var test_timeout := float(config.get("timeout", timeout))
	_tests.append({"name": name, "description": description, "callable": c, "loc": loc, "timeout": test_timeout, "empty_ok": empty_ok, "config": config})
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
func select_tests(requested: Array, tests: Array) -> Dictionary:
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
		for i in 2:
			await get_tree().process_frame
			if _finished:
				return
		# The watchdog covers the fixture hooks and the test body. A fixture that
		# hangs in setup or cleanup then fails with the test name.
		var watchdog := _start_test_watchdog(entry)
		await _setup_test()
		if _finished:
			return
		var work: Callable = entry["callable"]
		await work.call()
		if _finished:
			return
		await _cleanup_test()
		if _finished:
			return
		watchdog.stop()
		watchdog.queue_free()
		# A test body that returns early, or that errors before its first check,
		# otherwise reports success with nothing proved. A scene that needs a
		# window must run windowed, so a headless run fails here instead of
		# passing with no coverage.
		if _checks.is_empty() and not bool(entry["empty_ok"]):
			_fail_hard("test %s recorded no checks (does the scene need a window?)" % str(entry["name"]))
			return
		_test_open = false
	_finish_all()


# Start one test. The test owns its checks and steps, so its report section is
# independent of the other tests in the file.
func _begin_test(entry: Dictionary) -> void:
	_checks = []
	_steps = []
	_current_step = -1
	_name = get_script().resource_path.get_file().get_basename()
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


# Isolate the shared editor state around each test. A file overrides these to
# reset the state its tests change.
func _setup_test() -> void:
	pass


func _cleanup_test() -> void:
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
	if failed > 0:
		print("TEST FAILED: %d/%d checks failed -> %s/report.md" % [
			failed, _count_all_checks(), _dir()
		])
		get_tree().quit(1)
	else:
		print("TEST OK")
		get_tree().quit(0)


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


func editor_viewport() -> SubViewport:
	return main.get_node("%Viewport").get_node("PanelContainer/SubViewportContainer/Viewport")

func camera_rig() -> EditorCameraRig:
	return editor_viewport().get_node("ViewportScene/CameraRig")

func viewport_scene() -> Node:
	return editor_viewport().get_node("ViewportScene")

func camera_menu() -> MenuButton:
	return main.get_node("%Viewport").get_node("ControlBar/CameraMenu")

func pick_request(pos: Vector2) -> PickRequest:
	var cam := camera_rig()
	var req := PickRequest.new()
	req.origin = cam.project_ray_origin(pos)
	req.dir = cam.project_ray_normal(pos)
	req.frame = State.get_current_voxel_frame()
	req.forward = -cam.basis.z
	return req

func aim(pos: Vector2) -> PickResult:
	var req := pick_request(pos)
	return VoxelPicking.start_pick(req.origin, req.dir, req.frame, req.forward)

func drag(pos: Vector2, plane: StrokePlane) -> PickResult:
	var req := pick_request(pos)
	return VoxelPicking.drag_pick(req.origin, req.dir, req.frame, plane)

func activate_tool(button_name: String) -> void:
	for b in main.get_node("%ToolBar").get_children():
		if b.name == button_name:
			b.button_pressed = true
			return

func select_toolbar_item(button_name: String, item_text: String) -> void:
	for b in main.get_node("%ToolBar").get_children():
		if b is MenuButton and b.name == button_name:
			var popup: PopupMenu = b.get_popup()
			for i in popup.item_count:
				if popup.get_item_text(i) == item_text:
					popup.index_pressed.emit(i)
					return

func press_option(tooltip: String) -> void:
	var b := _find_option_button(tooltip)
	if b != null:
		b.button_pressed = not b.button_pressed

func _find_option_button(tooltip: String) -> BaseButton:
	var option_bar := main.get_node("%OptionBar")
	for container in option_bar.get_children():
		var b := _find_button_by_tooltip(container, tooltip)
		if b != null:
			return b
	return null

func _find_button_by_tooltip(node: Node, tooltip: String) -> BaseButton:
	for c in node.get_children():
		if c is BaseButton and c.tooltip_text == tooltip:
			return c
		var found := _find_button_by_tooltip(c, tooltip)
		if found != null:
			return found
	return null

func plugin(plugin_name: String) -> Node:
	return get_tree().root.get_node_or_null(plugin_name)

func sync_viewport() -> void:
	State.document._bounds_dirty = true
	var affected: Array[Vector3i] = []
	State.cells_changed.emit(State.current_frame, affected)

func active_tool_node(plugin_name: String) -> Node3D:
	var p := plugin(plugin_name)
	if p == null:
		return null
	return p._tool

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


func _caller_frame(stack: Array) -> Dictionary:
	var harness: String = get_script().get_base_script().resource_path.get_file()
	for sf in stack:
		var f := sf as Dictionary
		if not str(f["source"]).ends_with(harness):
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


func _dir() -> String:
	var dir := "%s/artifacts/%s" % [get_script().resource_path.get_base_dir(), _name]
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func _write_file(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(text)
		f.close()
