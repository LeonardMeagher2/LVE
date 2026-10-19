extends "res://tests/test.gd"

# An edit reports each chunk that needs a new surface. A mesher reads one cell
# beyond its chunk, so only cells on a chunk face affect a neighbor.

const BLOCK_SIZE := 32
const CHUNK := Vector3i.ZERO

var frame: VoxelFrame
var renderer: VoxelRenderer
var material := VoxelFrame.material(Color.RED)
var reported: Array[Vector3i] = []


func _ready() -> void:
	test("an edit reports only the chunks whose mesher input changed", _run)


func _run() -> void:
	step("Given a settled solid 32-cube", func():
		State.document = VoxelDocument.new()
		frame = State.get_current_voxel_frame()
		var cells := {}
		for z in BLOCK_SIZE:
			for y in BLOCK_SIZE:
				for x in BLOCK_SIZE:
					cells[Vector3i(x, y, z)] = material
		frame.set_cells(cells)
		renderer = viewport_scene().get_node("VoxelRenderer")
		sync_viewport()
	)
	await _settle()
	step("Then every chunk of the block is drawn", func():
		expect(renderer.is_settled(), "the renderer finished the initial surfaces")
		expect(renderer._chunk_instances.size() == 8, "the block covers eight chunks")
	)

	step("When an interior cell changes material", func():
		reported = _edit(Vector3i(8, 8, 8))
	)
	step("Then only the owning chunk is rebuilt", func():
		expect(reported == [CHUNK], "an interior cell rebuilds only its own chunk")
		expect(_pending() == [CHUNK], "the renderer requests only that chunk")
	)
	await _settle()

	step("When a cell on the positive x face changes material", func():
		reported = _edit(Vector3i(15, 8, 8))
	)
	step("Then the owning chunk and its face neighbor are rebuilt", func():
		expect(reported == [CHUNK, Vector3i(1, 0, 0)], "a face cell also rebuilds the neighbor across that face")
		expect(_pending() == [CHUNK, Vector3i(1, 0, 0)], "the renderer requests the chunk and its face neighbor")
	)
	await _settle()

	step("When the corner cell at 15,15,15 changes material", func():
		reported = _edit(Vector3i(15, 15, 15))
	)
	step("Then every chunk that reads that corner is rebuilt", func():
		var corners: Array[Vector3i] = []
		for z in range(0, 2):
			for y in range(0, 2):
				for x in range(0, 2):
					corners.append(Vector3i(x, y, z))
		corners.sort()
		var sorted_reported := reported.duplicate()
		sorted_reported.sort()
		expect(sorted_reported == corners, "a corner cell reports all eight corner chunks")
		var requested := _pending()
		var within_reported := true
		for chunk_location in requested:
			within_reported = within_reported and reported.has(chunk_location)
		expect(within_reported, "the renderer requests no chunk outside the reported set")
	)
	await _settle()

	step("When the same material is written again", func():
		reported = _edit(Vector3i(8, 8, 8))
	)
	step("Then no surface is rebuilt", func():
		expect(reported.is_empty(), "a repeated material write reports no chunk")
		expect(renderer.is_settled(), "the renderer stays idle after a repeated write")
	)


func _edit(cell_position: Vector3i) -> Array[Vector3i]:
	var changed := frame.set_cells({cell_position: VoxelFrame.material(Color.BLUE)})
	State.chunks_changed.emit(State.current_frame, changed)
	return changed


func _pending() -> Array[Vector3i]:
	var pending: Array[Vector3i] = []
	pending.assign(renderer._pending_surface_keys.keys())
	pending.sort()
	return pending


func _settle() -> void:
	while not renderer.is_settled():
		await get_tree().process_frame
