extends "res://tests/test.gd"

# Behavior and differential tests for the partial declared-uniform write path in
# `VoxelFrame.Chunk`. The fast path must match the generic per-cell path cell for
# cell, and must keep the copy-on-write, bounds, neighbor, and compaction rules.
# A `bench` case times the two paths on fresh snapshots.
#
#   godot --path . res://tests/uniform_partial_writes.tscn
#   godot --path . res://tests/uniform_partial_writes.tscn -- differential bench
#
# The generic path is the reference: `set_cells(changes, null, null)` never takes
# the fast path, so the differential compares production code against production
# code. The bench compares the same two calls, so no production hook is needed.

const CHUNK_SIZE := VoxelFrame.CHUNK_SIZE
const CHUNK_CELLS := CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE


# Test-only baseline frame. It drops the uniform hint, so a write through it or
# through a copy of it takes the generic path. `copy_frame` keeps the class, which
# the atomic fill path needs because it writes a snapshot.
class NoHintFrame extends VoxelFrame:
	func set_cells(cell_materials: Dictionary, edit_job: VoxelFrame.EditJob = null, uniform_material: Variant = null) -> Array[Vector3i]:
		return super.set_cells(cell_materials, edit_job, null)

	func copy_frame() -> VoxelFrame:
		var copy := NoHintFrame.new()
		copy.restore(capture())
		copy.delay_ms = delay_ms
		return copy


func _row_count(frame: VoxelFrame, location: Vector3i) -> int:
	var chunk: VoxelFrame.Chunk = frame.chunks[location]
	return chunk.materials.size() / VoxelFrame.MATERIAL_STRIDE


func _ready() -> void:
	timeout = 60.0
	test("a partial uniform write matches the generic path for every fixture", _differential, "differential")
	test("a repeated partial batch is a no-op", _noop, "noop")
	test("a partial uniform write leaves untouched cells alone", _untouched, "untouched")
	test("the stored material does not follow a later input mutation", _input_isolation, "input_isolation")
	test("a partial uniform write respects copy-on-write", _cow, "cow")
	test("a single-cell write after a partial uniform write is isolated", _single_after_partial, "single_after_partial")
	test("an erase after a partial uniform write is exact", _erase_after_partial, "erase_after_partial")
	test("a partial write on a chunk face reports the right neighbors", _neighbors, "neighbors")
	test("the table compacts and keeps valid ids", _compaction, "compaction")
	test("repeated partial writes on one cell stay bounded", _memory_bound, "memory_bound")
	test("a cancelled write job writes nothing", _cancel, "cancel")
	test("a partial uniform write reserializes to the same frame", _reserialize, "reserialize")
	# The two bench cases print timings only. They record no check on purpose.
	allow_no_checks = true
	test("partial uniform writes are timed against the generic path", _bench, "bench")
	allow_no_checks = true
	test("brush-like repaint sequences are timed for each source shape", _bench_shapes, "bench_shapes")
	test("the new shared row is isolated from a later single-cell write", _shared_row_later_edit, "shared_row_later_edit")
	test("a mixed batch over the new shared row keeps each cell's material", _shared_row_mixed, "shared_row_mixed")
	test("a compaction keeps the shared-row content and ids", _multi_id_compaction, "multi_id_compaction")
	test("a partial shared write inserts missing cells", _missing_cell, "missing_cell")
	test("a partial shared write respects dirty bounds", _dirty_bounds, "dirty_bounds")
	test("a no-op shared batch keeps the chunk identity and revision", _cow_noop, "cow_noop")
	test("a write does not mutate its captured source", _source_untouched, "source_untouched")
	test("the write compares all nine material values", _nine_values, "nine_values")
	test("the table stays bounded under many one-cell repaints", _growth_bounded, "growth_bounded")
	test("the no-hint baseline keeps its class through a copy", _no_hint_copy, "no_hint_copy")


# Fixtures. Each builder makes a fresh frame so a test never shares execution state.

func _origin(location: Vector3i) -> Vector3i:
	return location * CHUNK_SIZE


