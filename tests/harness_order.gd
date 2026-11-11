extends "res://tests/test.gd"

# Dedicated probe for the multi-test runner. It records every test and hook call
# and checks the sequence after each test. Each probe also runs alone or in a
# different order, so selected tests never depend on unselected tests.

var events: Array[String] = []


func _ready() -> void:
	test("the first probe test runs after its setup", _probe_a, "probe_a")
	test("the second probe test runs after a fresh setup", _probe_b, "probe_b")
	test("the runner ordered every test with its hooks", _probe_c, "probe_c")


# Both hooks await a frame, so the probe proves the runner waits for them.
func before_test() -> void:
	await get_tree().process_frame
	events.append("setup")


func after_test() -> void:
	await get_tree().process_frame
	events.append("cleanup")
	expect(events == _expected_events(true), "every completed test awaits its cleanup")


func _probe_a() -> void:
	step("Then the setup completed before the first test", func():
		expect(events.back() == "setup", "the setup completed before the first test")
	)
	events.append("a")


func _probe_b() -> void:
	step("Then a fresh setup completed before the second test", func():
		expect(events.back() == "setup", "a fresh setup completed before the second test")
	)
	events.append("b")


func _probe_c() -> void:
	events.append("c")
	step("Then every selected test ran with its hooks", func():
		expect(events == _expected_events(false), "the runner ordered every test with its setup and cleanup")
	)


func _expected_events(include_last_cleanup: bool) -> Array[String]:
	var expected: Array[String] = []
	for index in _results.size():
		expected.append("setup")
		expected.append(str(_results[index]["name"]).trim_prefix("probe_"))
		if include_last_cleanup or index < _results.size() - 1:
			expected.append("cleanup")
	return expected
