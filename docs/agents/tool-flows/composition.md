# Composition guide: current shared mechanisms

Use this guide when a new tool needs an existing shared mechanism.
It covers the current A to H slices.
This guide does not define a universal tool class, registry, event bus, or controller.

## Rules

1. Separate pure preparation, worker calculation, and main-thread publication.
2. Keep ownership local. The tool owns its operation id, revision or epoch, queue, cursor, cancel path, and undo scope.
3. Write the capture point for each operation. Do not move a capture point into a shared helper.
4. Define completion in separate steps. Input release, worker done, queue drained, cursor done, and commit are different events.
5. Reuse a mechanism only when its contract matches. Keep tool-specific policies visible.
6. Add no universal base tool, tool registry, event bus, controller, or universal policy flag set. A capability flag on one mechanism is allowed when its owner and contract stay explicit.

## A. Existing edit-job runner

### Current signature

`State.run_edit_job(job: VoxelFrame.EditJob, operation_id: int, task_name: String, on_frame: Callable = Callable()) -> void`

### Current callers

- `ClipboardPlugin._copy_voxels`
- `ClipboardPlugin.paste_voxels` for the import
- `LineTool._start_preview`

### Ownership

The caller owns the job, the operation id, the result, and the cancel policy.
The runner owns the worker start, the progress pump, and the join.
The runner calls `on_frame` before each progress update.
The runner joins exactly once.
A caller that waits itself retires the task id, so the runner stops without a second wait.
`ClipboardPlugin._exit_tree` uses the same join.

### Policy examples

- Clipboard copy and cut cancel when the document or frame changes. They install only after the runner returns and the checkpoint passes.
- Line cancels a superseded preview through `_cancel_preview_if_stale`. Its `_process` override updates idle hover only when no anchor is open. The base `_process` is unconditional. `_service_preview` starts the newest request after the runner returns.
- Paste overrides `_begin_preview_operation` and `_finish_preview_operation`. The placement and the preview share `_placement_operation_id`.
- These two virtual methods are a narrow status seam for Line and Paste. They are not a general hook framework.

### Reuse when

- One worker body needs progress and a guaranteed join.
- A per-frame context check can cancel the job.
- The caller can keep its own result gate, undo scope, and install step.

### Do not reuse when

- The work is inline only.
- The caller needs a different completion rule.
- The job must outlive the caller without a join.

## B. Terrain captured inputs and footprint depth

### Current types and signatures

- `TerrainTool.StrokeInputs` holds `tool`, `build_mode`, `radius`, `strength`, `falloff`, `material`, `selection`, `context`, and `frame_index`.
- `TerrainTool._run_tick()` sets up `TerrainTickJob` for Build and Flatten.
- `TerrainTool._run_smooth()` sets up `SmoothJob`.
- `TerrainPreview.footprint_depth(size: int) -> int`
- `TerrainTool._footprint_depth(radius: int) -> int`
- `TerrainTool._height_depth() -> int`
- `TerrainPreview.watch_half(radius: int) -> int`
- `TerrainPreview.watch_half_for(radius: int, depth: int) -> int`

### Current callers

- `TerrainTool.open_stroke` creates `StrokeInputs`.
- `_run_tick` serves Build and Flatten.
- `_run_smooth` serves Smooth.
- `_height_depth` serves the sample map and `job.prep_depth`.
- `_footprint_depth` serves the Smooth refit, the prep jobs, and the preview inputs.
- `HoverJob` uses `watch_half` for the fit and `watch_half_for` for the map.

### Ownership

The tool owns the mutable execution state: planes, anchors, samples, progress, and drains.
`StrokeInputs` owns only the captured inputs.
`StrokeInputs` is a Terrain-family record.
A new tool must copy the capture pattern, not reuse this type or its fields.
The material is duplicated. The selection is the frozen edit-context selection.
The jobs own their frame snapshots and their job inputs.

### Policy examples

- Build uses `_height_depth()`: `min(64, max(8, 2 * size))`.
- Flatten and the other tools use `_height_depth()` 64.
- Smooth uses `footprint_depth(size)`: `min(64, max(16, size))`. Grab returns the same value from the helper, but its source capture uses ball offsets.
- The fit watch and the map watch stay separate.

### Reuse when

