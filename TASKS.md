---
max_active: 1
---

# Roadmap

Keep one active task at a time. Keep all remaining features until the scope review.
Use Git history for completed work. See [MEMORY.md](MEMORY.md) for verified engine and workflow facts.

## Verification

- [ ] Close the remaining implementation tasks
  - [ ] Ask the user to test the Transform and Plane tools manually
  - [ ] Run the affected behavior tests:
	- Per-voxel materials and material swatches
	- Independent picker settings and palette entries
	- Shared planar cleanup in the viewport and exporter
- [ ] Investigate the intermittent keyboard-focus failure in `material_controls`. A targeted rerun does not replace a clean full suite.
- [ ] Keep the test suite near 10 minutes
  - [ ] Merge the material, export, large, dialog, and selection scenes. Keep each scene below 25 s.
- [ ] Audit the coverage against `docs/agents/tool-flows/*.md`
- [ ] Check orthographic rays and long-distance occlusion in the selection depth test.

## Tools

- [ ] Finish the floor-plane slice
  - [ ] Add the arrow-key nudge. Godot consumes bare arrows for focus navigation, so route it before the GUI, or use a modifier.
  - [ ] Ask the user to test the slice option manually with Brush, Paint, Line, Spray, Fill, Transform, Cut, and Erase Selection.
  - [ ] A Terrain stroke does not refresh the matte. Terrain stays outside the write gate, and it publishes through `chunks_changed`, while the matte listens to `cells_changed`. Connect it only if Terrain stays outside the gate.
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
	  1. Scale the footprint depth with the radius for small radii. Guard the tall-terrain regression.
	  2. Track changed chunks across the stroke. Skip the full `_chunks_equal` pass at finish.
	  3. Replace the per-dab bounds rescan with incremental or debounced bounds.
	  4. Measure the idle re-pose frame copy before changing it.
	- Measure each candidate before and after. Compare the counters and the MEASURE lines.
	- Guard exact geometry, materials, undo, redo, cancellation, symmetry, and selection with A/B pairs.
	- Run the affected tests and the full suite before reporting done.
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
