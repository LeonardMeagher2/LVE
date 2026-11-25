extends "res://tests/test.gd"


const MODELS := [
	{"name": "flamingo_v1", "path": "C:/Users/meagh/Downloads/Flamingo.lve", "all_frames": true},
	{"name": "splash", "path": "res://splash.lve", "all_frames": true},
	{"name": "failed_greed", "path": "res://tests/fixtures/FailedGreed.lve", "all_frames": true},
	{"name": "sword_and_shield", "path": "C:/Users/meagh/Downloads/LVE-prototypes/LVE-prototypes/sword_and_shield.lve", "all_frames": true},
	{"name": "pumpkin", "path": "C:/Users/meagh/Downloads/LVE-prototypes/LVE-prototypes/Pumpkin.lve", "all_frames": true},
	{"name": "flamingo", "path": "C:/Users/meagh/Downloads/LVE-prototypes/LVE-prototypes/flamingo.lve", "all_frames": true},
	{"name": "krab", "path": "C:/Users/meagh/Downloads/LVE-prototypes/LVE-prototypes/Krab.lve", "all_frames": true},
	{"name": "me", "path": "C:/Users/meagh/Downloads/LVE-prototypes/LVE-prototypes/me.lve", "all_frames": true},
	{"name": "noodle_stand", "path": "C:/Users/meagh/Downloads/LVE-prototypes/LVE-prototypes/noodle_stand.lve", "all_frames": true},
	{"name": "egypt", "path": "C:/Users/meagh/Downloads/LVE-prototypes/LVE-prototypes/egypt.lve", "all_frames": true},
	{"name": "dragon", "path": "C:/Users/meagh/Downloads/LVE-prototypes/LVE-prototypes/Dragon.lve", "all_frames": false},
	{"name": "brain", "path": "C:/Users/meagh/Downloads/LVE-prototypes/LVE-prototypes/brain.lve", "all_frames": false},
	{"name": "drowned_cathedral", "path": "C:/Users/meagh/Downloads/LVE-prototypes/LVE-prototypes/drowned_cathedral.lve", "all_frames": false},
]

const WELD_VERTEX_LIMIT := 2000000
const CHUNK_SIZE := VoxelFrame.CHUNK_SIZE

var loaded := 0
var measured := 0
var filter: PackedStringArray = []
var debug := false
var profile := false


func _ready() -> void:
	timeout = 1800.0
	debug = not OS.get_environment("LVE_DEBUG").is_empty()
	profile = not OS.get_environment("LVE_PROFILE").is_empty()
	var wanted := OS.get_environment("LVE_MODELS")
	if not wanted.is_empty():
		filter = wanted.split(",", false)
	test("the low poly mesher closes every model", _measure, "low_poly_models")


func _measure() -> void:
	step("Given prototype models on disk and in the repository", func():
		expect(MODELS.size() > 0, "the model list is present")
	)
	step("When each model builds its low poly surface", func():
		for entry in MODELS:
			_measure_model(entry)
	)
	step("Then every model that loads builds a surface", func():
		expect(loaded > 0, "at least one model loads")
		expect(measured > 0, "at least one frame builds low poly geometry")
	)


func _measure_model(entry: Dictionary) -> void:
	if not filter.is_empty() and not _selected(entry.name):
		return
	var document := VoxelDocument.load_file(entry.path)
	if document == null:
		print("MODEL %s skipped: does not load" % entry.name)
		return
	loaded += 1
	var frame_count := document.frames.size()
	var limit := frame_count if entry.all_frames else mini(1, frame_count)
	print("MODEL %s frames=%d measuring=%d" % [entry.name, frame_count, limit])
	for index in limit:
		_measure_frame(document.frames[index], entry.name, index, frame_count)
	document.frames.clear()


