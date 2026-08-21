class_name Test
extends Node

var timeout := 10.0
var _name := ""
var _desc := ""
var _test_loc := ""
var _checks: Array = []
var _steps: Array = []
var _current_step := -1
var _snap_seq := 0
var _snap_by_frame := {}


func test(description: String, c: Callable) -> void:
	_name = get_script().resource_path.get_file().get_basename()
	_desc = description
	_test_loc = _caller_loc(_caller_frame(get_stack()))
	print(description)
	for i in 2:
		await get_tree().process_frame
	var watchdog := _start_watchdog()
	await c.call()
	watchdog.stop()
	_finish()


func _start_watchdog() -> Timer:
	var t := Timer.new()
	t.one_shot = true
	t.wait_time = timeout
	t.timeout.connect(_fail_timeout)
	add_child(t)
	t.start()
	return t


func _fail_timeout() -> void:
	_checks.append({
		"loc": _test_loc,
		"msg": "test timed out after %.1f s" % timeout,
		"ok": false,
		"step": _current_step,
		"src": "",
		"img": _screenshot_for(Engine.get_process_frames()),
	})
	_write_report()
	print("TEST FAILED: timed out after %.1f s -> %s/report.md" % [timeout, _dir()])
	get_tree().quit(1)


func _finish() -> void:
	var failed := _count_failed()
	if failed > 0:
		_write_report()
		print("TEST FAILED: %d/%d checks failed -> %s/report.md" % [
			failed, _checks.size(), _dir()
		])
		get_tree().quit(1)
	else:
		print("TEST OK")
		get_tree().quit(0)


func step(description: String, c: Callable) -> Variant:
	_steps.append({"desc": description})
	_current_step = _steps.size() - 1
	print("  %s" % description)
	return await c.call()


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


func aim(vp: EditorViewport, pos: Vector2) -> PickResult:
	var req := vp.pick_request(pos)
	return VoxelPicking.start_pick(req.origin, req.dir, req.cells)


func drag(vp: EditorViewport, pos: Vector2, plane: StrokePlane) -> PickResult:
	var req := vp.pick_request(pos)
	return VoxelPicking.drag_pick(req.origin, req.dir, req.cells, plane)


func _count_failed() -> int:
	var n := 0
	for ch in _checks:
		if not ch.ok:
			n += 1
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
	lines.append("%s" % _desc)
	lines.append("")
	lines.append("**Ran:** %s · **Checks:** %d · **Failed:** %d" % [
		Time.get_datetime_string_from_system(), _checks.size(), _count_failed()
	])
	lines.append("")
	var last_step := -2
	for ch in _checks:
		var step_id: int = ch.step
		if step_id != last_step:
			last_step = step_id
			lines.append("")
			if step_id >= 0:
				lines.append("### %s" % _steps[step_id].desc)
			else:
				lines.append("### Intro")
			lines.append("")
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
	_write_file(_dir() + "/report.md", "\n".join(lines) + "\n")


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
