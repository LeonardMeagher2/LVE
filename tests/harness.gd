extends "res://tests/test.gd"

# Focused checks for the multi-test harness and the runner selection. Every test
# is independent, so any single test can run alone in any requested order.

const RUNNER := preload("res://tests/run_all.gd")
const GROUP_SCENES := {"tag_group": ["frames", "tag_frame_remove", "tag_playback", "tags"], "step_timing": []}


func _ready() -> void:
	test("the test filter selects tests by name", _filter, "filter")
	test("a whole group dominates its case names in any order", _whole_group, "whole_group")
	test("several case names deduplicate to one run", _case_dedup, "case_dedup")
	test("a test owns its own result and check list", _own_result, "own_result")
	test("engine errors cannot pass as successful output", _engine_errors, "engine_errors")
	test("every registered name resolves to its scene", _name_resolution, "name_resolution")


func _filter() -> void:
	step("Then an empty request selects every test", func():
		var sample := [{"name": "a"}, {"name": "b"}]
		var result: Dictionary = select_tests([], sample)
		var selected: Array = result["selected"]
		var unknown: Array = result["unknown"]
		expect(selected.size() == 2, "an empty request selects both tests")
		expect(unknown.is_empty(), "an empty request has no unknown names")
	)
	step("Then a named request selects only that test", func():
		var sample := [{"name": "a"}, {"name": "b"}]
		var result: Dictionary = select_tests(["b"], sample)
		var selected: Array = result["selected"]
		expect(selected.size() == 1, "a named request selects one test")
		expect(str(selected[0]["name"]) == "b", "the named test is selected")
	)
	step("Then an unknown name is reported", func():
		var sample := [{"name": "a"}]
		var result: Dictionary = select_tests(["missing"], sample)
		var selected: Array = result["selected"]
		var unknown: Array = result["unknown"]
		expect(unknown == ["missing"], "the unknown name is reported")
		expect(selected.is_empty(), "an unknown name selects no test")
	)
	step("Then a repeated name selects one test", func():
		var sample := [{"name": "a"}, {"name": "b"}]
		var result: Dictionary = select_tests(["b", "b"], sample)
		var selected: Array = result["selected"]
		expect(selected.size() == 1, "a repeated name selects one test")
	)


func _whole_group() -> void:
	step("Then the whole group wins in the group-first order", func():
		_expect_whole_group(RUNNER.build_entries(["tag_group", "tags"], GROUP_SCENES))
	)
	step("Then the whole group wins in the case-first order", func():
		_expect_whole_group(RUNNER.build_entries(["tags", "tag_group"], GROUP_SCENES))
	)
	step("Then the whole group wins with every case name present", func():
		var names := ["frames", "tags", "tag_group", "tag_playback", "tag_frame_remove"]
		_expect_whole_group(RUNNER.build_entries(names, GROUP_SCENES))
	)


func _expect_whole_group(result: Dictionary) -> void:
	var entries: Array = result["entries"]
	expect(entries.size() == 1, "the group runs once")
	expect(str(entries[0]["path"]) == "tag_group", "the entry is the group scene")
	var cases: Array = entries[0]["cases"]
	expect(cases.is_empty(), "the whole group selects every case")


func _case_dedup() -> void:
	step("Then several case names deduplicate to one run", func():
		var result: Dictionary = RUNNER.build_entries(["tags", "frames", "tags"], GROUP_SCENES)
		var entries: Array = result["entries"]
		expect(entries.size() == 1, "one group entry is built")
		var cases: Array = entries[0]["cases"]
		expect(cases == ["frames", "tags"], "the case names deduplicate in sorted order")
	)
	step("Then an unknown name is reported and nothing is built", func():
		var result: Dictionary = RUNNER.build_entries(["tags", "missing"], GROUP_SCENES)
		var unknown: Array = result["unknown"]
		var entries: Array = result["entries"]
		expect(unknown == ["missing"], "the unknown name is reported")
		expect(entries.is_empty(), "no entry is built when a name is unknown")
	)


func _own_result() -> void:
	step("Then this test owns its own result and check list", func():
		var last: Dictionary = _results[_results.size() - 1]
		expect(str(last["name"]) == "own_result", "the result carries this test name")
		expect(is_same(last["checks"], _checks), "the result holds this test's checks")
		expect(is_same(last["steps"], _steps), "the result holds this test's steps")
	)


func _engine_errors() -> void:
	step("Then script and engine errors invalidate a child run", func():
		expect(RUNNER.is_engine_error("SCRIPT ERROR: invalid call"), "a script error is recognized")
		expect(RUNNER.is_engine_error("  ERROR: invalid resource"), "an indented engine error is recognized")
		expect(not RUNNER.is_engine_error("TEST OK"), "a pass marker is not an engine error")
		expect(not RUNNER.is_engine_error("WARNING: optional reference is absent"), "a warning is not an engine error")
		expect(not RUNNER.is_engine_error("ERROR: Unable to open clipboard."), "a busy OS clipboard is not a scene error")
	)


func _name_resolution() -> void:
	step("Then every registered case resolves to the scene that declares it", func():
		var scenes := {}
		var errors: Array[String] = []
		for file in DirAccess.get_files_at("res://tests"):
			if not file.ends_with(".tscn"):
				continue
			var scene_name := file.get_basename()
			var cases := RUNNER._scene_cases("res://tests/%s.gd" % scene_name)
			scenes[scene_name] = cases
			if cases.is_empty():
				continue
			for case_name in cases:
				var entries: Array = RUNNER.build_entries([case_name], scenes)["entries"]
				var found := false
				for entry in entries:
					if entry["path"] != scene_name:
						continue
					# A case named after its own scene is reached as the whole
					# scene, so the scene name still wins that selection.
					if entry["cases"] == [case_name] or (case_name == scene_name and entry["cases"].is_empty()):
						found = true
				if not found:
					errors.append("%s does not resolve to %s" % [case_name, scene_name])
		expect(not scenes.is_empty(), "the runner discovers scenes")
		expect(errors.is_empty(), "every registered case resolves to its scene: %s" % "; ".join(errors))
	)
	step("Then a plain scene name selects every case and the scene name wins", func():
		var entries: Array = RUNNER.build_entries(["tag_group", "tags"], GROUP_SCENES)["entries"]
		expect(entries.size() == 1 and entries[0]["cases"].is_empty(), "the scene name dominates its case names")
	)
	step("Then an unknown name is reported", func():
		var result: Dictionary = RUNNER.build_entries(["missing"], GROUP_SCENES)
		expect(result["unknown"] == ["missing"], "the unknown name is reported")
		expect(result["entries"].is_empty(), "an unknown name builds no plan")
	)