- A stroke must ignore later settings or selection changes.
- A hover and an executed dab must read the same footprint depth.
- A job needs a frozen frame snapshot and a captured selection.

### Do not reuse when

- The tool needs live settings for a hover.
- The tool needs a different capture time.
- The tool cannot copy its material or freeze its selection.

## C. Preview request identity and final spray centers

### Current signatures

- `VoxelPreview.show_voxels(colors: Dictionary, color: Color, outline: bool = false, cube_diameter: int = 0, use_voxel_colors: bool = true, token: Variant = null) -> void`
- `VoxelPreview._request(cells: Dictionary, style: PreviewStyle, use_voxel_colors: bool = false, color_key: Color = Color.WHITE, token: Variant = null, mask_chunks: Dictionary = {}) -> void`
- `VoxelPreview.SolidPayload.token: Variant`
- `VoxelPreview.PreviewJob.token: Variant`
- `VoxelPreview.installed_token() -> Variant`
- `SprayTool.BatchToken` holds `center`, `frame`, `axes`, `origin_twice`, and `selection`.
- `SprayTool._make_batch_token(frame: VoxelFrame, center: Vector3i, context: VoxelFrame.EditContext) -> BatchToken`
- `SprayTool._shown_owned_by_press(token: Variant) -> bool`
- `BrushJob.centers_are_final: bool`

### Current callers

- `SprayTool._show_spots` passes `_batch_token` to `show_voxels` or `SolidPayload.token`.
- `SprayTool._apply_offered` reads `installed_cells` and `installed_token`.
- `SprayTool._build_job` sets `centers_are_final`.
- Other preview callers leave the token null and `centers_are_final` false.

### Ownership

The tool owns the token and its fields.
`VoxelPreview` owns the installed surface and reports its token.
The token is opaque metadata. It is not part of the mesh key.
Capture the token before submit. Do not mutate it while a job is in flight or a surface is installed.
A worker job keeps its own token.
A cache hit reports the token of the request that asked for the hit. Caches do not clone the payload token.
A clear drops the installed token.

### Policy examples

- A lagging surface of the same cell and context can paint.
- A surface of another cell never paints.
- The Spray write skips the second `EditContext.expand` only.
- The write still applies the selection mask, the existing-only filter, and the captured material.

### Reuse when

- A caller must attribute a visible surface to its request.
- A cache hit must report the current request identity.
- A producer already expanded the final cells and the write can skip one expansion.

### Do not reuse when

- The surface identity is already exact from the cell set.
- The write still needs the second expansion.
- The caller cannot compare the token fields safely.

## D. Bounded batch cursor

### Current signature

- `VoxelRegionSearch.BatchQueue`
- `BatchQueue.LIMIT = 4`
- `BatchQueue.push(batch: Dictionary) -> bool`
- `BatchQueue.take() -> Dictionary`
- `BatchQueue.cancel() -> void`
- `BatchQueue.is_empty() -> bool`
- `BatchQueue.depth() -> int`
- `BatchCursor.queue: BatchQueue`
- `BatchCursor.keys: Array`
- `BatchCursor.cursor: int`
- `BatchCursor.is_done() -> bool`
- `BatchCursor.next_end(limit: int) -> int`
- `BatchCursor.apply_slice(limit: int, apply: Callable) -> bool`

The callback signature is `(keys: Array, start: int, end: int) -> bool`.

`apply_slice` returns `false` when the queue is null, a nested call is active, no key waits, or the callback returns `false`.
The cursor advances only after the callback returns `true`.
A refused slice remains pending for the next attempt. A cancelled owner discards its own cursor.
`is_done` means the queue is empty and the cursor reached the end of the current keys.
It does not mean the producer finished. Check the producer task and `is_done` separately.
`next_end` loads the next batch only when the current keys are consumed.

### Current callers

- `FillTool._drain_fill_batches` binds `_apply_fill_slice`.
- `WandSelectTool._drain_selection_batches` binds `_apply_selection_slice`.

### Ownership

The cursor owns the queue reference, the current keys, and the cursor.
The producer owns `push`.
The tool owns `cancel`, the join, and the edit handle.
The consumer owns the slice callback and the main-thread apply.
A full queue blocks the producer, not the consumer.
One cursor serves one operation. Do not share a cursor across operations.

### Reuse when

