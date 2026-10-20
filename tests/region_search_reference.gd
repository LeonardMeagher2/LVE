extends RefCounted

# Frozen copy of the region search that the fill job ran before the shared helper
# replaced it. The search algorithm itself is frozen here: the pending list, the
# neighbor order, the visited set, the mask test, and the checkpoint positions.
#
# This is not a fully independent implementation. It reuses production helpers
# that this unit did not change, which are also the specification the optimized
# search must agree with: `VoxelFrame.chunk_position`, `VoxelFrame.DIRECTIONS`,
# `VoxelFrame.matches`, `Chunk.matches`, and `Chunk.world_cells`. Re-read this file
# when any of those helpers changes.
#
# The frozen search has no seed test. The original job added the seed to its result
# without one, because the caller validates the seed first. The shared helper adds
# that test, so an empty seed differs by design and the parity test states it.


static func find(result: Dictionary, frame: VoxelFrame, seed_cell: Vector3i, target_material: PackedFloat32Array, connected: bool, value: Variant = true, selection_mask: Dictionary = {}, job: VoxelFrame.EditJob = null) -> bool:
	if frame == null:
		return true
	if connected:
		return _find_connected(result, frame, seed_cell, target_material, value, selection_mask, job)
	return _find_occupied(result, frame, target_material, value, selection_mask, job)


static func _find_connected(result: Dictionary, frame: VoxelFrame, seed_cell: Vector3i, target_material: PackedFloat32Array, value: Variant, selection_mask: Dictionary, job: VoxelFrame.EditJob) -> bool:
	var pending: Array[Vector3i] = [seed_cell]
	result[seed_cell] = value
	var examined := 0
	while not pending.is_empty():
		var cell_position: Vector3i = pending.pop_back()
		for direction in VoxelFrame.DIRECTIONS:
			var neighbor: Vector3i = cell_position + direction
			if result.has(neighbor) or (not selection_mask.is_empty() and not selection_mask.has(neighbor)):
				continue
			if frame.matches(neighbor, target_material):
				result[neighbor] = value
				pending.append(neighbor)
		examined += 1
		if job and examined % 4096 == 0 and not job.checkpoint(result.size()):
			return false
	return true


static func _find_occupied(result: Dictionary, frame: VoxelFrame, target_material: PackedFloat32Array, value: Variant, selection_mask: Dictionary, job: VoxelFrame.EditJob) -> bool:
	var examined := 0
	for chunk in frame.chunks.values():
		for cell_position in chunk.world_cells():
			if chunk.matches(cell_position, target_material) and (selection_mask.is_empty() or selection_mask.has(cell_position)):
				result[cell_position] = value
			examined += 1
			if job and examined % 4096 == 0 and not job.checkpoint(examined):
				return false
	return true
