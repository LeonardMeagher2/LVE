class_name AnimationTag
extends Resource

## One named animation range of frames.
##
## A tag selects an inclusive frame range and a loop mode. The repeat count
## controls how many passes the playback runs.

## How playback moves through the tag range.
enum LoopMode {
	## Play forward from the first frame to the last frame.
	FORWARD,
	## Play backward from the last frame to the first frame.
	REVERSE,
	## Play forward, then backward.
	PING_PONG,
	## Play backward, then forward.
	PING_PONG_REVERSE,
}

## The tag name.
@export var name := "Tag"
## The first frame index.
@export var from := 0
## The last frame index.
@export var to := 0
## The playback direction mode.
@export var loop_mode := LoopMode.FORWARD
## The repeat count. Zero means continuous playback.
@export var repeats := 0


## Returns the inclusive frame count.
func frame_count() -> int:
	return absi(to - from) + 1
