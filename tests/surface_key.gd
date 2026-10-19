extends "res://tests/test.gd"

# Exact surface-key regression and A/B. The packed key must equal the legacy
# String key for every state, and it must cost less. The legacy key lives in a
# test-only reference, so the production code has one key path.
#
#   godot --headless --path . res://tests/surface_key.tscn

const REFERENCE := preload("res://tests/surface_key_reference.gd")
const RENDERER_SCENE := preload("res://ui/Viewport/VoxelRenderer.tscn")
const BENCH_CHUNKS := 6
const BENCH_REPEATS := 9

var frame: VoxelFrame
var view_a: VoxelRenderer
var view_b: VoxelRenderer
var bench_frame: VoxelFrame
var bench_chunks: Array[Vector3i] = []
var legacy_samples: Array[int] = []
var new_samples: Array[int] = []
var legacy_sink := 0
var new_sink := 0
var parity_cases := 0
var parity_mismatches := 0


func _ready() -> void:
	timeout = 60.0
	test("the packed surface key matches the legacy key and costs less", _run)


func _run() -> void:
	step("Given equal-content packed arrays", func():
		_expect_packed_behavior()
	)
	step("Given a frame with a chunk and its face neighbors", func():
		frame = _neighbor_frame()
		expect(frame.chunks.size() == 3, "the frame holds the center chunk and two face neighbors")
	)
	step("Then the packed key matches the legacy key for unchanged state", func():
		_expect_parity(frame, Vector3i.ZERO, false, "flat unchanged")
		_expect_parity(frame, Vector3i.ZERO, true, "smooth unchanged")
		expect(parity_mismatches == 0, "every unchanged-state key matches the legacy key")
	)
	step("Then a flat key holds the shading mode and seven ordered pairs", func():
		var key := _key(frame, Vector3i.ZERO, false)
		var chunk: VoxelFrame.Chunk = frame.chunks[Vector3i.ZERO]
		expect(key.size() == 1 + 7 * 2, "the flat key holds one mode and seven pairs")
		expect(key[0] == 0, "the flat key marks flat shading")
		expect(key[1] == chunk.get_instance_id() and key[2] == chunk.voxel_revision, "the first pair is the center chunk")
	)
	step("Then a smooth key holds the shading mode and twenty-seven ordered pairs", func():
		var key := _key(frame, Vector3i.ZERO, true)
		expect(key.size() == 1 + 27 * 2, "the smooth key holds one mode and twenty-seven pairs")
		expect(key[0] == 1, "the smooth key marks smooth shading")
	)
	step("Then a missing neighbor writes the unambiguous zero pair", func():
		var alone := VoxelFrame.new()
		alone.set_cell(Vector3i.ZERO, VoxelFrame.material(Color.RED))
		var key := _key(alone, Vector3i.ZERO, false)
		var missing := true
		for pair in range(1, 7):
			missing = missing and key[1 + pair * 2] == 0 and key[2 + pair * 2] == 0
		expect(missing, "every missing face neighbor writes a zero pair")
		expect(key[1] != 0, "the present center chunk writes a nonzero instance id")
	)
	step("When only the voxel revision changes", func():
		var before := _key(frame, Vector3i.ZERO, false)
		frame.set_cell(Vector3i(0, 0, 0), VoxelFrame.material(Color.GREEN))
		var after := _key(frame, Vector3i.ZERO, false)
		expect(after != before, "a revision-only change changes the key")
		_expect_parity(frame, Vector3i.ZERO, false, "revision-only change")
	)
	step("When a copy-on-write chunk replaces the shared chunk", func():
		var cow := VoxelFrame.new()
		cow.set_cell(Vector3i(0, 0, 0), VoxelFrame.material(Color.RED))
		cow.set_cell(Vector3i(48, 0, 0), VoxelFrame.material(Color.RED))
		var center_before := _key(cow, Vector3i.ZERO, false)
		var far_before := _key(cow, Vector3i(3, 0, 0), false)
		var copy := cow.copy_frame()
		copy.set_cell(Vector3i(1, 0, 0), VoxelFrame.material(Color.YELLOW))
		expect(_key(copy, Vector3i.ZERO, false) != center_before, "the replaced chunk changes the key")
		expect(_key(copy, Vector3i(3, 0, 0), false) == far_before, "a non-adjacent untouched chunk keeps its key")
		_expect_parity(copy, Vector3i.ZERO, false, "copy-on-write replacement")
	)
	step("When a face neighbor is removed", func():
		var before := _key(frame, Vector3i.ZERO, false)
		frame.set_cell(Vector3i(16, 0, 0), VoxelFrame.material(Color.TRANSPARENT))
		expect(_key(frame, Vector3i.ZERO, false) != before, "a removed face neighbor changes the key")
		_expect_parity(frame, Vector3i.ZERO, false, "removed neighbor")
	)
	step("When a face neighbor is added", func():
		var before := _key(frame, Vector3i.ZERO, false)
		frame.set_cell(Vector3i(16, 0, 0), VoxelFrame.material(Color.BLUE))
		expect(_key(frame, Vector3i.ZERO, false) != before, "an added face neighbor changes the key")
		_expect_parity(frame, Vector3i.ZERO, false, "added neighbor")
	)
	step("Then a diagonal neighbor changes only the smooth key", func():
		var flat_before := _key(frame, Vector3i.ZERO, false)
		var smooth_before := _key(frame, Vector3i.ZERO, true)
		frame.set_cell(Vector3i(16, 16, 16), VoxelFrame.material(Color.BLUE))
		expect(_key(frame, Vector3i.ZERO, false) == flat_before, "the flat key ignores a diagonal neighbor")
		expect(_key(frame, Vector3i.ZERO, true) != smooth_before, "the smooth key includes a diagonal neighbor")
		_expect_parity(frame, Vector3i.ZERO, true, "diagonal neighbor")
	)
	step("Then a negative chunk matches the legacy key", func():
		var negative := VoxelFrame.new()
		negative.set_cell(Vector3i(-1, -1, -1), VoxelFrame.material(Color.RED))
		negative.set_cell(Vector3i(-16, -1, -1), VoxelFrame.material(Color.BLUE))
		_expect_parity(negative, Vector3i(-1, -1, -1), false, "negative flat")
		_expect_parity(negative, Vector3i(-1, -1, -1), true, "negative smooth")
	)
	step("When two edits publish in one frame with a reused notification array", func():
		State.document = VoxelDocument.new()
		State.paint(Vector3i(1, 0, 0), VoxelFrame.material(Color.RED))
		var positions: Array[Vector3i] = [Vector3i.ZERO]
		State.chunks_changed.emit(0, positions)
		var first := _key(State.get_current_voxel_frame(), Vector3i.ZERO, false)
		State.paint(Vector3i(2, 0, 0), VoxelFrame.material(Color.BLUE))
		State.chunks_changed.emit(0, positions)
		var second := _key(State.get_current_voxel_frame(), Vector3i.ZERO, false)
		expect(first != second, "the reused notification array does not pin a stale key")
		_expect_parity(State.get_current_voxel_frame(), Vector3i.ZERO, false, "reused notification array")
	)
	step("Then a different source frame yields a different key", func():
		var base := State.get_current_voxel_frame()
		var other := base.copy_frame()
		other.set_cell(Vector3i(1, 0, 0), VoxelFrame.material(Color.GREEN))
		expect(_key(other, Vector3i.ZERO, false) != _key(base, Vector3i.ZERO, false), "a changed source frame changes the key")
		var document := VoxelDocument.new()
		document.set_cell(0, Vector3i(1, 0, 0), VoxelFrame.material(Color.GREEN))
		_expect_parity(document.frames[0], Vector3i.ZERO, false, "a separate document")
	)
	step("When an edit is undone and redone", func():
		State.document = VoxelDocument.new()
		State.begin_stroke()
		State.paint(Vector3i(1, 0, 0), VoxelFrame.material(Color.BLUE))
		State.end_stroke()
		var edited := _key(State.get_current_voxel_frame(), Vector3i.ZERO, false)
		State.undo_redo.undo()
		var undone := _key(State.get_current_voxel_frame(), Vector3i.ZERO, false)
		State.undo_redo.redo()
		var redone := _key(State.get_current_voxel_frame(), Vector3i.ZERO, false)
		expect(edited != undone, "undo changes the key")
		expect(edited == redone, "redo restores the same key")
		_expect_parity(State.get_current_voxel_frame(), Vector3i.ZERO, false, "redo restore")
	)
	step("Given a frame the views share", func():
		State.document = VoxelDocument.new()
		frame = _block_frame(Vector3i.ZERO, 32)
		view_a = RENDERER_SCENE.instantiate()
		view_a.source_frame = frame
		main.add_child(view_a)
		view_b = RENDERER_SCENE.instantiate()
		view_b.source_frame = frame
		main.add_child(view_b)
	)
	await _settle_views()
	step("Then both views hold the same key and share one cache entry", func():
		var key_a: PackedInt64Array = view_a._displayed_surface_keys.get(Vector3i.ZERO)
		var key_b: PackedInt64Array = view_b._displayed_surface_keys.get(Vector3i.ZERO)
		expect(key_a != null and key_a.size() > 0, "the first view holds a display key")
		expect(key_a == key_b, "both views computed the same key")
		expect(VoxelRenderer._surface_cache.has(key_a), "the shared cache holds the key once")
	)
	step("Then packed keys hit and evict in the shared cache", func():
		_measure_cache_eviction()
	)
	step("When a view leaves and re-enters the tree", func():
		main.remove_child(view_b)
		main.add_child(view_b)
	)
	await _settle_views()
	step("Then the re-entered view rebuilds its display records", func():
		expect(view_b._displayed_surface_keys.has(Vector3i.ZERO), "the re-entered view has its display record")
		expect(view_a._displayed_surface_keys.has(Vector3i.ZERO), "the other view keeps its display record")
	)
	step("When many chunks are keyed in a warmed loop", func():
		_benchmark()
	)
	step("Then the signature cost is reported", func():
		var legacy_median: int = legacy_samples[legacy_samples.size() / 2]
		var new_median: int = new_samples[new_samples.size() / 2]
		print("MEASURE signature A/B: %d chunks, legacy median %d us, packed median %d us, ratio %.2f" % [
			bench_chunks.size(), legacy_median, new_median, float(new_median) / maxf(1.0, float(legacy_median)),
		])
		expect(legacy_samples.size() == BENCH_REPEATS and new_samples.size() == BENCH_REPEATS, "the benchmark kept independent samples")
	)


