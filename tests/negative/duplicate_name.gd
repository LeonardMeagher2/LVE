extends "res://tests/test.gd"

# Negative fixture for the multi-test harness. Two tests share one name, so the
# harness must fail the run and name the duplicate. It lives outside the suite
# directory, so the default suite never runs it. Run it directly:
#
#   godot --headless --path . res://tests/negative/duplicate_name.tscn


func _ready() -> void:
	test("the first duplicate test", _first, "same")
	test("the second duplicate test", _second, "same")


func _first() -> void:
	expect(true, "the first duplicate test never runs")


func _second() -> void:
	expect(true, "the second duplicate test never runs")
