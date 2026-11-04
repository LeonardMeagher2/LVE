# Rendering, scheduling, and interaction research

Status: research only.
This page changes no runtime code and no test.
It records source evidence and ranked experiments for the render path, the worker schedule, and the pointer interaction.
It makes no performance promise.

Date: 2026-10-24.
Project: Leonard's Voxel Editor, Godot 4.7.2, GDScript only.
This page uses "LVE" for Leonard's Voxel Editor.
Access date for every web source: 2026-10-24.

## Scope

This page covers three areas only.

1. Render: chunk surfaces, mesh install, atlas materials, GPU upload, shader pipelines.
2. Scheduling: `WorkerThreadPool` tasks, priority, in-flight limits, frame work slices, cancellation.
3. Interaction: pointer pose, preview visibility, commit, settle.

Other owners cover voxel queries, data layout, and picking.
This page does not repeat their work.

## Top findings

1. Jobs that run through `State.run_edit_job` pass `high_priority = true`. Every chunk surface build passes `high_priority = false`. The low share is a reserve for tool jobs. The editor viewport competes with thumbnails and export for that low share and for global job slots.
2. The previous mesh stays visible until the new surface is ready. That behavior already exists. The main-thread reap is partly instrumented, and a finer split is unknown.
3. `material_override` blocks the Mesh-stage pipeline precompile. The Surface stage can still compile on the first frame after a node enters the tree. This does not prove a Draw stutter in LVE. Measure the counters.
4. Published worker gains measure CPU evaluation. Undo capture and contention can dominate the worker phase.
5. Low priority is a share of the pool, not a thread count. A priority flag affects new launches only. More in-flight builds is not a proven fix.

## Current pipeline: code facts and measured behavior

These facts come from the current code and from `MEMORY.md`.
They are the baseline for every experiment below.

| Mechanism | Current behavior | Evidence |
| --- | --- | --- |
| Edit job | `State.run_edit_job` starts one high-priority pool task, pumps progress, and joins once. The join is idempotent. | `State.gd`, `MEMORY.md` 2026-10-23 |
| Input classes | An accepted stroke queue, a replaceable hover, and absolute Grab targets are separate. | `docs/tool-flows/composition.md` B and H |
| Preview identity | The preview token is not the mesh key. The mesh cache keys exact content. A cache hit reports the requesting token. | `VoxelPreview.gd`, `MEMORY.md` 2026-10-23 |
| Frame snapshots | `VoxelFrame.copy_chunks` keeps chunk references and marks them copy-on-write. | `VoxelFrame.gd`, `MEMORY.md` 2026-10-24 |
| Chunk requests | Each chunk has one in-flight request and one latest-pending slot. | `VoxelRenderer._inflight_surface_keys`, `_pending_surface_keys` |
| Old mesh | `VoxelRenderer._install` swaps `MeshInstance3D.mesh` only when the new surface is ready. The previous mesh stays visible until then. | `VoxelRenderer._install` |
| Stale results | A retire or frame change clears eligibility. The running job is not cancelled. | `VoxelRenderer._retire`, `_consume_inflight` |
| Upload point | The worker returns arrays and atlas bytes. The main thread creates the `ArrayMesh`, the `ImageTexture` objects, and the material at reap. | `VoxelRenderer._update_surfaces`, `_build_material` |
| Worker priority | `State.run_edit_job` jobs pass `true`. Every chunk surface build passes `false`. | `State.run_edit_job`, `VoxelRenderer._launch_surface` |
| Work slice | The renderer spends at most `State.WORK_SLICE_US` (3000 us) per frame. | `State.gd`, `VoxelRenderer._work_slice_us` |
| Reap profile | `profile_surfaces` records `material_us`, `cache_us`, `install_us`, and `snapshot_us`. `material_us` covers the `ArrayMesh` and the material build. `cache_us` covers the cache write and atlas readback. The windowed renderer `_process` averages about 1 ms. Install is not a measured bottleneck. | `VoxelRenderer.gd` profile fields, `MEMORY.md` 2026-10-18 |
| Atlas cost | Worker-side cleanup and atlas generation took 90 percent of a measured fragmented checkerboard build. This is `VoxelMeshBuilder` finishing, not the main-thread texture upload. | `MEMORY.md` 2026-10-23 |
| Build cursor | Working-tree target, under validation by another owner: `_pose_build_footprint` sets transforms on a cached ring, and the idle pose uses a cheap frame. | `TerrainTool.gd` working tree |
| Spray index | Warm dense width 64, spot 1, speed 8 measured 28.705 ms against 671.518 ms for the frozen path. Cost still grows with width row work. The preview still spreads work across chunks, and that cost remains. | `MEMORY.md` 2026-10-24 |

