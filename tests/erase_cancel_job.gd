extends "res://Globals/State/State.gd".EraseJob

# Test-only erase job that cancels itself after a fixed number of checkpoints, so
# the erase stops in the middle of its work instead of before it starts.
var checks := 0
var cancel_after := 1


func checkpoint(completed: int) -> bool:
	checks += 1
	if checks > cancel_after:
		cancel()
	return super.checkpoint(completed)
