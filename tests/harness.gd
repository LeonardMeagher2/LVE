extends "res://tests/test.gd"

# Focused checks for the multi-test harness and the runner selection. Every test
# is independent, so any single test can run alone in any requested order.

const RUNNER := preload("res://tests/run_all.gd")
const GROUP_SCENES := {"tag_group": true, "step_timing": true}


func _ready() -> void:
	test("the test filter selects tests by name", _filter, "filter")
	test("a whole group dominates its aliases in any order", _whole_group, "whole_group")
	test("several aliases deduplicate to one run", _alias_dedup, "alias_dedup")
	test("a test owns its own result and check list", _own_result, "own_result")
	test("engine errors cannot pass as successful output", _engine_errors, "engine_errors")
	test("every legacy name selects its migrated test", _legacy_aliases, "legacy_aliases")


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
	step("Then the whole group wins in the alias-first order", func():
		_expect_whole_group(RUNNER.build_entries(["tags", "tag_group"], GROUP_SCENES))
	)
	step("Then the whole group wins with every alias present", func():
		var names := ["frames", "tags", "tag_group", "tag_playback", "tag_frame_remove"]
		_expect_whole_group(RUNNER.build_entries(names, GROUP_SCENES))
	)


func _expect_whole_group(result: Dictionary) -> void:
	var entries: Array = result["entries"]
	expect(entries.size() == 1, "the group runs once")
	expect(str(entries[0]["path"]) == "tag_group", "the entry is the group scene")
	var cases: Array = entries[0]["cases"]
	expect(cases.is_empty(), "the whole group selects every case")


func _alias_dedup() -> void:
	step("Then several aliases deduplicate to one run", func():
		var result: Dictionary = RUNNER.build_entries(["tags", "frames", "tags"], GROUP_SCENES)
		var entries: Array = result["entries"]
		expect(entries.size() == 1, "one group entry is built")
		var cases: Array = entries[0]["cases"]
		expect(cases == ["frames", "tags"], "the aliases deduplicate in sorted order")
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
	)


func _legacy_aliases() -> void:
	step("Then all migrated aliases resolve without narrowing a whole group", func():
		var scenes := {}
		for file in DirAccess.get_files_at("res://tests"):
			if file.ends_with(".tscn"):
				scenes[file.get_basename()] = true
		var errors: Array[String] = []
		for name in RUNNER.GROUP_ALIASES:
			var alias: Dictionary = RUNNER.GROUP_ALIASES[name]
			var selected: Dictionary = RUNNER.build_entries([name], scenes)
			var entries: Array = selected["entries"]
			if entries.size() != 1:
				errors.append("%s has no unique scene" % name)
				continue
			if entries[0]["path"] != alias["scene"] or entries[0]["cases"] != [alias["case"]]:
				errors.append("%s selects the wrong case" % name)
			for names in [[name, alias["scene"]], [alias["scene"], name]]:
				var whole: Dictionary = RUNNER.build_entries(names, scenes)
				var groups: Array = whole["entries"]
				if groups.size() != 1 or not groups[0]["cases"].is_empty():
					errors.append("%s narrows the whole group" % name)
		expect(errors.is_empty(), "all legacy selectors resolve independently and in whole groups: %s" % "; ".join(errors))
	)
