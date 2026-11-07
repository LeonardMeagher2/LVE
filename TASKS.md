---
max_active: 1
---

# Roadmap

Keep one active task at a time. Keep all remaining features until the scope review.
Use Git history for completed work. See [MEMORY.md](MEMORY.md) for verified engine and workflow facts.
See [GLTF_EXPORT.md](GLTF_EXPORT.md) for the mesh export format and import settings.

## Verification

- [ ] Close the remaining implementation tasks
  - [ ] Ask the user to test the Transform and Plane tools manually
  - [ ] Run the affected behavior tests:
    - Per-voxel materials and material swatches
    - Independent picker settings and palette entries
    - Shared planar cleanup in the viewport and exporter
- [ ] Investigate the intermittent keyboard-focus failure in `material_controls`. A targeted rerun does not replace a clean full suite.
- [ ] Keep the test suite near 10 minutes
  - [x] Report the wall clock and the slowest scenes in every run.
  - [x] Fail a case that records no check. A headless run reports a skip instead.
  - [x] Delete the temporary probe scenes and the orphan script.
  - [x] Merge the chunk, palette, sprite, and editor-chrome scenes.
  - [x] Resolve a named run by scanning the registered case names. The alias table is gone.
  - The measured facts: a windowed child pays about 3.7 s before its first check. The suite now runs 152 scenes and takes 15.2 min with every scene green.
  - [x] Fix the terrain suite. The probes read removed `_stroke` fields, the ring was never posed, and Grab kept a 12-voxel cap. The full suite passes.
  - [ ] Merge the material, export, large, dialog, and selection scenes. Keep each scene below 25 s.
- [ ] Audit the coverage against `docs/tool-flows/*.md`
- [ ] Check orthographic rays and long-distance occlusion in the selection depth test.

## Tools

- [ ] Finish the floor-plane slice
  - [ ] Make Terrain slice-aware. Its per-column surface tracking must plan only the layer. A write filter desyncs the next dab.
  - [ ] Add the arrow-key nudge. Godot consumes bare arrows for focus navigation, so route it before the GUI, or use a modifier.
  - [ ] Ask the user to test the slice option manually with Brush, Paint, Line, Spray, Fill, Transform, Cut, and Erase Selection.
  - [x] Add the slice context cue: a projected matte of the off-slice cells on the slice plane. The plate hides it where the slice layer holds cells. A slice-layer write does not rebuild it. Test `slice_matte`.
  - [ ] Optional: a static selection-line wire of the layers around the slice, if the matte reads too flat.

- [ ] Add the Extrude tool
  - Extrude selected voxels along the plane normal.
  - Set the distance with a drag.

## Rendering and performance