- A worker produces key lists into a bounded queue.
- The main thread applies a `[start, end)` range of keys.
- The callback can refuse stale work and return `false`.
- The operation can check the producer task and `is_done` separately.

### Do not reuse when

- The work is not a key list.
- The consumer needs a different batch shape.
- The producer cannot block on a full queue.
- The callback cannot return a bool.
- Do not delegate undo, cancel, or completion policy to the cursor. The clients keep different policies.
- The stream is a preview. Use the `VoxelPreview` request policy instead.
- The stream is an accepted stroke queue. Use the tool's own queue instead.

### Tool policies that stay local

| Policy | Fill | Wand |
| --- | --- | --- |
| Slice size | Adaptive 64 to 512 cells | Fixed 256 cells |
| Frame budget | One 2000 us budget shared by the seeds of a frame | One 2000 us budget per frame |
| Publication | Coalesced chunk ids at three frames and 20 ms | One `selection_changed` after a merge |
| Edit handle | `open_stroke` and `abort_stroke` | `State.begin_edit` and `State.cancel_edit` |
| Undo | One `Stroke` action | One `Wand selection` action |
| Cancel | Revision, queue cancel, and abort | Retire and join, cancel edit, restore selection |

Fill also keeps its seed queue, lazy source capture, connected option, and idle wait.
Wand also keeps its previous selection, mode, final restore, and retired-job reaper.

## E. Base pick publication gate

### Current signature

- `VoxelTool._apply_pick(target: Vector3i, hit: Vector3i) -> void`
- `VoxelTool.apply(_target: Vector3i, _hit: Vector3i) -> bool`
- `VoxelTool.applied_cells(target: Vector3i, hit: Vector3i) -> Array[Vector3i]`

`_apply_pick` calls `apply`.
A `false` result returns at once.
A `true` result appends `applied_cells` and flushes them.
`applied_cells` returns the target and the hit cell by default.

### Current callers

- `EyedropperTool.apply` returns `false` after `State.set_material`.
- The base `handle_input` opens an empty edit before the pick.
- The empty edit closes with no change. It adds no stroke action.
- No state-only flag exists.

### Ownership

The tool owns its state change and its pick result.
The base pick owns only the publication gate.
`State.set_material` owns the `Set Material` undo action.
The empty edit remains tool-owned.

### Reuse when

- A tool changes cells and returns `true` from `apply`.
- A state-only tool returns `false` and does its own state change.
- The tool can accept the base pick order: open edit, pick, apply, publish or return.

### Do not reuse when

- A tool writes cells but returns `false`. The base publishes nothing.
- A tool needs a pick before it opens an edit. The base opens the edit first.
- A tool needs a different cell notification path.
- A tool needs a state-only flag. No flag exists.

## F. Local frame snapshots and occupancy rows

### Current signatures

- `VoxelFrame.copy_chunks(locations: Array[Vector3i]) -> VoxelFrame`
- `VoxelFrame.get_bounds() -> AABB`
- `VoxelFrame.invalidate_bounds() -> void`
- `Chunk.occupancy_rows() -> OccupancyRows`

### Current callers

- `SprayTool._build_sample_job` uses `copy_chunks` for the worker ROI.
- `TerrainPreview` uses `copy_chunks` for the fit and map snapshots.
- `SprayOccupancyIndex` reads `Chunk.occupancy_rows`.

### Ownership

`copy_chunks` keeps the same chunk objects. The source marks them shared before the subset is exposed.
The snapshot owns the subset references. Existing shared entries stay shared.
`get_bounds` caches between API writes. The raw chunk count guards a raw add or remove.
`invalidate_bounds` repairs bounds only. It does not repair a raw grid write or copy-on-write metadata.
Occupancy rows are immutable after the build. They are shared by copy-on-write copies.
A material-only write keeps `occupancy_revision`, so the rows survive a repaint.
The bounds cache adds metadata only. The storage version and model transparency do not change.

### Reuse when

- A worker needs only a selected local chunk set.
- A fit or map read has a bounded region.
- A query needs occupied row masks or counts.

### Do not reuse when

- The worker needs the whole frame.
- A raw grid write needs full metadata repair.
- A raw chunk replacement keeps the count but changes occupancy.

## G. Indexed Spray search

### Current signatures

