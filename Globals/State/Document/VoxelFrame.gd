class_name VoxelFrame
extends Resource

@export var delay_ms := 100

# Version 3 stores sparse chunk roots, one material table per chunk, and flattened octree nodes.
@export_storage var voxel_data: PackedByteArray:
	get:
		return _encode()
	set(value):
		if not value.is_empty():
			_decode(value)

const CHUNK_SIZE := 16
# `chunk_position` shifts by this, because a right shift floors toward negative
# infinity the way floor division does. It must stay `log2(CHUNK_SIZE)`, and
# `chunk_storage` fails if the two drift apart.
const CHUNK_SHIFT := 4
const STORAGE_VERSION := 3
const STORAGE_RECORD_SIZE := 3
const VERSION_2_RECORD_SIZE := 5
const VERSION_1_RECORD_SIZE := 3
# One material holds nine floats. The color alpha stays live for the mesher and the export.
const MATERIAL_STRIDE := 9
const MATERIAL_COLOR := 0
const MATERIAL_EMISSION := 4
const MATERIAL_METALLIC := 7
const MATERIAL_ROUGHNESS := 8
const DEFAULT_EMISSION := Color.BLACK
const DEFAULT_METALLIC := 0.0
const DEFAULT_ROUGHNESS := 1.0
const DIRECTIONS := [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP, Vector3i.DOWN, Vector3i.BACK, Vector3i.FORWARD]


# Build one material. A transparent color erases the voxel.
static func material(color: Color, emission: Color = DEFAULT_EMISSION, metallic: float = DEFAULT_METALLIC, roughness: float = DEFAULT_ROUGHNESS) -> PackedFloat32Array:
	return PackedFloat32Array([color.r, color.g, color.b, color.a, emission.r, emission.g, emission.b, metallic, roughness])


static func is_empty(cell_material: PackedFloat32Array) -> bool:
	return material_color(cell_material) == Color.TRANSPARENT


static func material_color(cell_material: PackedFloat32Array) -> Color:
	return Color(cell_material[MATERIAL_COLOR], cell_material[MATERIAL_COLOR + 1], cell_material[MATERIAL_COLOR + 2], cell_material[MATERIAL_COLOR + 3])


class EditContext extends RefCounted:
	var axes := 0
	var origin_twice := Vector3i.ZERO
	var selection := {}

	func expand(changes: Dictionary, frame: VoxelFrame, existing_only: bool, matching_material: Variant, job: EditJob = null) -> Dictionary:
		if axes == 0 and selection.is_empty() and not existing_only and matching_material == null:
			return changes
		var expanded := {}
		var masks: Array[int] = []
		for mask in 8:
			if (mask & ~axes) == 0:
				masks.append(mask)
		var completed := 0
		for cell: Vector3i in changes:
			for mask in masks:
				var destination := reflect(cell, mask)
				if _allows(destination, frame, existing_only, matching_material):
					expanded[destination] = changes[cell]
				completed += 1
				if job and completed % 4096 == 0 and not job.checkpoint(completed):
					return {}
		if axes == 0:
			return expanded
		# Preserve original colors where the original and reflected patterns overlap.
		for cell: Vector3i in changes:
			if _allows(cell, frame, existing_only, matching_material):
				expanded[cell] = changes[cell]
			completed += 1
			if job and completed % 4096 == 0 and not job.checkpoint(completed):
				return {}
		return expanded

	func reflect(cell: Vector3i, mask: int) -> Vector3i:
		var destination := cell
		for axis in 3:
			if mask & (1 << axis):
				destination[axis] = origin_twice[axis] - cell[axis]
		return destination

	# The reflected destination must hold the same full material as the source cell.
	func _allows(cell: Vector3i, frame: VoxelFrame, existing_only: bool, matching_material: Variant) -> bool:
		return (selection.is_empty() or selection.has(cell)) and (not existing_only or frame.has(cell)) and (matching_material == null or frame.matches(cell, matching_material))

class EditJob extends RefCounted:
	var worker_task_id := -1
	var edit_context: EditContext
	var applied_cells := {}
	# Set this when every cell of the job holds the same material. The write then
	# skips the per-chunk test for a uniform batch. Leave it null when the cells
	# can differ, or the write would treat a mixed batch as uniform.
	var applied_uniform: Variant = null
	var _label := "Preparing edit"
	var _completed := 0
	var _total := -1
	var _cancel_requested := false
	var _progress_lock := Mutex.new()

	func stage(label: String, total: int) -> void:
		_progress_lock.lock()
		_label = label
		_completed = 0
		_total = total
		_progress_lock.unlock()

	func checkpoint(completed: int) -> bool:
		_progress_lock.lock()
		_completed = completed
		var keep_running := not _cancel_requested
		_progress_lock.unlock()
		return keep_running

	func progress() -> Array:
		_progress_lock.lock()
		var result := [_label, _completed, _total]
		_progress_lock.unlock()
		return result

	func cancel() -> void:
		_progress_lock.lock()
		_cancel_requested = true
		_progress_lock.unlock()

	# Wait for the worker and retire its handle. This owns the wait and the id
	# reset only: it never cancels the job, and it never touches the operation,
	# the result, or the publication checkpoint. Main thread only. A job without
	# a worker, or one whose task was already retired, returns at once.
	func wait_for_worker() -> void:
		if worker_task_id < 0:
			return
		WorkerThreadPool.wait_for_task_completion(worker_task_id)
		worker_task_id = -1

	func apply_cells(frame: VoxelFrame, changes: Dictionary, existing_only := false, matching_material: Variant = null) -> Array[Vector3i]:
		applied_cells = edit_context.expand(changes, frame, existing_only, matching_material, self) if edit_context else changes
		if not checkpoint(0):
			return []
		return frame.set_cells(applied_cells, self, applied_uniform)

	func estimate_work(original_work: int) -> int:
		var work := original_work
		if edit_context:
			for axis in 3:
				if edit_context.axes & (1 << axis):
					work *= 2
		return work