- [ ] Keep drawing responsive on large models (active)
  - [ ] Keep every Terrain use within usable frame rates
    - Build, Flatten, Smooth, and Grab must be fast for taps and drags at every radius.
    - A small dab writes the live stroke frame. A worker dab writes a shared `job_frame` and publishes only its changed chunks, so neither path copies the whole frame per dab.
    - A tap still pays a `_chunks_equal` pass, a bounds rescan, and the renderer snapshots.
    - Measure first. Extend `tests/benchmarks/terrain_latency.gd` for all four tools.
    - Benchmark taps and fast drags at radii 2, 4, 16, and 32.
    - Benchmark the small slab and a large model of about 1000 to 3000 chunks.
    - Keep the MEASURE lines, A/B pairs, medians, warmups, and the 120 s deadline.
    - Keep the benchmark out of suite discovery.
    - Add per-phase counters: frame copies, capture and restore, `_chunks_equal`, bounds rescan, footprint scans, cell writes, and worker surface builds.
    - Take one candidate at a time, in this order:
      1. [x] Drop the per-dab whole-frame snapshot. Write the tick job to the live frame. Keep the stroke-level rollback. Measured 2026-11-02.
      2. [x] Publish a worker result by chunk location. Hand the worker a shared `job_frame`. Measured 2026-11-02.
      3. [x] Batch several crossed centers into one prep job. Measured 2026-11-02.
      4. Scale the footprint depth with the radius for small radii. Guard the tall-terrain regression.
      5. Track changed chunks across the stroke. Skip the full `_chunks_equal` pass at finish.
      6. Replace the per-dab bounds rescan with incremental or debounced bounds.
      7. Measure the idle re-pose frame copy before changing it.
      8. [x] Bound the hover request snapshot to its read box. Measured 2026-11-02.
    - Measure each candidate before and after. Compare the counters and the MEASURE lines.
    - Guard exact geometry, materials, undo, redo, cancellation, symmetry, and selection with A/B pairs.
    - Run the affected tests and the full suite before reporting done.
    - Candidate 1 result, measured 2026-11-02.
      - The benchmark covers 64 tool, radius, gesture, and fixture pairs plus three legacy Smooth viewport rows. The before run had six leaked headless test processes. The after run ran on the quiet machine. The unchanged legacy rows show a 0.84 to 0.98x machine bias by radius.
      - Small dabs of 4096 cells or fewer write the live frame inline. Larger dabs write a job frame and publish the changed chunks at finish. Grab captures one baseline per press and restores only the touched chunks at finish.
      - The small-radius drags are the clear win. The radius 32 drags are within the noise band after the machine bias.
      - Flatten radius 2 drag, large model: 29.50 to 6.21. Smooth radius 2 drag, large model: 56.71 to 21.86. Grab radius 2 drag, large model: 28.38 to 11.31. Build radius 2 drag, large model: 54.05 to 26.75.
      - Smooth radius 32 drag, small model: 7899.60 to 6791.21. Build radius 32 drag, small model: 2002.85 to 1565.73. Flatten radius 32 drag, small model: 1320.39 to 1102.20. Grab radius 32 tap, small model: 223.50 to 190.06.
      - The phase counters show the mechanism. Smooth radius 32 drag, small model: capture 83.4 to 32.8, copy frame 55.4 to 29.8, restore 81.4 to 30.8. Job frame and publish add 25 calls each. Grab radius 32 tap, small model: copy frame 1 to 0, restore 2 to 1.
      - The 18 affected test groups passed. The full suite passed with 167 scenes.
      - Grab removed the old radius 12 source clamp. A Grab press now reads the full radius ball. The before and after Grab radius 32 rows are not directly comparable. The after rows read about 19x more cells per mask.
    - Candidates 2 and 3 result, measured 2026-11-02.
      - Fixture: a 400 by 400 one-cell plate of 625 chunks, radius 16 Build, ten drag events, 81 crossed dabs.
      - Before: 1669 ms, with 49 ms capture and 38 ms restore.
      - After the per-location publish and the shared `job_frame`: 1512 ms, capture 17 ms, restore 11 ms, publish 2 ms. The whole-frame restore per dab is gone.
      - After batching: 1105 ms over two runs. About 3.7 dabs per job, 22 jobs instead of 81. That is 34 percent below the 1669 ms baseline.
      - The worker takes 10 to 17 ms for one radius 16 dab, so one dab already fills a render frame. The batch target is 50 ms of worker time (`PREP_BATCH_TARGET_US`). A larger target adds no gain.
      - One job costs at least one frame, because `State.run_edit_job` waits a process frame. Batching is the only way to amortize that wait.
      - `_chunks_equal` at release cost 0 ms on the sparse plate. Keep the changed-chunk tracking for dense models.
      - The bounds rescan cost 21 ms over 80 calls, about 1.4 percent. It stays a later candidate.
      - New test `terrain_prep_worker.batch_parity` compares one batched job against three single-center jobs, for the frame and the carried influence. It fails when the internal progress debit is removed.
      - New test `chunk_materials.chunk_publish` locks the copy-on-write marker of `apply_published`.
      - The hover request now snapshots only the read box. Radius 4 on a 676-chunk frame: 431 to 195 us. Test `terrain_prep_worker.hover_subset`.
      - [x] Delete the hover cell pass and make the hover fit only.
        - The hover built a sample map or a Smooth field, then a cell set that the ring never used. Only `tests/benchmarks/terrain_preview_probe.gd` read it.
        - `compute_preview_cells`, `smooth_field_cells`, `publish_now(cells)`, `_preview_cells`, the `cells_*` counters, and the map watch are gone.
        - The hover request no longer carries the tool, build mode, selection, context, symmetry, falloff, or depth. It carries the pick, the source, the radius, the floor, and the view.
        - The Smooth hover no longer builds its rounding field.
        - The obsolete preview and hover-scaling benchmarks are deleted.
      - [x] One Build layer for both directions, with a cylinder brush and a center base ground.
        - The Build brush is a cylinder: size s wide, half-height `max(1, ceil(s * 0.25))`. The sample map reads inside it.
        - `TerrainGeometry.dominant_step` and `build_layer_cells` add or clear one cardinal cell along the dominant normal axis. Add and Dig share the axis, so they feel the same.
        - The first sample of a column records `base_surface`. `TerrainPreview.center_surface` and `TerrainFrame.recenter_to` move the plane origin to the base under the cursor. The ground never follows the average, so a flat floor does not spiral.
        - A later stroke starts from the grown surface.
        - Tests: `terrain_tools.build_dig_symmetry`, `terrain_build_follow.layer_tilt`, `terrain_build_follow.spacing_frozen`, `terrain_build_follow.follow_levels`, `terrain_build_follow.follow_beyond_scan`, `terrain_stroke_input.tall_build_parity`.
        - The 16 terrain scenes pass.
      - [x] Make the terrain brush size a diameter.
        - `TerrainGeometry.disk_offsets` delegates to `VoxelBrushSize.disk_offsets`, so size 1 is one cell, 2 is 2x2, and 3 is 3x3. An even size centers between four cells.
        - `TerrainRing.legacy_plane_ring`, `_pose_footprint`, and the sample map all read the one size disc, so the ring encloses the cells that the dab writes.
        - The setting field is still named `radius`. Read it as a size.
        - Tests: `terrain_ring.ring_encloses_footprint`, `terrain_tools.fit_disc`, `terrain_cursor_preview.motion_cache`, `terrain_build_profile`.
      - [x] Start the falloff at the nearest cell of the footprint.
        - An even size has no center cell, so a curve measured from the geometric center peaked below one. A strength-one dab then applied no step, and the largest brush silently did nothing.
        - `TerrainGeometry.disk_inner` returns the nearest distance. `weight_at` takes it as the start of the curve, so the nearest cell of every size weighs exactly one.
        - Tests: `terrain_prep_worker.large_worker`, `terrain_prep_worker.flatten_worker`, `terrain_prep_worker.smooth_worker`.
      - [x] Seed an empty surface on the captured floor.
        - The seed no longer depends on where the stroke started. A press on a voxel does not block a later floor seed.
        - The seed uses the captured floor plane, not the moving operation plane.
        - `build_layer_cells` and `flatten_action` take the per-sample `seed` cell. `seed_empty` is gone.
        - Tests: `terrain_build_follow.add_hit_then_floor_miss`, `terrain_tools.build_empty_floor`.
      - [x] Remove the Surface and Face normal-source option.
        - Build, Flatten, and Smooth fit the local surface. Grab uses the picked face.
        - `TerrainToolSettings.normal_source`, the option toggle, and `terrain_normal_toggle` are gone.
      - [x] Terrain reacts to grid movement, not raw pointer motion.
        - `update_visual` skips a motion that stays in the same hit cell, entry, and target, but it still marks the hover read region dirty. A raw write can change the surface under the same cell.
        - Tests: `terrain_cursor_preview`, `terrain_sample_ownership`.
      - [x] One strength rule for every tool, with no credit and no time.
        - `strength` is an int from 1 through 16. One dab adds `roundi(strength * weight)` layers, or passes for Smooth.
        - A weight below 0.5 adds nothing, so a soft rim needs a higher strength.
        - `TerrainPrep.accumulated`, `_progress`, `used_steps`, `settled`, the Smooth seconds, rate, carry, and credits are gone.
        - The Strength control uses whole steps and the `depth` icon.
        - Tests: `terrain_tools.build_strength`, `terrain_tools.build_repeat`, `terrain_tools.falloff_fractional`, `terrain_smooth.weights_scale_rate`, `terrain_rounding.pass_cap_bounds_call`.
      - [x] A Build revisit keeps the tracked top of every column.
        - `_stroke_columns` keeps the top per logical column for the whole stroke.
        - The Build read bound is `min(64, max(8, size * 2))`, so a first read reaches a tall column.
        - A failed read no longer seeds the captured floor cell on a column that already grew.
        - Test: `terrain_build_follow.revisit_keeps_top`.
      - [x] A dab needs a visible screen move.
        - A view nearly parallel to the cursor plane moves the anchor several cells per pixel, mostly along the view ray.
        - `_dab_moved_enough` requires 3 pixels between two accepted dabs, so a tiny jitter adds no layer.
        - The surface plane, the kernel, and the per-cell dab count do not change.
      - [x] Smooth rounds a sphere.
        - `TerrainGeometry.sphere_offsets` fills the field from the cells within `size * 0.5`.
        - `SMOOTH_NORMAL_REACH`, `depth`, and `reach` are gone from the Smooth path.
        - A tall step at the brush rim is outside the sphere.
  - [ ] Complete the remaining Terrain integration
    - Move cold-press surface fitting off the main thread.
    - Verify long Build strokes manually. Keep the original mound profile without periodic waves.
    - Remove the fixed Build lookup restriction without adding unbounded searches.
    - Add a terrain-following contour for idle and other appropriate previews. Every terrain tool poses one flat footprint ring from `TerrainRing.legacy_plane_ring`. The ring follows the fitted surface plane by user choice.
    - Apply the shared size range from 1 to 64 to Terrain and Grab.
    - Move the maximum-size Grab capture off the main thread. The press copies the whole frame and reads about 137 thousand cells per mask at radius 32.
    - Keep broad rounding disabled until complete-tool measurements justify its larger read region and cost.
  - [ ] Close the maximum-size Spray preview and rendering gaps
    - Require visible cursor updates during sustained drags.
    - Reduce model installation gaps. The mesher changes did not remove the multi-second gaps.
  - [ ] Consolidate proven performance mechanisms for new tools
    - Add no universal framework or class hierarchy.
    - Reuse footprints, operation ownership, cancellation, and prepared outputs without adding per-voxel overhead.
    - Keep replaceable hover requests separate from accepted edits. Preserve every accepted edit.
    - Measure Transform, Line, Paste, and selection depth checks before choosing further changes.
    - [x] Publish repeated worker results by chunk location.
      - `VoxelFrame.apply_published` replaces the whole-frame restore in Terrain, Brush, Paint Brush, Spray, Line, Paste, Transform, Fill, Erase Selection, and Cut.
      - `VoxelFrame.job_frame` replaces the per-job `copy_frame` where the source is not written during the job.
      - A published frame keeps the copy-on-write marker where the job did not write. The test `chunk_materials.chunk_publish` locks this.
      - A baseline preview publishes the union of the current and previous locations. Grab does this.
      - Do not use `job_frame` for a read snapshot that outlives the job unless the source is marked shared. Select and Wand keep `copy_frame`.
      - The 40 affected scenes pass. Terrain fell from 1669 to 1105 ms on the radius-16 plate fixture.
      - The pencil fell from 203 to 169 ms on a 3200-chunk fixture with 21 batches.
  - [ ] Bound measured main-thread work across frames
    - Compare a shared per-frame installation budget against the current per-renderer budgets.
    - If uploads dominate, divide large mesh installations across frames.
    - Preserve the previous mesh until its replacement is ready.
    - Measure continuous drags and queued motion bursts. Preserve every stroke cell and bounded cancellation.
    - An installation costs about 1 ms per frame. Do not prioritize shared installation budgets without new evidence.
  - [ ] Complete the drawing acceptance measurements
    - Run `tests/draw_latency.tscn` after cleanup changes. Compare every `MEASURE` line.
    - Compare maximum-diameter gaps with the idle and small-brush gaps under the same display settings and load.
    - Keep the 7 to 8 ms headless result as a reference, not a 60 Hz windowed target.
    - Require visible latency to follow the stroke footprint, not the queued motion count.
    - Do not regress edit time, visible latency, or frame gaps at ordinary brush sizes.
    - Verify geometry, material samples, sparse models, undo, and cancellation.
    - `draw_latency` needs about 51 s under load and keeps its named 125 s suite deadline.
  - Preserve dense 16-cube chunks unless measurements support a storage change.
  - Keep the exact stepped sphere preview. A box is exact only for cube brushes.
  - Keep full-material seams and identical polygon cleanup for flat and smooth shading.