# A chunk filled in one uniform batch: one shared table row, every slot occupied.
func _bulk_frame(location: Vector3i, material: PackedFloat32Array) -> VoxelFrame:
	var frame := VoxelFrame.new()
	var origin := _origin(location)
	var cells := {}
	for z in CHUNK_SIZE:
		for y in CHUNK_SIZE:
			for x in CHUNK_SIZE:
				cells[origin + Vector3i(x, y, z)] = material
	frame.set_cells(cells)
	return frame


# A chunk written cell by cell: one table row per occupied cell.
func _percell_frame(location: Vector3i, material: PackedFloat32Array) -> VoxelFrame:
	var frame := VoxelFrame.new()
	var origin := _origin(location)
	for z in CHUNK_SIZE:
		for y in CHUNK_SIZE:
			for x in CHUNK_SIZE:
				frame.set_cell(origin + Vector3i(x, y, z), material)
	return frame


# Half the chunk holds RED with the default finish, half holds the same color
# with a different metallic. The 9-float compare must treat the two as different.
func _mixed_frame(location: Vector3i) -> VoxelFrame:
	var frame := VoxelFrame.new()
	var origin := _origin(location)
	var plain := VoxelFrame.material(Color.RED)
	var finished := VoxelFrame.material(Color.RED, VoxelFrame.DEFAULT_EMISSION, 0.8, 0.5)
	for z in CHUNK_SIZE:
		for y in CHUNK_SIZE:
			for x in CHUNK_SIZE:
				frame.set_cell(origin + Vector3i(x, y, z), plain if x < CHUNK_SIZE / 2 else finished)
	return frame


# Several one-cell chunks.
func _sparse_frame(material: PackedFloat32Array) -> VoxelFrame:
	var frame := VoxelFrame.new()
	for index in 4:
		frame.set_cell(Vector3i(index * CHUNK_SIZE, 0, 0), material)
	return frame


# `count` distinct cells of one chunk, in a shuffled order, so the change
# dictionary order is not the grid order.
func _pick_cells(location: Vector3i, count: int, shuffle_seed: int) -> Array[Vector3i]:
	var origin := _origin(location)
	var all: Array[Vector3i] = []
	for slot in CHUNK_CELLS:
		all.append(origin + Vector3i(slot % CHUNK_SIZE, (slot / CHUNK_SIZE) % CHUNK_SIZE, slot / (CHUNK_SIZE * CHUNK_SIZE)))
	var rng := RandomNumberGenerator.new()
	rng.seed = shuffle_seed
	for index in count:
		var swap := rng.randi_range(index, all.size() - 1)
		var held := all[index]
		all[index] = all[swap]
		all[swap] = held
	return all.slice(0, count)


func _changes(cells: Array[Vector3i], material: PackedFloat32Array) -> Dictionary:
	var out := {}
	for cell in cells:
		out[cell] = material
	return out


# One cell of the chunk that the batch does not touch.
func _outside_cell(location: Vector3i, cells: Array[Vector3i]) -> Vector3i:
	var inside := {}
	for cell in cells:
		inside[cell] = true
	var origin := _origin(location)
	for slot in CHUNK_CELLS:
		var cell := origin + Vector3i(slot % CHUNK_SIZE, (slot / CHUNK_SIZE) % CHUNK_SIZE, slot / (CHUNK_SIZE * CHUNK_SIZE))
		if not inside.has(cell):
			return cell
	return origin


# Write the batch with the uniform hint and without it, on two twins of the
# source. Returns [fast frame, generic frame, fast chunks, generic chunks].
func _apply_pair(source: VoxelFrame, changes: Dictionary, material: PackedFloat32Array) -> Array:
	var fast := source.copy_frame()
	var generic := source.copy_frame()
	var fast_chunks := fast.set_cells(changes.duplicate(), null, material)
	var generic_chunks := generic.set_cells(changes.duplicate(), null, null)
	return [fast, generic, fast_chunks, generic_chunks]


