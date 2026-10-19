extends "res://tests/test.gd"

# A later registration must not extend an earlier test's watchdog.


func _ready() -> void:
	timeout = 0.05
	test("the first test keeps its shorter deadline", _short, "short")
	timeout = 0.5
	test("the second test has a longer deadline", _long, "long")


func _short() -> void:
	await get_tree().create_timer(0.2).timeout
	expect(false, "the short test cannot outlive its registered deadline")


func _long() -> void:
	expect(false, "a hard timeout cannot continue into the next test")
