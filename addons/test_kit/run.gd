extends SceneTree

# The shared test runner. It finds every `*.test.tscn` in the project, runs the
# selected scenes in this process, and exits with a CI-friendly status.
#
# There is no child process and no project setting. A test scene owns its main
# scene and its environment. The runner only adds the scene, awaits `finished`,
# prints the result, and frees it.

const KIT := preload("res://addons/test_kit/test_case.gd")
const TEST_SUFFIX := ".test.tscn"
# Stop after this many failed scenes. A green project gets fast feedback by
# default. Edit this constant to run every scene.
const MAX_FAILURES := 3

var _failed := 0
var _timings: Array = []


func _initialize() -> void:
	await _run_all()
	print("")
	print("TEST SUITE: %s" % ("OK" if _failed == 0 else "FAILED (%d scene(s))" % _failed))
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
			print("STOPPED after %d failed scene(s)" % _failed)
			break
		var result := await _run_one(entry)
		var path: String = entry["path"]
		var seconds := float(result["seconds"])
		_timings.append({"path": path, "seconds": seconds})
		if bool(result["ok"]):
			print("PASS %s (%.1f s)" % [path, seconds])
		else:
			_failed += 1
			print("FAIL %s (%d/%d checks failed) (%.1f s)" % [
				path, int(result["failed"]), int(result["checks"]), seconds
			])
			var report := str(result["report"])
			if not report.is_empty():
				print("  report: %s" % report)
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
# to pass to the scene. A named run resolves the name against the scenes and
# their cases. An unknown name stops the run instead of running nothing.
func _test_entries() -> Array:
	var scenes := {}
	var paths := {}
	for scene_path in _test_scene_files():
		var key: String = KIT.scene_key(scene_path)
		if paths.has(key):
			print("DUPLICATE SCENE KEY: %s" % key)
			continue
		paths[key] = scene_path
		scenes[key] = KIT.scan_cases(scene_path)
	var only := _requested()
	if only.is_empty():
		var names := scenes.keys()
		names.sort()
		var all: Array = []
		for name in names:
			all.append({"path": paths[name], "cases": []})
		return all
	var result: Dictionary = KIT.build_entries(only.keys(), scenes)
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
		var key := str(entry["path"])
		out.append({"path": paths[key], "cases": entry["cases"]})
	return out


# Every `*.test.tscn` under `res://`. Hidden directories and `.godot` are
# skipped. The file name is the whole test contract; the runner does not inspect
# a scene to decide whether it is a test.
func _test_scene_files() -> Array[String]:
	var out: Array[String] = []
	_collect_scenes("res://", out)
	out.sort()
	return out


func _collect_scenes(dir_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for f in dir.get_files():
		if f.ends_with(TEST_SUFFIX):
			out.append(_join(dir_path, f))
	for d in dir.get_directories():
		if d.begins_with("."):
			continue
		_collect_scenes(_join(dir_path, d), out)


func _join(dir_path: String, name: String) -> String:
	if dir_path.ends_with("/"):
		return dir_path + name
	return dir_path + "/" + name


# The scenes named after `--`, or every scene when none are named. Name a batch
# to run only those scenes, still in this one process:
#
#   godot --path . -s res://addons/test_kit/run.gd -- paint line brush_modes
func _requested() -> Dictionary:
	var names := {}
	for argument in OS.get_cmdline_user_args():
		names[argument] = true
	return names


func _run_one(entry: Dictionary) -> Dictionary:
	var path: String = entry["path"]
	var cases: Array = entry["cases"]
	var begin := Time.get_ticks_msec()
	_wipe_dir(KIT.artifact_dir(path))
	var packed: PackedScene = load(path)
	if packed == null:
		return {"ok": false, "checks": 0, "failed": 1, "report": "", "seconds": 0.0}
	var scene: Node = packed.instantiate()
	if scene == null or not scene.has_signal("finished"):
		if scene != null:
			scene.free()
		return {"ok": false, "checks": 0, "failed": 1, "report": "", "seconds": 0.0}
	scene.set("quit_on_finish", false)
	scene.set("run_all_cases", cases.is_empty())
	scene.set("requested_cases", PackedStringArray(cases))
	root.add_child(scene)
	var result: Dictionary = await scene.finished
	if scene.has_method("before_scene_free"):
		await scene.before_scene_free()
	scene.queue_free()
	# Let deferred cleanup finish before the next scene starts. A scene can
	# queue worker joins and preview teardown from `_exit_tree`.
	for i in 3:
		await process_frame
	var seconds := (Time.get_ticks_msec() - begin) / 1000.0
	return {
		"ok": bool(result.get("ok", false)),
		"checks": int(result.get("checks", 0)),
		"failed": int(result.get("failed", 0)),
		"report": str(result.get("report", "")),
		"seconds": seconds,
	}


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
