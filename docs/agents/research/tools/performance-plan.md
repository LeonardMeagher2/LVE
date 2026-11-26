# Performance analysis and plan

Date: 2026-11-18.

Status: analysis only.
No behavior change is in this document.
The plan keeps every tool result, every cell order, and every undo record.

## Evidence labels

| Label | Meaning |
| --- | --- |
| Measured | A benchmark or a test run shows it on this machine. |
| Inference | A reasoned conclusion from code and measured facts. It is not measured. |
| Proposed | A bounded experiment. It has no result yet. |

Do not read an inference as a measurement.

## Method

- Measure inside one process. A second process on the same machine changes the numbers.
- Compare before and after with the same fixture, the same warmups, and the same order.
- A performance change must keep every affected test green. A faster wrong result is a failure.
- The plan adds no limit to a grid, a scene, or a tool range. A slow case must get faster, not smaller.

Benchmark commands:

```text
godot --path . --screen 0 res://tests/benchmarks/terrain_latency.tscn
godot --headless --path . res://tests/benchmarks/mesher_phases.tscn
godot --headless --path . res://tests/benchmarks/primitive_cost.tscn
godot --path . --screen 0 res://tests/benchmarks/renderer_cycle.tscn
godot --headless --path . res://tests/benchmarks/spray_cost.tscn
```

Logs are in `.tests/`.

## Ranked costs

The rank uses the measured cost of one user action.
A primitive preview runs on every gizmo motion, so a slow rasterize is visible.

| Rank | Operation | Measured cost | Log |
| --- | --- | --- | --- |
| 1 | Primitive add with a smooth blend, 64 cubed cells | 13.33 s apply | `bench_primitive_cost_now.log` |
| 2 | Smooth, size 32, drag | 4.18 to 4.21 s visible, kernel about 4.1 s | `bench_terrain_latency_before.log` |
| 3 | Chunk surface, mixed materials, atlas | 4.38 to 4.61 s per 27 chunks, about 162 ms per chunk | `bench_mesher_phases_now.log` |
| 4 | Primitive add without a blend, 64 cubed cells | 1.16 s apply | `bench_primitive_cost_now.log` |
| 5 | Spray press at width 64, mixed model with one symmetry axis | 0.52 s draw over 76 frames | `bench_spray_max64_now.log` |
| 6 | Build, size 32, drag | 0.61 s small, 0.53 s large, `set_cells` 275 and 237 ms | `bench_terrain_latency_before.log` |
| 7 | Smooth, size 16, drag | 0.68 to 0.69 s | `bench_terrain_latency_before.log` |
| 8 | Flatten, size 32, drag | 0.36 s, worker prep about 89 percent | `bench_terrain_latency_before.log` |
| 9 | Selection outline, 65536 cells | 134 ms | `MEMORY.md`, 2026-10-18 |
| 10 | Chunk surface install, one chunk | About 1 ms per frame | `MEMORY.md`, 2026-10-30 |

Spray sampling itself is already fast: width 64 warm reads 27.5 ms against 1790 ms for the frozen path, which is 65 times faster.
Its press cost is in the write and the surface install, not the sampler.

### Remeasured 2026-11-25

The loop reran the commands above on `main`. This table supersedes the ranks for the measured paths.

| Rank | Operation | 2026-11-25 | 2026-11-18 |
| --- | --- | --- | --- |
| 1 | Primitive add with a smooth blend, 64 cubed cells | 1.64 s | 13.33 s |
| 2 | Chunk surface, mixed materials, atlas, 27 chunks | 1.52 s flat, 2.14 s smooth | 4.68 s |
| 3 | Sprite sheet export, 24 frames, 128 px | 1.28 s | not measured |
| 4 | Primitive add without a blend, 64 cubed cells | 0.51 s | 1.16 s |
| 5 | GIF export, 24 frames, 128 px | 0.69 s | not measured |
| 6 | Chunk surface, mixed materials, color | 0.40 s | 0.35 s |
| 7 | Spray sampling, width 64 warm | 0.028 s | 0.028 s |
| 8 | Document load, 52,428 cells, 2 frames | 0.083 s | not measured |
| 9 | Document encode, same document | 0.026 s | not measured |
| 10 | Document preview render, 94,793 cells | 0.021 s | not measured |
| 11 | Document save, pre-encoded bytes | 0.0004 s | not measured |

