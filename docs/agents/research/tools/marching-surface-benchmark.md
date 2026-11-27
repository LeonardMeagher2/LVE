# Low-poly surface benchmark

Date: 2026-11-26.

Status: measured and committed.
The benchmark guards the geometry of the low-poly mesh style.
The optimization keeps every tested mesh identical.

## Commands

Run the snapshot test:

```text
godot --headless --path . res://tests/marching_snapshot.test.tscn
```

Run the benchmark:

```text
godot --headless --path . res://tests/benchmarks/marching_surface.tscn
```

Run the marching suite:

```text
godot --path . -s res://addons/test_kit/run.gd -- marching_mesh marching_bridge marching_chunks marching_snapshot
```

## Method

- Use one process for a scene.
- Request the content chunks and their 26 neighbors.
- Sort the chunk locations.
- Run one warmup pass.
- Run three measured passes.
- Report the median.
- Compare the geometry hash on every pass.
- Compare every hash with the snapshot.

The hash covers each non-empty chunk location.
It covers each vertex position and normal at 1/1024 precision.
It covers each vertex colour at 8-bit precision.
It covers each index.

The low-poly material uses vertex colours.
The hash does not cover metallic or roughness values.

The viewport measurement loads the same sphere into the editor renderer.
It times the frame copy, the worker jobs, the mesh install, and the material.
It reports one run after the mesher passes.

## Snapshot

| Scene | Chunks | Non-empty | Vertices | Triangles | Hash |
| --- | --- | --- | --- | --- | --- |
| Material sphere, radius 5 | 64 | 8 | 3194 | 2606 | 1437062865021484261 |
| Testing2 frame 0 | 66 | 5 | 6075 | 6444 | 1949223109262883231 |
| Test3 frame 0 | 27 | 1 | 240 | 128 | 8805424844172740783 |
| Testing frame 0 | 48 | 4 | 778 | 952 | -5652785560359355839 |
| me frame 0 | 48 | 4 | 7730 | 9464 | 6203146698049274931 |

The radius-5 sphere is deterministic and runs in the test suite.
It uses four materials.
Its cells cover eight chunks around the origin.
The input cells have their own hash: 5752160045764862365.

The prototype models are not tracked.
The benchmark skips a model when its file is absent.
The snapshot test does not use a model file.

## Cost

The "before" column is commit `5274453` with the same fixture, order, warmup, and median.
The "after" column is the optimized builder.

| Scene | Before (us) | After (us) | Speedup |
| --- | --- | --- | --- |
| Material sphere | 1049239 | 125643 | 8.4x |
| Testing2 | 940450 | 197839 | 4.8x |
| Test3 | 121936 | 8134 | 15.0x |
| Testing | 502327 | 44370 | 11.3x |
| me | 985508 | 347572 | 2.8x |

The editor viewport settles the sphere in 117440 us in one run.
This value includes the parallel chunk jobs and the frame waits.

After phases:

| Scene | Sample | Field | Cells | Drop | Normals |
| --- | --- | --- | --- | --- | --- |
| Material sphere | 9011 | 41136 | 53582 | 9357 | 9707 |
| Testing2 | 7114 | 24539 | 113611 | 24333 | 23418 |
| me | 13265 | 98908 | 162798 | 34778 | 33170 |

All values are microseconds.

The field phase was the largest cost before the change.
On Testing2 it fell from 776717 to 25107 microseconds.
The cell phase is now the largest cost on Testing2 and me.

## Changes

1. Build the union field by writing each solid sample into its 5x5x5 neighbourhood.
   - The old loop read 125 samples for each field cell.
   - The new loop writes 125 distances for each solid sample.
   - Both loops cover the same pairs.
   - A dense chunk skips interior solid samples.
   - An interior solid sample is never the nearest solid for a surface corner.
2. Precompute the case data for all 256 occupancy bits.
   - The diagonal mask follows from the occupancy bits.
   - The opposite-pair test follows from the occupancy bits.
   - A cell with all eight corners solid has no surface, so it exits early.
3. Read the eight corner samples with fixed index steps.
   - The step table removes the per-corner vector and index arithmetic.
4. Compute the quad points, labels, sites, and component grid once for each quad.
   - The material partition, corner rule, fan rule, flat rule, and diagonal rule share the result.
   - The old code computed the same values up to three times.
5. Use a 16-entry packed grid for the quad components.
   - The old code used a dictionary with vector keys and a vector stack.
6. Group duplicate triangles with nested position keys.
   - The old code formatted a string for each triangle and sorted the parts.
7. Remove the first weld.
   - The final normal rebuild created new vertices and welded them again.
   - The first weld therefore did not change the final arrays.

## Verification

- The marching suite passes with the snapshot scene.
- The snapshot hash matches on all four models and on the sphere.
- The full suite has three failures. They also fail on the unmodified commit:
  - `chunk_materials`, 3 of 149 checks.
  - `draw_profile`, 1 of 5 checks.
  - `drawing_visibility`, 1 of 6 checks.

## Update the snapshot

1. Change the builder.
2. Run the snapshot test.
3. Compare the vertices, triangles, and hash with the table.
4. Change the constants in `tests/marching_snapshot.gd` only for an accepted geometry change.
5. Change the model hashes in `tests/benchmarks/marching_surface.gd` only for an accepted geometry change.
