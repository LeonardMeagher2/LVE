extends "./SelectTool.gd"

## The box selection tool.
##
## It selects the volume behind a dragged screen rectangle. A press and release
## in one place selects a small area under the pointer.

# The box tool selects the volume behind a dragged rectangle.


func _begin_shape(_pos: Vector2) -> void:
	_show_band_rectangle(_screen_rectangle(_screen_press))


func _update_shape(pos: Vector2) -> void:
	_show_band_rectangle(_screen_rectangle(pos))


func _commit_shape(pos: Vector2) -> void:
	_commit_screen(_screen_rectangle(pos), PackedVector2Array())
