extends "res://tests/spray_reference.gd"

# The frozen sampler, adapted to the canonical brush size input.
#
# `tests/spray_reference.gd` is the frozen historical kernel. It keeps its own
# random selection body, its own spot footprint body, and its own per-instance
# caches. It still takes the old integer radius and builds the old ball
# candidate pool, and it still gathers the local set with the old two-branch
# strategy.
#
# This adapter changes only the sampler input contract:
#
# 1. The gather reach comes from the canonical search size, not a radius.
# 2. The candidate pool is the shared brush sphere of the size, not the old
#    ball of a radius. The intentional change is that the sphere admits more
#    corner and diagonal cells than the ball of the radius with the same width.
# 3. The local set comes from the snapshot chunk walk, not a ball offset array.
#
# The random selection and the footprint body stay inherited and unchanged, so
# the adapter still proves the live sampler keeps the frozen algorithm.
#
# The three points above must match `plugins/paint/SprayTool.gd` exactly, or the
# differential compare in `tests/spray_perf.gd` reports a false failure. Re-read
# this file when the production gather or candidate filter changes.

const VoxelBrushSize := preload("res://Globals/State/Tools/VoxelBrushSize.gd")

# The search size of the next `sample_size` call. The frozen candidate filter
# reads it, because the frozen `sample` passes only its radius slot.
var search_size := 1


# Samples with a canonical search size. It maps the size to the gather reach and
# calls the frozen body with that reach, so the frozen reach and footprint body
# stay unchanged.
func sample_size(center: Vector3i, frame: VoxelFrame, context: VoxelFrame.EditContext, spot_size: int, search_size_value: int, speed: int, rng: RandomNumberGenerator, material: PackedFloat32Array) -> Array[Vector3i]:
	search_size = search_size_value
	return sample(center, frame, context, spot_size, VoxelBrushSize.reach(search_size_value), speed, rng, material)


# The frozen `sample` passes its radius slot to this filter. This adapter reads
# the canonical size instead, so the candidate pool is the shared brush sphere.
func _candidates(center: Vector3i, local: Array[Vector3i], _reach: int) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	for cell in local:
		if VoxelBrushSize.contains_sphere(search_size, cell - center):
			cells.append(cell)
	return cells


# The snapshot chunk walk that the live sampler uses. It mirrors
# `SpraySampler.local_cells`, so the candidate order matches the live one.
func _local_cells(center: Vector3i, reach: int, frame: VoxelFrame, context: VoxelFrame.EditContext) -> Array[Vector3i]:
	var min_chunk := VoxelFrame.chunk_position(center - Vector3i.ONE * reach)
	var max_chunk := VoxelFrame.chunk_position(center + Vector3i.ONE * reach)
	var limit := reach * reach
	var cells: Array[Vector3i] = []
	for x in range(min_chunk.x, max_chunk.x + 1):
		for y in range(min_chunk.y, max_chunk.y + 1):
			for z in range(min_chunk.z, max_chunk.z + 1):
				var chunk: VoxelFrame.Chunk = frame.chunks.get(Vector3i(x, y, z))
				if chunk == null:
					continue
				for cell in chunk.world_cells():
					if Vector3(cell - center).length_squared() > limit:
						continue
					if not _allows(cell, frame, context):
						continue
					cells.append(cell)
	return cells
