extends "res://tests/test.gd"

# A later passing case must not hide an earlier failure.


func _ready() -> void:
	test("an intentional failure is reported", _failure, "failure")
	test("a later case still runs", _later, "later")


func _failure() -> void:
	expect(false, "the intentional failure remains in the report")


func _later() -> void:
	expect(true, "the later case completes after the failure")
