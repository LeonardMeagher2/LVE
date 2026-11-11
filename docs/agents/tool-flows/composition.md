# Composition guide: current shared mechanisms

Use this guide when a new tool needs an existing shared mechanism.
It covers the current A to H slices.
The verification record is below.
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
- `TerrainTool._make_tick_job() -> TerrainTickJob`
- `TerrainTool._make_smooth_job() -> SmoothJob`
- `TerrainPreview.footprint_depth(tool: int, radius: int) -> int`
- `TerrainTool._footprint_depth(radius: int) -> int`
- `TerrainPreview.watch_half(radius: int) -> int`
- `TerrainPreview.watch_half_for(radius: int, depth: int) -> int`
- `TerrainTool._depth(radius: int) -> int` remains only for the frozen benchmark.

### Current callers

- `TerrainTool.open_stroke` creates `StrokeInputs`.
- `_make_tick_job` serves Build and Flatten.
- `_make_smooth_job` serves Smooth.
- `_footprint_depth` serves the sample map, the Smooth refit, the prep jobs, and the preview inputs.
- `HoverJob` uses `watch_half` for the fit and `watch_half_for` for the map.

### Ownership

The tool owns the mutable execution state: planes, anchors, samples, progress, credits, carry, and drains.
`StrokeInputs` owns only the captured inputs.
`StrokeInputs` is a Terrain-family record.
A new tool must copy the capture pattern, not reuse this type or its fields.
The material is duplicated. The selection is the frozen edit-context selection.
The jobs own their frame snapshots and their job inputs.

### Policy examples

- Build and Flatten use footprint depth 64.
- Smooth uses `depth_for(radius)`. Grab returns the same value from the helper, but its source capture uses ball offsets.
- The fit watch and the map watch stay separate.
- `_depth(radius)` is the frozen benchmark reference only. Do not change that algorithm.

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

### Remaining hypothesis

A state-only flag or a pick-only hook can remove the empty edit.
It is not implemented.
It must not change Plane or Symmetry.
It needs tests for Escape and busy states.

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
- `TerrainTool._build_footprint_mesh(radius: int)`
- `TerrainTool._pose_footprint_idle(pick: PickResult)`
- `TerrainTool._pose_footprint_cell(cell: Vector3i)`
- `TerrainTool._pose_footprint(frame, center, context)`
- `TerrainTool._idle_frame(pick: PickResult) -> TerrainFrame`
- `TerrainTool._idle_pose_inputs(pick: PickResult) -> Array`
- `TerrainTool._start_idle_fit(pick: PickResult, key: Array)`
- `TerrainTool._run_idle_fit_worker(job)`
- `TerrainTool.TerrainIdleFitJob`
- `TerrainTool._invalidate_idle_pose()`
- `TerrainTool._cell_center_on(frame, cell) -> Vector3`
- `TerrainTool._clear_footprint()`
- `TerrainRing.legacy_plane_ring(radius: int)`

### Current callers

- `TerrainTool._footprint_visual` poses the one ring for Build, Flatten, Smooth, and Grab.
- An open stroke poses it from the captured frame, radius, and context.
- An idle pick poses it from the live frame and the active normal source.
- A Surface idle pick runs the fit on the worker pool and re-poses the ring from the fitted frame.

### Ownership

The cursor is one separate white leaf ring named `Footprint`.
It is not the idle `VoxelPreview`.
A clone of `plugins/cursor_material.tres` sets the color once.
The clone is unshaded and sets `no_depth_test`. It has no depth bias.
Paint color and stroke material never tint the ring.
The ring is identical in idle, press, pending job, held, drain, and release.
The mesh is cached per radius from 1 through 32.
The legacy radius plus 0.5 gives width 2r + 1. Radius 32 gives width 65.
The ring shows its perimeter only. It has no fill and no `VoxelEdges`.
One disc rule gives the cells, so every tool shows the same footprint.
No hover job, preview cell map, terrain snapshot, or index exists.
`update_visual` runs on every pointer motion, so the idle pose must stay cheap.
The idle fit uses the full active radius, so the ring shows the orientation the press will use.
The idle fit and the press fit read the same surface points.
A bounded patch fit deviates up to 14 degrees from the press normal on a coarse ramp.
That patch fit is rejected.
The tool caches the idle pose by its inputs. A repeat of one cell sets transforms only.
A cell change, a document change, an undo or redo, or a clear drops the cache.
A repeat of one cell costs about 10 microseconds.
A crossed cell refits at the full radius, on the worker pool.
The ring keeps its fallback pose while the idle fit runs, so a move stays cheap.
The press fit costs about 55 milliseconds at radius 32. That cost is an open task in `../../../TASKS.md`.
The idle pose uses the entered face or floor and the fitted surface plane.
A Surface source fits the surface. A Face source and Grab use the exact entered face.
A floor miss uses the floor plane.
A press still runs the actual Surface or Face fit, operation plane, kernels, credits, and undo.
Accepted edits are unchanged.
A visual sub-voxel move changes no accepted dab.
A stroke pose uses the captured frame, radius, and context. The idle pose uses live inputs.
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