class Chunk extends RefCounted:
	# One grid slot holds one material id. Id 0 is an empty cell, so an erase
	# leaves no hole. Each occupied cell owns its table entry, so a write
	# changes one cell. Table id k reads entry k - 1 of the material table.
	var location := Vector3i.ZERO
	var grid := PackedInt32Array()
	var materials := PackedFloat32Array()
	var occupied_count := 0
	var voxel_revision := 0
	var occupied_bounds := AABB()
	var bounds_dirty := false
	# A bulk fill points every cell at one table entry. A later single-cell write
	# must not change that shared entry, so it gives that cell its own entry and
	# leaves the shared one alone. The flag stays set, because the chunk can still
	# hold shared entries after the write.
	var shared_materials := false
	var serialized_record: Array = []
	var positions_by_color: Dictionary = {}

	func _init() -> void:
		grid.resize(VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE)

	# Flat slot for one local cell. The z axis runs slowest.
	static func cell_slot(local_cell: Vector3i) -> int:
		return local_cell.x + VoxelFrame.CHUNK_SIZE * (local_cell.y + VoxelFrame.CHUNK_SIZE * local_cell.z)

	# The first world cell of this chunk.
	func origin() -> Vector3i:
		return location * VoxelFrame.CHUNK_SIZE

	func copy() -> Chunk:
		var chunk_copy := Chunk.new()
		chunk_copy.location = location
		chunk_copy.grid = grid.duplicate()
		chunk_copy.materials = materials.duplicate()
		chunk_copy.occupied_count = occupied_count
		chunk_copy.voxel_revision = voxel_revision
		chunk_copy.occupied_bounds = occupied_bounds
		chunk_copy.bounds_dirty = bounds_dirty
		chunk_copy.shared_materials = shared_materials
		return chunk_copy

	# The material id of one world cell. A missing or empty cell returns 0.
	func material_id(cell_position: Vector3i) -> int:
		var local_cell := cell_position - origin()
		if local_cell.x < 0 or local_cell.y < 0 or local_cell.z < 0 or local_cell.x >= VoxelFrame.CHUNK_SIZE or local_cell.y >= VoxelFrame.CHUNK_SIZE or local_cell.z >= VoxelFrame.CHUNK_SIZE:
			return 0
		return grid[cell_slot(local_cell)]

	func has(cell_position: Vector3i) -> bool:
		return material_id(cell_position) > 0

	func matches(cell_position: Vector3i, cell_material: PackedFloat32Array) -> bool:
		var id := material_id(cell_position)
		if id == 0:
			return false
		var base := (id - 1) * MATERIAL_STRIDE
		for offset in MATERIAL_STRIDE:
			if materials[base + offset] != cell_material[offset]:
				return false
		return true

	# Compare by content. Two equal chunks can number their ids differently.
	func equals(other: Chunk) -> bool:
		if occupied_count != other.occupied_count:
			return false
		# Identical ids and tables are equal. This is a sufficient check only, so
		# a miss falls through to the content compare below.
		if grid == other.grid and materials == other.materials:
			return true
		for slot in grid.size():
			var id := grid[slot]
			if id == 0:
				continue
			var other_id: int = other.grid[slot]
			if other_id == 0:
				return false
			var base := (id - 1) * MATERIAL_STRIDE
			var other_base := (other_id - 1) * MATERIAL_STRIDE
			for offset in MATERIAL_STRIDE:
				if materials[base + offset] != other.materials[other_base + offset]:
					return false
		return true

	func store(cell_position: Vector3i, cell_material: PackedFloat32Array) -> void:
		var local_cell := cell_position - origin()
		var slot := cell_slot(local_cell)
		var id := grid[slot]
		if id > 0:
			var base := (id - 1) * MATERIAL_STRIDE
			var same := true
			for offset in MATERIAL_STRIDE:
				if materials[base + offset] != cell_material[offset]:
					same = false
					break
			if same:
				return
			# A bulk fill points every cell at one entry. Give this cell its own entry
			# rather than expanding the whole chunk, and leave the shared entry alone
			# so the cells that still point at it keep their material. A repaint-only
			# workload never erases, so the reclamation has to happen here or the
			# table grows with every edit.
			if shared_materials:
				materials.append_array(cell_material)
				grid[slot] = materials.size() / MATERIAL_STRIDE
				if materials.size() > occupied_count * MATERIAL_STRIDE * 2:
					_compact()
				return
			for offset in MATERIAL_STRIDE:
				materials[base + offset] = cell_material[offset]
			return
		materials.append_array(cell_material)
		grid[slot] = materials.size() / MATERIAL_STRIDE
		occupied_count += 1

	func erase(cell_position: Vector3i) -> void:
		var local_cell := cell_position - origin()
		if local_cell.x < 0 or local_cell.y < 0 or local_cell.z < 0 or local_cell.x >= VoxelFrame.CHUNK_SIZE or local_cell.y >= VoxelFrame.CHUNK_SIZE or local_cell.z >= VoxelFrame.CHUNK_SIZE:
			return
		var slot := cell_slot(local_cell)
		if grid[slot] == 0:
			return
		grid[slot] = 0
		occupied_count -= 1
		if materials.size() > occupied_count * MATERIAL_STRIDE * 2:
			_compact()

	# Apply a batch of changes whose cells all belong to this chunk. The chunk
	# origin is passed in, so no cell pays for it again.
	#
	# `copy_for_write` runs once, before the first change, and returns the chunk
	# to mutate. It returns a copy while the frame still shares this one, so a
	# batch that changes nothing never copies.
	#
	# Returns [chunk to keep, face bits of the changed cells, changed cell count].
	func apply_changes(changes: Dictionary, chunk_origin: Vector3i, copy_for_write: Callable, declared_uniform: Variant = null) -> Array:
		# A batch that covers every cell of this chunk with one material writes the
		# region at once instead of one store per cell. The dense grid then costs
		# almost nothing per cell, which is the dense equivalent of writing one
		# high node of an octree. The test is on the batch, not on the caller, so
		# any writer that covers a chunk qualifies: a large brush, a fill, a
		# paste, or an erase. A smaller footprint does not reach it, and pays the
		# per-cell path. A caller that knows its batch is uniform passes the
		# material and skips the test.
		var bulk := _uniform_batch(changes, declared_uniform)
		if bulk.size() > 0:
			return _fill_chunk(bulk, chunk_origin, copy_for_write)
		# A partial batch whose cells the caller declared share one material can
		# write one appended row for the whole batch. The hint is trusted only
		# because it is explicit, and the chunk must already share rows: on an
		# unshared chunk every cell owns its row, so the per-cell path below writes
		# in place without growing the table or forcing a compaction. An empty
		# replacement also keeps that path, so the erase semantics stay in one
		# place.
		if shared_materials and declared_uniform != null:
			var declared: PackedFloat32Array = declared_uniform
			if not VoxelFrame.is_empty(declared):
				return _apply_uniform_partial(changes, chunk_origin, copy_for_write, declared)
		var target := self
		var copied := false
		var face_bits := 0
		var changed_count := 0
		var min_cell := Vector3i.MAX
		var max_cell := Vector3i.MIN
		for cell_position: Vector3i in changes:
			var cell_material: PackedFloat32Array = changes[cell_position]
			var local := cell_position - chunk_origin
			var slot := cell_slot(local)
			var id := target.grid[slot]
			if VoxelFrame.is_empty(cell_material):
				if id == 0:
					continue
				if not copied:
					target = copy_for_write.call()
					copied = true
				target.grid[slot] = 0
				target.occupied_count -= 1
				if target.on_bounds(cell_position):
					target.bounds_dirty = true
			else:
				if id > 0:
					var base := (id - 1) * MATERIAL_STRIDE
					var same := true
					for offset in MATERIAL_STRIDE:
						if target.materials[base + offset] != cell_material[offset]:
							same = false
							break
					if same:
						continue
					if not copied:
						target = copy_for_write.call()
						copied = true
					if target.shared_materials:
						# Give this cell its own entry and leave the shared one alone.
						# Reclaim here too, because a repaint-only batch never erases.
						target.materials.append_array(cell_material)
						target.grid[slot] = target.materials.size() / MATERIAL_STRIDE
						if target.materials.size() > target.occupied_count * MATERIAL_STRIDE * 2:
							target._compact()
					else:
						for offset in MATERIAL_STRIDE:
							target.materials[base + offset] = cell_material[offset]
				else:
					if not copied:
						target = copy_for_write.call()
						copied = true
					target.materials.append_array(cell_material)
					target.grid[slot] = target.materials.size() / MATERIAL_STRIDE
					target.occupied_count += 1
				if not target.bounds_dirty:
					min_cell = Vector3i(mini(min_cell.x, local.x), mini(min_cell.y, local.y), mini(min_cell.z, local.z))
					max_cell = Vector3i(maxi(max_cell.x, local.x), maxi(max_cell.y, local.y), maxi(max_cell.z, local.z))
			face_bits |= VoxelFrame._face_bits(local)
			changed_count += 1
		# One compaction per batch instead of one per erased cell. The table never
		# grows on an erase, so the end state is the same. A chunk this batch emptied
		# needs no compaction, because the frame drops it. Only a copied target is
		# compacted, so a batch that changes nothing leaves the chunk shared.
		if changed_count > 0 and target.occupied_count > 0 and target.materials.size() > target.occupied_count * MATERIAL_STRIDE * 2:
			target._compact()
		# One bounds merge for the whole batch instead of one per cell.
		if changed_count > 0 and not target.bounds_dirty and max_cell.x >= min_cell.x:
			var batch_bounds := AABB(Vector3(chunk_origin + min_cell) - Vector3.ONE * 0.5, Vector3(max_cell - min_cell + Vector3i.ONE))
			target.occupied_bounds = target.occupied_bounds.merge(batch_bounds) if target.occupied_bounds.has_volume() else batch_bounds
		return [target, face_bits, changed_count]


	# A partial batch whose cells the caller declared share one material. The chunk
	# already shares rows, so every changed slot moves to one row appended once for
	# the batch. The batch pays one row instead of one row or one in-place write per
	# cell. Rows outside the batch stay, so a cell the batch does not touch keeps
	# its material. The row is appended only when the batch changes a cell, so a
	# repeated batch copies nothing. The caller must pass the hint only when every
	# cell holds it.
	func _apply_uniform_partial(changes: Dictionary, chunk_origin: Vector3i, copy_for_write: Callable, cell_material: PackedFloat32Array) -> Array:
		var target := self
		var copied := false
		var face_bits := 0
		var changed_count := 0
		var min_cell := Vector3i.MAX
		var max_cell := Vector3i.MIN
		var new_id := 0
		# The last id and its match are cached. A batch writes one chunk, and a
		# coherent batch visits the same row in a run, so a scalar cache removes the
		# repeated compare without a dictionary step per cell.
		var last_id := 0
		var last_same := false
		for cell_position: Vector3i in changes:
			var local := cell_position - chunk_origin
			var slot := cell_slot(local)
			var id := target.grid[slot]
			if id > 0:
				var same := false
				if id == last_id:
					same = last_same
				else:
					var base := (id - 1) * MATERIAL_STRIDE
					same = true
					for offset in MATERIAL_STRIDE:
						if target.materials[base + offset] != cell_material[offset]:
							same = false
							break
					last_id = id
					last_same = same
				if same:
					continue
			if not copied:
				target = copy_for_write.call()
				copied = true
				# One owned row for the whole batch. `append_array` copies the values,
				# so a later change to the caller's material cannot reach the table.
				target.materials.append_array(cell_material)
				new_id = target.materials.size() / MATERIAL_STRIDE
				target.shared_materials = true
			if id == 0:
				target.occupied_count += 1
			target.grid[slot] = new_id
			face_bits |= VoxelFrame._face_bits(local)
			changed_count += 1
			if not target.bounds_dirty:
				min_cell = Vector3i(mini(min_cell.x, local.x), mini(min_cell.y, local.y), mini(min_cell.z, local.z))
				max_cell = Vector3i(maxi(max_cell.x, local.x), maxi(max_cell.y, local.y), maxi(max_cell.z, local.z))
		# One compaction for the whole batch, after every changed slot moved to the
		# new row, so the new id is never used after a remap.
		if changed_count > 0 and target.occupied_count > 0 and target.materials.size() > target.occupied_count * MATERIAL_STRIDE * 2:
			target._compact()
		# One bounds merge for the whole batch. Every change here is a write, so the
		# bounds only grow.
		if changed_count > 0 and not target.bounds_dirty and max_cell.x >= min_cell.x:
			var batch_bounds := AABB(Vector3(chunk_origin + min_cell) - Vector3.ONE * 0.5, Vector3(max_cell - min_cell + Vector3i.ONE))
			target.occupied_bounds = target.occupied_bounds.merge(batch_bounds) if target.occupied_bounds.has_volume() else batch_bounds
		return [target, face_bits, changed_count]


	# The one material of a batch that covers every cell of this chunk, or an empty
	# material when the batch is partial or holds more than one material. The
	# caller buckets by chunk, so a batch of 4096 cells covers this chunk whole.
	# A caller that knows its material passes it and skips the per-cell test. The
	# coverage test stays, because a partial batch must never fill a whole chunk.
	func _uniform_batch(changes: Dictionary, declared: Variant = null) -> PackedFloat32Array:
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


	# Write one material to every cell of this chunk. The grid holds one id and the
	# table one material, so the cost does not follow the cell count. An empty
	# material removes the chunk, so the caller receives a null chunk to drop.
	func _fill_chunk(cell_material: PackedFloat32Array, chunk_origin: Vector3i, copy_for_write: Callable) -> Array:
		var cells := VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE
		if VoxelFrame.is_empty(cell_material):
			if occupied_count == 0:
				return [self, 0, 0]
			# Every occupied cell changes, and the empty ones are already empty. The
			# frame drops the whole chunk, so a copy, a grid fill, and a compaction
			# would all be discarded work. The faces that need a rebuild are the
			# extent of what was occupied.
			var bounds := get_bounds()
			var min_cell := Vector3i(bounds.position + Vector3.ONE * 0.5) - chunk_origin
			var max_cell := Vector3i(bounds.end - Vector3.ONE * 0.5) - chunk_origin
			return [null, _extent_face_bits(min_cell, max_cell), occupied_count]
		# The batch covers the chunk, so the result is one entry for every cell. A
		# chunk the bulk fill wrote already holds exactly one entry, and then the
		# answer needs no scan at all: the same material changes nothing, and any
		# other material changes every cell and touches every face. Anything else
		# needs the walk, because a chunk written cell by cell holds one entry per
		# cell and the comparison has to be by content.
		var count := 0
		var bits := 0
		if occupied_count == cells and materials.size() == MATERIAL_STRIDE:
			if materials == cell_material:
				return [self, 0, 0]
			count = cells
			bits = 63
		else:
			var changed := _changed_extent(cell_material)
			count = changed[0]
			if count == 0:
				return [self, 0, 0]
			bits = _extent_face_bits(changed[1], changed[2])
		var filled: Chunk = copy_for_write.call()
		filled.grid.fill(1)
		filled.materials = cell_material.duplicate()
		filled.occupied_count = cells
		filled.shared_materials = true
		filled.bounds_dirty = false
		filled.occupied_bounds = AABB(Vector3(chunk_origin) - Vector3.ONE * 0.5, Vector3.ONE * VoxelFrame.CHUNK_SIZE)
		return [filled, bits, count]


	# How many cells of this chunk differ from a full uniform batch, and the extent
	# of those cells. A chunk that already holds the material reports a count of
	# zero, so a repeated motion copies nothing. Each id is compared once, so the
	# walk costs a grid scan rather than a material scan per cell.
	func _changed_extent(cell_material: PackedFloat32Array) -> Array:
		var size := VoxelFrame.CHUNK_SIZE
		if occupied_count == 0:
			return [grid.size(), Vector3i.ZERO, Vector3i.ONE * (size - 1)]
		var matches := {}
		var changed := 0
		var min_cell := Vector3i.MAX
		var max_cell := Vector3i.MIN
		for slot in grid.size():
			var id := grid[slot]
			var same := false
			if id > 0:
				if not matches.has(id):
					var base := (id - 1) * MATERIAL_STRIDE
					var equal := true
					for offset in MATERIAL_STRIDE:
						if materials[base + offset] != cell_material[offset]:
							equal = false
							break
					matches[id] = equal
				same = matches[id]
			if same:
				continue
			var local := Vector3i(slot % size, (slot / size) % size, slot / (size * size))
			changed += 1
			min_cell = Vector3i(mini(min_cell.x, local.x), mini(min_cell.y, local.y), mini(min_cell.z, local.z))
			max_cell = Vector3i(maxi(max_cell.x, local.x), maxi(max_cell.y, local.y), maxi(max_cell.z, local.z))
		return [changed, min_cell, max_cell]


	# The faces a set of changed cells touches, from their extent. A bit is set when
	# a changed cell sits on that face, which is exactly when the extent reaches it.
	static func _extent_face_bits(min_cell: Vector3i, max_cell: Vector3i) -> int:
		if max_cell.x < min_cell.x:
			return 0
		var bits := 0
		for axis in 3:
			if min_cell[axis] == 0:
				bits |= 1 << (axis * 2)
			if max_cell[axis] == VoxelFrame.CHUNK_SIZE - 1:
				bits |= 1 << (axis * 2 + 1)
		return bits

	# Drop the table entries no slot uses. The grid remaps to the used ids.
	# The remap walks the ids in order, so equal chunks save equal bytes.
	func _compact() -> void:
		var used_ids: Array = []
		var seen := {}
		for slot in grid.size():
			var id := grid[slot]
			if id > 0 and not seen.has(id):
				seen[id] = true
				used_ids.append(id)
		used_ids.sort()
		var remap := PackedInt32Array()
		remap.resize(materials.size() / MATERIAL_STRIDE + 1)
		remap.fill(0)
		var next_id := 1
		for id: int in used_ids:
			remap[id] = next_id
			next_id += 1
		var compacted := PackedFloat32Array()
		compacted.resize((next_id - 1) * MATERIAL_STRIDE)
		var write := 0
		for id: int in used_ids:
			var base: int = (id - 1) * MATERIAL_STRIDE
			for offset in MATERIAL_STRIDE:
				compacted[write + offset] = materials[base + offset]
			write += MATERIAL_STRIDE
		for slot in grid.size():
			grid[slot] = remap[grid[slot]]
		materials = compacted

	func get_color(cell_position: Vector3i) -> Color:
		var id := material_id(cell_position)
		if id == 0:
			return Color.TRANSPARENT
		var base := (id - 1) * MATERIAL_STRIDE
		return Color(materials[base], materials[base + 1], materials[base + 2], materials[base + 3])

	func get_emission(cell_position: Vector3i) -> Color:
		var id := material_id(cell_position)
		if id == 0:
			return DEFAULT_EMISSION
		var base := (id - 1) * MATERIAL_STRIDE + MATERIAL_EMISSION
		return Color(materials[base], materials[base + 1], materials[base + 2])

	func get_metallic(cell_position: Vector3i) -> float:
		var id := material_id(cell_position)
		return materials[(id - 1) * MATERIAL_STRIDE + MATERIAL_METALLIC] if id > 0 else DEFAULT_METALLIC

	func get_roughness(cell_position: Vector3i) -> float:
		var id := material_id(cell_position)
		return materials[(id - 1) * MATERIAL_STRIDE + MATERIAL_ROUGHNESS] if id > 0 else DEFAULT_ROUGHNESS

	func get_material(cell_position: Vector3i) -> PackedFloat32Array:
		var id := material_id(cell_position)
		if id == 0:
			return VoxelFrame.material(Color.TRANSPARENT)
		return materials.slice((id - 1) * MATERIAL_STRIDE, id * MATERIAL_STRIDE)

	# Every occupied world cell, in grid order.
	func world_cells() -> Array[Vector3i]:
		var cell_positions: Array[Vector3i] = []
		cell_positions.resize(occupied_count)
		var written := 0
		for slot in grid.size():
			if grid[slot] > 0:
				cell_positions[written] = origin() + Vector3i(slot % VoxelFrame.CHUNK_SIZE, (slot / VoxelFrame.CHUNK_SIZE) % VoxelFrame.CHUNK_SIZE, slot / (VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE))
				written += 1
		return cell_positions

	func get_bounds() -> AABB:
		if bounds_dirty:
			var min_cell := Vector3i.MAX
			var max_cell := Vector3i.MIN
			var size := VoxelFrame.CHUNK_SIZE
			for slot in grid.size():
				if grid[slot] == 0:
					continue
				var local_cell := Vector3i(slot % size, (slot / size) % size, slot / (size * size))
				min_cell = Vector3i(mini(min_cell.x, local_cell.x), mini(min_cell.y, local_cell.y), mini(min_cell.z, local_cell.z))
				max_cell = Vector3i(maxi(max_cell.x, local_cell.x), maxi(max_cell.y, local_cell.y), maxi(max_cell.z, local_cell.z))
			if max_cell.x < min_cell.x:
				occupied_bounds = AABB()
			else:
				occupied_bounds = AABB(Vector3(origin() + min_cell) - Vector3.ONE * 0.5, Vector3(max_cell - min_cell + Vector3i.ONE))
			bounds_dirty = false
		return occupied_bounds

	# True when the cell sits on the current occupied bounds, so removing it can
	# shrink them. Only then does an erase need a full rescan.
	func on_bounds(cell_position: Vector3i) -> bool:
		var min_cell := Vector3i(occupied_bounds.position + Vector3.ONE * 0.5)
		var max_cell := Vector3i(occupied_bounds.end - Vector3.ONE * 0.5)
		return cell_position.x == min_cell.x or cell_position.y == min_cell.y or cell_position.z == min_cell.z or cell_position.x == max_cell.x or cell_position.y == max_cell.y or cell_position.z == max_cell.z

	# Extend the cached bounds with one written cell. The caller keeps the
	# bounds clean, so a batch of writes needs no rescan.
	func grow_bounds(cell_position: Vector3i) -> void:
		if bounds_dirty:
			return
		var cell_bounds := AABB(Vector3(cell_position) - Vector3.ONE * 0.5, Vector3.ONE)
		occupied_bounds = occupied_bounds.merge(cell_bounds) if occupied_bounds.has_volume() else cell_bounds

