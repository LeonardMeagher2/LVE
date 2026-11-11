extends "res://tests/test.gd"

# The per-test watchdog must cover asynchronous fixture setup.


func _ready() -> void:
	timeout = 0.05
	test("a stalled setup fails with the case name", _body, "stalled_setup")


func before_test() -> void:
	await get_tree().create_timer(1.0).timeout


func _body() -> void:
	expect(false, "the body cannot run after its setup times out")
