extends "res://plugins/Fill/FillTool.gd".FillJob

# Test-only fill job that cancels itself after a fixed number of checkpoints, so
# the shared search stops in the middle of its work instead of before it starts.
# It runs the real `FillJob.run`, so the checkpoint positions under test are the
# production ones.
var checks := 0
var cancel_after := 1


func checkpoint(completed: int) -> bool:
	checks += 1
	if checks > cancel_after:
		cancel()
	return super.checkpoint(completed)