## Verification

### Prior Oct23 modular selection

The clean smoke command `godot --headless --path . res://tests/harness.tscn -- engine_errors legacy_aliases` returned `TEST OK` with no errors.

The prior modular selection covered 65 distinct scenes.
The first 7-batch run had 4 passes and 3 failures. All 3 failures were fixed without weakening a test.
The initial passing scenes were `eyedropper_apply`, `region_batch_slices`, `line_lifecycle`, and `preview_schedule`.
The rerun `godot --path . -s res://addons/test_kit/run.gd -- clipboard_lifecycle terrain_stroke_input` passed both scenes.
The remaining 59 scenes ran in `Temp/opencode/lve-modular-regressions.log`. The runner reported `TEST SUITE: OK` with 59 PASS and no errors.

The test plan is `Temp/opencode/lve-modular-test-plan.txt`.
The other logs are `Temp/opencode/lve-modular-new-behaviors.log` and `Temp/opencode/lve-modular-capture-rerun.log`.
No unnamed full suite ran. The historical 156/157 full-suite result stays separate.
The three optional benchmark adapters passed in serial windowed runs:
- `godot --path . --screen 1 res://tests/benchmarks/terrain_preview_ab.tscn -- changed_r4`
- `godot --path . --screen 1 res://tests/benchmarks/terrain_preview_ab.tscn -- resize_r32`
- `godot --path . --screen 1 res://tests/benchmarks/spray_latency.tscn -- dense16`

Each returned `TEST OK` and exit 0. No `SCRIPT ERROR` or `ERROR` appeared.
Both Terrain cases matched exact cells, vertices, and bounds across five measured pairs.
The Spray case validates publication and signature on its small fixture. It does not measure maximum latency.
The Spray run printed a preexisting SubViewport size `WARNING` only.
Logs: `Temp/opencode/lve-modular-sculpt-changed.log`, `lve-modular-sculpt-resize.log`, and `lve-modular-spray-dense16.log`.
No performance gain is claimed from the prior selection.

### Final Oct24 verification

All 169 current scenes are verified across the full attempt and targeted follow-ups.
The full attempt stopped at 3 failures: 124 PASS, 3 FAIL, and 41 unrun.
The failures were Smooth reentrant nil record, maximum hover cost, and worker fixture row gate.
The maximum hover scene ran 13.6 s under the unchanged 30 s deadline.
The worker fixtures now force `ROW` above 2200. They no longer assume size 17.
Terrain tools now split into 48 root cases and 39 `terrain_tools_smooth` cases. The moved cases keep legacy `GROUP_ALIASES` support. The root total is 169.
The corrected 8-scene Terrain batch passed 8 scenes. One worker scene passed 1 scene. The completion batch passed 53 scenes.
The combined logs cover 169 unique scenes with 0 missing.
This was not one clean full-suite run. The accurate statement is "All 169 current scenes verified across the full attempt and targeted follow-ups."
Latest clean logs have no `SCRIPT ERROR` or `ERROR`.
`material_controls` passed, but the intermittent focus issue remains open.

### Latest Build cursor verification

The latest simple Build cursor change passed all 20 affected Terrain scenes.
The last 11-scene batch passed:
`terrain_hover_local terrain_input terrain_cursor_preview terrain_normals terrain_prep_worker terrain_tools terrain_tools_smooth terrain_stroke_input terrain_preview_cache terrain_preview_async terrain_sample_ownership`
The remaining 9 scenes passed in a separate runner batch:
`terrain_build_follow terrain_build_profile terrain_normal_toggle terrain_occupancy terrain_ring terrain_rounding terrain_sample_max_ownership terrain_smooth terrain_smooth_placement`
The runner reported `TEST SUITE: OK` with 0 errors.
No full 169 rerun occurred after this change. The 169 coverage above is historical before this change.

The cursor source passed final read-only review.
Lifecycle, constant color, continuous pose, update fallback, and Layer fixes are approved.
Accepted edit and undo behavior is preserved.
The white `Footprint` is implemented. No under-test or stale failure claim remains.

Build cursor movement at R32 with 256 distant chunks measured 2852 us over 40 moves.
The average was 71 us. The worst was 240 us.
There were zero launches, maps, or snapshot copies.
This is an input-event and pose case. It is not a GPU end-to-end guarantee.

