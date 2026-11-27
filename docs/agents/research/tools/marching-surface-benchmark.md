# Low-poly surface benchmark

Date: 2026-11-27.

Status: measured and committed.
The benchmark guards the geometry of the low-poly mesh style.
The coplanar merge changes the accepted geometry and the hashes.

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
godot --path . -s res://addons/test_kit/run.gd -- marching_mesh marching_bridge marching_chunks marching_material marching_snapshot
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
It covers each UV at 1/1024 precision.
It covers each index.

The hash covers the UV mapping.
It does not cover the atlas texel values.

The viewport measurement loads the same sphere into the editor renderer.
It times the frame copy, the worker jobs, the mesh install, and the material.
It reports one run after the mesher passes.

## Snapshot

| Scene | Chunks | Non-empty | Vertices | Triangles | Hash |
| --- | --- | --- | --- | --- | --- |
| Material sphere, radius 5 | 64 | 8 | 3188 | 2594 | 1883275330112574591 |
| Testing2 frame 0 | 66 | 5 | 5249 | 4792 | -5498388611216165116 |
| Test3 frame 0 | 27 | 1 | 240 | 128 | -7364442111179200461 |
| Testing frame 0 | 48 | 4 | 570 | 536 | 7524680455144278717 |
| me frame 0 | 48 | 4 | 5928 | 5860 | 6804043150157951673 |

The radius-5 sphere is deterministic and runs in the test suite.
It uses four materials.
Its cells cover eight chunks around the origin.
The input cells have their own hash: 5752160045764862365.

The prototype models are not tracked.
The benchmark skips a model when its file is absent.
The snapshot test does not use a model file.
The benchmark builds the models in flat mode.
The smooth viewport path merges only a fan whose vertex normals all match.

## Cost

The "before" column is commit `5274453` with the same fixture, order, warmup, and median.
The "after" column is the optimized builder.

| Scene | Before (us) | After (us) | Speedup |
| --- | --- | --- | --- |
| Material sphere | 1049239 | 139323 | 7.5x |
| Testing2 | 940450 | 251660 | 3.7x |
| Test3 | 121936 | 8604 | 14.2x |
| Testing | 502327 | 53493 | 9.4x |
| me | 985508 | 446905 | 2.2x |

The editor viewport settles the sphere in 106776 us in one run.
This value includes the parallel chunk jobs and the frame waits.

After phases:

| Scene | Sample | Field | Cells | Drop | Normals | Merge | Atlas |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Material sphere | 9122 | 41746 | 53357 | 8823 | 9808 | 12557 | 851 |
| Testing2 | 7166 | 25401 | 113843 | 22838 | 22969 | 53792 | 751 |
| Test3 | 918 | 788 | 4954 | 398 | 511 | 423 | 110 |
| Testing | 3490 | 6180 | 26136 | 3204 | 3352 | 9903 | 211 |
| me | 13052 | 101293 | 162984 | 34680 | 34176 | 94771 | 781 |

All values are microseconds.

The performance changes kept every hash equal until the coplanar merge.
The atlas and smooth normal changes add UVs and optional smooth normals.
The coplanar merge changes the accepted geometry and its hash.

The field phase was the largest cost before the change.
On Testing2 it fell from 776717 to 25107 microseconds.
The cell phase is now the largest cost on Testing2 and me.

## Coplanar merge

Flat mode merges coplanar triangle fans after the normal rebuild and after ambient occlusion.
Smooth mode also merges a fan when the removed vertex and every link vertex have the same normal at 1/1024 precision.
The merge removes an interior vertex when its incident triangles share one normal, one material, and one plane, and the link is one convex loop.
It retriangulates the loop and keeps every boundary vertex.

| Scene | Mode | Triangles before | Triangles after | Change | Merge (us) |
| --- | --- | --- | --- | --- | --- |
| Material sphere | Flat | 2606 | 2594 | -0.5% | 12557 |
| Testing2 | Flat | 6444 | 4792 | -25.6% | 53792 |
| Testing2 | Smooth | 6444 | 5116 | -20.6% | 50819 |
| Test3 | Flat | 128 | 128 | 0% | 423 |
| Testing | Flat | 952 | 536 | -43.7% | 9903 |
| me | Flat | 9464 | 5860 | -38.1% | 94771 |
| me | Smooth | 9464 | 7714 | -18.5% | 74916 |

The benchmark measures the flat rows.
The smooth rows are separate probes of frame 0 with the merge on.

The flat mesh build is slower by 6% on the sphere and 17% to 25% on the models.
The flat rendered triangle count falls 26% to 44% on the models.
The smooth rendered triangle count falls 18% to 21%.
The material coverage stays the same.
Triangle-level symmetry is not kept for coplanar faces.

## Materials and normals

The builder now writes one 1x1 atlas patch for each material in the final mesh.
It writes the patch centre as the UV of each vertex.
The chunk material therefore gets the albedo, ORM, and emission textures.
Metal, roughness, emission, and transparency use the same atlas path as style 0.

Smooth normals are optional.
The renderer passes the document setting to the builder.
The smooth pass averages the adjacent triangle normals by area at each position.
Flat mode keeps one normal per triangle.
A zero average falls back to the face normal.

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
- The full suite passes.

## Update the snapshot

1. Change the builder.
2. Run the snapshot test.
3. Compare the vertices, triangles, UVs, and hash with the table.
4. Change the constants in `tests/marching_snapshot.gd` only for an accepted geometry or UV change.
5. Change the model hashes in `tests/benchmarks/marching_surface.gd` only for an accepted geometry or UV change.