- `SprayOccupancyIndex.build_candidates(center, frame, size, selection, job, selection_index, spans) -> Candidates`
- `SpraySampler.work_estimate(frame, center, search_size, spot_size, selection, speed, selection_index) -> int`
- `SpraySampler.capture_chunks(center, search_size, spot_size, axes, origin_twice) -> Array[Vector3i]`
- `SpraySampler.sample(center, frame, context, spot_size, search_size, speed, rng, material, cache, job, report, selection_index) -> Array[Vector3i]`

### Current callers

- `SprayTool` inline sample.
- `SpraySamplingJob` worker sample.
- `SprayTool._build_sample_job` ROI capture.
- `SprayTool._cached_selection_index` selection reuse.

### Ownership

The index reads occupied rows. It does not build a candidate array or gather the full reach volume.
Canonical sphere spans are cached per size.
Native chunk and slot order stays stable. The lazy Fisher-Yates keeps the old cells and RNG draws.
A direct selected footprint queries only its selected rows.
A worker ROI covers the search, maximum spot box, and every symmetry reflection.
A captured intent resolves its sizes once. The ROI does not follow a live crop.
The source frame and token keep the live identity.
One read-only selection index serves the editor snapshot. A mutable selection resamples conservatively.

### Reuse when

- A wide search needs distinct occupied cells.
- The spot and speed stay fixed for one sample.
- Stable order and RNG parity must hold.
- A worker needs a local ROI, not the full frame.

### Do not reuse when

- A caller needs the full candidate array.
- Candidate order or RNG draw order changes.
- The work must scan every cell of the reach volume.
- The selection is mutable without a conservative resample.

### Policy

The inline gate uses 2200 indexed row units. It excludes the cold occupancy-row build.
Benchmarks report `index_builds` and `index_grid_reads`.
The cold cost is measured, not fixed in milliseconds.
`tests/spray_reference.gd` stays unchanged.
No maximum-size performance claim is made.

## H. Terrain cursor and idle hover

### Current signatures

- `TerrainTool._setup_footprint()`
- `TerrainTool._pose_footprint(pick: PickResult)`
- `TerrainTool._footprint_frame(pick: PickResult) -> TerrainFrame`
- `TerrainTool._hide_footprint()`
- `TerrainTool._footprint_depth(radius: int) -> int`
- `TerrainTool._height_depth() -> int`
- `TerrainTool._floor_grid_frame(frame: TerrainFrame) -> TerrainFrame`
- `TerrainTool._stroke_cursor_frame() -> TerrainFrame`
- `TerrainTool._dab_moved_enough(from_cell: Vector3i, to_cell: Vector3i) -> bool`
- `TerrainPreview.HoverJob`
- `TerrainPreview.hover_frame() -> TerrainFrame`
- `TerrainPreview.is_settled() -> bool`
- `TerrainPreview.last_publish_target`
- `VoxelBrushSize.disk_outline(size: int) -> PackedVector3Array`
- `VoxelLineMesh.build(vertices: PackedVector3Array) -> ArrayMesh`

### Current callers

- `TerrainTool._pose_footprint` poses the one ring for Build, Flatten, Smooth, and Grab.
- An open stroke poses it from `_stroke_frame`, `_cursor_frame`, or the floor grid frame.
- An idle pick poses it from `_preview.hover_frame()` when `last_publish_target` matches the pick.
- `TerrainPreview.HoverJob` runs the idle fit on the worker pool.

### Ownership