Two consequences follow.

1. "Keep the previous mesh until the new mesh is ready" is already the behavior.
   Do not add a second mechanism for it.
   Prove it under cancellation instead.
2. The main-thread reap is partly instrumented.
   `material_us` combines `ArrayMesh` creation and the material build.
   `cache_us` covers the cache write and atlas readback.
   `install_us` covers the swap.
   A split between `ArrayMesh`, texture creation, and first draw is unknown.
   Measure that finer split only for a pathological atlas.
   Do not treat the worker-side 90 percent atlas cost as the main-thread upload cost.

## The five moments

One number cannot describe an edit.
Record these moments separately.

| Moment | Meaning in this project | Current hook |
| --- | --- | --- |
| Input latency | Pointer event to the first visible change. | `VoxelTool.handle_input`, `VoxelPreview` install |
| Preview visible | The replaceable cursor or footprint shows the request. | `VoxelPreview._install_surface`, `_pose_build_footprint` |
| Edited model visible | The first chunk surface of the new content installs. | `VoxelRenderer._install` |
| Undo committed | One history action covers the whole accepted stroke, after the final batch publishes. | `State.finish_edit` |
| Full remesh settled | No chunk request stays pending. | `VoxelRenderer.is_settled` |

`is_settled` checks this renderer's pending requests only.
A shared job started by another renderer can still run.
Report both counters.

Release, drain, and commit are separate.
A release sets `_end_requested`.
The runner drains the queued centers.
`close_stroke` calls `State.finish_edit` after the last batch publishes.
One action covers the whole accepted stroke, across all batches.
A cancel before commit rolls back the whole stroke.
A commit must not wait for settle.
A settle must not reopen the edit.

## Source notes

The numbers below belong to the cited source.
They are not LVE measurements.

### S1. Godot 4.7, Thread-safe APIs

URL: https://docs.godotengine.org/en/stable/tutorials/performance/thread_safe_apis.html

- The scene tree is not thread-safe. Build nodes outside the tree, then add them on the main thread.
- The doc tells you to avoid functions that interact with the GPU on other threads. It names creating textures and modifying or retrieving image data.
- The doc gives the reason: those calls need synchronization with `RenderingServer` and can stall.
- Resource modification from several threads is unsupported. Loading and handling references is supported.
- The separate render thread needs the `Rendering > Driver > Thread Model` setting. The doc warns that this model has several known bugs.

Use: keep `ArrayMesh` creation, `ImageTexture` creation, and `MeshInstance3D` changes on the main thread.
Do not move upload work to a worker to hide it.

### S2. Godot 4.7, WorkerThreadPool

URL: https://docs.godotengine.org/en/stable/classes/class_workerthreadpool.html

- `add_task(action, high_priority = false, description = "")` returns a task ID.
- `add_group_task` spreads one callable over worker threads with one index per execution.
- Every task must be waited for. The warning is explicit.
- `wait_for_task_completion` can return `ERR_BUSY` from inside another task. The doc names the deadlock risk.
- There is no cancel call and no preemption. A task runs to completion.
- `get_caller_task_id` lets code detect that it runs in the pool.
- The class note says the pool can hurt performance when the task is not expensive.

Use: cancellation must be cooperative.
A cancelled job still needs its join.

### S3. Godot 4.7, pipeline compilations

URL: https://docs.godotengine.org/en/stable/tutorials/performance/pipeline_compilations.html

- Pipeline compilation is the driver step from SPIR-V or DXIL to a usable pipeline.
- Godot 4.4 and later precompile pipelines at load time with ubershaders.
- Precompilation can run "in multiple background threads" during loading.
- The monitor names are `Canvas`, `Mesh`, `Surface`, `Draw`, and `Specialization`.
- `Surface` compiles on the first frame after 3D objects enter the scene tree, even when they are invisible.
- `Draw` compilations happen on demand and cause stutters.
- A `Mesh`-step precompile can run on a background thread when the mesh loads.
- "Modifiers that are part of nodes such as material overrides can't be compiled on this step."
- Changing MSAA, a feature, or a render setting during play causes immediate compiles.