func _differential() -> void:
	step("Given fixture chunks and partial uniform batches", func():
		var material := VoxelFrame.material(Color.BLUE)
		var fixtures: Array = [
			["bulk", Vector3i.ZERO, _bulk_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))],
			["percell", Vector3i.ZERO, _percell_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))],
			["mixed", Vector3i.ZERO, _mixed_frame(Vector3i.ZERO)],
			["negative", Vector3i(-1, -1, -1), _bulk_frame(Vector3i(-1, -1, -1), VoxelFrame.material(Color.RED))],
		]
		var checked := 0
		for entry in fixtures:
			var name: String = entry[0]
			var location: Vector3i = entry[1]
			var source: VoxelFrame = entry[2]
			for count in [8, 64, 128, 512]:
				var cells := _pick_cells(location, count, count * 7 + 1)
				var changes := _changes(cells, material)
				var pair := _apply_pair(source, changes, material)
				var fast: VoxelFrame = pair[0]
				var generic: VoxelFrame = pair[1]
				var fast_chunks: Array[Vector3i] = pair[2]
				var generic_chunks: Array[Vector3i] = pair[3]
				expect(fast.storage_data() == generic.storage_data(), "%s count %d matches the generic path" % [name, count])
				expect(fast_chunks == generic_chunks, "%s count %d reports the same chunks" % [name, count])
				expect(fast.count() == generic.count(), "%s count %d keeps the same cell count" % [name, count])
				checked += 1
		expect(checked == 16, "every fixture and batch size ran")
	)


func _noop() -> void:
	step("Given a chunk and one partial uniform batch", func():
		var source := _bulk_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var material := VoxelFrame.material(Color.BLUE)
		var cells := _pick_cells(Vector3i.ZERO, 512, 3)
		var changes := _changes(cells, material)
		var frame := source.copy_frame()
		var first := frame.set_cells(changes, null, material)
		expect(first.size() > 0, "the first batch changes the chunk")
		var chunk: VoxelFrame.Chunk = frame.chunks[Vector3i.ZERO]
		var revision := chunk.voxel_revision
		var second := frame.set_cells(changes, null, material)
		expect(second.is_empty(), "the repeated batch reports no changed chunk")
		expect(chunk.voxel_revision == revision, "the repeated batch keeps the revision")
	)


func _untouched() -> void:
	step("Given a bulk chunk and a partial batch", func():
		var source := _bulk_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var material := VoxelFrame.material(Color.BLUE)
		var cells := _pick_cells(Vector3i.ZERO, 128, 5)
		var frame := source.copy_frame()
		frame.set_cells(_changes(cells, material), null, material)
		var inside := {}
		for cell in cells:
			inside[cell] = true
		var wrong := 0
		for slot in CHUNK_CELLS:
			var cell := Vector3i(slot % CHUNK_SIZE, (slot / CHUNK_SIZE) % CHUNK_SIZE, slot / (CHUNK_SIZE * CHUNK_SIZE))
			var expected := Color.BLUE if inside.has(cell) else Color.RED
			if frame.get_color(cell) != expected:
				wrong += 1
		expect(wrong == 0, "only the batch cells changed")
	)


func _input_isolation() -> void:
	step("Given a partial uniform write", func():
		var source := _bulk_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var material := VoxelFrame.material(Color.BLUE)
		var cells := _pick_cells(Vector3i.ZERO, 64, 7)
		var frame := source.copy_frame()
		frame.set_cells(_changes(cells, material), null, material)
		var before := frame.get_material(cells[0])
		material[0] = 0.25
		expect(frame.get_material(cells[0]) == before, "the stored material does not follow the input")
	)


func _cow() -> void:
	step("Given two frames that share a chunk", func():
		var source := _bulk_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var twin := source.copy_frame()
		var material := VoxelFrame.material(Color.BLUE)
		var cells := _pick_cells(Vector3i.ZERO, 128, 9)
		twin.set_cells(_changes(cells, material), null, material)
		var wrong := 0
		for cell in cells:
			if source.get_color(cell) != Color.RED:
				wrong += 1
		expect(wrong == 0, "the shared source chunk is untouched")
		expect(source.chunks[Vector3i.ZERO] != twin.chunks[Vector3i.ZERO], "the write copied the chunk")
	)


func _single_after_partial() -> void:
	step("Given a chunk with a shared row after a partial uniform write", func():
		var source := _bulk_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var material := VoxelFrame.material(Color.BLUE)
		var cells := _pick_cells(Vector3i.ZERO, 512, 11)
		var frame := source.copy_frame()
		frame.set_cells(_changes(cells, material), null, material)
		var other := _outside_cell(Vector3i.ZERO, cells)
		frame.set_cell(other, VoxelFrame.material(Color.GREEN))
		expect(frame.get_color(other) == Color.GREEN, "the single cell takes its own material")
		var wrong := 0
		for cell in cells:
			if frame.get_color(cell) != Color.BLUE:
				wrong += 1
		expect(wrong == 0, "the batch cells keep the shared material")
	)