var chunks: Dictionary = {}
var _shared_chunks: Dictionary = {}


func count() -> int:
	var cell_count := 0
	for chunk in chunks.values():
		cell_count += chunk.occupied_count
	return cell_count


# The first cell of the chunk that holds this cell. A right shift floors toward
# negative infinity, which is what floor division does, so it matches
# `floori(x / CHUNK_SIZE)` for negative cells too. `CHUNK_SHIFT` carries the
# power-of-two assumption, and `chunk_storage` checks it against `CHUNK_SIZE`.
static func chunk_position(cell_position: Vector3i) -> Vector3i:
	return Vector3i(cell_position.x >> CHUNK_SHIFT, cell_position.y >> CHUNK_SHIFT, cell_position.z >> CHUNK_SHIFT)


func clear() -> void:
	chunks = {}
	_shared_chunks = {}


func has(cell_position: Vector3i) -> bool:
	var chunk: Chunk = chunks.get(chunk_position(cell_position))
	return chunk != null and chunk.has(cell_position)


func get_color(cell_position: Vector3i) -> Color:
	var chunk: Chunk = chunks.get(chunk_position(cell_position))
	return chunk.get_color(cell_position) if chunk else Color.TRANSPARENT


func get_emission(cell_position: Vector3i) -> Color:
	var chunk: Chunk = chunks.get(chunk_position(cell_position))
	return chunk.get_emission(cell_position) if chunk else DEFAULT_EMISSION