Use: LVE sets `material_override` per chunk.
That blocks the Mesh-stage precompile for those surfaces.
The Surface stage can still compile on the first frame after a node enters the tree.
This does not prove a Draw stutter in LVE.
Measure `PIPELINE_COMPILATIONS_MESH`, `SURFACE`, and `DRAW` on the first stroke.
Warm one material variant only if a counter spikes.

### S4. Godot 4.7, ArrayMesh

URL: https://docs.godotengine.org/en/stable/classes/class_arraymesh.html

- `add_surface_from_arrays` creates a new surface from arrays. The arrays are the CPU input.
- `surface_update_vertex_region`, `surface_update_attribute_region`, and `surface_update_skin_region` update a byte range of an existing surface.
- Those updates need a stable vertex layout, a byte offset, and a stride.
- The class reference gives no cost model and no thread-safety promise for these calls.

Use: whole-surface rebuild fits a greedy mesher, because each edit can change topology.
A partial vertex update needs a fixed vertex order and is a poor fit for merged faces.

### S5. Godot 4.7, RenderingServer

URL: https://docs.godotengine.org/en/stable/classes/class_renderingserver.html

- `is_on_render_thread` reports whether the caller runs on the render thread.
- `call_on_render_thread` pushes a callable to the render thread, because server internals can run on a separate thread.
- `force_sync` synchronizes CPU and GPU and "has a performance cost".
- `mesh_surface_update_vertex_region` takes a byte range and a stride.

Use: the render thread is not a free worker.
The doc presents it as a correctness boundary, not a throughput tool.
The known bugs warning in S1 applies.

### S6. Godot Voxel Tools, Performance and VoxelViewer

URLs:
- https://voxel-tools.readthedocs.io/en/latest/performance
- https://voxel-tools.readthedocs.io/en/latest/api/VoxelViewer

Version: "latest" docs for the Godot 4 module. The pages show no version number.

- The module uses its own prioritised thread pool. The docs recommend that you do not use all cores.
- A block edit schedules one re-mesh task per block. The module skips a second task when one is already scheduled.
- `voxel/threads/main/time_budget_ms` defaults to about 8 ms, half a frame.
- In the Godot 3 OpenGL case, mesh uploads run on the main thread in a time budget. The doc names this as the fix for CPU-side stutter.
- In Godot 3 OpenGL, the first GL call in a frame could cost about 15 ms. That made the budget upload one mesh per frame.
- In Godot 4 Vulkan, buffer destruction is slow and runs on the main thread. The module spreads destruction over time.
- A block size of 32 reduces draw calls but increases edit cost.
- `VoxelViewer` sets update priority by distance. An edit near the player outranks work 100 units away.

Use: the 8 ms budget and the main-thread upload queue are design evidence for a budgeted install path.
They are not a drop-in design for GDScript.
The distance priority is evidence for a viewport priority hint, not for a new scheduler.

### S7. 0fps, meshing in a Minecraft game, parts 1 and 2

URLs:
- https://0fps.net/2012/06/30/meshing-in-a-minecraft-game
- https://0fps.net/2012/07/07/meshing-minecraft-part-2

Author: Mikola Lysenko.
Dates: 2012-06-30 and 2012-07-07.

- The greedy mesher merges adjacent quads of one type and one orientation.
- Part 1 gives two criteria: smaller meshes are better, and meshing latency must stay low.
- Part 1 proposes a fast coarse mesh first, then a later high-quality remesh that replaces it.
- Part 2 reports a 65x65x65 volume, JavaScript, and 10 warm iterations.
- Naive culling took 81.80 to 297.15 ms over the frequency sweep.
- Greedy took 92.40 to 198.30 ms.
- Vertex counts fell from 26536 to 7932 on the terrain case.
- Empty-volume cost stayed near 80 to 92 ms. That is the traversal cost.
- The post separates `O(n)` volume traversal from `O(k)` surface work.

Use: a better mesher cuts surface work.
It does not remove the volume scan.
The absolute times are 2012 JavaScript and do not transfer to GDScript.

### S8. Blender, This Summer's Sculpt Mode Refactor

URL: https://code.blender.org/2024/11/this-summers-sculpt-mode-refactor
Author: Hans Goudey.
Date: 2024-11-07.