func _erase_after_partial() -> void:
	step("Given a partial uniform write, then an erase of half the batch", func():
		var source := _bulk_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var material := VoxelFrame.material(Color.BLUE)
		var cells := _pick_cells(Vector3i.ZERO, 512, 13)
		var frame := source.copy_frame()
		frame.set_cells(_changes(cells, material), null, material)
		var erased := {}
		var erased_count := 0
		for index in range(0, cells.size(), 2):
			erased[cells[index]] = VoxelFrame.material(Color.TRANSPARENT)
			erased_count += 1
		frame.set_cells(erased, null, VoxelFrame.material(Color.TRANSPARENT))
		var occupied := 0
		for slot in CHUNK_CELLS:
			var cell := Vector3i(slot % CHUNK_SIZE, (slot / CHUNK_SIZE) % CHUNK_SIZE, slot / (CHUNK_SIZE * CHUNK_SIZE))
			if frame.has(cell):
				occupied += 1
		expect(occupied == CHUNK_CELLS - erased_count, "the erase removes exactly the batch cells")
	)


func _neighbors() -> void:
	step("Given a partial write on a chunk face", func():
		var source := _bulk_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var material := VoxelFrame.material(Color.BLUE)
		var cells: Array[Vector3i] = []
		for y in CHUNK_SIZE:
			cells.append(Vector3i(CHUNK_SIZE - 1, y, 0))
		var changes := _changes(cells, material)
		var pair := _apply_pair(source, changes, material)
		var fast_chunks: Array[Vector3i] = pair[2]
		var generic_chunks: Array[Vector3i] = pair[3]
		expect(fast_chunks == generic_chunks, "the neighbor report matches the generic path")
		expect(fast_chunks.has(Vector3i(1, 0, 0)), "the positive x neighbor is reported")
		expect(fast_chunks.has(Vector3i(0, -1, 0)), "the negative y neighbor is reported")
		expect(fast_chunks.has(Vector3i(0, 0, -1)), "the negative z neighbor is reported")
	)


func _compaction() -> void:
	step("Given a one-cell chunk and repeated partial writes", func():
		var frame := VoxelFrame.new()
		var cell := Vector3i(3, 4, 5)
		frame.set_cell(cell, VoxelFrame.material(Color.RED))
		var colors: Array[Color] = [Color.BLUE, Color.GREEN, Color.YELLOW, Color.CYAN]
		for index in 12:
			var material := VoxelFrame.material(colors[index % colors.size()])
			frame.set_cells({cell: material}, null, material)
		expect(frame.get_color(cell) == colors[11 % colors.size()], "the last write wins")
		var chunk: VoxelFrame.Chunk = frame.chunks[Vector3i.ZERO]
		expect(chunk.materials.size() / VoxelFrame.MATERIAL_STRIDE <= 3, "the table stays inside the compaction threshold")
		var restored := VoxelFrame.new()
		restored.restore_storage(frame.storage_data())
		expect(restored.storage_data() == frame.storage_data(), "the compacted frame reserializes the same")
		expect(restored.get_color(cell) == frame.get_color(cell), "the compacted id remap keeps the material")
	)


func _memory_bound() -> void:
	step("Given one cell written many times with the uniform hint", func():
		var frame := VoxelFrame.new()
		var cell := Vector3i(0, 0, 0)
		frame.set_cell(cell, VoxelFrame.material(Color.RED))
		for index in 200:
			var material := VoxelFrame.material(Color.from_rgba8(index % 255, 10, 20))
			frame.set_cells({cell: material}, null, material)
		var chunk: VoxelFrame.Chunk = frame.chunks[Vector3i.ZERO]
		expect(chunk.materials.size() / VoxelFrame.MATERIAL_STRIDE <= 3, "the unused table stays bounded")
	)