Start the following tasks after the active drawing task. Measure one candidate at a time.
The first three come from the current Terrain and Spray code.

- [ ] Bound the idle Terrain hover fit
  - The idle Surface fit runs on the worker pool. The ring keeps its fallback pose while the fit runs, so the main thread stays free.
  - The pose cache reuses one fit per pick, so only a new cell or a cell-change signal starts a fit.
  - The fit walks a disc of about 3200 columns at radius 32. Each column marches up to 64 cells.
  - The idle fit passes a query context. A small-radius press fit does not, and a large press reuses the hover frame.
  - Pass the drawing context to the fit to reject empty columns and out-of-bounds rays.
  - Measure `tests/benchmarks/terrain_hover_scaling.gd` before and after. Read `fit_us`, `input_us`, and `frame_gap_us`.
- [ ] Stop the full occupancy row rebuild after a write
  - Every occupancy change bumps `Chunk.occupancy_revision`, so the next read rebuilds 256 row masks from 4096 grid slots.
  - One stroke writes many chunks. Each write invalidates the rows of that chunk, so the next Spray sample rebuilds it.
  - Patch the row mask and the count on the write path. Keep the immutable build for a chunk copy.
  - Measure `tests/benchmarks/spray_cost.gd` and the `index_builds` and `grid_reads` counters of `spray_search_scaling`.