- The PBVH is a spatial index for brush lookup and raycasting.
- Brush evaluation tests BVH nodes for inclusion, then processes the vertices of a node in simple loops.
- GPU data is split per BVH node.
- A node reuploads only the attributes that changed. Tracking costs one bit per node.
- Undo snapshot storage took 60 percent of brush evaluation time. The cause was a lock plus a linear search per node. A hash map removed it.
- Writing one boolean from many threads cost a 2x brush slowdown. Removing the redundant flag recovered it.
- Entering sculpt mode fell from 11 s to 1.9 s on a 16 million face mesh with a Ryzen 7950X.
- The post claims about 8x faster brushes in Blender 4.3.
- The post also states that drawing is "always bottlenecked to some extent" by geometry upload.

Use: published worker gains measure CPU evaluation, not the time until the user sees the result.
Contention and undo capture can dominate the worker phase.
Keep worker writes disjoint and keep the undo snapshot off the hot path.

### S9. Blender 2.81 release notes, sculpt

URL: https://developer.blender.org/docs/release_notes/2.81/sculpt

- "Terrain cursor follows the surface normal and displays symmetry."
- The same release added a normal radius and world spacing for strokes.

Use: a cursor overlay can carry orientation and symmetry without a remesh.
This supports the current Build ring pose, which only sets transforms.

### S10. Forch, Franke, Rauh, Krems (2017), Are 100 ms Fast Enough?

DOI: 10.1007/978-3-319-58475-1_4
Venue: HCII 2017, LNCS 10276, Springer.
Access: publisher page and abstract. The full text is paywalled.

- The study measures latency perception thresholds for a simple mouse-based task.
- The published abstract reports thresholds "in the range of 60 ms".
- The measured baseline system latency was 8 ms (SD 1.7 ms).

Use: 100 ms is not a safe target for a mouse editor.
Treat 60 ms as a perception range from one study, not a universal limit.
Some LVE inputs are below this range. Some hover cases are not.
The visible result is the risk.

## What the sources do not prove

- No source measures LVE.
- No source measures GDScript chunk meshing at LVE chunk size.
- S8 measures a 16 million face mesh on a Ryzen 7950X in C++. The brush numbers do not transfer to a 16-cube chunk in GDScript.
- S7 measures 2012 JavaScript on 65-cube volumes.
- S6 is a C++ module with its own pool and locks.
- S3 describes pipeline compilation, not mesh building.
- S10 measures perception of added delay in a simple mouse task, not trust in a slow editor.
- A faster worker does not imply a faster visible result. The install path and the GPU upload remain.

## Scheduling tradeoff: frame budget against worker priority

Four levers exist today.

| Lever | Current value | Effect | Risk |
| --- | --- | --- | --- |
| Work slice | 3000 us | Caps main-thread reap and install work per frame | A long material build can delay its own install to a later frame |
| Renderer job limit | `OS.get_processor_count() - 1`, clamped 2 to 8, shared by every renderer | Caps concurrent chunk builds | A foreground request can wait for a global slot |
| Worker priority | `State.run_edit_job` jobs high, chunk surfaces low | Reserves pool capacity for tool jobs | A viewport mesh job cannot outrank an accepted tool job |
| Request policy | One in-flight plus latest pending per chunk | Bounds duplicate work per chunk | A superseded build still runs to completion |

`State.run_edit_job` passes `true`.
`VoxelRenderer._launch_surface` passes `false`.
This is a deliberate reserve for brush, fill, and wand jobs.
It is not an oversight.

Low-priority tasks draw from the share set by `threading/worker_pool/low_priority_thread_ratio`.
The project setting default is 0.3 in the 4.7 class reference.
`MEMORY.md` records the same cap.
The `WorkerThreadPool` class reference does not state the queue policy.
Measure the effect. Do not assume a fixed thread count.

The tradeoff is not "more threads is faster".
More concurrent builds can raise contention on the main thread at reap.
S8 shows contention and snapshot work can dominate a worker phase.
S6 shows the upload queue, not the mesher, can set the visible rate.

Raising the editor viewport to high priority is a hypothesis.
It can delay accepted tool jobs, not only offscreen renders.
The pool has one queue and no per-view quota.

Two shared-path effects limit a priority flag.

1. `_surface_jobs` is static and shared by every renderer.
   A foreground view can adopt a low-priority job that a thumbnail already queued.
   A flag cannot upgrade a queued task.