func _cancel() -> void:
	step("Given a cancelled write job", func():
		var source := _bulk_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var material := VoxelFrame.material(Color.BLUE)
		var cells := _pick_cells(Vector3i.ZERO, 512, 17)
		var frame := source.copy_frame()
		var before := frame.storage_data()
		var job := VoxelFrame.EditJob.new()
		job.cancel()
		var changed := frame.set_cells(_changes(cells, material), job, material)
		expect(changed.is_empty(), "a cancelled write reports no changed chunk")
		expect(frame.storage_data() == before, "a cancelled write leaves the frame")
	)


func _reserialize() -> void:
	step("Given a partial uniform write on a per-cell chunk", func():
		var source := _percell_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var material := VoxelFrame.material(Color.BLUE)
		var cells := _pick_cells(Vector3i.ZERO, 512, 19)
		var frame := source.copy_frame()
		frame.set_cells(_changes(cells, material), null, material)
		var restored := VoxelFrame.new()
		restored.restore_storage(frame.storage_data())
		expect(restored.storage_data() == frame.storage_data(), "the frame reserializes the same")
		expect(restored.count() == frame.count(), "the restored frame keeps the cell count")
	)


# A chunk with one cell, written by `set_cell`, so its row is not shared.
func _onecell_frame() -> VoxelFrame:
	var frame := VoxelFrame.new()
	frame.set_cell(Vector3i(3, 4, 5), VoxelFrame.material(Color.RED))
	return frame


# A chunk with two shared rows: a bulk fill, then one partial shared write. The
# batch visits both rows, so it stresses the match cache.
func _shared_two_row_frame() -> VoxelFrame:
	var frame := _bulk_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))
	var material := VoxelFrame.material(Color.BLUE)
	var cells := _pick_cells(Vector3i.ZERO, 2048, 99)
	frame.set_cells(_changes(cells, material), null, material)
	return frame


# Focused sequence bench. A single write hides the table-growth cost, so each
# shape repaints the same cells three times on one frame. That is the ordinary
# brush path: a stroke writes the same footprint again and again.
func _bench_shapes() -> void:
	step("Given a brush-like repaint sequence for each source shape", func():
		var palette: Array[PackedFloat32Array] = [VoxelFrame.material(Color.BLUE), VoxelFrame.material(Color.GREEN), VoxelFrame.material(Color.YELLOW)]
		var onecell := _onecell_frame()
		var onecell_cells: Array[Vector3i] = [Vector3i(3, 4, 5)]
		var shapes: Array = [
			["onecell", onecell, onecell_cells],
			["cells8", _percell_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED)), _pick_cells(Vector3i.ZERO, 8, 8 * 5 + 3)],
			["cells64", _percell_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED)), _pick_cells(Vector3i.ZERO, 64, 64 * 5 + 3)],
			["cells128", _percell_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED)), _pick_cells(Vector3i.ZERO, 128, 128 * 5 + 3)],
			["percell", _percell_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED)), _pick_cells(Vector3i.ZERO, 512, 512 * 5 + 3)],
			["bulk", _bulk_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED)), _pick_cells(Vector3i.ZERO, 512, 512 * 5 + 3)],
			["shared2", _shared_two_row_frame(), _pick_cells(Vector3i.ZERO, 512, 512 * 5 + 3)],
			["mixed", _mixed_frame(Vector3i.ZERO), _pick_cells(Vector3i.ZERO, 512, 512 * 5 + 3)],
		]
		for entry in shapes:
			var name: String = entry[0]
			var source: VoxelFrame = entry[1]
			var cells: Array[Vector3i] = entry[2]
			var count := cells.size()
			var sequence: Array = []
			for index in palette.size():
				sequence.append(_changes(cells, palette[index]))
			var fast_samples: Array[int] = []
			var generic_samples: Array[int] = []
			for warm in 2:
				_time_sequence(source, sequence, palette, true)
				_time_sequence(source, sequence, palette, false)
			for index in 9:
				if index % 2 == 0:
					fast_samples.append(_time_sequence(source, sequence, palette, true))
					generic_samples.append(_time_sequence(source, sequence, palette, false))
				else:
					generic_samples.append(_time_sequence(source, sequence, palette, false))
					fast_samples.append(_time_sequence(source, sequence, palette, true))
			var fast_rows := _final_rows(source, sequence, palette, true)
			var generic_rows := _final_rows(source, sequence, palette, false)
			print("MEASURE uniform_partial_seq %s count=%d: fast %s us rows %d, generic %s us rows %d" % [name, count, _stat(fast_samples), fast_rows, _stat(generic_samples), generic_rows])
	)