The terrain preview benchmark now measures Flatten with the Face source.
Build deliberately has no terrain preview.
All `MEASURE` lines use `tool=flatten source=face`.
The labels are `resize_flatten_4_32` and `shrink`.
The frozen reference body is unchanged. Only the old `_stroke_tool` to `_stroke.tool` adapter remains.
`godot --path . --screen 1 res://tests/benchmarks/terrain_preview_ab.tscn -- changed_r4 resize_r32` returned `TEST OK`.
Each pair had exact cells, vertices, and AABB. There were five measured pairs each.
The changed case had 27 cells and 228 vertices.
`godot --path . --screen 1 res://tests/benchmarks/terrain_preview.tscn -- ramp_r4` returned `TEST OK`.
Cold and same cases had 27 cells and 228 vertices. After geometry had 28 cells and 252 vertices.
A color-only change had zero rebuilds, zero submits, and an unchanged mesh.
These are Flatten and Face terrain preview values. They are not old Build performance.

Verification commands and outcomes:

- `godot --path . -s res://addons/test_kit/run.gd` -> 124 PASS, 3 FAIL, 41 unrun. Log `Temp/opencode/lve-local-20261024-full-suite.log`.
- Corrected 8-scene Terrain batch -> 8 PASS. Log `lve-local-20261024-sculpt-final2.log`.
- Worker scene -> 1 PASS. Log `lve-local-20261024-whole-worker-scene.log`.
- Completion batch -> 53 PASS. Log `lve-local-20261024-completion.log`.
- `godot --path . --screen 1 res://tests/benchmarks/terrain_hover_scaling.tscn -- scaling density near_outside max_symmetry` -> `TEST OK`. Log `lve-local-20261024-grow-final-benchmark.log`.
- `godot --headless --path . res://tests/benchmarks/spray_cost.tscn` -> `TEST OK`. Log `lve-local-20261024-spray-rendered2.log`.
- Latest Build cursor 11-scene batch `godot --path . -s res://addons/test_kit/run.gd -- terrain_hover_local terrain_input terrain_cursor_preview terrain_normals terrain_prep_worker terrain_tools terrain_tools_smooth terrain_stroke_input terrain_preview_cache terrain_preview_async terrain_sample_ownership` -> `TEST SUITE: OK`, 0 errors.
- Remaining 9 Terrain scenes passed in a separate runner batch with `TEST SUITE: OK` and 0 errors.
- `godot --path . --screen 1 res://tests/benchmarks/terrain_preview_ab.tscn -- changed_r4 resize_r32` -> `TEST OK`. Log `Temp/opencode/lve-bench-terrain-ab.log`.
- `godot --path . --screen 1 res://tests/benchmarks/terrain_preview.tscn -- ramp_r4` -> `TEST OK`. Log `Temp/opencode/lve-bench-terrain-base.log`.

Cautious metric scope:

- The final `terrain_hover_scaling` local preview benchmark had 40 steady R4 rows. Publish ranged from 2.630 to 19.614 ms. The median was 6.277 ms. Per event ranged from 53 to 109 us. All 40 were under 50 ms.
- The same fit used 16 locations and 4 chunks. The map used 72 locations and 4 chunks. Output was 48 cells and 144 vertices.
- Cold first hover was 52.974 ms. Maximum R32 + X symmetry publish was 166.016 ms. It remains heavier than the 50 ms R4 claim.
- These are local preview values. The new Build ring has no fit or map. Old Build terrain hover timings are historical for the removed path. Flatten and Smooth keep the two-stage local preview.
- Spray warm dense width 64 with spot 1 and speed 8 measured 28.705 ms kernel and payload. The frozen path measured 671.518 ms. These are five alternating medians.
- Spray cold measured 69.452 ms against 697.228 ms. These are single cold observations, not medians.
- Rendered width 64 cold: dense 0.762 ms input and 86.550 ms visible. Plate 0.653/71.068. Sparse 3.944/4.188. Hollow 1024 1.122/84.746.
- All tested cold inputs were under 8 ms. All widest previews were under 100 ms.
- A material repaint built no index. A neighboring occupancy erase invalidated the queried chunk and rebuilt one index.
- Indexed cost still grows with width row work. No constant-time or all-output claim is made.
- Earlier inline benchmark values are historical. They are not the latest values.
- Before and after runs use separate processes. They are not a controlled speedup.

These gaps stay open:
- Cold-press Terrain fitting.
- TerrainRing contour integration beyond the Build cursor.
- A canonical Terrain size range.
- Maximum-size Spray latency under sustained drag.
- Maximum-radius idle hover publish remains heavier than the 50 ms goal.
- Column walk at maximum radius on sparse models.
