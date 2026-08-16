class_name VoxelFrame
extends Resource

# Vector3i -> palette index (int)
var cells: Dictionary = {}


func count() -> int:
	return cells.size()
