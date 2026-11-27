class_name VoxelFrame
extends Resource


@export_range(1, 1000, 1) var delay_ms := 100


@export_storage var voxel_data: PackedByteArray:
	get:
		return _encode()
	set(value):
		if not value.is_empty():
			_decode(value)


const CHUNK_SIZE := 16


const CHUNK_SHIFT := 4

const STORAGE_VERSION := 3

const STORAGE_RECORD_SIZE := 3

const VERSION_2_RECORD_SIZE := 5

const VERSION_1_RECORD_SIZE := 3


const MATERIAL_STRIDE := 9

const MATERIAL_COLOR := 0

const MATERIAL_EMISSION := 4

const MATERIAL_METALLIC := 7

const MATERIAL_ROUGHNESS := 8

const DEFAULT_EMISSION := Color.BLACK

const DEFAULT_METALLIC := 0.0

const DEFAULT_ROUGHNESS := 1.0

const DIRECTIONS := [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP, Vector3i.DOWN, Vector3i.BACK, Vector3i.FORWARD]


static var _occupancy_lock := Mutex.new()


static var _profile_capture_calls := 0
static var _profile_capture_us := 0
static var _profile_restore_calls := 0
static var _profile_restore_us := 0
static var _profile_copy_frame_calls := 0
static var _profile_job_frame_calls := 0
static var _profile_publish_calls := 0
static var _profile_publish_us := 0
static var _profile_set_cells_calls := 0
static var _profile_set_cells_us := 0
static var _profile_cell_writes := 0
static var _profile_bounds_rescan_calls := 0
static var _profile_bounds_rescan_us := 0


static func material(color: Color, emission: Color = DEFAULT_EMISSION, metallic: float = DEFAULT_METALLIC, roughness: float = DEFAULT_ROUGHNESS) -> PackedFloat32Array:
	return PackedFloat32Array([color.r, color.g, color.b, color.a, emission.r, emission.g, emission.b, metallic, roughness])


static func is_empty(cell_material: PackedFloat32Array) -> bool:
	return material_color(cell_material) == Color.TRANSPARENT


static func material_color(cell_material: PackedFloat32Array) -> Color:
	return Color(cell_material[MATERIAL_COLOR], cell_material[MATERIAL_COLOR + 1], cell_material[MATERIAL_COLOR + 2], cell_material[MATERIAL_COLOR + 3])


class EditContext extends RefCounted:


	const SurfaceMaskRule := preload("res://Globals/State/Tools/SurfaceMask.gd")


	var axes := 0

	var origin_twice := Vector3i.ZERO


	var selection := {}

	var slice_axis := -1

	var slice_index := 0


	var slice_count := 1


	var bounded_axes := 0

	var bounds_min := Vector3i.ZERO

	var bounds_max := Vector3i.ZERO


	func allows(cell: Vector3i) -> bool:
		if slice_axis >= 0 and (cell[slice_axis] < slice_index or cell[slice_axis] >= slice_index + slice_count):
			return false
		if bounded_axes != 0:
			for axis in 3:
				if bounded_axes & (1 << axis) and (cell[axis] < bounds_min[axis] or cell[axis] >= bounds_max[axis]):
					return false
		return selection.is_empty() or selection.has(cell)


	func duplicate() -> EditContext:
		var copy := EditContext.new()
		copy.axes = axes
		copy.origin_twice = origin_twice
		copy.selection = selection
		copy.slice_axis = slice_axis
		copy.slice_index = slice_index
		copy.slice_count = slice_count
		copy.bounded_axes = bounded_axes
		copy.bounds_min = bounds_min
		copy.bounds_max = bounds_max
		return copy


	func filter(cells: Dictionary) -> Dictionary:
		if slice_axis < 0 and selection.is_empty() and bounded_axes == 0:
			return cells
		var kept := {}
		for cell: Vector3i in cells:
			if allows(cell):
				kept[cell] = cells[cell]
		return kept


	func expand(changes: Dictionary, frame: VoxelFrame, existing_only: bool, matching_material: Variant, job: EditJob = null, surface_only := false) -> Dictionary:
		if axes == 0 and selection.is_empty() and slice_axis < 0 and bounded_axes == 0 and not existing_only and matching_material == null and not surface_only:
			return changes
		var expanded := {}
		var masks: Array[int] = []
		for mask in 8:
			if (mask & ~axes) == 0:
				masks.append(mask)
		var completed := 0
		for cell: Vector3i in changes:

			if surface_only and not SurfaceMaskRule.is_exposed(frame, cell):
				continue
			for mask in masks:
				var destination := reflect(cell, mask)
				if _allows(destination, frame, existing_only, matching_material, surface_only):
					expanded[destination] = changes[cell]
				completed += 1
				if job and completed % 4096 == 0 and not job.checkpoint(completed):
					return {}
		if axes == 0:
			return expanded

		for cell: Vector3i in changes:
			if _allows(cell, frame, existing_only, matching_material, surface_only):
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


	func _allows(cell: Vector3i, frame: VoxelFrame, existing_only: bool, matching_material: Variant, surface_only := false) -> bool:
		return allows(cell) and (not existing_only or frame.has(cell)) and (matching_material == null or frame.matches(cell, matching_material)) and (not surface_only or SurfaceMaskRule.is_exposed(frame, cell))