# Apply the whole sequence to one twin and time it.
func _time_sequence(source: VoxelFrame, sequence: Array, palette: Array[PackedFloat32Array], hint: bool) -> int:
	var frame := source.copy_frame()
	var started := Time.get_ticks_usec()
	for index in sequence.size():
		frame.set_cells(sequence[index], null, palette[index] if hint else null)
	return Time.get_ticks_usec() - started


# The row count of the one chunk after the sequence.
func _final_rows(source: VoxelFrame, sequence: Array, palette: Array[PackedFloat32Array], hint: bool) -> int:
	var frame := source.copy_frame()
	for index in sequence.size():
		frame.set_cells(sequence[index], null, palette[index] if hint else null)
	var chunk: VoxelFrame.Chunk = frame.chunks.values()[0]
	return chunk.materials.size() / VoxelFrame.MATERIAL_STRIDE


func _no_hint_copy() -> void:
	step("Given a no-hint frame and its copy", func():
		var base := _bulk_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var frame := NoHintFrame.new()
		frame.restore(base.capture())
		var copy := frame.copy_frame()
		expect(copy is NoHintFrame, "copy_frame keeps the no-hint class")
		var material := VoxelFrame.material(Color.BLUE)
		var cells := _pick_cells(Vector3i.ZERO, 128, 61)
		copy.set_cells(_changes(cells, material), null, material)
		expect(_row_count(copy, Vector3i.ZERO) > 2, "the copy dropped the hint and appended per cell")
	)


# A partial shared write gives the batch one row. A later single-cell write of a
# cell on that row must give the cell its own row and leave the batch cells alone.
func _shared_row_later_edit() -> void:
	step("Given a shared chunk with a batch on one new row", func():
		var source := _bulk_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var material := VoxelFrame.material(Color.BLUE)
		var cells := _pick_cells(Vector3i.ZERO, 512, 23)
		var frame := source.copy_frame()
		frame.set_cells(_changes(cells, material), null, material)
		frame.set_cell(cells[0], VoxelFrame.material(Color.GREEN))
		expect(frame.get_color(cells[0]) == Color.GREEN, "the edited cell takes its own material")
		var wrong := 0
		for index in range(1, cells.size()):
			if frame.get_color(cells[index]) != Color.BLUE:
				wrong += 1
		expect(wrong == 0, "the other batch cells keep the shared material")
		var outside := _outside_cell(Vector3i.ZERO, cells)
		expect(frame.get_color(outside) == Color.RED, "a cell outside the batch keeps its material")
	)


# A mixed batch with no hint writes each cell on its own, even when the cells
# point at the same shared row.
func _shared_row_mixed() -> void:
	step("Given a shared chunk with a batch on one new row", func():
		var source := _bulk_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var material := VoxelFrame.material(Color.BLUE)
		var cells := _pick_cells(Vector3i.ZERO, 512, 29)
		var frame := source.copy_frame()
		frame.set_cells(_changes(cells, material), null, material)
		var mixed := {}
		mixed[cells[0]] = VoxelFrame.material(Color.GREEN)
		mixed[cells[1]] = VoxelFrame.material(Color.YELLOW)
		frame.set_cells(mixed, null, null)
		expect(frame.get_color(cells[0]) == Color.GREEN, "the first mixed cell takes its material")
		expect(frame.get_color(cells[1]) == Color.YELLOW, "the second mixed cell takes its material")
		expect(frame.get_color(cells[2]) == Color.BLUE, "a cell outside the mixed batch keeps the shared material")
	)