# The packed array must behave as an exact content key. A packed array passes by
# reference, so only a duplicate may change after a dictionary holds the key.
func _expect_packed_behavior() -> void:
	var a := PackedInt64Array([1, 2, 3])
	var b := PackedInt64Array([1, 2, 3])
	expect(a == b, "equal packed content compares equal")
	expect(hash(a) == hash(b), "equal packed content hashes equal")
	expect(a != PackedInt64Array([1, 2, 4]), "different packed content compares unequal")
	var dictionary := {}
	dictionary[a] = "v"
	expect(dictionary.has(b), "a content-equal packed key finds the entry")
	expect(dictionary[b] == "v", "the entry reads through the equal packed key")
	var copy := a.duplicate()
	copy[0] = 99
	expect(dictionary.has(PackedInt64Array([1, 2, 3])), "the stored packed key keeps its content")
	expect(copy[0] == 99, "the duplicated packed array changed independently")
	var list: Array[PackedInt64Array] = []
	list.append(a)
	expect(list.has(b), "a typed packed array list finds equal content")
	list.erase(b)
	expect(list.is_empty(), "a typed packed array list erases equal content")


func _expect_parity(active_frame: VoxelFrame, chunk_location: Vector3i, smooth_normals: bool, label: String) -> void:
	var packed := VoxelRenderer._signature(active_frame, chunk_location, smooth_normals)
	var legacy := REFERENCE.legacy_signature(active_frame, chunk_location, smooth_normals)
	var decoded := REFERENCE.decode(packed, smooth_normals)
	parity_cases += 1
	if decoded != legacy:
		parity_mismatches += 1
	expect(decoded == legacy, "%s: the packed key decodes to the legacy key" % label)