2. `_launch_surface` returns when `_surface_jobs.size() >= _job_limit()`.
   The global limit can delay a new foreground launch before pool priority applies.

A flag affects new launches only.
Measure the role of the first request per chunk, the adopted-low count, and the wait for a global slot.
Keep tool progress and cancel unchanged.
Do not add a priority registry without that proof.

`MEMORY.md` already records rejected candidates.
A higher in-flight limit did not reliably change settle or frame gap.
Holding work back made the gaps worse.
A new install budget or priority policy must clear the same measured bar.

## Ranked experiments

Run each experiment in one process with alternating order.
Report medians and spread.
Reject a result when the spread is wider than the effect.

### 1. Measure the five moments and the reap split

Goal: find the real bottleneck before any behavior change.

Change: none.
Add timestamps in the benchmark, not in the runtime.
Record:
- pointer event time
- preview install time
- first and last chunk install time
- `State.finish_edit` time
- `is_settled` time
- `_profile.material_us`, `cache_us`, `install_us`, `snapshot_us`
- `_profile.launch`, `reaped`, `consume`, `truncated`, `lost`
- `Performance.PIPELINE_COMPILATIONS_MESH`, `SURFACE`, and `DRAW`

The profile fields already split the reap into material, cache, install, and snapshot totals.
`material_us` combines the `ArrayMesh` and the material build.
Add only the missing split:
- `ArrayMesh.add_surface_from_arrays` time
- texture creation time inside `_build_material`
- first-draw time for a new material
- texture count per surface
- geometry bytes

Accept: a stable split over at least five alternating samples.
Reject: one run, or a headless-only run for upload cost.
A headless frame excludes GPU upload, as `MEMORY.md` records.

Why first: every later experiment needs this split.
A windowed renderer `_process` averages about 1 ms, and install is not a measured bottleneck.
That does not prove the texture path is cheap on a fragmented atlas.
Run the finer split only on a pathological atlas fixture.
A fragmented atlas can make the worker build long.
Its main-thread texture creation cost is unknown.

### 2. Test a viewport priority hint after measuring adoption

Goal: test whether a viewport priority hint shortens visible completion without delaying accepted tool jobs.

Current state: jobs through `State.run_edit_job` already pass high priority.
Chunk surfaces pass low priority by design.

Change: one explicit flag on `VoxelRenderer`.
The default stays low.
The editor viewport sets it.
`_launch_surface` passes it to `add_task`.
The flag affects new launches only.

Measure:
- first-request role per chunk: editor, thumbnail, or export
- adopted low-priority job count
- global slot wait: time with `_surface_jobs.size() >= _job_limit()`
- pointer-to-first-install
- full settle
- p95 frame gap
- accepted tool job progress rate
- accepted tool job cancel time
- pool size: `OS.get_processor_count()`, `_job_limit()`, and `threading/worker_pool/max_threads`

Accept: a repeated win on first install or settle, with no tool progress or cancel regression.
Reject: a win that only moves work between views.
Reject: a win that adds delay to an accepted tool job.
Reject: a result that holds at only one processor count.

Source basis: S2 defines the priority argument.
S6 gives distance priority as design evidence.

Risk: high-priority mesh jobs can delay accepted tool jobs.
The low share exists to prevent that.
Test near 8 processors, because `_job_limit` caps at 8 and the pool size changes the competition.
Do not raise the in-flight limit in the same experiment.

### 3. Add a cooperative cancel flag to chunk builds

Goal: stop work that can never install.

Change: pass a cancel source into `VoxelMeshBuilder`.
Check it at plane or layer boundaries, not per cell.
Set it when `_retire` clears a chunk or when `_rebuild` clears the request maps.
Keep the join. Keep the old mesh visible until install.
The job keeps its read-only `copy_frame` snapshot.

Measure:
- `reaped` builds that never reach `consume`
- CPU time in abandoned builds
- settle time
- frame gap

Accept: fewer abandoned builds and no settle regression.
Reject: a cancel check that costs more than the abandoned work it saves.

Source basis: S2 states that the pool has no cancel and no preemption.
The caller must set a flag.
`VoxelFrame.EditJob.checkpoint` already uses this pattern.
`MEMORY.md` records one checkpoint at about 4.6 us because it locks a mutex.
Use a plain flag or an atomic counter at a coarse boundary.