class EditJob extends RefCounted:

	var worker_task_id := -1

	var edit_context: EditContext

	var applied_cells := {}


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


	func wait_for_worker() -> void:
		if worker_task_id < 0:
			return
		WorkerThreadPool.wait_for_task_completion(worker_task_id)
		worker_task_id = -1


	func apply_cells(frame: VoxelFrame, changes: Dictionary, existing_only := false, matching_material: Variant = null, surface_only := false) -> Array[Vector3i]:
		applied_cells = edit_context.expand(changes, frame, existing_only, matching_material, self, surface_only) if edit_context else changes
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


class OccupancyRows extends RefCounted:

	var masks := PackedInt32Array()

	var counts := PackedByteArray()

	var revision := 0

	var grid_reads := 0

	var build_slots := 0


class Chunk extends RefCounted:


	var location := Vector3i.ZERO

	var grid := PackedInt32Array()

	var materials := PackedFloat32Array()

	var occupied_count := 0

	var voxel_revision := 0

	var _content_key := PackedInt64Array()

	var _content_key_revision := -1

	var occupied_bounds := AABB()

	var bounds_dirty := false


	var shared_materials := false

	var serialized_record: Array = []

	var positions_by_color: Dictionary = {}


	var occupancy_revision := 0


	var _occupancy_rows: OccupancyRows = null


	const SPARSE_CELL_LIMIT := 512

	var _sparse_slots := PackedInt32Array()

	var _sparse_values := PackedInt32Array()

	const LOWEST_COLUMN := [0, 0, 1, 0, 2, 0, 1, 0, 3, 0, 1, 0, 2, 0, 1, 0]

	func _init() -> void:
		grid.resize(VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE)


	func is_sparse() -> bool:
		return grid.is_empty()


	static func first_column(mask: int) -> int:
		if mask & 15:
			return LOWEST_COLUMN[mask & 15]
		if mask & 240:
			return 4 + LOWEST_COLUMN[(mask >> 4) & 15]
		if mask & 3840:
			return 8 + LOWEST_COLUMN[(mask >> 8) & 15]
		return 12 + LOWEST_COLUMN[(mask >> 12) & 15]


	func _sparse_index(slot: int) -> int:
		var low := 0
		var high := _sparse_slots.size() - 1
		while low <= high:
			var middle := (low + high) >> 1
			var value := _sparse_slots[middle]
			if value == slot:
				return middle
			if value < slot:
				low = middle + 1
			else:
				high = middle - 1
		return -1


	func cell_id_at_slot(slot: int) -> int:
		if not grid.is_empty():
			return grid[slot]
		var index := _sparse_index(slot)
		return _sparse_values[index] if index >= 0 else 0


	func ensure_dense() -> void:
		if not grid.is_empty():
			return
		grid.resize(VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE)
		for index in _sparse_slots.size():
			grid[_sparse_slots[index]] = _sparse_values[index]
		_sparse_slots = PackedInt32Array()
		_sparse_values = PackedInt32Array()


	func compress_if_sparse() -> void:
		if grid.is_empty() or occupied_count > SPARSE_CELL_LIMIT:
			return
		_sparse_slots = PackedInt32Array()
		_sparse_values = PackedInt32Array()
		for slot in grid.size():
			var id := grid[slot]
			if id > 0:
				_sparse_slots.append(slot)
				_sparse_values.append(id)
		grid = PackedInt32Array()


	func occupancy_rows() -> OccupancyRows:
		for _attempt in 2:
			VoxelFrame._occupancy_lock.lock()
			var cached := _occupancy_rows
			if cached != null and cached.revision == occupancy_revision:
				VoxelFrame._occupancy_lock.unlock()
				return cached
			var revision := occupancy_revision
			VoxelFrame._occupancy_lock.unlock()
			var built := _build_occupancy_rows(revision)
			VoxelFrame._occupancy_lock.lock()
			if built.revision == occupancy_revision:
				_occupancy_rows = built
				VoxelFrame._occupancy_lock.unlock()
				return built
			VoxelFrame._occupancy_lock.unlock()
		return _build_occupancy_rows(occupancy_revision)


	func occupancy_index_current() -> bool:
		VoxelFrame._occupancy_lock.lock()
		var current := _occupancy_rows != null and _occupancy_rows.revision == occupancy_revision
		VoxelFrame._occupancy_lock.unlock()
		return current


	func _build_occupancy_rows(revision: int) -> OccupancyRows:
		var built := OccupancyRows.new()
		built.masks.resize(VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE)
		built.counts.resize(VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE)
		if grid.is_empty():
			for index in _sparse_slots.size():
				var slot := _sparse_slots[index]
				var row := slot >> VoxelFrame.CHUNK_SHIFT
				built.masks[row] |= 1 << (slot & (VoxelFrame.CHUNK_SIZE - 1))
				built.counts[row] += 1
				built.build_slots += 1
			built.revision = revision
			return built
		for row in VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE:
			var base := row * VoxelFrame.CHUNK_SIZE
			var mask := 0
			var count := 0
			for x in VoxelFrame.CHUNK_SIZE:
				built.grid_reads += 1
				if grid[base + x] > 0:
					mask |= 1 << x
					count += 1
			built.masks[row] = mask
			built.counts[row] = count
			built.build_slots += 1
		built.revision = revision
		return built


	static func cell_slot(local_cell: Vector3i) -> int:
		return local_cell.x + VoxelFrame.CHUNK_SIZE * (local_cell.y + VoxelFrame.CHUNK_SIZE * local_cell.z)


	func origin() -> Vector3i:
		return location * VoxelFrame.CHUNK_SIZE


	func copy() -> Chunk:
		var chunk_copy := Chunk.new()
		chunk_copy.location = location
		if grid.is_empty():
			chunk_copy.grid = PackedInt32Array()
			chunk_copy._sparse_slots = _sparse_slots.duplicate()
			chunk_copy._sparse_values = _sparse_values.duplicate()
		else:
			chunk_copy.grid = grid.duplicate()
		chunk_copy.materials = materials.duplicate()
		chunk_copy.occupied_count = occupied_count
		chunk_copy.voxel_revision = voxel_revision
		chunk_copy.occupied_bounds = occupied_bounds
		chunk_copy.bounds_dirty = bounds_dirty
		chunk_copy.shared_materials = shared_materials


		VoxelFrame._occupancy_lock.lock()
		chunk_copy.occupancy_revision = occupancy_revision
		chunk_copy._occupancy_rows = _occupancy_rows
		VoxelFrame._occupancy_lock.unlock()
		return chunk_copy


	func material_id(cell_position: Vector3i) -> int:
		var local_cell := cell_position - origin()
		if local_cell.x < 0 or local_cell.y < 0 or local_cell.z < 0 or local_cell.x >= VoxelFrame.CHUNK_SIZE or local_cell.y >= VoxelFrame.CHUNK_SIZE or local_cell.z >= VoxelFrame.CHUNK_SIZE:
			return 0
		return cell_id_at_slot(cell_slot(local_cell))


	func has(cell_position: Vector3i) -> bool:
		return material_id(cell_position) > 0


	func _id_matches_material(id: int, cell_material: PackedFloat32Array) -> bool:
		if id == 0:
			return false
		var base := (id - 1) * MATERIAL_STRIDE
		for offset in MATERIAL_STRIDE:
			if materials[base + offset] != cell_material[offset]:
				return false
		return true


	func matches(cell_position: Vector3i, cell_material: PackedFloat32Array) -> bool:
		return _id_matches_material(material_id(cell_position), cell_material)


	func equals(other: Chunk) -> bool:
		if occupied_count != other.occupied_count:
			return false


		if grid.is_empty() and other.grid.is_empty():
			if _sparse_slots == other._sparse_slots and _sparse_values == other._sparse_values and materials == other.materials:
				return true
		elif grid == other.grid and materials == other.materials:
			return true
		var cells := VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE
		for slot in cells:
			var id := cell_id_at_slot(slot)
			var other_id := other.cell_id_at_slot(slot)
			if id == 0:
				if other_id != 0:
					return false
				continue
			if other_id == 0:
				return false
			var base := (id - 1) * MATERIAL_STRIDE
			var other_base := (other_id - 1) * MATERIAL_STRIDE
			for offset in MATERIAL_STRIDE:
				if materials[base + offset] != other.materials[other_base + offset]:
					return false
		return true


	func content_key() -> PackedInt64Array:
		if _content_key_revision == voxel_revision and not _content_key.is_empty():
			return _content_key
		var cells := grid
		if cells.is_empty():
			cells = PackedInt32Array()
			cells.resize(VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE)
			for index in _sparse_slots.size():
				cells[_sparse_slots[index]] = _sparse_values[index]
		_content_key = PackedInt64Array([hash(cells), hash(materials), occupied_count])
		_content_key_revision = voxel_revision
		return _content_key


	func store(cell_position: Vector3i, cell_material: PackedFloat32Array) -> void:
		ensure_dense()
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
		occupancy_revision += 1


	func erase(cell_position: Vector3i) -> void:
		ensure_dense()
		var local_cell := cell_position - origin()
		if local_cell.x < 0 or local_cell.y < 0 or local_cell.z < 0 or local_cell.x >= VoxelFrame.CHUNK_SIZE or local_cell.y >= VoxelFrame.CHUNK_SIZE or local_cell.z >= VoxelFrame.CHUNK_SIZE:
			return
		var slot := cell_slot(local_cell)
		if grid[slot] == 0:
			return
		grid[slot] = 0
		occupied_count -= 1
		occupancy_revision += 1
		if materials.size() > occupied_count * MATERIAL_STRIDE * 2:
			_compact()


	func apply_changes(changes: Dictionary, chunk_origin: Vector3i, copy_for_write: Callable, declared_uniform: Variant = null) -> Array:


		var bulk := _uniform_batch(changes, declared_uniform)
		if bulk.size() > 0:
			return _fill_chunk(bulk, chunk_origin, copy_for_write)


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
			var id := target.cell_id_at_slot(slot)
			if VoxelFrame.is_empty(cell_material):
				if id == 0:
					continue
				if not copied:
					target = copy_for_write.call()
					copied = true
					target.ensure_dense()
				target.grid[slot] = 0
				target.occupied_count -= 1
				target.occupancy_revision += 1
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
						target.ensure_dense()
					if target.shared_materials:


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
						target.ensure_dense()
					target.materials.append_array(cell_material)
					target.grid[slot] = target.materials.size() / MATERIAL_STRIDE
					target.occupied_count += 1
					target.occupancy_revision += 1
				if not target.bounds_dirty:
					min_cell = Vector3i(mini(min_cell.x, local.x), mini(min_cell.y, local.y), mini(min_cell.z, local.z))
					max_cell = Vector3i(maxi(max_cell.x, local.x), maxi(max_cell.y, local.y), maxi(max_cell.z, local.z))
			face_bits |= VoxelFrame._face_bits(local)
			changed_count += 1


		if changed_count > 0 and target.occupied_count > 0 and target.materials.size() > target.occupied_count * MATERIAL_STRIDE * 2:
			target._compact()

		if changed_count > 0 and not target.bounds_dirty and max_cell.x >= min_cell.x:
			var batch_bounds := AABB(Vector3(chunk_origin + min_cell) - Vector3.ONE * 0.5, Vector3(max_cell - min_cell + Vector3i.ONE))
			target.occupied_bounds = target.occupied_bounds.merge(batch_bounds) if target.occupied_bounds.has_volume() else batch_bounds
		return [target, face_bits, changed_count]


	func _apply_uniform_partial(changes: Dictionary, chunk_origin: Vector3i, copy_for_write: Callable, cell_material: PackedFloat32Array) -> Array:
		var target := self
		var copied := false
		var face_bits := 0
		var changed_count := 0
		var min_cell := Vector3i.MAX
		var max_cell := Vector3i.MIN
		var new_id := 0


		var last_id := 0
		var last_same := false
		for cell_position: Vector3i in changes:
			var local := cell_position - chunk_origin
			var slot := cell_slot(local)
			var id := target.cell_id_at_slot(slot)
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
				target.ensure_dense()


				target.materials.append_array(cell_material)
				new_id = target.materials.size() / MATERIAL_STRIDE
				target.shared_materials = true
			if id == 0:
				target.occupied_count += 1
				target.occupancy_revision += 1
			target.grid[slot] = new_id
			face_bits |= VoxelFrame._face_bits(local)
			changed_count += 1
			if not target.bounds_dirty:
				min_cell = Vector3i(mini(min_cell.x, local.x), mini(min_cell.y, local.y), mini(min_cell.z, local.z))
				max_cell = Vector3i(maxi(max_cell.x, local.x), maxi(max_cell.y, local.y), maxi(max_cell.z, local.z))


		if changed_count > 0 and target.occupied_count > 0 and target.materials.size() > target.occupied_count * MATERIAL_STRIDE * 2:
			target._compact()


		if changed_count > 0 and not target.bounds_dirty and max_cell.x >= min_cell.x:
			var batch_bounds := AABB(Vector3(chunk_origin + min_cell) - Vector3.ONE * 0.5, Vector3(max_cell - min_cell + Vector3i.ONE))
			target.occupied_bounds = target.occupied_bounds.merge(batch_bounds) if target.occupied_bounds.has_volume() else batch_bounds
		return [target, face_bits, changed_count]


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


	func _fill_chunk(cell_material: PackedFloat32Array, chunk_origin: Vector3i, copy_for_write: Callable) -> Array:
		var cells := VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE * VoxelFrame.CHUNK_SIZE
		if VoxelFrame.is_empty(cell_material):
			if occupied_count == 0:
				return [self, 0, 0]


			var bounds := get_bounds()
			var min_cell := Vector3i(bounds.position + Vector3.ONE * 0.5) - chunk_origin
			var max_cell := Vector3i(bounds.end - Vector3.ONE * 0.5) - chunk_origin
			return [null, _extent_face_bits(min_cell, max_cell), occupied_count]


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
		filled.ensure_dense()
		var old_count := filled.occupied_count
		filled.grid.fill(1)
		filled.materials = cell_material.duplicate()
		filled.occupied_count = cells
		if old_count != cells:
			filled.occupancy_revision += 1
		filled.shared_materials = true
		filled.bounds_dirty = false
		filled.occupied_bounds = AABB(Vector3(chunk_origin) - Vector3.ONE * 0.5, Vector3.ONE * VoxelFrame.CHUNK_SIZE)
		return [filled, bits, count]


	func _changed_extent(cell_material: PackedFloat32Array) -> Array:
		var size := VoxelFrame.CHUNK_SIZE
		var cells := size * size * size
		if occupied_count == 0:
			return [cells, Vector3i.ZERO, Vector3i.ONE * (size - 1)]
		if grid.is_empty():


			var matching := 0
			var sparse_matches := {}
			for index in _sparse_slots.size():
				var id := _sparse_values[index]
				var same := false
				if sparse_matches.has(id):
					same = sparse_matches[id]
				else:
					same = _id_matches_material(id, cell_material)
					sparse_matches[id] = same
				if same:
					matching += 1
			var sparse_changed := cells - matching
			if sparse_changed == 0:
				return [0, Vector3i.ZERO, Vector3i.ZERO]
			return [sparse_changed, Vector3i.ZERO, Vector3i.ONE * (size - 1)]
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


	func _compact() -> void:
		ensure_dense()
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
		var compacted := PackedFloat32Array()
		var unique := {}
		var next_id := 1
		for id: int in used_ids:
			var base: int = (id - 1) * MATERIAL_STRIDE
			var key := materials.slice(base, base + MATERIAL_STRIDE)
			var existing: int = unique.get(key, -1)
			if existing < 0:
				existing = next_id
				unique[key] = existing
				compacted.append_array(key)
				next_id += 1
			remap[id] = existing
		var usage := PackedInt32Array()
		usage.resize(next_id)
		for slot in grid.size():
			var remapped := remap[grid[slot]]
			grid[slot] = remapped
			if remapped > 0:
				usage[remapped] += 1
		var shared := false
		for id in range(1, usage.size()):
			if usage[id] > 1:
				shared = true
				break


		materials = compacted
		shared_materials = shared


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


	func world_cells() -> Array[Vector3i]:
		var cell_positions: Array[Vector3i] = []
		var size := VoxelFrame.CHUNK_SIZE
		if grid.is_empty():
			cell_positions.resize(_sparse_slots.size())
			for index in _sparse_slots.size():
				var slot := _sparse_slots[index]
				cell_positions[index] = origin() + Vector3i(slot % size, (slot / size) % size, slot / (size * size))
			return cell_positions
		cell_positions.resize(occupied_count)
		var written := 0
		for slot in grid.size():
			if grid[slot] > 0:
				cell_positions[written] = origin() + Vector3i(slot % size, (slot / size) % size, slot / (size * size))
				written += 1
		return cell_positions


	func get_bounds() -> AABB:
		if bounds_dirty:
			var min_cell := Vector3i.MAX
			var max_cell := Vector3i.MIN
			var size := VoxelFrame.CHUNK_SIZE
			if grid.is_empty():
				for index in _sparse_slots.size():
					var slot := _sparse_slots[index]
					var local_cell := Vector3i(slot % size, (slot / size) % size, slot / (size * size))
					min_cell = Vector3i(mini(min_cell.x, local_cell.x), mini(min_cell.y, local_cell.y), mini(min_cell.z, local_cell.z))
					max_cell = Vector3i(maxi(max_cell.x, local_cell.x), maxi(max_cell.y, local_cell.y), maxi(max_cell.z, local_cell.z))
			else:
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


	func on_bounds(cell_position: Vector3i) -> bool:
		var min_cell := Vector3i(occupied_bounds.position + Vector3.ONE * 0.5)
		var max_cell := Vector3i(occupied_bounds.end - Vector3.ONE * 0.5)
		return cell_position.x == min_cell.x or cell_position.y == min_cell.y or cell_position.z == min_cell.z or cell_position.x == max_cell.x or cell_position.y == max_cell.y or cell_position.z == max_cell.z


	func grow_bounds(cell_position: Vector3i) -> void:
		if bounds_dirty:
			return
		var cell_bounds := AABB(Vector3(cell_position) - Vector3.ONE * 0.5, Vector3.ONE)
		occupied_bounds = occupied_bounds.merge(cell_bounds) if occupied_bounds.has_volume() else cell_bounds