Ranks 1 and 2 are within the run-to-run band, so the next step measures the mixed atlas surface.
The export, preview, and document rows come from `export_cost`, `thumbnail_cost`, and `document_io`.

### Parallel surface build (2026-11-25)

`tests/benchmarks/mesh_parallel.tscn` builds the 27-chunk mixed fixture serially and on `WorkerThreadPool`, one task per chunk:

| build | time | vertices | indices |
| --- | --- | --- | --- |
| serial | 1.670 s | 550,125 | 1,057,536 |
| WorkerThreadPool, 16 cores | 0.514 s | 550,125 | 1,057,536 |

The parallel build is 3.25 times faster with identical output.

**This is already the production design.** `ui/Viewport/VoxelRenderer.gd` launches one `VoxelMeshBuilder.run` task per chunk on `WorkerThreadPool` (line 404), caps concurrency at `clamp(cores - 1, 2, 8)` (lines 8 to 24), reaps finished jobs and creates the `ArrayMesh` on the main thread, and budgets each frame with `State.WORK_SLICE_US`.

So the `mesher_phases` totals are serial CPU sums, not the user path. No integration is needed, and the parallel probe validates the shipped scheduler instead of exposing a new opportunity. The remaining surface cost is per-chunk CPU, where six measured rewrites of the inner loops all lost to the current code.

### Dense greedy quad emit (2026-11-25)

Measured: the greedy dense merge holds 68.6 percent of the color scan.
Over 1,120 builds the merge is 8.41 s.
Of that, `_emit_quad` is 5.77 s and quad scanning is 2.64 s.

Measured: one empty call with the same 18 arguments costs 0.221 us.
One `_emit_quad` call costs 1.599 us per quad over 3,702,510 quads.
So the call holds 14 percent of the emit.

Three single-variable rewrites of the body measured inside the noise band, and each was reverted:

| Rewrite | Result |
| --- | --- |
| Per-material `Color` cache | mixed cases inside the existing range |
| Axis-branch face origin and edges | mixed cases inside the existing range |
| Indexed normals and colors instead of append | mixed cases inside the existing range |

Measured: inlining the body into the dense loop removes the call and wins.

| Case | Before | After |
| --- | --- | --- |
| Emit per quad | 1.599 us | 1.276 us |
| Merge, 1,120 builds | 8.62 s | 7.43 s |
| `mixed_flat_color`, no timers | 358,000 to 395,000 us | 332,857 us |
| `mixed_smooth_color`, no timers | 702,000 to 785,000 us | 689,312 us |

The vertex and triangle counts do not change: 705,024 and 352,512.
The sparse path still calls `_emit_quad`, because `chunk.is_sparse()` selects it.
The dense path holds a second copy of the emit body on purpose.
A change to one emit body must reach the other.
The gate scenes pass: `mesh_regressions`, `surface_rendering`, `mesher_read_parity`, `export_smooth_meshing`, `mesher_enclosed`, and `large_surface_edit`.

This moves the color row of the ranked table from 0.40 s to 0.33 s for the flat case.
The smooth color case is 0.69 s.
The atlas case is unchanged, because it finishes through `VoxelSurface`.

## 1. Primitive shape preview and apply

### Evidence

Measured at 64 cubed cells on a solid 32-cubed frame:

| Case | Apply time |
| --- | --- |
| Add, sharp box | 1.16 s |
| Add, step 2 | 0.36 s |
| Add, two primitives with smooth 4 | 13.33 s |
| Subtract | 0.11 s |
| Intersect | 0.11 s |

The blend case applies 241,858 cells and costs 13.33 s.
That is about 55 microseconds per applied cell.

The tool rebuilds the voxel preview on every gizmo motion.
A stale preview job is cancelled at a checkpoint.

### Code path