func get_metallic(cell_position: Vector3i) -> float:
	var chunk: Chunk = chunks.get(chunk_position(cell_position))
	return chunk.get_metallic(cell_position) if chunk else DEFAULT_METALLIC


func get_roughness(cell_position: Vector3i) -> float:
	var chunk: Chunk = chunks.get(chunk_position(cell_position))
	return chunk.get_roughness(cell_position) if chunk else DEFAULT_ROUGHNESS


func get_material(cell_position: Vector3i) -> PackedFloat32Array:
	var chunk: Chunk = chunks.get(chunk_position(cell_position))
	return chunk.get_material(cell_position) if chunk else material(Color.TRANSPARENT)


# Compare the whole stored material. One voxel holds the color, the emission, the metallic, and the roughness.
func matches(cell_position: Vector3i, cell_material: PackedFloat32Array) -> bool:
	var chunk: Chunk = chunks.get(chunk_position(cell_position))
	return chunk != null and chunk.matches(cell_position, cell_material)


# One write supplies the whole material. A transparent color erases the voxel.
func set_cell(cell_position: Vector3i, cell_material: PackedFloat32Array) -> void:
	var chunk_location := chunk_position(cell_position)
	var chunk: Chunk = chunks.get(chunk_location)
	var erased := is_empty(cell_material)
	var id: int = chunk.material_id(cell_position) if chunk else 0
	if erased:
		if id == 0:
			return
	elif id > 0 and chunk.matches(cell_position, cell_material):
		return
	if chunk == null:
		chunk = Chunk.new()
		chunk.location = chunk_location
		chunks[chunk_location] = chunk
	elif _shared_chunks.has(chunk_location):
		chunk = chunk.copy()
		chunks[chunk_location] = chunk
		_shared_chunks.erase(chunk_location)
	if erased:
		chunk.erase(cell_position)
		if chunk.on_bounds(cell_position):
			chunk.bounds_dirty = true
	else:
		chunk.store(cell_position, cell_material)
		chunk.grow_bounds(cell_position)
	chunk.voxel_revision += 1
	chunk.serialized_record.clear()
	chunk.positions_by_color.clear()
	if chunk.occupied_count == 0:
		chunks.erase(chunk_location)