var chunks: Dictionary = {}
var _shared_chunks: Dictionary = {}


var _bounds := AABB()
var _bounds_dirty := true
var _bounds_chunk_count := -1


func count() -> int:
	var cell_count := 0
	for chunk in chunks.values():
		cell_count += chunk.occupied_count
	return cell_count


static func chunk_position(cell_position: Vector3i) -> Vector3i:
	return Vector3i(cell_position.x >> CHUNK_SHIFT, cell_position.y >> CHUNK_SHIFT, cell_position.z >> CHUNK_SHIFT)


func clear() -> void:
	chunks = {}
	_shared_chunks = {}
	_bounds_dirty = true
	_bounds_chunk_count = -1


func material_id(cell_position: Vector3i) -> int:
	var chunk: Chunk = chunks.get(chunk_position(cell_position))
	return chunk.material_id(cell_position) if chunk else 0


func occupancy_rows_at(location: Vector3i) -> OccupancyRows:
	var chunk: Chunk = chunks.get(location)
	return chunk.occupancy_rows() if chunk else null


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


func matches(cell_position: Vector3i, cell_material: PackedFloat32Array) -> bool:
	var chunk: Chunk = chunks.get(chunk_position(cell_position))
	return chunk != null and chunk.matches(cell_position, cell_material)


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
	_bounds_dirty = true


