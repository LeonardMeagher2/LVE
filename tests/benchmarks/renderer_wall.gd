extends "res://tests/test.gd"


const SPAN := 3
const CHUNK := VoxelFrame.CHUNK_SIZE
const MAX_FRAMES := 600

var renderer: VoxelRenderer
var locations: Array[Vector3i] = []


func _ready() -> void:
	timeout = 900.0
	test("the app path reports where the renderer spends its wall time", _cost, "renderer_wall")


func _cost() -> void:
	step("Given a 27 chunk mixed document on the editor", func():
		var document := VoxelDocument.new()		document.frames.clear()
		var frame := _fixture()
		document.frames.append(frame)
		State.stop()
		State.document = document
		State.document.smooth_normals = false
		State.document.ao_strength = 0.0
		State.current_frame = 0
		var cap := OS.get_environment("LVE_JOB_CAP")
		if cap.is_valid_int():
			VoxelRenderer._surface_job_limit = int(cap)
		print("DOC_SETTINGS smooth=%s ao=%.2f cap=%d" % [
			State.document.smooth_normals, State.document.ao_strength, VoxelRenderer._job_limit(),
		])
		for location: Vector3i in frame.chunks:
			locations.append(location)
		renderer = editor_viewport().find_child("VoxelRenderer", true, false)
		expect(renderer != null, "the editor viewport holds a renderer")
		if renderer == null:
			return
		renderer.report_activity = false
		renderer.reset_profile()
		renderer.profile_surfaces = true
		expect(locations.size() == 27, "the fixture holds 27 chunks")
	)
	if DisplayServer.get_name() == "headless" or renderer == null:
		step("Then the wall benchmark needs a window", func():
			expect(true, "a headless run cannot create ArrayMesh surfaces")
		)
		return
	var started := Time.get_ticks_usec()
	var frames := 0
	var rebuild_started := 0
	var rebuild_frames := 0
	var rebuild_frame_us: Array[int] = []
	var emit_all_us := 0
	var per_chunk_emit_us: Array[int] = []
	var rebuild_mutate_us := 0
	var rebuild_emit_us := 0
	var rebuild_first_wait_us := 0
	var rebuild_window_started := 0
	step("When the document reports its chunks", func():
		State.chunks_changed.emit(0, locations)
	)
	while frames < MAX_FRAMES:
		await get_tree().process_frame
		frames += 1
		var progress: Dictionary = renderer.profile_snapshot()
		if frames <= 40:
			print("FRAME %d pending=%d inflight=%d jobs=%d reaped=%d consume=%d truncated=%d" % [
				frames, int(progress.get("pending", 0)), int(progress.get("inflight", 0)),
				int(progress.get("jobs", 0)), int(progress.get("reaped", 0)),
				int(progress.get("consume", 0)), int(progress.get("truncated", 0)),
			])
		if int(progress.get("reaped", 0)) + int(progress.get("consume", 0)) >= locations.size():
			break
	var elapsed := Time.get_ticks_usec() - started
	var profile: Dictionary = renderer.profile_snapshot()
	step("Then the profile reports the shares", func():
		print("SNAPSHOT " + JSON.stringify(profile))
		print("MEASURE renderer_wall: us=%d frames=%d chunks=%d reaped=%d consume=%d launched=%d cap=%d cores=%d" % [
			elapsed, frames, locations.size(), int(profile.get("reaped", 0)), int(profile.get("consume", 0)),
			int(profile.get("launch", 0)), VoxelRenderer._job_limit(), OS.get_processor_count(),
		])
		print("MEASURE renderer_wall shares: snapshot_us=%d install_us=%d material_us=%d cache_us=%d truncated=%d snapshots=%d" % [
			int(profile.get("snapshot_us", 0)), int(profile.get("install_us", 0)),
			int(profile.get("material_us", 0)), int(profile.get("cache_us", 0)),
			int(profile.get("truncated", 0)), int(profile.get("snapshots", 0)),
		])
		expect(int(profile.get("reaped", 0)) + int(profile.get("consume", 0)) >= locations.size(), "the renderer installs or resolves every chunk")
	)
	step("Then the change subscribers are listed", func():
		for connection in State.chunks_changed.get_connections():
			print("CHUNKS_CONN " + str(connection["callable"].get_object()))
		for connection in State.cells_changed.get_connections():
			print("CELLS_CONN " + str(connection["callable"].get_object()))
		expect(true, "the subscribers are listed")
	)
	step("When every chunk cell changes", func():
		var mutate_started := Time.get_ticks_usec()
		for location: Vector3i in locations:
			State.document.set_cell(0, location * CHUNK + Vector3i(8, 8, 8), VoxelFrame.material(Color.WHITE))
		var mutate_ended := Time.get_ticks_usec()
		renderer.reset_profile()
		rebuild_started = mutate_ended
		State.chunks_changed.emit(0, locations)
		var emit_ended := Time.get_ticks_usec()
		rebuild_mutate_us = mutate_ended - mutate_started
		rebuild_emit_us = emit_ended - mutate_ended
		rebuild_window_started = emit_ended
	)
	await get_tree().process_frame
	rebuild_first_wait_us = Time.get_ticks_usec() - rebuild_window_started
	while rebuild_frames < MAX_FRAMES:
		var frame_started := Time.get_ticks_usec()
		await get_tree().process_frame
		rebuild_frame_us.append(Time.get_ticks_usec() - frame_started)
		rebuild_frames += 1
		var rebuild_progress: Dictionary = renderer.profile_snapshot()
		if int(rebuild_progress.get("reaped", 0)) + int(rebuild_progress.get("consume", 0)) >= locations.size():
			break
	var rebuild_elapsed := Time.get_ticks_usec() - rebuild_started
	var rebuild_profile: Dictionary = renderer.profile_snapshot()
	for location: Vector3i in locations:
		State.document.set_cell(0, location * CHUNK + Vector3i(9, 9, 9), VoxelFrame.material(Color.BLACK))
	renderer.reset_profile()
	for location: Vector3i in locations:
		var one: Array[Vector3i] = [location]
		var single_started := Time.get_ticks_usec()
		State.chunks_changed.emit(0, one)
		per_chunk_emit_us.append(Time.get_ticks_usec() - single_started)
	step("Then the rebuild wall and the cold wall are both reported", func():
		print("MEASURE renderer_wall rebuild: us=%d frames=%d reaped=%d consume=%d launched=%d install_us=%d truncated=%d" % [
			rebuild_elapsed, rebuild_frames, int(rebuild_profile.get("reaped", 0)), int(rebuild_profile.get("consume", 0)),
			int(rebuild_profile.get("launch", 0)), int(rebuild_profile.get("install_us", 0)), int(rebuild_profile.get("truncated", 0)),
		])
		var slowest := rebuild_frame_us.duplicate()
		slowest.sort()
		slowest.reverse()
		print("MEASURE renderer_wall frames_us: " + str(slowest.slice(0, 8)))
		print("MEASURE renderer_wall first_frames_us: " + str(rebuild_frame_us.slice(0, 12)))
		print("MEASURE renderer_wall emit_all_us=%d" % emit_all_us)
		var frame_sum := 0
		for value in rebuild_frame_us:
			frame_sum += int(value)
		print("MEASURE renderer_wall stages: mutate_us=%d emit_us=%d first_wait_us=%d frames=%d frame_sum_us=%d wall_from_emit_us=%d" % [
			rebuild_mutate_us, rebuild_emit_us, rebuild_first_wait_us, rebuild_frames, frame_sum, rebuild_elapsed,
		])
		print("MEASURE renderer_wall per_chunk_emit_us: " + str(per_chunk_emit_us))
		expect(int(rebuild_profile.get("reaped", 0)) + int(rebuild_profile.get("consume", 0)) >= locations.size(), "the rebuild resolves every chunk")
	)