# Batch writes copy and invalidate each changed chunk once.
# The result lists every chunk that needs a new surface: each changed chunk and
# each neighbor that meshes across the changed faces. A mesher reads one cell
# beyond its chunk, so only cells on a chunk face affect a neighbor.
func set_cells(cell_materials: Dictionary, edit_job: EditJob = null, uniform_material: Variant = null) -> Array[Vector3i]:
	var changes_by_chunk := {}
	var completed := 0
	# Hold the current batch in a local. A brush stamp writes its cells in a
	# spatially coherent order, so almost every cell lands in the chunk the last
	# cell used and needs no dictionary lookup for its batch.
	var last_location := Vector3i.MAX
	var last_batch: Dictionary = {}
	for cell_position: Vector3i in cell_materials:
		var chunk_location := chunk_position(cell_position)
		if chunk_location != last_location:
			last_location = chunk_location
			last_batch = changes_by_chunk.get(chunk_location, {})
			changes_by_chunk[chunk_location] = last_batch
		last_batch[cell_position] = cell_materials[cell_position]
		completed += 1
		if edit_job and completed % 4096 == 0 and not edit_job.checkpoint(0):
			return []
	var changed_chunks: Array[Vector3i] = []
	completed = 0
	for chunk_location: Vector3i in changes_by_chunk:
		if edit_job and not edit_job.checkpoint(completed):
			return []
		var chunk: Chunk = chunks.get(chunk_location)
		var chunk_changes: Dictionary = changes_by_chunk[chunk_location]
		var chunk_origin := chunk_location * CHUNK_SIZE
		# The batch copies the chunk once, before its first change. A batch that
		# changes nothing leaves the frame sharing the chunk.
		var copy_for_write := func() -> Chunk:
			var target: Chunk = null
			if chunk == null:
				target = Chunk.new()
			elif _shared_chunks.has(chunk_location):
				target = chunk.copy()
			else:
				target = chunk
			target.location = chunk_location
			chunks[chunk_location] = target
			_shared_chunks.erase(chunk_location)
			return target
		var start := chunk if chunk else Chunk.new()
		var outcome: Array = start.apply_changes(chunk_changes, chunk_origin, copy_for_write, uniform_material)
		var face_bits: int = outcome[1]
		completed += chunk_changes.size()
		if outcome[2] == 0:
			continue
		chunk = outcome[0]
		if chunk == null:
			# The batch erased every cell of the chunk, so the frame drops it. No
			# copy was made, so the shared marker must go with the chunk. Otherwise
			# the marker outlives the removal until the next capture or restore.
			chunks.erase(chunk_location)
			_shared_chunks.erase(chunk_location)
		else:
			chunk.voxel_revision += 1
			chunk.serialized_record.clear()
			chunk.positions_by_color.clear()
			if chunk.occupied_count == 0:
				chunks.erase(chunk_location)
			else:
				# A clean batch needs no rescan. Only an erase on the bounds sets the flag.
				chunk.get_bounds()
		changed_chunks.append(chunk_location)
		for offset in _touched_neighbors(face_bits):
			changed_chunks.append(chunk_location + offset)
	if edit_job:
		edit_job.checkpoint(completed)
	return changed_chunks