`PrimitiveJob.run` calls `PrimitiveField.rasterize` on the worker.
`_rasterize_add` reads `field_distance` for every sample of the scan box.
`field_distance` gets each primitive value through `Dictionary` keys and builds a quaternion inverse per call.
With a smooth add on a non-empty frame, `_existing_field` allocates two float fields over the padded box.
It scans the box with `frame.has` per cell.
Then it runs four chamfer sweeps.
Each sweep reads 13 neighbors per cell.
Then it scans the box again to build the values.

### Inference

The blend field holds two float arrays over about 314,000 cells.
Each sweep reads about 4 million neighbors.
Four sweeps read about 16 million neighbors.
Each neighbor reads an `Array` entry with a `Vector3i` inside `CHAMFER_FORWARD` and tests a forward flag.
The sample loop then reads two primitives for every sample.

### Plan

1. Prepare the request once, before the sample loop:
   - Convert each primitive to a compact record.
   - Cache the inverse rotation per primitive.
   - Hoist the smooth value and the shell value out of the loop.
2. Bound the blend field to the band that can change a result:
   - The values clamp at `smooth + 2`.
   - A cell farther than that from the surface holds a value that clamps to the same result.
   - Measure a band-limited chamfer against the full field on the test shapes.
3. Rewrite the chamfer inner loop:
   - Split the forward and backward bodies.
   - Precompute the 13 flat index offsets.
   - Read no `Array` entry inside the loop.
4. Fill the two source fields from the chunk occupancy rows, not one `frame.has` per box cell.
5. Keep the exact cell set. Compare the full result against the current code on the test shapes and on a random set of rotations and shells.
6. Verify with `primitive_field` and `primitive_tool`.
7. Measure the preview on a gizmo drag, not only the apply.

### Risk

The rasterized cell set must stay exact.
A blend that clamps differently changes the shape at the rim.
A band limit must cover every cell that can reach the clamp.

### Done

The smooth add at 64 cubed cells falls by at least half.
The test cells are identical.

## 2. Smooth, size 32, drag

### Evidence

Measured: one drag of 12 pointer steps costs 4.18 to 4.21 s of edit time on the small and the large model.
The phase counters hold only about 90 ms of that on the small model: capture 2.9 ms, restore 1.9 ms, publish 2.1 ms, `set_cells` 61 ms, bounds and document rescans 7 ms, surface work 17 ms.
The remaining 4.1 s is the Smooth kernel, by subtraction.
The large model pays 48 ms of bounds rescan and about 55 ms in total phases.

Measured: the stroke publishes 125 dabs for 12 pointer steps.
The benchmark sets strength to 1, so one dab runs one pass.
So one dab costs about 33 ms.

### Code path

`TerrainTool._smooth_tick` calls `_run_smooth`.
A large patch runs `SmoothJob.run` on the worker.
The job calls `_occupancy(cells)` and then `SmoothOperation.advance`.
The advance runs one Jacobi pass at strength 1.
Each pass reads a frozen occupancy set through `Dictionary.has` with a `Vector3i` key.

### Inference

The tool sets `job.radius` to `SmoothOperation.KERNEL_RADIUS`, which is one.
So the production kernel always runs the base 3x3x3 rule.
A size-32 dab covers a sphere of about 17,000 candidate cells.
The falloff sends cells below one half weight to no pass.
One evaluated occupied candidate currently costs about 46 set reads:
- the surface normal twice, which is 12 reads
- the thin protection, which is 6 reads
- the density kernel, which is 27 reads
- the cell state, which is 1 read

The thin protection reads the same six face cells as the normal.
The density threshold is exact at 14 of 27 cells, so the count can stop early.

### Plan

1. Share the six face reads. Read the face neighbors of a candidate once:
   - Build the surface normal from them.
   - Build the thin protection from the same values.
   - Build the isolated-cell test from the same values.
   This removes 12 of the 46 reads and one whole normal pass.
2. Bound the density count by its threshold. The pass only compares the fraction:
   - Count occupied cells and empty cells.
   - Stop at 14 occupied, which proves the value is above one half.
   - Stop at 14 empty, which proves the value is below one half.
   - Keep the public `occupied_fraction` exact for its callers and tests.