func set_cells(cell_materials: Dictionary, edit_job: EditJob = null, uniform_material: Variant = null) -> Array[Vector3i]:


	if edit_job != null and edit_job.edit_context != null:
		cell_materials = edit_job.edit_context.filter(cell_materials)
		edit_job.applied_cells = cell_materials
	var started := Time.get_ticks_usec()

	_bounds_dirty = true
	var changes_by_chunk := {}
	var completed := 0


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


			chunks.erase(chunk_location)
			_shared_chunks.erase(chunk_location)
		else:
			chunk.voxel_revision += 1
			chunk.serialized_record.clear()
			chunk.positions_by_color.clear()
			if chunk.occupied_count == 0:
				chunks.erase(chunk_location)
			else:

				chunk.get_bounds()
		changed_chunks.append(chunk_location)
		for offset in _touched_neighbors(face_bits):
			changed_chunks.append(chunk_location + offset)
	if edit_job:
		edit_job.checkpoint(completed)
	_profile_set_cells_calls += 1
	_profile_set_cells_us += Time.get_ticks_usec() - started
	_profile_cell_writes += cell_materials.size()
	return changed_chunks


static func _face_bits(local_cell: Vector3i, reach := 0) -> int:
	var bits := 0
	for axis in 3:
		if local_cell[axis] <= reach:
			bits |= 1 << (axis * 2)
		if local_cell[axis] >= CHUNK_SIZE - 1 - reach:
			bits |= 1 << (axis * 2 + 1)
	return bits