- [ ] Include the cold occupancy build in the Spray work estimate
  - `work_estimate` excludes the first row build of a cold chunk. The inline limit can then pass on work that runs on the input event.
  - Count one cold row build for each touched chunk that holds no current rows.
  - Measure the cold rows of `spray_search_scaling` at size 64.
- [ ] Reduce remaining planar cleanup costs
  - Run `tests/planar_geometry.tscn -- planar_cleanup` for differential checks and in-process benchmarks. See `MEMORY.md` for measurements.
  - Preserve the test-only frozen region and surface references. Do not update them to hide a regression.
  - Re-profile protection, grouping, emission, and non-unit regions before selecting another change.
  - Compare delayed cell-mask compaction when prepared loops need no hole cut.
  - Compare a native cell sort against the script comparator on the sparse dictionary path.
  - Reuse prepared region data only within one build. Define invalidation when seam protection changes.
  - Preserve exact geometry, normal-dependent vertex sharing, protected seams, and cancellation.
  - Guard parity with `planar_cleanup`, `planar_paths`, `planar_merge`, `failed_greed`, and `greedy_viewport`.
  - Preserve the `failed_greed` counts: 64 greedy triangles and 72 cleanup triangles.
  - Preserve the solid chunk's twelve triangles, 24 flat vertices, and eight smooth corners.