# A compaction on a chunk with several shared rows must keep every cell's
# material and remap the ids to valid rows.
func _multi_id_compaction() -> void:
	step("Given a shared chunk with several rows", func():
		var frame := _bulk_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var colors: Array[Color] = [Color.BLUE, Color.GREEN, Color.YELLOW]
		var all := _pick_cells(Vector3i.ZERO, 768, 41)
		var groups: Array = [all.slice(0, 256), all.slice(256, 512), all.slice(512, 768)]
		for index in colors.size():
			var material := VoxelFrame.material(colors[index])
			frame.set_cells(_changes(groups[index], material), null, material)
		var before := frame.storage_data()
		var chunk: VoxelFrame.Chunk = frame.chunks[Vector3i.ZERO]
		var rows_before := chunk.materials.size() / VoxelFrame.MATERIAL_STRIDE
		chunk._compact()
		expect(frame.storage_data() == before, "the compaction keeps the frame content")
		expect(chunk.materials.size() / VoxelFrame.MATERIAL_STRIDE <= rows_before, "the compaction does not grow the table")
		var wrong := 0
		for index in colors.size():
			for cell in groups[index]:
				if frame.get_color(cell) != colors[index]:
					wrong += 1
		expect(wrong == 0, "every group keeps its material after the remap")
	)


# A partial shared write that includes empty cells must insert them.
func _missing_cell() -> void:
	step("Given a shared chunk with empty cells", func():
		var frame := _bulk_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var material := VoxelFrame.material(Color.BLUE)
		var cells := _pick_cells(Vector3i.ZERO, 256, 43)
		var erased := {}
		for cell in cells:
			erased[cell] = VoxelFrame.material(Color.TRANSPARENT)
		frame.set_cells(erased, null, VoxelFrame.material(Color.TRANSPARENT))
		expect(frame.count() == CHUNK_CELLS - cells.size(), "the erase removed the cells")
		frame.set_cells(_changes(cells, material), null, material)
		expect(frame.count() == CHUNK_CELLS, "the shared write inserted every cell")
		var wrong := 0
		for cell in cells:
			if frame.get_color(cell) != Color.BLUE:
				wrong += 1
		expect(wrong == 0, "every inserted cell takes the fill material")
	)


# A partial shared write on a chunk with dirty bounds must leave the flag set.
func _dirty_bounds() -> void:
	step("Given a chunk with dirty bounds", func():
		var source := _bulk_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var material := VoxelFrame.material(Color.BLUE)
		var cells := _pick_cells(Vector3i.ZERO, 64, 47)
		var frame := source.copy_frame()
		var chunk: VoxelFrame.Chunk = frame.chunks[Vector3i.ZERO]
		chunk.bounds_dirty = true
		var expected := chunk.get_bounds()
		chunk.bounds_dirty = true
		frame.set_cells(_changes(cells, material), null, material)
		expect(chunk.bounds_dirty, "a dirty chunk stays dirty after a partial write")
		expect(chunk.get_bounds() == expected, "the rescan bounds are unchanged")
	)


# A repeated shared batch must copy nothing and keep the chunk identity.
func _cow_noop() -> void:
	step("Given a shared chunk and a batch already applied", func():
		var source := _bulk_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var material := VoxelFrame.material(Color.BLUE)
		var cells := _pick_cells(Vector3i.ZERO, 128, 53)
		var frame := source.copy_frame()
		frame.set_cells(_changes(cells, material), null, material)
		var chunk: VoxelFrame.Chunk = frame.chunks[Vector3i.ZERO]
		var revision := chunk.voxel_revision
		var rows := _row_count(frame, Vector3i.ZERO)
		var changed := frame.set_cells(_changes(cells, material), null, material)
		expect(changed.is_empty(), "the repeated batch reports no changed chunk")
		expect(frame.chunks[Vector3i.ZERO] == chunk, "the repeated batch keeps the chunk identity")
		expect(chunk.voxel_revision == revision, "the repeated batch keeps the revision")
		expect(_row_count(frame, Vector3i.ZERO) == rows, "the repeated batch appends no row")
	)


# A write must not mutate the batch dictionary or the caller's material.
func _source_untouched() -> void:
	step("Given a shared chunk and a captured batch", func():
		var source := _bulk_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var material := VoxelFrame.material(Color.BLUE)
		var cells := _pick_cells(Vector3i.ZERO, 64, 59)
		var changes := _changes(cells, material)
		var keys_before := changes.keys()
		var material_before := material.duplicate()
		var frame := source.copy_frame()
		frame.set_cells(changes, null, material)
		expect(changes.keys() == keys_before, "the write does not change the batch keys")
		expect(changes.size() == keys_before.size(), "the write does not drop a batch cell")
		expect(material == material_before, "the write does not change the input material")
	)