static func crosstalk_chunks(cell_position: Vector3i, reach := 0) -> Array[Vector3i]:
	var local_cell := cell_position - chunk_position(cell_position) * CHUNK_SIZE
	return _touched_neighbors(_face_bits(local_cell, reach))


static func neighbor_chunks(location: Vector3i) -> Array[Vector3i]:
	var neighbors: Array[Vector3i] = []
	for offset in _crosstalk_offsets():
		neighbors.append(location + offset)
	return neighbors


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


static func _static_init() -> void:
	for z in range(-1, 2):
		for y in range(-1, 2):
			for x in range(-1, 2):
				var offset := Vector3i(x, y, z)
				if offset != Vector3i.ZERO:
					_crosstalk_offsets_cache.append(offset)


static func _crosstalk_offsets() -> Array[Vector3i]:
	return _crosstalk_offsets_cache


func capture() -> Dictionary:
	var started := Time.get_ticks_usec()
	_shared_chunks = chunks.duplicate()
	var snapshot := chunks.duplicate()
	_profile_capture_calls += 1
	_profile_capture_us += Time.get_ticks_usec() - started
	return snapshot


func restore(chunk_snapshot: Dictionary) -> void:
	var started := Time.get_ticks_usec()
	chunks = chunk_snapshot.duplicate()
	_shared_chunks = chunks.duplicate()
	_bounds_dirty = true
	_bounds_chunk_count = -1
	_profile_restore_calls += 1
	_profile_restore_us += Time.get_ticks_usec() - started