func _key(active_frame: VoxelFrame, chunk_location: Vector3i, smooth_normals: bool) -> PackedInt64Array:
	return VoxelRenderer._signature(active_frame, chunk_location, smooth_normals)


# The center chunk plus one face neighbor on each of two axes.
func _neighbor_frame() -> VoxelFrame:
	var built := VoxelFrame.new()
	built.set_cell(Vector3i(0, 0, 0), VoxelFrame.material(Color.RED))
	built.set_cell(Vector3i(16, 0, 0), VoxelFrame.material(Color.BLUE))
	built.set_cell(Vector3i(0, 16, 0), VoxelFrame.material(Color.GREEN))
	return built


func _block_frame(origin: Vector3i, side: int) -> VoxelFrame:
	var built := VoxelFrame.new()
	var cells := {}
	var material := VoxelFrame.material(Color.RED)
	for z in side:
		for y in side:
			for x in side:
				cells[origin + Vector3i(x, y, z)] = material
	built.set_cells(cells)
	return built


func _settle_views() -> void:
	for view in [view_a, view_b]:
		if view:
			while not view.is_settled():
				await get_tree().process_frame


# Hit and evict packed keys in the shared cache. The cache is saved and restored,
# so the check does not disturb the views.
func _measure_cache_eviction() -> void:
	var saved_cache := VoxelRenderer._surface_cache.duplicate()
	var saved_order: Array[PackedInt64Array] = VoxelRenderer._surface_use_order.duplicate()
	var saved_bytes: int = VoxelRenderer._surface_cache_bytes
	VoxelRenderer._surface_cache.clear()
	VoxelRenderer._surface_use_order.clear()
	VoxelRenderer._surface_cache_bytes = 0
	var limit := VoxelRenderer.SURFACE_CACHE_LIMIT_ENTRIES
	for index in limit + 1:
		VoxelRenderer._cache_surface(PackedInt64Array([index + 1]), null, 0, null)
	expect(VoxelRenderer._surface_cache.size() == limit, "the cache keeps its entry limit with packed keys")
	expect(VoxelRenderer._surface_cache.has(PackedInt64Array([limit + 1])), "a content-equal packed key hits the latest entry")
	expect(not VoxelRenderer._surface_cache.has(PackedInt64Array([1])), "the oldest packed key is evicted")
	VoxelRenderer._surface_cache = saved_cache
	VoxelRenderer._surface_use_order = saved_order
	VoxelRenderer._surface_cache_bytes = saved_bytes


