class_name AnimationTag
extends Resource

enum LoopMode { FORWARD, REVERSE, PING_PONG }

@export var name := "Tag"
@export var from := 0
@export var to := 0
@export var loop_mode := LoopMode.FORWARD
@export var repeats := 0


func frame_count() -> int:
	return absi(to - from) + 1