func copy_frame() -> VoxelFrame:
	_profile_copy_frame_calls += 1
	var frame_copy := VoxelFrame.new()
	frame_copy.restore(capture())
	frame_copy.delay_ms = delay_ms
	return frame_copy


func copy_chunks(locations: Array[Vector3i]) -> VoxelFrame:
	var selected := {}
	for location in locations:
		if selected.has(location):
			continue
		var chunk: Chunk = chunks.get(location)
		if chunk == null:
			continue
		selected[location] = chunk
		_shared_chunks[location] = true
	var frame_copy := VoxelFrame.new()
	frame_copy.restore(selected)
	frame_copy.delay_ms = delay_ms
	return frame_copy


static func job_frame(source: VoxelFrame) -> VoxelFrame:
	var frame_copy := job_frame_of_snapshot(source.chunks)
	frame_copy.delay_ms = source.delay_ms
	return frame_copy


static func job_frame_of_snapshot(snapshot: Dictionary) -> VoxelFrame:
	_profile_job_frame_calls += 1
	var frame_copy := VoxelFrame.new()
	frame_copy.chunks = snapshot.duplicate()
	frame_copy._shared_chunks = frame_copy.chunks.duplicate()
	return frame_copy


func apply_published(locations: Array[Vector3i], published: VoxelFrame) -> void:
	var started := Time.get_ticks_usec()
	var grows_only := not _bounds_dirty and _bounds.has_volume()
	var merged := _bounds
	for location in locations:
		var chunk: Chunk = published.chunks.get(location)
		var previous: Chunk = chunks.get(location)
		if chunk == null:
			chunks.erase(location)
			_shared_chunks.erase(location)
			if previous != null:
				grows_only = false
			continue
		chunks[location] = chunk
		if published._shared_chunks.has(location):
			_shared_chunks[location] = true
		else:
			_shared_chunks.erase(location)
		if grows_only:
			var chunk_bounds: AABB = chunk.get_bounds()
			if previous == null:
				merged = merged.merge(chunk_bounds) if chunk_bounds.has_volume() else merged
			elif chunk_bounds.encloses(previous.get_bounds()):
				merged = merged.merge(chunk_bounds)
			else:
				grows_only = false
	if grows_only:
		_bounds = merged
		_bounds_dirty = false
		_bounds_chunk_count = chunks.size()
	else:
		_bounds_dirty = true
		_bounds_chunk_count = -1
	_profile_publish_calls += 1
	_profile_publish_us += Time.get_ticks_usec() - started


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
	if not _bounds_dirty and chunks.size() == _bounds_chunk_count:
		return _bounds
	var started := Time.get_ticks_usec()
	var frame_bounds := AABB()
	for chunk in chunks.values():
		var chunk_bounds: AABB = chunk.get_bounds()


		if not chunk_bounds.has_volume():
			continue
		frame_bounds = frame_bounds.merge(chunk_bounds) if frame_bounds.has_volume() else chunk_bounds
	_bounds = frame_bounds
	_bounds_chunk_count = chunks.size()
	_bounds_dirty = false
	_profile_bounds_rescan_calls += 1
	_profile_bounds_rescan_us += Time.get_ticks_usec() - started
	return _bounds