3. Add change propagation for multi-pass dabs. It does not help a strength-1 dab, so it is a second step:
   - In pass zero, evaluate every eligible candidate.
   - In a later pass, evaluate only a candidate within `required_halo(radius)` of a cell that changed in the previous pass.
   - Extend the cleanup set by the reach around this pass's own changes.
   - A cell that was already isolated is removed by the pass decision itself.
   - The cleanup erase of one cell cannot isolate another cell.
4. Do not repeat the grid conversion. A byte grid was tried and measured slower:
   - The per-dab Dictionary to grid and grid to Dictionary walk cost more than the pass saved.
   - A GDScript method call per cell read cost more than a `Dictionary.has`.
   The record stays in the task log.
5. Verify with `terrain_smooth`, `terrain_rounding`, `terrain_occupancy`, `terrain_input`, `terrain_tools_smooth`, and `terrain_smooth_placement`.
6. Measure again with `terrain_latency`.

### Risk

The shared face reads must feed the same three decisions in the same order.
The early exit must use the same threshold comparison, not an approximated fraction.

Change propagation must keep the cleanup exact.
A cell erased by the cleanup changes its own neighborhood.
The next pass must evaluate it again.

### Done

The same cells move, in the same order, and every Smooth test is green.
The size-32 drag and the size-16 drag both fall by at least half.

## 3. Chunk surface, mixed materials, atlas

### Evidence

Measured: 27 mixed chunks take 4.68 s flat and 4.92 s smooth in atlas mode.
The finish phase holds 4.38 and 4.61 s of that.
The same fixture in color mode takes 0.35 s flat and 0.71 s smooth.
The uniform fixture takes 0.13 to 0.15 s.
The mixed fixture builds 550,125 vertices and 352,512 triangles.

Measured: the mixed fixture writes every cell with one of four materials in a diagonal pattern.
This is the worst fragmentation case.

### Finish attribution 2026-11-25

Measured per chunk with phase timers, 140 flat and 238 smooth builds:

| chunk kind | vertices | protect, us per vertex | triangulate, us per vertex | vertex loop, us per vertex |
| --- | --- | --- | --- | --- |
| mixed flat atlas | 20,375 | 0.77 | 0.16 | 1.11 |
| mixed smooth atlas | 19,340 | 0.80 | 0.16 | 2.00 |

The atlas bake is 0.05 ms per chunk. The UV pass is 2.9 ms per chunk.
The row totals are 1.52 s for the flat atlas and 2.14 s for the smooth atlas.
The smooth vertex loop holds 70 percent of the smooth finish, so it is the next target.

Measured: the normal cannot leave the smooth vertex key.
The key `[dbl, patch]` merges the two sides of a one-voxel wall, because `dbl` holds the plane position and not the plane sign.
`mixed_smooth_atlas` falls from 522,188 to 210,982 vertices.
The faster per-vertex number came from the lost vertices.
Reverted.

### Code path

`VoxelMeshBuilder.run` calls `VoxelSurface.run_groups`.
The finish path runs `_protect_groups`, `_triangulate_groups`, a vertex loop, and the atlas bake.
The vertex loop keys each vertex with an Array of a `Vector3i`, a `Vector3`, an integer patch, and an integer alpha.

### Inference

The finish costs about 8 microseconds per final vertex.
Each of the 550,125 vertices is reached through a key attempt.
Each key allocates an Array with a `Vector3i` and a `Vector3` inside it, then hashes the Array.
The planar cleanup also loops over groups more than once when it adds protected corners.

### Plan

1. Split the finish phase. Add timers for group collection, protection, triangulation, the vertex loop, and the atlas bake. The benchmark already reports the finish as one number.
2. Replace the Array vertex key with a packed integer key:
   - A flat normal is fixed by the plane. A smooth normal is fixed by the lattice corner plus the plane fallback.
   - Pack the lattice position, the plane, the patch, and the alpha into one integer.
   - A packed integer key needs no Array and no nested value hash.
3. Cache `add_patch` by material identity. It currently builds and hashes an Array key for each call.
4. Measure the triangulation pass count. If it repeats, compute the protected corner set to a fixed point before the last pass.
5. Keep the exact vertex order, index order, and patch ids. A surface parity test must compare with a frozen copy of the current code.
6. Verify with `mesher_phases`, the mesher tests, `draw_latency`, `surface_rendering`, and the full suite.

