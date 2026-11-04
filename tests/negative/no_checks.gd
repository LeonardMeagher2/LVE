extends "res://tests/test.gd"

# A test that records no check must fail. Run this scene directly and expect a
# non-zero exit code and a "recorded no checks" report.


func _ready() -> void:
	test("a test with no check fails", _no_checks, "no_checks")


func _no_checks() -> void:
	print("this test records no check")
