extends RefCounted

# Test-only copy of the legacy String surface key. It is the equality reference
# for the packed key, so the two must agree for every state. Keep its neighbor
# order and content in step with `VoxelRenderer._signature`.

static func legacy_signature(active_frame: VoxelFrame, chunk_location: Vector3i, smooth_normals: bool) -> String:
	var surface_key := "smooth/" if smooth_normals else "flat/"
	for offset in VoxelMeshBuilder.neighbor_offsets(smooth_normals):
		var chunk: VoxelFrame.Chunk = active_frame.chunks.get(chunk_location + offset)
		surface_key += "%s:%s/" % [chunk.get_instance_id(), chunk.voxel_revision] if chunk else "0/"
	return surface_key


# Decode a packed key into the legacy text, so a test compares the two forms.
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