The cursor is one separate white leaf ring named `Footprint`.
It is not the idle `VoxelPreview`.
`_setup_footprint` creates one unshaded `StandardMaterial3D`: white, `no_depth_test`, and `CULL_DISABLED`.
The ring material has no depth bias.
Paint color and stroke material never tint the ring.
The ring is identical in idle, press, pending job, held, drain, and release.
The mesh is cached per size from 1 through 32.
`VoxelBrushSize.disk_outline(size)` builds it. The setting is a footprint size, and `radius_to_size` maps a legacy radius to `2 * radius + 1`.
The ring shows its perimeter only. It has no fill and no `VoxelEdges`.
One disc rule gives the cells, so every tool shows the same footprint.
The hover job builds a `TerrainFrame`, not a cell map, snapshot, or index.
`update_visual` runs on every pointer motion, so the idle pose must stay cheap.
The idle fit uses the full active size, so the ring shows the orientation the press will use.
The idle fit and the press fit read the same surface points.
A bounded patch fit deviates up to 14 degrees from the press normal on a coarse ramp.
That patch fit is rejected.
`TerrainPreview` caches the hover frame by its inputs. A repeat of one cell sets transforms only.
The tool poses the ring from a published hover frame only when `last_publish_target` equals the current pick target.
A cell change, a document change, an undo or redo, or a clear invalidates the preview cache.
A crossed cell refits at the full size, on the worker pool.
The ring keeps its fallback pose while the idle fit runs, so a move stays cheap.
The press fit costs about 55 milliseconds at size 32. That cost is a known limit.
The idle pose uses the entered face or floor and the fitted surface plane.
A Surface source fits the surface. A Face source and Grab use the exact entered face.
A floor miss uses the floor plane.
A press still runs the actual Surface or Face fit, operation plane, kernels, and undo.
Accepted edits are unchanged.
A visual sub-voxel move changes no accepted dab.
A stroke pose uses the captured frame, size, and context. The idle pose uses live inputs.
A document change, an exit, a tool switch, or a cancel hides the ring and drops the cache.
A normal release keeps a fresh pointer position.
There is no new framework.
`TerrainQueryContext` stays for the worker paths only. `compute_sample_map` and `compute_smooth_fields` accept it as `query`.

### Reuse when

- A terrain tool needs a lightweight ring pose without a next-voxel prediction.
- A known Face or floor frame can skip the fit query.
- A repeat of one pointer cell can reuse the last pose.

### Do not reuse when

- The caller needs a predicted next-voxel mesh.
- An idle hover needs a map, terrain snapshot, or whole-frame index.
- The caller needs a new cursor job or controller.

## Composition checklist

1. Name the existing mechanism and its current callers.
2. Write the capture point.
3. Write the ownership of the queue, cursor, edit handle, and result.
4. Define input release, worker done, queue drained, cursor done, and commit as separate events.
5. Define the stale or refused result rule.
6. Keep undo and cancel local to the tool.
7. Add no universal class, registry, event bus, controller, or hook framework. Keep a capability flag local and named.
8. Measure the complete flow later. Do not claim a performance result from this guide.

## New tool recipe

1. Start from the closest current path. Do not start from a new abstraction.
2. Write the capture point for the operation.
3. Write the ownership of the edit, worker, queue, cursor, token, and result.
4. Write the completion steps: input release, worker done, queue drained, cursor done, and commit.
5. Reuse one current mechanism only when its contract matches.
6. Keep tool-specific capture, cancel, and undo policy local.
7. Add no universal class, registry, event bus, controller, or hook framework. Keep a capability flag local and named.
8. Leave performance claims to a complete-flow measurement.

## Source files

- [`State.gd`](../../../Globals/State/State.gd)
- [`VoxelTool.gd`](../../../Globals/State/Tools/VoxelTool.gd)
- [`EyedropperTool.gd`](../../../plugins/Eyedropper/EyedropperTool.gd)
- [`ClipboardPlugin.gd`](../../../plugins/Clipboard/ClipboardPlugin.gd)
- [`LineTool.gd`](../../../plugins/brush/LineTool.gd)
- [`PasteTool.gd`](../../../plugins/Clipboard/PasteTool.gd)
- [`VoxelFrame.gd`](../../../Globals/State/Document/VoxelFrame.gd)
- [`TerrainTool.gd`](../../../plugins/Terrain/TerrainTool.gd)
- [`TerrainPreview.gd`](../../../plugins/Terrain/TerrainPreview.gd)
- [`TerrainRing.gd`](../../../plugins/Terrain/TerrainRing.gd)
- [`VoxelPreview.gd`](../../../Globals/Rendering/VoxelPreview.gd)
- [`VoxelRegionSearch.gd`](../../../Globals/State/VoxelRegionSearch.gd)
- [`StrokeTool.gd`](../../../plugins/brush/StrokeTool.gd)
- [`SprayTool.gd`](../../../plugins/paint/SprayTool.gd)
- [`SpraySampler.gd`](../../../plugins/paint/SpraySampler.gd)
- [`SprayOccupancyIndex.gd`](../../../plugins/paint/SprayOccupancyIndex.gd)
- [`FillTool.gd`](../../../plugins/paint/FillTool.gd)
- [`WandSelectTool.gd`](../../../plugins/selection/tools/WandSelectTool.gd)
