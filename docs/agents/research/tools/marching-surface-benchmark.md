# Low-poly surface benchmark

Date: 2026-11-27.

Status: measured and committed.
The benchmark guards the geometry of the low-poly mesh style.
The coplanar merge changes the accepted geometry and the hashes.
The limited dissolve changes only the smooth geometry.
The flat hashes and the snapshot do not change.

## Constraints

- Keep one material per triangle.
- Keep the material coverage symmetry.
- Keep the visual design of the current low-poly models.
- Do not hardcode a symmetry plane.
- Keep the old stable mesher available for comparison.

The builder still holds unused repair passes: `_fill_boundary_ears`, `_pinch_material_seams`, `_collapse_near_hole_vertices`, and `_flip_diagonals`. `hard_boundaries` and `per_material` are unused.

## Decisions

- The benchmark hash covers position, normal, colour, UV, and index. It does not cover atlas texel values.
- Smooth normals use area-weighted face normals at each position.
- The atlas uses one 1x1 patch per material with the patch centre as the UV.
- The prototype model files stay untracked.
- The style-0 cache keeps 64 MB and 1024 entries. The low-poly cache keeps 256 MB and 4096 entries.
- A frame switch keeps the old chunk mesh until the replacement is ready. A document replacement hides the old document at once.
- The surface key hashes the chunk content, not the chunk instance. The content key hashes the dense cell grid and the material table.
- Ambient occlusion uses the corrected face normal and a 3-sample outside layer.
- The low-poly export uses one frame atlas and one patch-centre UV per vertex.
- A full rebuild requests only the occupied chunks. A slice filters the present neighbours by the slice row range.
- Flat mode merges coplanar fans after the normals and ambient occlusion. Smooth mode merges only a fan whose vertex normals all match.
- Coplanar merging may change triangle-level symmetry. Material coverage stays symmetric.
- The limited dissolve runs after the coplanar merge in smooth mode. A seam vertex does not dissolve. A seam edge is a boundary edge, a material edge, or a crease above 25 degrees.
- The dissolve keeps the normal at the removed position within 8 degrees and the colour within 0.02.
- The dissolve picks the fan with the lowest maximum normal spread, then the best shape, then an ear clip.
- The dissolve cost is reported in its own benchmark phase. The smooth dissolve adds 24% to the Testing2 build and 36% to the me build.

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
godot --path . -s res://addons/test_kit/run.gd -- marching_mesh marching_bridge marching_chunks marching_material marching_snapshot marching_dissolve
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

## Performance pass: packed passes

The "before" column is commit `86ce9fd`.
The "after" column is the optimized builder.
Both runs were adjacent on one machine.
Each value is the median of three measured passes after one warmup.

| Scene | Before (us) | After (us) | Speedup |
| --- | --- | --- | --- |
| Material sphere | 148040 | 110640 | 1.34x |
| Testing2 | 261836 | 196554 | 1.33x |
| Test3 | 8618 | 7284 | 1.18x |
| Testing | 53148 | 44295 | 1.20x |
| me | 436753 | 336210 | 1.30x |

Every scene keeps its geometry hash.

After phases:

| Scene | Sample | Field | Cells | Drop | Normals | Merge | Atlas |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Material sphere | 8899 | 29407 | 44713 | 4584 | 9418 | 9257 | 742 |
| Testing2 | 6965 | 15994 | 92891 | 11236 | 22300 | 41495 | 697 |
| Test3 | 921 | 711 | 4056 | 219 | 480 | 298 | 108 |
| Testing | 3208 | 4661 | 22320 | 1651 | 3268 | 7822 | 187 |
| me | 12689 | 58472 | 135801 | 16239 | 32533 | 72787 | 746 |

All values are microseconds.

Changes:

1. Write the union field into a volume that has the field radius as padding on each side.
   - The old splat tested three bounds for each of 125 samples.
   - The padded volume accepts every sample.
   - `_field_point` reads the padded volume with its own corner steps.
   - The field phase fell 13 to 40 percent.
2. Read the eight cell corners once for both the occupancy bits and the cell material.
   - The old scan read the corner samples twice.
   - A packed corner-step table removes the variant index math.
3. Keep the case loops, triangles, and face triangles in three static arrays.
   - The old cell loop did a dictionary lookup for each cell.
4. Reuse the four quad field points for the triangle emission.
   - The old loop computed each edge point again.
5. Return the edge site and label through builder fields.
   - The old helper allocated a two-entry array for each call.
6. Test the quad fan ambiguity only for a uniform quad.
   - The old test built two intrinsic length keys even when the result was unused.
7. Compute one canonical position id for each welded vertex, and use it in both drop passes.
   - The old passes rounded every position again.
   - A packed 63-bit group key replaces the three-level dictionary.
   - The drop phase fell about 50 percent.
8. Keep the coplanar merge triangles in one packed array.
   - Cache one normal key and one material for each triangle.
   - Replace the per-call link dictionaries with stamped packed arrays.
   - The merge phase fell 25 to 31 percent.

Limits:

- The normal rebuild keeps its cost.
- A fused weld through a helper function was slower than the separate pass.
  The nine-argument call costs more than the saved temporary arrays.

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

## Limited dissolve

Smooth mode dissolves an interior vertex after the coplanar merge.
A seam vertex does not dissolve.
A seam edge is a boundary edge, a material edge, or a crease above 25 degrees.

A vertex dissolves when its link is one closed cycle, the link stays within 0.2 cells of a plane, and every new triangle keeps a shape quality above 0.022.
The new triangles must also keep the removed vertex normal within 8 degrees and the colour within 0.02 in linear space.
Every new diagonal must be a new mesh edge.

The pass retriangulates the link from a fan of the nearest three link vertices.
The fan with the lowest maximum normal spread wins, then the best shape.
A concave link falls back to an ear clip.
The pass checks every new triangle for an inward winding and a non-zero area.

The smooth rows use the same fixture and order as the flat rows.
Each value is the median of five measured passes of the smooth build on all occupied chunks.
The "before" column is the same build with the dissolve off.

| Scene | Merged triangles | Dissolved triangles | Change | Dissolve (us) | Build before (us) | Build after (us) | Change |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Material sphere | 2606 | 2480 | -4.8% | 13985 | 107368 | 122550 | +14.1% |
| Testing2 | 5116 | 4322 | -15.5% | 43886 | 201798 | 246342 | +22.1% |
| me | 7714 | 5282 | -31.5% | 125055 | 330949 | 464797 | +40.4% |

Removed vertices: 65 on the sphere, 397 on Testing2, and 1319 on me.
Each removed vertex removes exactly two triangles.

Normal and colour error at the removed position, per dissolve:

| Scene | Maximum (deg) | Mean (deg) | Maximum colour |
| --- | --- | --- | --- |
| Material sphere | 7.90 | 1.76 | 0.0 |
| Testing2 | 8.00 | 0.43 | 0.0 |
| me | 8.00 | 0.76 | 0.0 |

The colour error is zero because these models have no ambient occlusion.
The deterministic dissolve fixture measures a maximum of 7.90 degrees, a mean of 1.09 degrees, and a zero colour error on its final surface.

Limits:

- The limit is per dissolve. Two neighbours can add their errors at one position.
- A chunk mesh is open at the chunk face, so most vertices near a face are seam vertices and cannot dissolve.
  Testing2 reaches 12.7%, below the 15% aim.
- The dissolve is the largest new cost on smooth mode.
  The me model is above the 25% build guide.
  Its cost comes from about 6000 vertex attempts and 2400 triangulations in GDScript.
  The next step is to cut the per-attempt work, not to weaken a limit.

The flat path does not run the dissolve.
Every flat model hash and the snapshot hash stay equal.

## Low-poly export

The style-1 export welds the whole frame before the atlas UVs.
A smooth weld keys on the quantized world position and the material id, and it averages the normals and colours.
A flat weld adds the quantized normal to the key.
The export then runs one dissolve on the whole frame.
The per-chunk export build skips its dissolve, so a chunk face is not a seam.

| Scene | Chunks | Chunk vertices | Chunk triangles | Welded vertices | Export vertices | Export triangles | Triangle change |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Testing2 | 6 | 4164 | 5116 | 4010 | 3571 | 4238 | -17.2% |
| me | 4 | 5601 | 7714 | 5417 | 4078 | 5036 | -34.7% |
| Material sphere, radius 4 | 8 | 1540 | 1546 | 1366 | 1275 | 1364 | -11.8% |

The weld takes 2.9 ms on Testing2 and 3.9 ms on me.
The global dissolve takes 52.6 ms on Testing2 and 182.1 ms on me with link limit 16.
These values come from one measured frame.

The weld removes 3% to 4% of the vertices.
The chunk mesh is already welded inside a chunk, so only the chunk face duplicates and the cross-chunk normal difference remain.
The global dissolve removes 12 to 40 triangles less than the chunk passes on the sphere fixture.

The export dissolve link limit was raised from 9 to 16.
The table below shows the measured trade-off.
Limit 24 adds nothing.

| Limit | Testing2 | me | Dissolve (us), Testing2 / me |
| --- | --- | --- | --- |
| 9 | -16.6% | -32.9% | 46687 / 137053 |
| 12 | -17.0% | -34.5% | 50422 / 168500 |
| 16 | -17.2% | -34.7% | 52639 / 182137 |
| 24 | -17.2% | -34.6% | 53232 / 176161 |

A Blender-style 5 degree edge dissolve was measured and rejected.
The 5 degree region union has a ceiling of -21.3% on Testing2 and -43.2% on me, with no normal bound.
Within the 0.2 cell planarity bound it gives -16.2% and -31.9%, which is worse than the vertex dissolve.
The cause is the 30 to 90 degree bevel between the flat patches of a marching surface.
A 5 degree union cannot cross a bevel, and the large curved regions fail the planarity bound.

`tests/export_low_poly.gd` checks the duplicate count, the triangle drop, the closed and manifold surface, the materials, the UVs, the normals, and the flat facets.
It also pins the sphere fixture at 1275 vertices and 1364 triangles.

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


