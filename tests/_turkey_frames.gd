extends SceneTree


func _init() -> void:
	var document := VoxelDocument.load_file("res://LVE-prototypes/Turkey.lve")
	print("frames=%d" % document.active_layer().frames.size())
	for index in document.active_layer().frames.size():
		var frame: VoxelFrame = document.active_layer().frames[index]
		var cells := 0
		for location: Vector3i in frame.chunks:
			var chunk: VoxelFrame.Chunk = frame.chunks[location]
			var rows = chunk.occupancy_rows()
			for row in rows.masks.size():
				cells += _bits(rows.masks[row])
		print("frame %d chunks=%d cells=%d bounds=%s" % [index, frame.chunks.size(), cells, frame.get_bounds()])
	quit()


func _bits(value: int) -> int:
	var total := 0
	while value != 0:
		value &= value - 1
		total += 1
	return total
