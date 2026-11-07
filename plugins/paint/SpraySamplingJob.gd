extends VoxelFrame.EditJob

## One cancellable spray sample that runs on the worker pool.
##
## The job holds every input explicitly: a copy-on-write frame snapshot, the
## brush cell, the symmetry axes and origin, the read-only selection, the full
## material, the spot size, the search size, the number of spot centers, and the
## exact captured random state. It reads no Node, no State, and no settings
## resource, so the same inputs give the same cells wherever the job runs.
##
## [method VoxelFrame.EditJob.run] is the worker body. A caller keeps the job and
## owns the join, the operation, and the install of [member cells].

const SpraySampler := preload("./SpraySampler.gd")
const VoxelPreview := preload("res://Globals/Rendering/VoxelPreview.gd")

## The copy-on-write frame snapshot to sample from.
var frame: VoxelFrame
## The live frame that the snapshot copies. The caller compares the current frame
## against this identity, so a frame or document change drops the result.
var source_frame: VoxelFrame
## The sampled brush cell.
var center := Vector3i.ZERO
## The symmetry axes of the frozen edit context.
var axes := 0
## Twice the symmetry origin of the frozen edit context.
var origin_twice := Vector3i.ZERO
## The read-only selection of the frozen edit context.
var selection := {}
## The world axis of the writable slice, or -1 when every layer is writable.
var slice_axis := -1
## The first writable layer along [member slice_axis].
var slice_index := 0
## The number of writable layers from [member slice_index].
var slice_count := 1
## The full material of every written cell.
var material := PackedFloat32Array()
## The spot diameter in cells.
var spot_size := 1
## The spray search width in cells.
var search_size := 9
## The number of distinct spot centers.
var speed := 8
## The random state of this sample. The job restores its own source from this
## exact state, so a worker draws the same sequence as an inline sample and no
## shared random state is read on the worker.
var sample_state := 0
## The random state after this sample. The caller commits it only when the result
## is adopted, so a cancelled or obsolete sample never advances the shared stream.
var result_state := 0
## The shared random epoch that the caller held when it built this job. A later
## inline sample or adopted worker result moves the epoch, so this older result
## cannot rewind the stream.
var rng_epoch := 0
## The shared spot shape cache.
var shape_cache: RefCounted
## The chunks that the frozen snapshot captured.
var capture_chunk_count := 0
## The frozen selection masks, or null when the caller has none. The sampler uses
## them for a large selection and returns the built index in
## [member built_selection_index].
var selection_index: RefCounted
## The selection masks that the sample used or built, or null.
var built_selection_index: RefCounted
## The chunk row builds that the sample paid.
var index_builds := 0
## The dense grid slots that those builds read.
var index_grid_reads := 0
## The row masks that those builds wrote.
var index_build_slots := 0
## The selection mask builds that the sample paid.
var selection_builds := 0
## The total indexed row operations of the sample.
var row_ops := 0
## The occupied footprint cells that the sample visited.
var footprint_visits := 0
## The request epoch of this sample. A caller drops a result whose epoch is not
## the newest installed one.
var request_epoch := 0
## The sampled write set. Empty until the worker publishes it.
var cells: Array[Vector3i] = []
## The identity and the voxel revision of every chunk that holds a sampled cell.
var witness := {}
## The prepared preview payload of the sampled batch, or null until the worker
## builds it. The worker builds the read-only color dictionary and the cell hash
## here, so the main thread never does that work for a large batch.
var preview_payload: VoxelPreview.SolidPayload
## The indexed row work estimate of the sample. It sizes the progress total.
var local_estimate := 0
## The legacy gathered cell count. The indexed sampler reports zero, because it
## never gathers the reach range.
var local_count := 0
## The candidate cell count inside the search sphere, or zero before the worker
## runs.
var candidate_count := 0

## Samples the batch. This is the worker body.
func run() -> void:
	var context := VoxelFrame.EditContext.new()
	context.axes = axes
	context.origin_twice = origin_twice
	context.selection = selection
	var rng := RandomNumberGenerator.new()
	rng.state = sample_state
	stage("Sampling spray", local_estimate)
	var report := {}
	cells = SpraySampler.sample(center, frame, context, spot_size, search_size, speed, rng, material, shape_cache, self, report, selection_index)
	# The slice limits the sampled cells, so the cursor shows exactly the cells a
	# press writes. The write gate repeats the test, so a later scope cannot pass.
	if slice_axis >= 0:
		var kept: Array[Vector3i] = []
		for cell in cells:
			if cell[slice_axis] >= slice_index and cell[slice_axis] < slice_index + slice_count:
				kept.append(cell)
		cells = kept
	local_count = report.get("local", 0)
	candidate_count = report.get("candidates", 0)
	built_selection_index = report.get("selection_index")
	index_builds = report.get("index_builds", 0)
	index_grid_reads = report.get("index_grid_reads", 0)
	index_build_slots = report.get("index_build_slots", 0)
	selection_builds = report.get("selection_builds", 0)
	row_ops = report.get("row_ops", 0)
	footprint_visits = report.get("footprint_visits", 0)
	result_state = rng.state
	# A cancelled union leaves no cells behind, so a caller never adopts a partial
	# batch and no payload is built for it.
	if not checkpoint(0):
		cells = []
		return
	# The witness comes from the snapshot, so it records the chunk object the
	# sample read. A caller compares it against the live frame.
	witness = SpraySampler.witness(frame, cells)
	# The payload is one uniform color, which is the solid preview of the spray
	# cursor. The main thread submits it without a value scan.
	preview_payload = VoxelPreview.build_solid_payload(cells, VoxelFrame.material_color(material))