- [ ] Re-profile the greedy mesh scan
  - Compare occupied plane rectangles only if scanning remains a measured cost.
  - Keep the direct textured-face path. Do not add a greedy pass to that path.
  - Do not repeat snapshot-loop clipping without new evidence. The earlier measurement rejected it.
- [ ] Reduce large uniform brush write preparation
  - Re-measure stamp generation, chunk bucketing, and storage separately.
  - Compare chunk-local spans or ranges against per-cell dictionaries for uniform shape brushes.
  - Preserve selection materials, write order, copy-on-write isolation, bounds, neighbor reports, undo, and cancellation.
  - Compare the full edit cost. Reject gains that only move work into conversion or publication.
- [ ] Reuse completed preview geometry across shape changes and application sessions
  - Measure cold generation, memory-cache hits, and disk-cache loads before choosing persistence.
  - Compare a versioned cache under `user://` with the existing bounded memory cache.
  - Define keys for shape, diameter, shading, material inputs, and generator version.
  - Bound disk storage. Reject corrupt or stale entries and regenerate them safely.
  - Preserve exact voxel previews and cancellation during rapid shape changes.
- [ ] Share an atlas set per frame
  - Treat this as a memory and material task, not a proven drawing-latency fix.
  - Keep albedo, finish, and emission textures separate.
  - Deduplicate full material content or use stable frame-wide ids. Chunk-local ids are not globally unique.
  - Define atlas lifetime, cache ownership, growth, UV stability, and frame-wide emission normalization.
  - Avoid rebuilding every chunk when one material changes. Test multiple viewports and animation frames.
  - Preserve the one-material 3x3 atlas and its gutter.