func _fixture() -> VoxelFrame:
	var value := VoxelFrame.new()
	var flat := VoxelFrame.material(Color.from_rgba8(90, 160, 220))
	var metal := VoxelFrame.material(Color.from_rgba8(220, 120, 70), Color(0.2, 0.1, 0.0), 0.8, 0.2)
	var rough := VoxelFrame.material(Color(0.1, 0.4, 0.9), Color.BLACK, 0.0, 1.0)
	var translucent := VoxelFrame.material(Color(1.0, 0.0, 0.0, 0.5))
	for cz in SPAN:
		for cy in SPAN:
			for cx in SPAN:
				var location := Vector3i(cx, cy, cz)
				var chunk := VoxelFrame.Chunk.new()
				chunk.location = location
				chunk.occupied_count = CHUNK * CHUNK * CHUNK
				chunk.shared_materials = true
				chunk.bounds_dirty = false
				chunk.occupied_bounds = AABB(Vector3(location * CHUNK) - Vector3.ONE * 0.5, Vector3.ONE * CHUNK)
				for lz in CHUNK:
					for ly in CHUNK:
						for lx in CHUNK:
							chunk.grid[VoxelFrame.Chunk.cell_slot(Vector3i(lx, ly, lz))] = 1 + ((lx + ly + lz) % 4)
				chunk.materials = rough.duplicate()
				chunk.materials.append_array(metal)
				chunk.materials.append_array(flat)
				chunk.materials.append_array(translucent)
				value.chunks[location] = chunk
	value.restore(value.chunks)
	return value