func _measure_frame(frame: VoxelFrame, name: String, index: int, frame_count: int) -> void:
	var voxels := 0
	for chunk: VoxelFrame.Chunk in frame.chunks.values():
		voxels += chunk.occupied_count
	var locations: Array[Vector3i] = []
	var meshers: Array[VoxelLowPolyMesh] = []
	for location: Vector3i in frame.chunks:
		locations.append(location)
		var mesher := VoxelLowPolyMesh.new()
		mesher.profile = profile
		meshers.append(mesher)
	var started_us := Time.get_ticks_usec()
	var tasks: Array[int] = []
	for mesher_index in meshers.size():
		var task := Callable(self, "_build_chunk").bind(meshers[mesher_index], frame, locations[mesher_index])
		tasks.append(WorkerThreadPool.add_task(task, false, "low poly chunk"))
	for task in tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	var build_us := Time.get_ticks_usec() - started_us
	var phases := {}
	for mesher in meshers:
		for key in mesher.phase_us:
			phases[key] = phases.get(key, 0) + mesher.phase_us[key]
	if profile:
		print("PHASE %s[%d] %s" % [name, index + 1, phases])
	var verify_started_us := Time.get_ticks_usec()
	var totals := {"triangles": 0, "degenerate": 0, "duplicate": 0}
	var vertices := 0
	var positions_all := PackedVector3Array()
	var indices_all := PackedInt32Array()
	var weld_skipped := not OS.get_environment("LVE_NOWELD").is_empty()
	for mesher_index in meshers.size():
		var mesher := meshers[mesher_index]
		totals["triangles"] += mesher.triangle_count
		totals["degenerate"] += mesher.degenerate_triangles
		totals["duplicate"] += _unwelded_nonmanifold(mesher.arrays[Mesh.ARRAY_INDEX])
		var arrays := mesher.arrays
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		vertices += positions.size()
		if not weld_skipped:
			var origin := Vector3(locations[mesher_index] * CHUNK_SIZE)
			var base := positions_all.size()
			for position: Vector3 in positions:
				positions_all.append(position + origin)
			for cell_index: int in arrays[Mesh.ARRAY_INDEX]:
				indices_all.append(base + cell_index)
			if positions_all.size() > WELD_VERTEX_LIMIT:
				weld_skipped = true
				positions_all = PackedVector3Array()
				indices_all = PackedInt32Array()
	var fine := Vector2i(-1, -1)
	var coarse := -1
	if not weld_skipped:
		fine = _open_edges(positions_all, indices_all, 10000.0, debug)
		coarse = _open_edges(positions_all, indices_all, 100.0).x
	var verify_us := Time.get_ticks_usec() - verify_started_us
	print("FRAME %s[%d/%d] voxels=%d chunks=%d/%d triangles=%d quads=%d degenerate=%d duplicate=%d open1e-4=%s open1e-2=%s nonmanifold=%s vertices=%d build_ms=%d verify_ms=%d" % [
		name, index + 1, frame_count, voxels, meshers.size(), frame.chunks.size(), totals["triangles"],
		totals["triangles"] / 2, totals["degenerate"], totals["duplicate"],
		"skipped" if fine.x < 0 else str(fine.x), "skipped" if coarse < 0 else str(coarse),
		"skipped" if fine.y < 0 else str(fine.y), vertices, build_us / 1000, verify_us / 1000,
	])
	if totals["triangles"] > 0:
		measured += 1


func _build_chunk(mesher: VoxelLowPolyMesh, frame: VoxelFrame, location: Vector3i) -> void:
	mesher.build_region(frame, location * CHUNK_SIZE, Vector3i.ONE * CHUNK_SIZE)
	mesher.release_scratch()


func _selected(name: String) -> bool:
	for wanted in filter:
		if name.contains(wanted):
			return true
	return false


func _open_edges(positions: PackedVector3Array, indices: PackedInt32Array, scale: float, debug := false) -> Vector2i:
	var lookup := {}
	var welded := PackedInt32Array()
	var points: Array[Vector3] = []
	for position: Vector3 in positions:
		var key := Vector3i((position * scale).round())
		if not lookup.has(key):
			lookup[key] = lookup.size()
			points.append(position)
		welded.append(lookup[key])
	var edges := {}
	var ends := {}
	for index in range(0, indices.size(), 3):
		var a := welded[indices[index]]
		var b := welded[indices[index + 1]]
		var c := welded[indices[index + 2]]
		for edge in [[a, b], [b, c], [c, a]]:
			var key := mini(int(edge[0]), int(edge[1])) * 1000000 + maxi(int(edge[0]), int(edge[1]))
			edges[key] = edges.get(key, 0) + 1
			ends[key] = edge
	var open := 0
	var nonmanifold := 0
	for key in edges:
		if edges[key] == 1:
			open += 1
			if debug and open <= 16:
				var pair: Array = ends[key]
				print("OPEN %s -> %s" % [points[pair[0]], points[pair[1]]])
		elif edges[key] > 2:
			nonmanifold += 1
			if debug:
				var pair: Array = ends[key]
				print("NONMANIFOLD x%d %s -> %s" % [edges[key], points[pair[0]], points[pair[1]]])
	return Vector2i(open, nonmanifold)


func _unwelded_nonmanifold(indices: PackedInt32Array) -> int:
	var edges := {}
	for index in range(0, indices.size(), 3):
		var trio := [indices[index], indices[index + 1], indices[index + 2]]
		for edge in [[trio[0], trio[1]], [trio[1], trio[2]], [trio[2], trio[0]]]:
			var key := mini(int(edge[0]), int(edge[1])) * 1000000 + maxi(int(edge[0]), int(edge[1]))
			edges[key] = edges.get(key, 0) + 1
	var count := 0
	for key in edges:
		if edges[key] > 2:
			count += 1
	return count