# One bit per chunk face: negative then positive for each axis.
static func _face_bits(local_cell: Vector3i) -> int:
	var bits := 0
	for axis in 3:
		if local_cell[axis] == 0:
			bits |= 1 << (axis * 2)
		if local_cell[axis] == CHUNK_SIZE - 1:
			bits |= 1 << (axis * 2 + 1)
	return bits


# Chunk offsets relative to the cell's own chunk whose mesher reads this cell.
# A mesher reads one cell beyond its chunk, so only face and corner cells cross over.
static func crosstalk_chunks(cell_position: Vector3i) -> Array[Vector3i]:
	var local_cell := cell_position - chunk_position(cell_position) * CHUNK_SIZE
	return _touched_neighbors(_face_bits(local_cell))


# A neighbor is affected when every crossing axis of its offset touches a changed face.
static func _touched_neighbors(face_bits: int) -> Array[Vector3i]:
	var touched: Array[Vector3i] = []
	if face_bits == 0:
		return touched
	for offset in _crosstalk_offsets():
		var crosses_changed_face := true
		for axis in 3:
			var direction: int = offset[axis]
			if direction != 0 and (face_bits & (1 << (axis * 2 + (1 if direction > 0 else 0)))) == 0:
				crosses_changed_face = false
				break
		if crosses_changed_face:
			touched.append(offset)
	return touched


static var _crosstalk_offsets_cache: Array[Vector3i] = []


# Every chunk offset a mesher can read across, including diagonal corners.
static func _crosstalk_offsets() -> Array[Vector3i]:
	if _crosstalk_offsets_cache.is_empty():
		for z in range(-1, 2):
			for y in range(-1, 2):
				for x in range(-1, 2):
					var offset := Vector3i(x, y, z)
					if offset != Vector3i.ZERO:
						_crosstalk_offsets_cache.append(offset)
	return _crosstalk_offsets_cache


func capture() -> Dictionary:
	_shared_chunks = chunks.duplicate()
	return chunks.duplicate()


func restore(chunk_snapshot: Dictionary) -> void:
	chunks = chunk_snapshot.duplicate()
	_shared_chunks = chunks.duplicate()


func copy_frame() -> VoxelFrame:
	var frame_copy := VoxelFrame.new()
	frame_copy.restore(capture())
	frame_copy.delay_ms = delay_ms
	return frame_copy


func positions() -> Array[Vector3i]:
	var cell_positions: Array[Vector3i] = []
	for chunk in chunks.values():
		cell_positions.append_array(chunk.world_cells())
	return cell_positions


func cells_with_color(color: Color) -> Array[Vector3i]:
	var matching_positions: Array[Vector3i] = []
	for chunk in chunks.values():
		if chunk.positions_by_color.is_empty():
			for cell_position in chunk.world_cells():
				var cell_color: Color = chunk.get_color(cell_position)
				if not chunk.positions_by_color.has(cell_color):
					chunk.positions_by_color[cell_color] = []
				chunk.positions_by_color[cell_color].append(cell_position)
		for cell_position in chunk.positions_by_color.get(color, []):
			matching_positions.append(cell_position)
	return matching_positions


