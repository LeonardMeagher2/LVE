class_name Test
extends Node

const MAIN_SCENE := "res://Main.tscn"

var main: Node
var timeout := 10.0
var _name := ""
var _desc := ""
var _test_loc := ""
var _checks: Array = []
var _steps: Array = []
var _current_step := -1
var _snap_seq := 0
var _snap_by_frame := {}
var _finished := false


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
	var t := get_tree().create_timer(timeout + 5.0)
	t.timeout.connect(_deadman_fire)


func _deadman_fire() -> void:
	if _finished:
		return
	_fail_hard("harness did not finish")


func _fail_hard(msg: String) -> void:
	_finished = true
	if _name == "":
		_name = get_script().resource_path.get_file().get_basename()
	_checks.append({
		"loc": _test_loc,
		"msg": msg,
		"ok": false,
		"step": _current_step,
		"src": "",
		"img": _screenshot_for(Engine.get_process_frames()),
	})
	_write_report()
	print("TEST FAILED: %s -> %s/report.md" % [msg, _dir()])
	get_tree().quit(1)


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
	_fail_hard("timed out after %.1f s" % timeout)


func _finish() -> void:
	_finished = true
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
