class_name Test
extends SceneTree

var _name := ""
var _desc := ""
var _checks: Array = []
var _steps: Array = []
var _current_step := -1
var _snap_seq := 0
var _snap_by_frame := {}


func test(description: String, c: Callable) -> void:
	_name = get_script().resource_path.get_file().get_basename()
	_desc = description
	print(description)
	await c.call()
	var failed := _count_failed()
	if failed > 0:
		_write_report()
		print("TEST FAILED: %d/%d checks failed -> %s/report.md" % [
			failed, _checks.size(), _dir()
		])
		quit(1)
	else:
		print("TEST OK")
		quit(0)


func step(description: String, c: Callable) -> Variant:
	_steps.append({"desc": description})
	_current_step = _steps.size() - 1
	print("  %s" % description)
	return await c.call()


func expect(cond: bool, msg: String) -> void:
	var stack := get_stack()
	var caller := _caller_frame(stack)
	var entry := {
		"loc": "%s:%d" % [caller["source"], caller["line"]],
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
		var img := root.get_texture().get_image()
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


func _caller_frame(stack: Array) -> Dictionary:
	for sf in stack:
		var f := sf as Dictionary
		if not str(f["source"]).ends_with(get_script().resource_path.get_file()):
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
