class_name VoxelLayer
extends Resource


var name := "Layer 1"
var visible := true
var locked := false
var frames: Array[VoxelFrame] = []


func copy_layer() -> VoxelLayer:
	var layer_copy := VoxelLayer.new()
	layer_copy.name = name
	layer_copy.visible = visible
	layer_copy.locked = locked
	layer_copy.frames.resize(frames.size())
	for index in frames.size():
		layer_copy.frames[index] = frames[index].copy_frame()
	return layer_copy
