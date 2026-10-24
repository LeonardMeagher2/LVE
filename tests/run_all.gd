extends SceneTree

const TEST_TIMEOUT_S := 30.0
# Drain verbose child output promptly so a full pipe does not stall its tests.
const POLL_INTERVAL_S := 0.01
const MAX_FAILURES := 3
const TEST_SCREEN := 1
# `draw_latency` runs visible maximum-diameter strokes on the second monitor, so
# it needs its own deadline. Every other scene keeps the default.
const DRAW_LATENCY_PATH := "res://tests/draw_latency.tscn"
const DRAW_LATENCY_TIMEOUT_S := 125.0
# A grouped scene runs several named tests in one process. An old scene name
# maps to its group scene and test name.
const GROUP_ALIASES := {
	"tags": {"scene": "tag_group", "case": "tags"},
	"tag_playback": {"scene": "tag_group", "case": "tag_playback"},
	"tag_frame_remove": {"scene": "tag_group", "case": "tag_frame_remove"},
	"frames": {"scene": "tag_group", "case": "frames"},
	"tags_ui": {"scene": "tag_controls", "case": "tags_ui"},
	"tag_loop_ui": {"scene": "tag_controls", "case": "tag_loop_ui"},
	"frame_delay": {"scene": "frame_timeline", "case": "frame_delay"},
	"frame_selection": {"scene": "frame_timeline", "case": "frame_selection"},
	"frame_reorder": {"scene": "frame_timeline", "case": "frame_reorder"},
	"paint": {"scene": "paint_strokes", "case": "paint"},
	"undo_redo": {"scene": "paint_strokes", "case": "undo_redo"},
	"stroke_connect": {"scene": "paint_strokes", "case": "stroke_connect"},
	"pixel_perfect": {"scene": "paint_strokes", "case": "pixel_perfect"},
	"pixel_perfect_tool": {"scene": "paint_strokes", "case": "pixel_perfect_tool"},
	"brush_modes": {"scene": "paint_strokes", "case": "brush_modes"},
	"fill_all": {"scene": "fill_wand", "case": "fill_all"},
	"wand_select": {"scene": "fill_wand", "case": "wand_select"},
	"wand_all": {"scene": "fill_wand", "case": "wand_all"},
	"erase_drag": {"scene": "erase_strokes", "case": "erase_drag"},
	"erase_hover": {"scene": "erase_strokes", "case": "erase_hover"},
	"erase_drag_visual": {"scene": "erase_strokes", "case": "erase_drag_visual"},
	"selection": {"scene": "selection_interaction", "case": "selection"},
	"selection_click": {"scene": "selection_interaction", "case": "selection_click"},
	"lasso": {"scene": "selection_interaction", "case": "lasso"},
	"material_matching": {"scene": "material_search", "case": "material_matching"},
	"material_matching_large": {"scene": "material_search", "case": "material_matching_large"},
	"transform_mode": {"scene": "transform_workflow", "case": "transform_mode"},
	"transform_move": {"scene": "transform_workflow", "case": "transform_move"},
	"transform_obstacle": {"scene": "transform_workflow", "case": "transform_obstacle"},
	"transform_rotate": {"scene": "transform_rotation", "case": "transform_rotate"},
	"transform_rotate_asymmetric": {"scene": "transform_rotation", "case": "transform_rotate_asymmetric"},
	"transform_rotate_flamingo": {"scene": "transform_rotation", "case": "transform_rotate_flamingo"},
	"transform_rotate_view_switch": {"scene": "transform_rotation", "case": "transform_rotate_view_switch"},
	"transform_scale": {"scene": "transform_scaling", "case": "transform_scale"},
	"transform_scale_view_switch": {"scene": "transform_scaling", "case": "transform_scale_view_switch"},
	"planar_cleanup": {"scene": "planar_geometry", "case": "planar_cleanup"},
	"planar_paths": {"scene": "planar_geometry", "case": "planar_paths"},
	"planar_regions": {"scene": "planar_geometry", "case": "planar_regions"},
	"planar_merge": {"scene": "mesh_regressions", "case": "planar_merge"},
	"failed_greed": {"scene": "mesh_regressions", "case": "failed_greed"},
	"snapshot_normals": {"scene": "normal_geometry", "case": "snapshot_normals"},
	"_bench_snapshot_normals": {"scene": "normal_geometry", "case": "_bench_snapshot_normals"},
	# The spray worker cases that moved to their own scenes, so a name selection
	# still reaches them.
	"worker_max": {"scene": "spray_worker_union", "case": "worker_max"},
	"worker_union": {"scene": "spray_worker_union", "case": "worker_union"},
	"worker_mirror": {"scene": "spray_worker_geometry", "case": "worker_mirror"},
	"worker_expand": {"scene": "spray_worker_geometry", "case": "worker_expand"},
	"worker_far": {"scene": "spray_worker_far", "case": "worker_far"},
}