Risk: a stale job can still write to its own arrays. That is safe.
It must not touch the live frame or a Node.

### 4. Reuse atlas textures by content

Goal: cut repeated main-thread texture creation, if repeats exist.

Measure first: count distinct atlas payloads per 100 installs.
Read the existing `material_us` field.
Then decide.

Change: a small bounded cache from atlas content key to `ImageTexture`.
Reuse the eviction accounting of `_surface_cache`.
Do not cache by chunk or by material instance.

Accept: a measured drop in `material_us` and in the longest reap.
Reject: low repeat rate. Then the cost is inherent.

Source basis: S1 forbids moving texture creation to a worker to hide a stall.
S4 gives no cost model for surface creation.
S3 says a `material_override` blocks the Mesh-stage precompile only.
Warm one material variant only if a pipeline counter spikes at Draw.

Risk: texture memory growth.
Bound the cache by bytes, not by entry count alone.

### 5. Run a budget and priority matrix

Goal: find a better pair, or prove the current pair is fine.

Matrix:
- work slice: 3000 us and 1500 us
- renderer priority: all low, and editor viewport high

`State.run_edit_job` jobs stay high in every cell.
Measure: installs per frame, p95 frame gap, settle, abandoned builds, tool progress, and tool cancel time.
Use at least five alternating samples per cell.

Accept: a cell that wins on both settle and p95 gap in repeated runs, with no tool regression.
Reject: a cell that wins on one metric only.
`MEMORY.md` records that in-flight limit sweeps disagreed in sign, and that run-to-run spread was wider than the effect.

Source basis: S6 shows a main-thread time budget is a real control.
S8 shows contention can invert an expected gain.

Risk: a shorter slice delays a heavy reap.
A longer slice raises the frame gap.

### 6. Verify cursor pose independence under saturation

Goal: prove the pointer never waits for a mesh job.

Current state: a working-tree target under validation by another owner.
`_pose_build_footprint` sets a transform on a cached ring.
`_pose_build_idle` uses a cheap frame.
The ring mesh is cached per radius.
This path is not verified runtime behavior in this page.

Measure:
- pointer-to-pose time while eight builds run
- pointer-to-pose time during a stroke worker
- pose time on a same-cell motion

Accept: pose stays inside one frame budget in every case.
Reject: a pose path that calls a fit, a map, or a preview request.

Source basis: S9 documents a cursor that follows the surface normal and shows symmetry.
It does not document the update mechanism.
S8 separates brush evaluation from drawing.
The manual sources support cursor orientation as a user-facing feature.
They do not prove how a closed-source editor updates its cursor.

Keep the pose independent of the edit job.
The neutral outline, the absent `VoxelEdges`, and the smooth same-cell motion belong to the separate owner.
Do not add a cursor job or a controller.
S9 documents one editor. It does not prove that every editor uses one cursor design.

## Status, cancellation, and undo rules

- Report the five moments. Do not collapse them into one percentage.
- A percentage can describe a known total. It cannot describe an unknown remaining chunk count.
- If a settle indicator is added, it must count pending chunks and in-flight jobs separately.
- Do not add a worker stage label. `MEMORY.md` records that the job widget shows a label, a measured percentage, or `Cancelling…`.
- A cancel must stop new launches first, then cancel pending requests, then join.
- A cancelled job must not install.
- Release, drain, and commit are separate. One history action covers the whole accepted stroke.
- Settle must not add a second action.
- A read-only worker snapshot must not be mutated after launch. `VoxelFrame.copy_chunks` gives this.

## Rejected designs

| Design | Reason |
| --- | --- |
| Render scheduler singleton or job hierarchy | The current maps and one flag per job cover the need. A new owner adds lifetime and cancellation paths with no measured gain. |
| Move `ArrayMesh` or texture creation to a worker | S1 warns that GPU interaction off the main thread stalls on `RenderingServer` synchronization. |
| Use the separate render thread as a worker | S1 warns that the model has several known bugs. S5 presents it as a correctness boundary. |
| Partial vertex buffer updates for chunk edits | S4 requires a stable layout and byte offsets. A greedy mesh changes topology per edit. |
| Raise the in-flight limit | `MEMORY.md` found no reliable effect on settle or frame gap. |
| A native plugin or compute mesher as a near-term step | It adds a toolchain and an unmeasured cost. Treat it as a long-term option only. |
| A second "keep old mesh" layer | `_install` already keeps the previous mesh until the new surface is ready. |
| A generic priority manager | One boolean on the renderer is enough. Do not add it without measured adoption and slot wait. |