### Risk

The mesh arrays are compared by tests and by the export path.
A key change that merges two vertices changes normals or UVs.
The key identity must equal the shading identity exactly.
A zero corner normal falls back to the plane normal, so the key needs the plane even in the smooth case.

### Done

The finish share falls for the mixed atlas fixture.
All surface parity checks are green.

## 4. Build and Flatten drags

### Evidence

Measured: a size-32 Build drag costs 0.61 s on the small model and 0.53 s on the large model.
A size-32 Flatten drag costs 0.36 s.
Input time is 10 to 13 ms.

The phase counters tell a different story per case:
- Build, small: `set_cells` 275 ms of 622 ms. Worker prep holds most of the rest.
- Build, large: `set_cells` 237 ms, capture 70 ms, restore 51 ms, bounds rescan 87 ms, document rescan 28 ms.
- Flatten, small: `set_cells` 27 ms of 364 ms, so worker prep holds about 89 percent.

MEMORY records one worker prep dab at 10 to 17 ms at size 16.
A batch of about 3.7 centers per job cut an 81-dab drag from 1515 to 1105 ms.

### Plan

1. Attribute the worker prep. The sample map is the unmeasured part of the small Build and of Flatten.
2. Optimize the prep function that holds the largest share:
   - Hold each chunk grid and material array in a local inside the sample loop.
   - Cache the disk offsets and the weight table by size.
   - Check whether the sample map rebuilds per crossed cell or per job.
3. For the large model, look at the chunk bookkeeping. Capture, restore, bounds rescan, and document rescan hold 236 ms of the 529 ms edit:
   - Count the rescans per stroke. 171 bounds rescans for 61 dabs is about three per dab.
   - Find the write that marks the bounds dirty without a need.
4. Do not raise the prep batch target. MEMORY has a measurement that a larger target adds no gain on this machine.
5. The per-cell write is near its measured floor. `set_cells` reads 2.7 microseconds per cell, against 2.6 in the recorded best case. Do not rebuild that path.
6. Verify with the terrain tool tests and measure with `terrain_latency`.

### Done

A size-32 Build drag falls below 0.5 s on both models.
The same cells are written.

## 5. Spray press at width 64

### Evidence

Measured: the dense 128 model press draws for 56 ms over 9 frames and paints 11,672 cells.
The mixed 64 model with one symmetry axis draws for 519 ms over 76 frames and paints 12,150 cells.
The sparse 256 model draws for 2 ms.
The spray sampler itself is 65 times faster than the frozen path at width 64.

The phase line in the benchmark is not the production path.
It feeds every candidate to the footprint and skips the occupancy index.
Do not read its sums as press cost.

### Plan

1. Attribute the mixed symmetry press. 76 frames for 12,150 cells is the outlier.
2. Compare the production batch with the symmetry expansion off. If the expansion holds the share, optimize the reflected destination test.
3. Do not change the sampler. Its measured cost is already far below the frozen path.

### Done

The mixed symmetry press draw time falls without a change to the painted cells.

## 6. Unmeasured suspects

These paths have no benchmark. Measure before any change.

- glTF export and GIF export on a large animation.
- Document save, load, and autosave on a large scene.
- Sprite frame generation for many views.
- Frame thumbnail rebuild on a large frame.

Plan: add one benchmark scene each. Rank the result against the table before any optimization.

## Order of work

1. Primitive smooth blend. It is the largest measured cost and it previews on every gizmo motion.
2. Smooth kernel. It is the largest cost in an existing tool.
3. Chunk surface finish. It is the largest single rebuild cost.
4. Build and Flatten dabs. They share one code path.
5. Spray press phases.
6. Measure the unmeasured paths, then decide.

Each step keeps this order: attribute, change, verify, measure, record.

## Non-goals

- No grid, scene, or tool-range limit.
- No machine-specific tuning.
- No change to the accepted cell order or the undo record.
- No visual change to a mesh or a shape.