var _failed := 0
var _pending := {}
var _saw_ok := false
var _saw_error := false


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
	for entry in entries:
		if _failed >= MAX_FAILURES:
			print("STOPPED after %d failures" % _failed)
			break
		var path: String = entry["path"]
		var result := await _run_one(entry)
		if result["code"] == 0:
			print("PASS %s" % path)
		else:
			_failed += 1
			var note: String = result["note"]
			if note == "":
				note = "exit %d" % result["code"]
			print("FAIL %s (%s)" % [path, note])


# One entry per scene to run. An entry holds the scene path and the case names
# to pass to a grouped scene. A named run maps old scene names to their group.
# An unknown name stops the run instead of running nothing.
func _test_entries() -> Array:
	var base: String = get_script().resource_path.get_base_dir()
	var dir := DirAccess.open(base)
	if dir == null:
		return []
	var scenes := {}
	for f in dir.get_files():
		if f.ends_with(".tscn"):
			scenes[f.get_basename()] = true
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


# Map requested names to the scenes and case names to run. A whole group name
# selects every case, so it dominates the aliases of that group in any order.
# Several aliases of one group deduplicate to a single run. Unknown names are
# reported instead of silently running nothing.
static func build_entries(requested_names: Array, scenes: Dictionary) -> Dictionary:
	var order: Array[String] = []
	var by_scene := {}
	var whole := {}
	var unknown: Array[String] = []
	var sorted_names := requested_names.duplicate()
	sorted_names.sort()
	for name in sorted_names:
		if GROUP_ALIASES.has(name):
			var group: Dictionary = GROUP_ALIASES[name]
			var scene_name := str(group["scene"])
			if not scenes.has(scene_name):
				unknown.append(str(name))
				continue
			if not by_scene.has(scene_name):
				by_scene[scene_name] = []
				order.append(scene_name)
			if whole.has(scene_name):
				continue
			var cases: Array = by_scene[scene_name]
			var case_name := str(group["case"])
			if not cases.has(case_name):
				cases.append(case_name)
		elif scenes.has(name):
			whole[name] = true
			if not by_scene.has(name):
				order.append(name)
			by_scene[name] = []
		else:
			unknown.append(str(name))
	# An unknown name stops the run, so the helper builds no plan then.
	if not unknown.is_empty():
		return {"entries": [], "unknown": unknown}
	var entries: Array = []
	for scene_name in order:
		entries.append({"path": scene_name, "cases": by_scene[scene_name]})
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


# The deadline for one scene. A named scene can need longer than the default.
func _timeout_for(path: String) -> float:
	return DRAW_LATENCY_TIMEOUT_S if path == DRAW_LATENCY_PATH else TEST_TIMEOUT_S


func _run_one(entry: Dictionary) -> Dictionary:
	_saw_ok = false
	_saw_error = false
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
	_pending.erase(out)
	_pending.erase(err_out)
	if timed_out:
		return {"code": 1, "note": "timed out after %.0f s" % timeout_s}
	var code := OS.get_process_exit_code(pid)
	if code == 0 and _saw_error:
		return {"code": 1, "note": "child reported an engine or script error"}
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
	if is_engine_error(line):
		_saw_error = true
	print(line)


static func is_engine_error(line: String) -> bool:
	var text := line.strip_edges()
	return text.begins_with("SCRIPT ERROR:") or text.begins_with("ERROR:")


func _is_engine_banner(line: String) -> bool:
	return line.begins_with("Godot Engine") or line.begins_with("Vulkan ")