# The compare reads all nine stored values, so a same-color cell of a different
# finish is not a no-op.
func _nine_values() -> void:
	step("Given a chunk with a same-color different-finish row", func():
		var frame := _bulk_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var finished := VoxelFrame.material(Color.RED, VoxelFrame.DEFAULT_EMISSION, 0.8, 0.5)
		var cell := Vector3i(2, 3, 4)
		frame.set_cell(cell, finished)
		var material := VoxelFrame.material(Color.RED)
		var cells: Array[Vector3i] = [cell]
		var changed := frame.set_cells(_changes(cells, material), null, material)
		expect(changed.size() > 0, "the same-color different-finish cell changes")
		expect(frame.get_material(cell) == material, "the cell takes the declared full material")
	)


# The table must stay bounded under many repaints, for both source shapes.
func _growth_bounded() -> void:
	step("Given a shared chunk repainted many times on one cell", func():
		var frame := _bulk_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var cell := Vector3i(1, 1, 1)
		for index in 400:
			var material := VoxelFrame.material(Color.from_rgba8(index % 255, 10, 20))
			frame.set_cells({cell: material}, null, material)
		expect(_row_count(frame, Vector3i.ZERO) <= CHUNK_CELLS * 2 + 1, "the shared table stays inside the compaction threshold")
		expect(frame.get_color(cell) == Color.from_rgba8(399 % 255, 10, 20), "the last shared repaint wins")
	)
	step("Given an unshared chunk repainted many times on one cell", func():
		var frame := VoxelFrame.new()
		var cell := Vector3i(1, 1, 1)
		frame.set_cell(cell, VoxelFrame.material(Color.RED))
		for index in 400:
			var material := VoxelFrame.material(Color.from_rgba8(index % 255, 10, 20))
			frame.set_cells({cell: material}, null, material)
		expect(_row_count(frame, Vector3i.ZERO) == 1, "the unshared row is written in place, not appended")
		expect(frame.get_color(cell) == Color.from_rgba8(399 % 255, 10, 20), "the last unshared repaint wins")
	)


func _bench() -> void:
	step("Given fixture chunks and partial uniform batches", func():
		var material := VoxelFrame.material(Color.BLUE)
		var fixtures: Array = [
			["bulk", Vector3i.ZERO, _bulk_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))],
			["percell", Vector3i.ZERO, _percell_frame(Vector3i.ZERO, VoxelFrame.material(Color.RED))],
			["mixed", Vector3i.ZERO, _mixed_frame(Vector3i.ZERO)],
			["negative", Vector3i(-1, -1, -1), _bulk_frame(Vector3i(-1, -1, -1), VoxelFrame.material(Color.RED))],
		]
		for entry in fixtures:
			var name: String = entry[0]
			var location: Vector3i = entry[1]
			var source: VoxelFrame = entry[2]
			for count in [8, 64, 128, 512]:
				var cells := _pick_cells(location, count, count * 3 + 1)
				var changes := _changes(cells, material)
				var fast_samples: Array[int] = []
				var generic_samples: Array[int] = []
				for warm in 2:
					_time_write(source, changes, material, true)
					_time_write(source, changes, material, false)
				for index in 9:
					if index % 2 == 0:
						fast_samples.append(_time_write(source, changes, material, true))
						generic_samples.append(_time_write(source, changes, material, false))
					else:
						generic_samples.append(_time_write(source, changes, material, false))
						fast_samples.append(_time_write(source, changes, material, true))
				print("MEASURE uniform_partial %s count=%d: fast %s us, generic %s us" % [name, count, _stat(fast_samples), _stat(generic_samples)])
	)


# One write on a fresh twin of the source, with or without the uniform hint.
func _time_write(source: VoxelFrame, changes: Dictionary, material: PackedFloat32Array, hint: bool) -> int:
	var frame := source.copy_frame()
	var started := Time.get_ticks_usec()
	frame.set_cells(changes, null, material if hint else null)
	return Time.get_ticks_usec() - started


func _stat(samples: Array[int]) -> String:
	if samples.is_empty():
		return "none"
	var sorted := samples.duplicate()
	sorted.sort()
	return "min %d median %d max %d" % [sorted[0], sorted[sorted.size() / 2], sorted[sorted.size() - 1]]
