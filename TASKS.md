---
max_active: 1
---

# Roadmap

Keep one active task at a time. Keep all remaining features until the scope review.
Use Git history for completed work. See [NOTES.md](NOTES.md) for verified engine and workflow facts.
See [GLTF_EXPORT.md](GLTF_EXPORT.md) for the mesh export format and import settings.

## Verification

- [ ] Close the remaining implementation tasks
  - [ ] Ask the user to test the Transform and Plane tools manually
  - [ ] Run the full behavior suite and the final full suite for these changes:
    - Per-voxel materials and material swatches
    - Independent picker settings and palette entries
    - Shared planar cleanup in the viewport and exporter
  - Run the suites without another Godot instance using this project.
  - Clipboard and model settings popup checks previously failed in a suite but passed alone.
  - The latest closing suite passed 138 of 139 scenes. `hidpi` and `draw_latency` passed.
  - `material_controls` failed five keyboard-entry checks in that suite, then passed four targeted reruns.
  - [ ] Investigate the intermittent keyboard-focus failure in `material_controls`. Do not treat targeted reruns as a clean full suite.
  - [ ] Check orthographic rays and long-distance occlusion in the selection depth test.
  - Keep full-material seams and the same polygon cleanup for flat and smooth shading.
  - Skip the optional Blender OBJ comparison when the reference file is absent.

## Tools

- [ ] Add the Extrude tool
  - Extrude selected voxels along the plane normal.
  - Set the distance with a drag.

## Rendering and performance

- [ ] Keep drawing responsive on large models (active)
  - [x] Profile maximum-diameter strokes with the real renderer before choosing the next change.
    - Measure cube and sphere brushes at diameters 9, 32, and 64.
    - Separate input handling, edit completion, surface completion, and the longest frame gap.
    - Time chunk notifications, surface signatures, snapshot copies, mesh uploads, materials, and cache eviction.
    - Check one viewport and multiple viewports. Headless timings exclude GPU upload costs.
    - Count unique changed chunks separately from emitted chunk entries.
  - [ ] Bound measured main-thread work across frames.
    - Compare a shared per-frame installation budget against the current per-renderer budgets.
    - If uploads dominate, divide large mesh installations across frames.
    - Preserve the previous mesh until its replacement is ready.
    - Measure continuous drags and queued motion bursts. Preserve every stroke cell and bounded cancellation.
    - An exact packed-int64 surface key reduced signature generation to about one third in repeated in-process comparisons.
    - Cross-run publication estimates fell 26 percent flat and 44 percent smooth. External load limits that comparison.
    - The measured installation cost averages about 1 ms per frame. Do not prioritize shared installation budgets without new evidence.
  - [ ] Complete the drawing acceptance measurements.
    - Run `tests/draw_latency.tscn` after the cleanup changes. Compare every `MEASURE` line.
    - Compare maximum-diameter gaps with the idle and small-brush gaps under the same display settings and load.
    - Keep the 7 to 8 ms headless result as a reference, not a 60 Hz windowed target.
    - Require visible latency to follow the stroke footprint, not the queued motion count.
    - Keep edit time, visible latency, and frame gaps from regressing at ordinary brush sizes.
    - Verify geometry, material samples, sparse models, undo, and cancellation.
    - Run affected tests and the required full suites when closing this implementation task.
    - `draw_latency` runs visible strokes on the second monitor and needs about 51 s under load. It has a named 125 s suite deadline. Every other scene keeps the 30 s default.
    - The closing suite passed 138 of 139 scenes. Keep the keyboard-focus failure open despite four passing targeted reruns.
  - Use the 2026-10-18 pre-cleanup checkpoint only as context: 26 ms maximum gap and 0.828 s visible completion.
  - At that checkpoint, diameter nine had 48 ms visible latency and an 8 ms gap.
  - Preserve dense 16-cube chunks unless measurements support a storage change.
  - Keep the exact stepped sphere preview. A box is exact only for cube brushes.

Start the following tasks after the active drawing task. Measure one candidate at a time.

- [ ] Reduce remaining planar cleanup costs
  - Run `tests/planar_geometry.tscn -- planar_cleanup` for differential checks and in-process benchmarks. See `NOTES.md` for measurements.
  - Preserve the test-only frozen region and surface references. Do not update them to hide a regression.
  - Re-profile protection, grouping, emission, and non-unit regions before selecting another change.
  - Compare delayed cell-mask compaction when prepared loops need no hole cut.
  - Compare a native cell sort against the script comparator on the sparse dictionary path.
  - Reuse prepared region data only within one build. Define invalidation when seam protection changes.
  - Preserve exact geometry, normal-dependent vertex sharing, protected seams, and cancellation.
  - Guard parity with `planar_cleanup`, `planar_paths`, `planar_merge`, `failed_greed`, and `greedy_viewport`.
  - Preserve `failed_greed` counts: 64 greedy triangles and 72 cleanup triangles.
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
  - Measure many one-cell chunks, not only dense blocks.
  - The recorded one-cell chunk costs about 18 KB, including a 16 KB grid.
  - If grid memory is material, compare byte-encoded 16-bit ids against the current grid.
  - Include read, write, snapshot, and serialization costs. Godot has no `PackedInt16Array`.
- [ ] Reduce the triangle count around holes and notches
  - Keep this separate from geometry-preserving cleanup optimizations.
  - A recorded one-cell hole raises a 16 by 16 plate from twelve triangles to forty.
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