func get_bounds() -> AABB:
	var frame_bounds := AABB()
	for chunk in chunks.values():
		var chunk_bounds: AABB = chunk.get_bounds()
		frame_bounds = frame_bounds.merge(chunk_bounds) if frame_bounds.has_volume() else chunk_bounds
	return frame_bounds


func _encode() -> PackedByteArray:
	return var_to_bytes(storage_data())


func storage_data() -> Array:
	var serialized_chunks: Array = []
	for chunk_location in chunks:
		var chunk: Chunk = chunks[chunk_location]
		if chunk.serialized_record.size() != STORAGE_RECORD_SIZE:
			chunk.serialized_record = _encode_chunk(chunk, chunk_location)
		serialized_chunks.append(chunk.serialized_record)
	return [STORAGE_VERSION, serialized_chunks]


# A record holds one material table and one octree of material ids. Id 0 is empty.
# The table keeps one entry per distinct material, so a uniform chunk stays small.
static func _encode_chunk(chunk: Chunk, chunk_location: Vector3i) -> Array:
	var material_table := material(Color.TRANSPARENT)
	var material_ids := {}
	material_ids[material_table.slice(0, MATERIAL_STRIDE)] = 0
	var cell_ids := PackedInt32Array()
	cell_ids.resize(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE)
	for slot in chunk.grid.size():
		var id := chunk.grid[slot]
		if id == 0:
			continue
		var cell_material := chunk.materials.slice((id - 1) * MATERIAL_STRIDE, id * MATERIAL_STRIDE)
		var material_id: int = material_ids.get(cell_material, -1)
		if material_id < 0:
			material_id = material_table.size() / MATERIAL_STRIDE
			material_ids[cell_material] = material_id
			material_table.append_array(cell_material)
		cell_ids[slot] = material_id
	var octree_nodes := PackedInt32Array()
	_encode_region(cell_ids, Vector3i.ZERO, CHUNK_SIZE, octree_nodes)
	return [chunk_location, material_table, octree_nodes]


static func _encode_region(cell_value_ids: PackedInt32Array, region_origin: Vector3i, region_size: int, octree_nodes: PackedInt32Array) -> void:
	var region_value_id := cell_value_ids[region_origin.x + CHUNK_SIZE * (region_origin.y + CHUNK_SIZE * region_origin.z)]
	var is_uniform := true
	for z in range(region_origin.z, region_origin.z + region_size):
		for y in range(region_origin.y, region_origin.y + region_size):
			for x in range(region_origin.x, region_origin.x + region_size):
				if cell_value_ids[x + CHUNK_SIZE * (y + CHUNK_SIZE * z)] != region_value_id:
					is_uniform = false
		if not is_uniform:
			break
	if is_uniform:
		octree_nodes.append(region_value_id)
		return
	octree_nodes.append(-1)
	var child_size := region_size >> 1
	for child_index in 8:
		var child_offset := Vector3i(child_index & 1, (child_index >> 1) & 1, (child_index >> 2) & 1) * child_size
		_encode_region(cell_value_ids, region_origin + child_offset, child_size, octree_nodes)


func _decode(encoded_voxels: PackedByteArray) -> void:
	var serialized_frame: Variant = bytes_to_var(encoded_voxels)
	if validate_storage(serialized_frame) < 0:
		push_error("Invalid voxel storage")
		return
	restore_storage(serialized_frame)


# Call only after validate_storage succeeds for the complete document.
func restore_storage(serialized_frame: Array) -> void:
	var version: int = serialized_frame[0]
	var restored_chunks := {}
	for serialized_chunk in serialized_frame[1]:
		var chunk_location: Vector3i = serialized_chunk[0]
		var chunk := Chunk.new()
		chunk.location = chunk_location
		var chunk_origin := chunk_location * CHUNK_SIZE
		var octree_nodes: PackedInt32Array = serialized_chunk[serialized_chunk.size() - 1]
		if version == STORAGE_VERSION:
			_decode_materials(octree_nodes, [0], serialized_chunk[1], chunk_origin, CHUNK_SIZE, chunk)
		else:
			var emission_table := PackedColorArray()
			var finish_table := PackedColorArray()
			if version == 2:
				emission_table = serialized_chunk[2]
				finish_table = serialized_chunk[3]
			_decode_region(octree_nodes, [0], serialized_chunk[1], emission_table, finish_table, chunk_origin, CHUNK_SIZE, chunk)
		chunk.bounds_dirty = true
		if version == STORAGE_VERSION:
			chunk.serialized_record = serialized_chunk
		restored_chunks[chunk_location] = chunk
	restore(restored_chunks)


const MAX_STORED_VOXELS := 4 * 1024 * 1024
const MAX_STORED_CHUNKS := 65536
const MAX_CHUNK_COORDINATE := 65535


# Count occupied leaves before expanding any chunk into voxel dictionaries.
static func validate_storage(data: Variant, voxel_limit := MAX_STORED_VOXELS) -> int:
	if not data is Array or data.size() != 2 or not data[0] is int or data[0] < 1 or data[0] > STORAGE_VERSION or not data[1] is Array:
		return -1
	if data[1].size() > MAX_STORED_CHUNKS:
		return -1
	var version: int = data[0]
	var locations := {}
	var occupied := 0
	for record in data[1]:
		if not _valid_record(record, version):
			return -1
		var location: Vector3i = record[0]
		if absi(location.x) > MAX_CHUNK_COORDINATE or absi(location.y) > MAX_CHUNK_COORDINATE or absi(location.z) > MAX_CHUNK_COORDINATE or locations.has(location):
			return -1
		locations[location] = true
		var value_count := -1
		if version == STORAGE_VERSION:
			var material_table: PackedFloat32Array = record[1]
			if not _valid_material_values(material_table):
				return -1
			value_count = material_table.size() / MATERIAL_STRIDE
		else:
			var color_table: PackedColorArray = record[1]
			if not _valid_colors(color_table):
				return -1
			var emission_table := PackedColorArray()
			var finish_table := PackedColorArray()
			if version == 2:
				emission_table = record[2]
				finish_table = record[3]
				if not _valid_material_table(emission_table, finish_table):
					return -1
			value_count = color_table.size() * (emission_table.size() + 1)
		var nodes: PackedInt32Array = record[record.size() - 1]
		if nodes.is_empty() or nodes.size() > 4681:
			return -1
		var cursor := [0]
		var chunk_count := _validate_region(nodes, cursor, value_count, CHUNK_SIZE)
		if chunk_count < 0 or cursor[0] != nodes.size():
			return -1
		occupied += chunk_count
		if occupied > voxel_limit:
			return -1
	return occupied


