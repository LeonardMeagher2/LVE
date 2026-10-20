extends RefCounted

# Frozen copy of the erase mutation and compaction algorithm, taken before the
# shared sentinel, the whole-chunk removal, and the deferred compaction replaced
# it. The frozen functions own the batch loop, the chunk write, the whole-chunk
# removal, and the compaction.
#
# This is not a fully independent implementation. It reuses production helpers
# that this unit did not change: `VoxelFrame.chunk_position`, `Chunk.cell_slot`,
# `VoxelFrame._face_bits`, `VoxelFrame._touched_neighbors`, `Chunk.on_bounds`,
# `Chunk.get_bounds`, and the chunk storage fields. Re-read this file when any of
# those helpers changes.
#
# The frozen batch path handles transparent batches alone, which is what the erase
# job writes. A batch that holds any other material is rejected, because the store
# branch is not part of the frozen algorithm. `apply_cells` covers a batch of any
# materials through the single-cell path, which this unit did not change.


# An independent oracle for a batch of any materials: apply each change through
# the single-cell path. Erasing is commutative and a single-cell write is
# idempotent, so the order does not matter.
static func apply_cells(frame: VoxelFrame, changes: Dictionary) -> void:
	for cell_position: Vector3i in changes:
		frame.set_cell(cell_position, changes[cell_position])


static func prepare_changes(selection_mask: Dictionary) -> Dictionary:
	var changes := {}
	for cell_position in selection_mask:
		changes[cell_position] = VoxelFrame.material(Color.TRANSPARENT)
	return changes


# The old full path: prepare one material per cell, then write the batch.
static func erase(frame: VoxelFrame, selection_mask: Dictionary, uniform_material: Variant = null) -> Array[Vector3i]:
	return set_cells(frame, prepare_changes(selection_mask), uniform_material)


static func set_cells(frame: VoxelFrame, cell_materials: Dictionary, uniform_material: Variant = null) -> Array[Vector3i]:
	var changes_by_chunk := {}
	var last_location := Vector3i.MAX
	var last_batch: Dictionary = {}
	for cell_position: Vector3i in cell_materials:
		var chunk_location := VoxelFrame.chunk_position(cell_position)
		if chunk_location != last_location:
			last_location = chunk_location
			last_batch = changes_by_chunk.get(chunk_location, {})
			changes_by_chunk[chunk_location] = last_batch
		last_batch[cell_position] = cell_materials[cell_position]
	var changed_chunks: Array[Vector3i] = []
	for chunk_location: Vector3i in changes_by_chunk:
		var chunk: VoxelFrame.Chunk = frame.chunks.get(chunk_location)
		var chunk_changes: Dictionary = changes_by_chunk[chunk_location]
		var chunk_origin := chunk_location * VoxelFrame.CHUNK_SIZE
		var copy_for_write := func() -> VoxelFrame.Chunk:
			var target: VoxelFrame.Chunk = null
			if chunk == null:
				target = VoxelFrame.Chunk.new()
			elif frame._shared_chunks.has(chunk_location):
				target = chunk.copy()
			else:
				target = chunk
			target.location = chunk_location
			frame.chunks[chunk_location] = target
			frame._shared_chunks.erase(chunk_location)
			return target
		var start: VoxelFrame.Chunk = chunk if chunk else VoxelFrame.Chunk.new()
		var outcome: Array = apply_changes(start, chunk_changes, chunk_origin, copy_for_write, uniform_material)
		var face_bits: int = outcome[1]
		if outcome[2] == 0:
			continue
		chunk = outcome[0]
		chunk.voxel_revision += 1
		chunk.serialized_record.clear()
		chunk.positions_by_color.clear()
		if chunk.occupied_count == 0:
			frame.chunks.erase(chunk_location)
		else:
			chunk.get_bounds()
		changed_chunks.append(chunk_location)
		for offset in VoxelFrame._touched_neighbors(face_bits):
			changed_chunks.append(chunk_location + offset)
	return changed_chunks