func invalidate_bounds() -> void:
	_bounds_dirty = true
	_bounds_chunk_count = -1
	for chunk in chunks.values():
		chunk.bounds_dirty = true


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


static func _encode_chunk(chunk: Chunk, chunk_location: Vector3i) -> Array:
	var material_table := material(Color.TRANSPARENT)
	var material_ids := {}
	material_ids[material_table.slice(0, MATERIAL_STRIDE)] = 0


	var material_values := {}
	var cell_ids := PackedInt32Array()
	cell_ids.resize(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE)


	var sparse := chunk.grid.is_empty()
	var sparse_slots := chunk._sparse_slots
	var sparse_values := chunk._sparse_values
	var count := sparse_slots.size() if sparse else chunk.grid.size()
	for index in count:
		var slot: int
		var id: int
		if sparse:
			slot = sparse_slots[index]
			id = sparse_values[index]
		else:
			slot = index
			id = chunk.grid[index]
		if id == 0:
			continue
		var cell_material: PackedFloat32Array
		if material_values.has(id):
			cell_material = material_values[id]
		else:
			cell_material = chunk.materials.slice((id - 1) * MATERIAL_STRIDE, id * MATERIAL_STRIDE)
			material_values[id] = cell_material
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
			var material_table: PackedFloat32Array = serialized_chunk[1]


			if _has_empty_stored_entry(material_table):
				continue


			chunk.materials = material_table.slice(MATERIAL_STRIDE)
			var usage := PackedInt32Array()
			usage.resize(chunk.materials.size() / MATERIAL_STRIDE + 1)
			_decode_materials(octree_nodes, [0], chunk_origin, CHUNK_SIZE, chunk, usage)
			for material_id in range(1, usage.size()):
				if usage[material_id] > 1:
					chunk.shared_materials = true
					break
		else:
			var emission_table := PackedColorArray()
			var finish_table := PackedColorArray()
			if version == 2:
				emission_table = serialized_chunk[2]
				finish_table = serialized_chunk[3]
			_decode_region(octree_nodes, [0], serialized_chunk[1], emission_table, finish_table, chunk_origin, CHUNK_SIZE, chunk)


			chunk._compact()
		chunk.compress_if_sparse()

		if chunk.occupied_count == 0:
			continue
		chunk.bounds_dirty = true
		if version == STORAGE_VERSION:
			chunk.serialized_record = serialized_chunk
		restored_chunks[chunk_location] = chunk
	restore(restored_chunks)


