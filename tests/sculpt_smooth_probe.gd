extends "res://plugins/Sculpt/SculptTool.gd"

## A test-only probe that records the resolved hit and entered face of every
## Smooth dab. The placement test reads the recorded hits to prove that each dab
## resolved the real surface at dab time, so no dab sits in the air and a miss
## applies nothing.

## The resolved hit of every Smooth dab, in application order.
var dab_hits: Array = []
## The entered face of every Smooth dab.
var dab_entries: Array = []


## Clears the recorded dabs.
func reset_dabs() -> void:
	dab_hits = []
	dab_entries = []


func _run_smooth_dab() -> void:
	super._run_smooth_dab()
	dab_hits.append(_smooth_hit)
	dab_entries.append(_smooth_entry)