- [ ] Reduce atlas packing cost for material-heavy models
  - Re-measure the packing sort on thousands of unique patches.
  - Compare native sortable keys against the script comparator. Preserve deterministic packing and material samples.
- [ ] Measure sparse-model memory and edit costs
  - Measure many one-cell chunks, not only dense blocks. Each one-cell chunk holds a 16 KB grid.
  - If grid memory is material, compare byte-encoded 16-bit ids against the current grid.
  - Include read, write, snapshot, and serialization costs. Godot has no `PackedInt16Array`.
- [ ] Reduce the triangle count around holes and notches
  - Keep this separate from geometry-preserving cleanup optimizations.
  - Preserve coverage, material boundaries, winding, and crack-free seams in viewport and export meshes.
  - Test diagonal notches, touching holes, negative coordinates, and coordinates near 4096.
- [ ] Distribute expensive jobs across the available worker threads
  - Profile independent chunk work and single-job tools before changing worker allocation.
  - Compare bounded chunk work groups with individual tasks. Include task and merge overhead.
  - Preserve surface-signature caching and job deduplication across viewports.
  - Keep a reserve for interaction, cancellation flags, deterministic merges, and a bounded in-flight window.
  - Judge visible latency and frame gaps, not core utilization.
  - Do not repeat rejected job-limit sweeps, stamp splits, or renderer-backlog holds without new evidence.

For performance changes, compare warmed alternatives in one process with alternating execution order.
Treat differences near five percent as noise. Reject synthetic-only gains and incomplete test reports.
Keep known runner-startup errors separate from scene errors. Do not assume new failures are baseline failures.

## Import

- [ ] Import native Aseprite files

## Palette

- [ ] Select and move multiple swatches
  - Select multiple swatches with a drag.
  - Move the selected swatches to a new palette location with a drag.
- [ ] Add palette sorting
  - Reverse the swatch order.
  - Sort by hue, saturation, and brightness.
  - Sort by red, green, and blue.
- [ ] Create a gradient across selected swatches
  - Use the first and last selected swatches as the endpoints.
  - Replace the selected swatches between the endpoints.

## Primitives and stamps

- [ ] Add sphere, box, and cylinder fill primitives to a tool menu
- [ ] Place a saved voxel file as a stamp

## Onion skinning

- [ ] Show previous and next frames as ghosts behind the current frame
  - Add a toggle and a strength control.

## Responsive UI

- [ ] Adapt narrow layouts for phone use