const MAX_STORED_VOXELS := 4 * 1024 * 1024

const MAX_STORED_CHUNKS := 65536

const MAX_CHUNK_COORDINATE := 65535


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


static func _valid_colors(color_table: PackedColorArray) -> bool:
	if color_table.is_empty() or color_table.size() > 4097 or color_table[0] != Color.TRANSPARENT:
		return false
	for color in color_table:
		if not is_finite(color.r) or not is_finite(color.g) or not is_finite(color.b) or not is_finite(color.a):
			return false
		if color.r < 0.0 or color.r > 1.0 or color.g < 0.0 or color.g > 1.0 or color.b < 0.0 or color.b > 1.0 or color.a < 0.0 or color.a > 1.0:
			return false
	return true


static func _valid_material_values(material_table: PackedFloat32Array) -> bool:
	if material_table.size() < MATERIAL_STRIDE or material_table.size() > 4097 * MATERIAL_STRIDE or material_table.size() % MATERIAL_STRIDE != 0:
		return false
	if not is_empty(material_table.slice(0, MATERIAL_STRIDE)):
		return false
	for value in material_table:
		if not is_finite(value) or value < 0.0 or value > 1.0:
			return false
	return true


static func _has_empty_stored_entry(material_table: PackedFloat32Array) -> bool:
	for entry in range(1, material_table.size() / MATERIAL_STRIDE):
		if is_empty(material_table.slice(entry * MATERIAL_STRIDE, (entry + 1) * MATERIAL_STRIDE)):
			return true
	return false


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


static func _decode_materials(octree_nodes: PackedInt32Array, node_cursor: Array, region_origin: Vector3i, region_size: int, chunk: Chunk, usage: PackedInt32Array) -> void:
	var material_id := octree_nodes[node_cursor[0]]
	node_cursor[0] += 1
	if material_id == 0:
		return
	if material_id > 0:
		_fill_material_region(chunk, region_origin, region_size, material_id, usage)
		return
	var child_size := region_size >> 1
	for child_index in 8:
		var child_offset := Vector3i(child_index & 1, (child_index >> 1) & 1, (child_index >> 2) & 1) * child_size
		_decode_materials(octree_nodes, node_cursor, region_origin + child_offset, child_size, chunk, usage)


static func _fill_material_region(chunk: Chunk, region_origin: Vector3i, region_size: int, material_id: int, usage: PackedInt32Array) -> void:
	var local_origin := region_origin - chunk.origin()
	var z_step := CHUNK_SIZE * CHUNK_SIZE
	var y_step := CHUNK_SIZE
	for z in region_size:
		var z_base := (local_origin.z + z) * z_step
		for y in region_size:
			var row_start := z_base + (local_origin.y + y) * y_step + local_origin.x
			for x in region_size:
				chunk.grid[row_start + x] = material_id
	var volume := region_size * region_size * region_size
	chunk.occupied_count += volume
	if material_id < usage.size():
		usage[material_id] += volume


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
