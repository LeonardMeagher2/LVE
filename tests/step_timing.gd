extends "res://tests/test.gd"


func _ready() -> void:
	test("step timing includes synchronous work, awaited work, and steps without checks", _run)


func _run() -> void:
	var result: Variant = await step("Given synchronous setup without checks", func(): return 42)
	step("Then the setup returns its result and records its duration", func():
		expect(result == 42, "step returns the callable result")
		expect(_steps[0].elapsed_ms >= 0.0, "synchronous setup has a recorded duration")
	)
	await step("When the step waits for asynchronous work", _wait)
	step("Then the report includes all steps and their durations", func():
		expect(_steps[2].elapsed_ms >= 20.0, "the asynchronous duration includes the wait")
		_write_report()
		var report := FileAccess.get_file_as_string(_dir() + "/report.md")
		expect(report.contains("Given synchronous setup without checks"), "the report includes steps without checks")
		expect(report.contains("When the step waits for asynchronous work"), "the report includes asynchronous steps")
		expect(report.count("**Time:**") == _steps.size(), "the report gives every step a duration")
	)


func _wait() -> void:
	var deadline := Time.get_ticks_usec() + 30000
	while Time.get_ticks_usec() < deadline:
		await get_tree().process_frame
