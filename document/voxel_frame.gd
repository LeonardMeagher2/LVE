class_name VoxelFrame
extends Resource

# Vector3i -> palette index (int)
var cells: Dictionary = {}

@export var delay_ms := 100


func count() -> int:
	return cells.size()