static func apply_changes(chunk: VoxelFrame.Chunk, changes: Dictionary, chunk_origin: Vector3i, copy_for_write: Callable, declared_uniform: Variant = null) -> Array:
	var bulk := uniform_batch(chunk, changes, declared_uniform)
	if bulk.size() > 0:
		return fill_chunk(chunk, bulk, chunk_origin, copy_for_write)
	var target := chunk
	var copied := false
	var face_bits := 0
	var changed_count := 0
	var min_cell := Vector3i.MAX
	var max_cell := Vector3i.MIN
	for cell_position: Vector3i in changes:
		var cell_material: PackedFloat32Array = changes[cell_position]
		if not VoxelFrame.is_empty(cell_material):
			push_error("the erase reference only handles transparent batches")
			continue
		var local := cell_position - chunk_origin
		var slot := VoxelFrame.Chunk.cell_slot(local)
		var id := target.grid[slot]
		if id == 0:
			continue
		if not copied:
			target = copy_for_write.call()
			copied = true
		target.grid[slot] = 0
		target.occupied_count -= 1
		if target.on_bounds(cell_position):
			target.bounds_dirty = true
		if target.materials.size() > target.occupied_count * VoxelFrame.MATERIAL_STRIDE * 2:
			old_compact(target)
		face_bits |= VoxelFrame._face_bits(local)
		changed_count += 1
	if changed_count > 0 and not target.bounds_dirty and max_cell.x >= min_cell.x:
		var batch_bounds := AABB(Vector3(chunk_origin + min_cell) - Vector3.ONE * 0.5, Vector3(max_cell - min_cell + Vector3i.ONE))
		target.occupied_bounds = target.occupied_bounds.merge(batch_bounds) if target.occupied_bounds.has_volume() else batch_bounds
	return [target, face_bits, changed_count]


static func uniform_batch(chunk: VoxelFrame.Chunk, changes: Dictionary, declared: Variant = null) -> PackedFloat32Array:
	var cells := VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE
	if changes.size() != cells:
		return PackedFloat32Array()
	if declared != null:
		return declared
	var single := PackedFloat32Array()
	for cell_position: Vector3i in changes:
		var cell_material: PackedFloat32Array = changes[cell_position]
		if single.is_empty():
			single = cell_material
		elif cell_material != single:
			return PackedFloat32Array()
	return single


# The old empty-branch: copy the chunk, zero the grid, compact the table. The
# caller then removes the emptied chunk from the frame.
static func fill_chunk(chunk: VoxelFrame.Chunk, cell_material: PackedFloat32Array, chunk_origin: Vector3i, copy_for_write: Callable) -> Array:
	if not VoxelFrame.is_empty(cell_material):
		push_error("the erase reference only handles transparent batches")
		return [chunk, 0, 0]
	if chunk.occupied_count == 0:
		return [chunk, 0, 0]
	var removed := chunk.occupied_count
	var bounds := chunk.get_bounds()
	var emptied: VoxelFrame.Chunk = copy_for_write.call()
	emptied.grid.fill(0)
	emptied.occupied_count = 0
	old_compact(emptied)
	var min_cell := Vector3i(bounds.position + Vector3.ONE * 0.5) - chunk_origin
	var max_cell := Vector3i(bounds.end - Vector3.ONE * 0.5) - chunk_origin
	return [emptied, VoxelFrame.Chunk._extent_face_bits(min_cell, max_cell), removed]


# Drop the table entries no slot uses. The grid remaps to the used ids.
static func old_compact(chunk: VoxelFrame.Chunk) -> void:
	var used_ids: Array = []
	var seen := {}
	for slot in chunk.grid.size():
		var id := chunk.grid[slot]
		if id > 0 and not seen.has(id):
			seen[id] = true
			used_ids.append(id)
	used_ids.sort()
	var remap := PackedInt32Array()
	remap.resize(chunk.materials.size() / VoxelFrame.MATERIAL_STRIDE + 1)
	remap.fill(0)
	var next_id := 1
	for id: int in used_ids:
		remap[id] = next_id
		next_id += 1
	var compacted := PackedFloat32Array()
	compacted.resize((next_id - 1) * VoxelFrame.MATERIAL_STRIDE)
	var write := 0
	for id: int in used_ids:
		var base: int = (id - 1) * VoxelFrame.MATERIAL_STRIDE
		for offset in VoxelFrame.MATERIAL_STRIDE:
			compacted[write + offset] = chunk.materials[base + offset]
		write += VoxelFrame.MATERIAL_STRIDE
	for slot in chunk.grid.size():
		chunk.grid[slot] = remap[chunk.grid[slot]]
	chunk.materials = compacted
