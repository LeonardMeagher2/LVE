extends RefCounted


static func reference_signature(active_frame: VoxelFrame, chunk_location: Vector3i, smooth_normals: bool) -> String:
	var surface_key := "smooth/" if smooth_normals else "flat/"
	for offset in VoxelMeshBuilder.neighbor_offsets(smooth_normals):
		var chunk: VoxelFrame.Chunk = active_frame.chunks.get(chunk_location + offset)
		if chunk:
			var content := chunk.content_key()
			surface_key += "%s:%s/" % [content[0], content[1]]
		else:
			surface_key += "0/"
	return surface_key


static func decode(key: PackedInt64Array, smooth_normals: bool) -> String:
	var text := "smooth/" if smooth_normals else "flat/"
	var index := 1
	while index + 1 < key.size():
		if key[index] == 0:
			text += "0/"
		else:
			text += "%s:%s/" % [key[index], key[index + 1]]
		index += 2
	return text
