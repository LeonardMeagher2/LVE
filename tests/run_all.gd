extends SceneTree

var _failed := 0


func _initialize() -> void:
	await _run_all()
	print("")
	print("TEST SUITE: %s" % ("OK" if _failed == 0 else "FAILED (%d test(s))" % _failed))
	quit(1 if _failed > 0 else 0)


func _run_all() -> void:
	var paths := _test_paths()
	for path in paths:
		var code := await _run_one(path)
		if code == 0:
			print("PASS %s" % path)
		else:
			_failed += 1
			print("FAIL %s (exit %d)" % [path, code])


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


func _run_one(path: String) -> int:
	var output: Array = []
	var code := OS.execute(
		OS.get_executable_path(),
		PackedStringArray(["--path", ProjectSettings.globalize_path("res://"), path]),
		output,
		true
	)
	for chunk in output:
		for raw in String(chunk).split("\n"):
			var line := raw.trim_suffix("\r")
			if line.strip_edges() == "" or _is_engine_banner(line):
				continue
			print(line)
	return code


func _is_engine_banner(line: String) -> bool:
	return line.begins_with("Godot Engine") or line.begins_with("Vulkan ")