## Caveats

- All LVE numbers in this page come from `MEMORY.md` and keep their original scope.
- Separate-process values are historical, not controlled speedups.
- A headless run excludes GPU upload.
- Windowed frame intervals on this machine are about twice the nominal refresh, with a p95 jitter near 33 ms.
- The editor scene has four `VoxelRenderer` instances. Each one requests surfaces for the same edit.
- A cache hit still costs a main-thread install.
- GPU warm cost and index cold cost are separate measurements. Keep them apart.
- The 169-scene verification covers behavior. It does not cover GPU warm cost.
- The 90 percent atlas figure is worker-side finishing. It is not the main-thread upload cost.
- The pipeline claim is conditional. `material_override` blocks the Mesh stage only. The Surface stage can still compile on the first frame after a node enters the tree.
- The idle Build footprint path is a working-tree target under validation by another owner. It is not verified runtime behavior in this page.
- S8 measures C++ brush evaluation. Its 8x claim is not a visible latency claim.
- S7 measures 2012 JavaScript. Its times do not transfer.
- S6 is a C++ module with its own pool. Its 8 ms budget is design evidence.
- S10 is paywalled. The 60 ms value comes from the published abstract.
- No experiment in this page has run yet.

## Open questions

1. What share of `material_us` is `ArrayMesh` creation, texture creation, and material setup?
2. Do atlas payloads repeat across chunks in one stroke?
3. Does a viewport priority hint win when the global slot is free, and how often is it blocked?
4. How many chunk builds are abandoned per stroke at the maximum radius?
5. Do the pipeline counters spike at Mesh, Surface, or Draw on the first stroke?
6. Does a cancelled build still cost more than its cancel check?

## Source list

| ID | Source | Author or owner | Date | Version | Access |
| --- | --- | --- | --- | --- | --- |
| S1 | Thread-safe APIs | Godot Engine docs | current stable | 4.7 | 2026-10-24 |
| S2 | WorkerThreadPool class reference | Godot Engine docs | current stable | 4.7 | 2026-10-24 |
| S3 | Reducing stutter from shader (pipeline) compilations | Godot Engine docs | current stable | 4.7 | 2026-10-24 |
| S4 | ArrayMesh class reference | Godot Engine docs | current stable | 4.7 | 2026-10-24 |
| S5 | RenderingServer class reference | Godot Engine docs | current stable | 4.7 | 2026-10-24 |
| S6 | Performance and VoxelViewer pages | Voxel Tools docs | latest | Godot 4 module, unnumbered | 2026-10-24 |
| S7 | Meshing in a Minecraft Game, parts 1 and 2 | Mikola Lysenko, 0fps | 2012-06-30, 2012-07-07 | article | 2026-10-24 |
| S8 | This Summer's Sculpt Mode Refactor | Hans Goudey, Blender | 2024-11-07 | Blender 4.3 dev | 2026-10-24 |
| S9 | Sculpt release notes | Blender developers | 2019 | 2.81 | 2026-10-24 |
| S10 | Are 100 ms Fast Enough? | Forch, Franke, Rauh, Krems | 2017 | HCII 2017, LNCS 10276 | 2026-10-24 |

## Project evidence

- `docs/tool-flows/composition.md`, sections A to H.
- `docs/tool-flows/shared-and-utilities.md`, model render and preview paths.
- `MEMORY.md`, entries dated 2026-10-17 through 2026-10-24.
- `ui/Viewport/VoxelRenderer.gd`, symbols `_launch_surface`, `_update_surfaces`, `_build_material`, `_install`, `_retire`, `is_settled`, `_job_limit`, `_surface_jobs`, `_profile`.
- `Globals/State/State.gd`, symbols `WORK_SLICE_US`, `run_edit_job`, `finish_edit`.
- `Globals/Rendering/VoxelMeshBuilder.gd`, symbol `run`.
- `plugins/brush/StrokeTool.gd`, symbols `_end`, `_finish_stroke`, `close_stroke`.
- `plugins/Terrain/TerrainTool.gd`, symbols `_setup_build_footprint`, `_build_build_footprint_mesh`, `_pose_build_footprint`, `_pose_build_idle`.