static func _valid_record(record: Variant, version: int) -> bool:
	var record_size := STORAGE_RECORD_SIZE if version == STORAGE_VERSION else (VERSION_2_RECORD_SIZE if version == 2 else VERSION_1_RECORD_SIZE)
	if not record is Array or record.size() != record_size or not record[0] is Vector3i:
		return false
	if version == STORAGE_VERSION:
		return record[1] is PackedFloat32Array and record[2] is PackedInt32Array
	if version == 2:
		return record[1] is PackedColorArray and record[2] is PackedColorArray and record[3] is PackedColorArray and record[4] is PackedInt32Array
	return record[1] is PackedColorArray and record[2] is PackedInt32Array


# The empty entry holds id 0. Every other entry holds a color.
static func _valid_colors(color_table: PackedColorArray) -> bool:
	if color_table.is_empty() or color_table.size() > 4097 or color_table[0] != Color.TRANSPARENT:
		return false
	for color in color_table:
		if not is_finite(color.r) or not is_finite(color.g) or not is_finite(color.b) or not is_finite(color.a):
			return false
		if color.r < 0.0 or color.r > 1.0 or color.g < 0.0 or color.g > 1.0 or color.b < 0.0 or color.b > 1.0 or color.a < 0.0 or color.a > 1.0:
			return false
	return true


# The empty entry holds id 0. Every other entry holds nine floats in 0 through 1.
static func _valid_material_values(material_table: PackedFloat32Array) -> bool:
	if material_table.size() < MATERIAL_STRIDE or material_table.size() > 4097 * MATERIAL_STRIDE or material_table.size() % MATERIAL_STRIDE != 0:
		return false
	if not is_empty(material_table.slice(0, MATERIAL_STRIDE)):
		return false
	for value in material_table:
		if not is_finite(value) or value < 0.0 or value > 1.0:
			return false
	return true


# Emission stores the glow color. Finish stores metallic and roughness. Alpha is unused.
static func _valid_material_table(emission_table: PackedColorArray, finish_table: PackedColorArray) -> bool:
	if emission_table.size() != finish_table.size() or emission_table.size() > 4096:
		return false
	for index in emission_table.size():
		var emission: Color = emission_table[index]
		var finish: Color = finish_table[index]
		for value in [emission.r, emission.g, emission.b, finish.r, finish.g]:
			if not is_finite(value) or value < 0.0 or value > 1.0:
				return false
	return true


static func _validate_region(nodes: PackedInt32Array, cursor: Array, value_count: int, size: int) -> int:
	if cursor[0] >= nodes.size():
		return -1
	var value_id := nodes[cursor[0]]
	cursor[0] += 1
	if value_id >= 0:
		return (0 if value_id == 0 else size * size * size) if value_id < value_count else -1
	if value_id != -1 or size == 1:
		return -1
	var occupied := 0
	for child in 8:
		var child_count := _validate_region(nodes, cursor, value_count, size >> 1)
		if child_count < 0:
			return -1
		occupied += child_count
	return occupied


# Version 1 stores color ids alone. Version 2 packs a color id and a material id.
static func _decode_region(octree_nodes: PackedInt32Array, node_cursor: Array, color_table: PackedColorArray, emission_table: PackedColorArray, finish_table: PackedColorArray, region_origin: Vector3i, region_size: int, chunk: Chunk) -> void:
	var cell_value_id := octree_nodes[node_cursor[0]]
	node_cursor[0] += 1
	if cell_value_id == 0:
		return
	if cell_value_id > 0:
		var material_count := emission_table.size() + 1
		var cell_color: Color = color_table[floori(cell_value_id / float(material_count))]
		var finish_slot := cell_value_id % material_count
		var cell_material := material(cell_color)
		if finish_slot != 0:
			var finish: Color = finish_table[finish_slot - 1]
			cell_material = material(cell_color, emission_table[finish_slot - 1], finish.r, finish.g)
		_fill_cells(chunk, region_origin, region_size, cell_material)
		return
	var child_size := region_size >> 1
	for child_index in 8:
		var child_offset := Vector3i(child_index & 1, (child_index >> 1) & 1, (child_index >> 2) & 1) * child_size
		_decode_region(octree_nodes, node_cursor, color_table, emission_table, finish_table, region_origin + child_offset, child_size, chunk)


# Version 3 stores one material id per cell. Every cell gets its own table
# entry, so a later write changes one cell at a time.
static func _decode_materials(octree_nodes: PackedInt32Array, node_cursor: Array, material_table: PackedFloat32Array, region_origin: Vector3i, region_size: int, chunk: Chunk) -> void:
	var material_id := octree_nodes[node_cursor[0]]
	node_cursor[0] += 1
	if material_id == 0:
		return
	if material_id > 0:
		var cell_material := material_table.slice(material_id * MATERIAL_STRIDE, (material_id + 1) * MATERIAL_STRIDE)
		_fill_cells(chunk, region_origin, region_size, cell_material)
		return
	var child_size := region_size >> 1
	for child_index in 8:
		var child_offset := Vector3i(child_index & 1, (child_index >> 1) & 1, (child_index >> 2) & 1) * child_size
		_decode_materials(octree_nodes, node_cursor, material_table, region_origin + child_offset, child_size, chunk)


# Store one material for every cell of a uniform octree region.
static func _fill_cells(chunk: Chunk, region_origin: Vector3i, region_size: int, cell_material: PackedFloat32Array) -> void:
	var local_origin := region_origin - chunk.origin()
	var z_step := CHUNK_SIZE * CHUNK_SIZE
	var y_step := CHUNK_SIZE
	for z in range(local_origin.z, local_origin.z + region_size):
		var z_base := z * z_step
		for y in range(local_origin.y, local_origin.y + region_size):
			var row_start := z_base + y * y_step + local_origin.x
			for x in range(local_origin.x, local_origin.x + region_size):
				chunk.materials.append_array(cell_material)
				chunk.grid[row_start + (x - local_origin.x)] = chunk.materials.size() / MATERIAL_STRIDE
				chunk.occupied_count += 1
