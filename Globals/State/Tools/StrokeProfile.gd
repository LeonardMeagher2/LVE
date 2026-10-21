extends RefCounted

## The opt-in stroke profiling hook.
##
## A test turns the hook on to time the edit result publication, which the frame
## gap hides. The values live in this one neutral holder, so no tool script names
## a static variable. A `static var` that the tool script chain read or wrote
## kept the document and renderer scripts in use at exit. Godot then printed
## `ERROR: <n> resources still in use at exit`.

## Whether the hook records the publication time.
static var enabled := false
## The last edit publication time in microseconds.
static var finish_us := 0
# One publication per finished edit. A reader compares this against the value it
# last saw, so a stale duration never attributes to a later frame.
## The publication counter that a reader compares.
static var finish_seq := 0


## Returns the publication start time in microseconds. It is zero when the hook
## is off.
static func mark_us() -> int:
	return Time.get_ticks_usec() if enabled else 0


## Records one edit publication. [param started_us] is the start time from
## [method mark_us].
static func publish(started_us: int) -> void:
	if not enabled:
		return
	finish_us = Time.get_ticks_usec() - started_us
	finish_seq += 1