# A warmed alternating A/B on one frame. Each implementation keeps its own
# accumulator, so neither can influence the other. Timings are printed, not
# asserted.
func _benchmark() -> void:
	bench_frame = VoxelFrame.new()
	var material := VoxelFrame.material(Color.RED)
	for z in BENCH_CHUNKS:
		for y in BENCH_CHUNKS:
			for x in BENCH_CHUNKS:
				bench_frame.set_cell(Vector3i(x * 16 + 1, y * 16 + 1, z * 16 + 1), material)
	bench_chunks.clear()
	for location in bench_frame.chunks.keys():
		bench_chunks.append(location)
	bench_chunks.sort()
	legacy_samples.clear()
	new_samples.clear()
	var smooth := false
	_legacy_loop(smooth)
	_new_loop(smooth)
	for repeat in BENCH_REPEATS:
		if repeat % 2 == 0:
			legacy_samples.append(_legacy_loop(smooth))
			new_samples.append(_new_loop(smooth))
		else:
			new_samples.append(_new_loop(smooth))
			legacy_samples.append(_legacy_loop(smooth))
	legacy_samples.sort()
	new_samples.sort()


func _legacy_loop(smooth_normals: bool) -> int:
	var sink := 0
	var started := Time.get_ticks_usec()
	for location in bench_chunks:
		sink += REFERENCE.legacy_signature(bench_frame, location, smooth_normals).length()
	legacy_sink = sink
	return Time.get_ticks_usec() - started


func _new_loop(smooth_normals: bool) -> int:
	var sink := 0
	var started := Time.get_ticks_usec()
	for location in bench_chunks:
		sink += VoxelRenderer._signature(bench_frame, location, smooth_normals).size()
	new_sink = sink
	return Time.get_ticks_usec() - started
