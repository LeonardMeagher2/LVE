# Low-poly mesher tracker

Date: 2026-11-27.

Branch: `design-k-mesher`.

PR: #84.

## Status

Done:

- The low-poly surface style renders with one material per triangle.
- The material bridge compares full material values.
- The mesher cost fell 2.8x to 14x on the tested scenes.
- The geometry snapshot test is in the suite.
- The benchmark reports phases and the editor viewport settle.
- The low-poly mesh writes atlas UVs and uses the PBR atlas material.
- The low-poly mesh supports smooth normals.
- The cache entry limit now counts empty surfaces.
- A frame switch keeps the old meshes visible until the replacements arrive.
- The surface key uses the chunk content, not the chunk instance.
- The cache lifetime test isolates the shared cache.
- An empty or fully enclosed chunk returns an empty surface before the field pass.
- The low-poly mesh bakes ambient occlusion into the vertex colors.
- A slice keeps its cap at a chunk row edge.
- The glTF export uses the marching mesh for the low-poly style.
- Flat and smooth modes merge coplanar triangle fans when the fan normals match.
- The build uses padded field writes and packed merge and drop passes.
- Smooth mode dissolves near-planar interior vertices after the merge.
- A regression test covers the low-poly chunk crosstalk rebuild.
- The style-1 export welds the whole frame and dissolves it once.

In progress:

- None.

Open:

- Dead repair passes and unused flags remain in the builder.
- No LOD or draw call batching.

## Constraints

- Keep one material per triangle.
- Keep the material coverage symmetry.
- Keep the visual design of the current low-poly models.
- Do not hardcode a symmetry plane.
- Keep the old stable mesher available for comparison.

## Done: atlas UVs and PBR materials

The builder writes one 1x1 `VoxelAtlas` patch for each material in the final mesh.
It writes the patch centre to each vertex.
It fills `atlas_albedo`, `atlas_orm`, and `atlas_emission`.
`VoxelRenderer._build_material` builds the atlas material from those arrays.

Evidence:

- `tests/marching_material.gd` checks albedo, metallic, roughness, and emission.
- The chunk material uses the blue channel for metal and the green channel for roughness.
- The emission energy stays at the atlas default of 1.0.

Limits:

- The atlas costs about 1 ms per benchmark scene.
- The geometry hash now covers UVs.
- The hash does not cover the atlas texels.

## Done: smooth normals

The renderer passes `State.document.smooth_normals` to the marching builder.
The builder averages the corrected face normals by area at each position.
It welds by position, normal, and material.
A zero average falls back to the face normal.
Flat mode keeps one normal per triangle.

Evidence:

- `tests/marching_material.gd` checks flat and smooth output.
- The renderer test checks that the document setting reaches the mesh.
- The smooth block uses fewer vertices than the flat block.

## Done: coplanar fan merge

Flat mode merges coplanar triangle fans after the normal rebuild and after ambient occlusion.
Smooth mode also merges a fan when every link vertex and the removed vertex have the same normal at 1/1024 precision.
The merge removes an interior vertex when its incident triangles share one normal, one material, and one plane, and the link is one convex loop.
It retriangulates the link and keeps every boundary vertex.
A smooth fan with mixed normals skips the merge.
A non-convex link skips the merge.

Triangle changes:

- Material sphere: 2606 to 2594.
- Testing2 flat: 6444 to 4792.
- Testing2 smooth: 6444 to 5116.
- Test3: 128 to 128.
- Testing flat: 952 to 536.
- me flat: 9464 to 5860.
- me smooth: 9464 to 7714.

Cost:

- The merge phase takes 12.6 ms on the sphere, 53.8 ms on Testing2 flat, and 50.8 ms on Testing2 smooth.
- The me merge phase takes 94.8 ms flat and 74.9 ms smooth.
- The total build is 6% slower on the sphere and 17% to 25% slower on the models.
- The rendered triangle count falls 26% to 44% on the flat models and 18% to 21% on the smooth models.

Constraints:

- The merge keeps one material per triangle.
- The material coverage stays symmetric.
- Triangle-level symmetry is not kept for coplanar faces.
- The geometry snapshot and the benchmark hashes change.

Evidence:

- `tests/marching_mesh.gd` keeps every surface closed.
- `tests/marching_bridge.gd` and `tests/marching_chunks.gd` keep the seams closed and unique.
- `tests/marching_snapshot.gd` and the benchmark use the new hashes.

## Done: ambient occlusion

The renderer passes the document occlusion strength to the marching builder.
The builder computes occlusion from the mesh edges after the weld.
For an edge with two triangles, it uses the outward face normals and the third vertex of each triangle to decide whether the edge is concave.
It skips flat and convex edges.
It scales the normal angle by the strength and darkens both edge endpoints.
The vertex color holds a linear gray factor.
The renderer multiplies the atlas albedo by that color.

Evidence:

- `tests/marching_material.gd` checks a dark crease, a bright convex cube, and a mirrored U-channel.
- The U-channel test compares every mirrored vertex and finds no difference.
- The blocky style keeps its occupancy corner AO.

Limit:

- The edge set is chunk-local.
  A symmetric model can differ at a few vertices where chunk ownership changes the triangles.
  Testing2 differs at 18 of 3224 mirrored vertices.
- `me.lve` also has asymmetric voxels, so its AO follows the model.

The occupancy corner AO of the blocky style cannot move to the marching mesh unchanged.
The marching mesh has face-center vertices and arbitrary bevels, so the four-corner cell rule has no unique corner there.
The edge rule is the crease-based equivalent.

## Done: empty and enclosed fast paths

The sample pass counts the occupied sample cells.
A chunk with no occupied sample cell returns an empty surface.
A chunk with a fully occupied sample returns an empty surface and sets `enclosed_culled`.
The empty path also clears the atlas and the geometry byte count.

A full rebuild requests only the occupied chunks.
The 26-neighbour requests built no triangle on Dragon, and they cost most of the initial settle.
The renderer also retires an absent chunk at once for every style.
The editor changed-chunk list is authoritative, so the renderer no longer expands it.

Evidence:

- `tests/marching_chunks.gd` checks an enclosed chunk and a shell chunk.
- Dragon dropped from 289 requests to 75.
- The warm cache dropped to 202 entries and 13.7 MB.

## Done: slice caps

`_sample` now filters the `present` map by the same chunk-row range as the renderer.
Before the change, a chunk outside the slice could own the cap cells of a rendered row.
The owner chunk was not built, so the cap and the side band were missing.

Evidence:

- `tests/marching_chunks.gd` checks a two-chunk solid column at slice 0, count 2.
- The lower cap stays at y -0.5 and the slab is closed.
- The unsliced hashes do not change.

## Done: low-poly glTF export

`ExportJob` takes the document mesh style.
For style 1 it builds each frame from `VoxelMarchingMeshBuilder`.
It offsets each chunk by its world origin.
It maps the per-chunk material values to one frame table.
It bakes one frame atlas and writes one patch-centre UV for each vertex.
It stores the ambient occlusion colors only when the strength is above zero.
The base style path is unchanged.

Evidence:

- `tests/export_low_poly.gd` checks the triangle count, the three atlas colors, two chunks, the occlusion colors, and a GLB round trip.
- The existing glTF tests stay green.

## Done: Dragon frame switching

Symptom:

- Switching frames of `Dragon.lve` in smooth mode flashed the model.
- The model disappeared, then chunks appeared one by one.

Cause:

- `VoxelRenderer._rebuild` hid every chunk at once.
- The surface key used chunk instance ids and revisions.
- Loaded frames hold independent chunk objects, so a revisit rebuilt every chunk.
- The 3 ms work slice spread the installs over several frames.

Fix:

- `_rebuild` no longer hides the old chunks.
- A chunk keeps its old mesh until its replacement arrives.
- A chunk that leaves the request set retires at once.
- `_request` installs cached surfaces during the rebuild.
- The surface key uses a content key for each chunk in the 3x3x3 neighbourhood.
- `Chunk.content_key` hashes the cells and the material table once per revision.
- The empty neighbourhood is one cache entry, not one entry per location.
- A rebuild requests only the occupied chunks.
- The renderer trusts the changed chunks from the editor and does not expand them.
- An absent chunk retires at once for every mesh style.
- A document replacement still hides the old document at once.
- An erase in style 0 retires the emptied chunk at once.
- `is_settled` now waits for a scheduled update.

Measurements (headless, one probe renderer plus the editor viewport):

- Dragon uses style 1, smooth normals, 7 frames.
- Each frame holds 74 to 76 chunks and about 51,400 cells.
- Frame 0 delay is 600 ms. The other delays are 80 to 200 ms.
- The initial settle takes about 1.26 s and keeps 68 meshes.
- The first frame visits take 179 to 869 ms. The visible mesh count stays 67 or 68.
- A warm frame visit takes 4 to 5 ms in one rebuild. It waits no process frame.
- The warm cache holds 202 entries and 13.7 MB.
- The old key scheme held 1988 entries and 36.3 MB for the same cycle.
- A full rebuild used 289 requests before the change. It now uses 75.
- The 214 removed requests built no triangle.
- 50 of 75 neighbourhoods match across all frames.
- Consecutive frames share 15 to 61 neighbourhoods.

Contract change:

- `tests/drawing_visibility` now expects the old mesh during a frame switch.
- It checks the exact restored mesh on a warm revisit.
- The previous contract hid the old frame at once.

Tests:

- `tests/drawing_visibility` covers a cold switch and a warm revisit.
- `tests/surface_cache_lifetime` saves and restores the shared cache.
- The history keys use a style-0 header so they do not change the cache limit.

## Done: performance pass

Date: 2026-11-27.

Branch: `design-k-mesher`.

The build time fell 1.18x to 1.34x on the benchmark scenes.
Every geometry hash stays equal.
The one-material-per-triangle rule and the symmetry behavior do not change.

Changes:

- The union field writes into a padded volume.
  The splat needs no bounds test.
- The cell scan reads each corner once for the occupancy bits and the cell material.
- The case loops, triangles, and face triangles are three static arrays.
- The quad field points are reused for the triangle emission.
- The edge site and label return through builder fields, not a new array.
- The quad fan ambiguity test runs only for a uniform quad.
- Both drop passes share one canonical position id array.
  The duplicate pass groups with one packed 63-bit key.
- The coplanar merge keeps the triangles in one packed array.
  It caches one normal key and one material for each triangle.
  It replaces the per-call link dictionaries with stamped packed arrays.

Evidence:

- The benchmark reports the before and after medians in
  [marching-surface-benchmark.md](marching-surface-benchmark.md).
- The snapshot hash and every model hash stay equal.
- The marching suite passes.

Limit:

- The normal rebuild keeps its cost.
- A fused weld call was slower than the separate pass.

## Done: export weld and global dissolve

The style-1 export did not weld across chunks.
`_build_marching_frame` now welds the whole frame before it builds the atlas UVs.

- With smooth normals, the key is the quantized world position and the material id.
  The normal and the colour average over the group, then the normal normalizes.
- With flat normals, the key is the quantized world position, the normal, and the material id.
- The position precision is 1/1024 cell.
- Two material ids never merge, because the atlas gives one patch-centre UV for each material.

The export then runs one dissolve on the whole frame.
The per-chunk build skips its dissolve, so a chunk face is no longer a seam.
The pass calls `VoxelMarchingMeshBuilder.dissolve_surface`.
The atlas UVs rebuild from the surviving material ids.
The frame material table stays.

Measurements (one smooth frame):

| Scene | Chunks | Chunk vertices | Chunk triangles | Welded vertices | Export vertices | Export triangles | Weld (us) | Dissolve (us) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Testing2 | 6 | 4164 | 5116 | 4010 | 3574 | 4244 | 2647 | 52490 |
| me | 4 | 5601 | 7714 | 5417 | 4011 | 4902 | 3712 | 156491 |
| Material sphere, radius 4 | 8 | 1540 | 1546 | 1366 | 1253 | 1320 | 961 | 14645 |

Triangle change: -17.0% on Testing2, -36.5% on me, and -14.6% on the sphere.
The per-chunk dissolve reached -34.9% on me, so the global pass removes 2% more.
The weld removes 3% to 4% of the vertices.
The export job takes 283 ms on Testing2 and 524 ms on me for one smooth frame.

Evidence:

- `tests/export_low_poly.gd` checks that no two vertices share a position and a material.
- It checks the triangle drop, the closed and manifold surface, the four materials, the unit normals, and the flat facets.
- Without the weld, the duplicate check fails.
- The flat export keeps one normal for each triangle.

Limit:

- The export only. The runtime chunked renderer still welds inside a chunk and dissolves each chunk.

## Done: low-poly chunk crosstalk test

The marching mesher samples the 3x3x3 chunk neighbourhood.
A boundary cell edit must rebuild the adjacent chunk.
The renderer adds `VoxelFrame.crosstalk_chunks(cell_position)` for each changed cell.
The style-1 surface key also covers the 26 neighbour chunks.

`tests/marching_mesh.gd` checks the rebuild.
It paints a voxel on each side of a chunk boundary.
It then paints the boundary cell and emits `cells_changed`.
It checks that the adjacent chunk rebuild changed its geometry and that the model stays closed.

The test fails when the crosstalk loop is removed.

## Done: limited dissolve

Date: 2026-11-27.

Smooth mode dissolves an interior vertex when its link is almost planar.
The pass runs after the coplanar merge.
It runs only when `smooth_normals` and `merge_coplanar` are true.

A vertex is a seam vertex when it touches:
- A boundary edge with one adjacent triangle.
- An edge with a face normal angle above 25 degrees.
- A position that two vertices of different materials share.

The material rule covers the UV case.
The current atlas gives every vertex of a material the same patch-centre UV.
A material change therefore also changes the UV.

A vertex dissolves when:
- Every incident triangle has the vertex material.
- The link is one closed cycle and every link edge is a mesh edge.
- The link stays within 0.2 cells of the plane through the vertex.
- Every new triangle keeps a shape quality above 0.022.
- The new triangles keep the removed vertex normal within 8 degrees.
- The new triangles keep the removed vertex colour within 0.02 in linear space.
- Every new diagonal is not an existing mesh edge.

The normal and colour checks use the barycentric weights of the removed position.
The weights come from the plane of each new triangle.
A link-plane projection is not enough, because a tilted triangle then hides its error.

The retriangulation tries a fan from the three link vertices nearest the removed vertex.
The fan with the lowest maximum normal spread wins.
A tie takes the best smallest triangle shape.
When no fan is valid, an ear clip triangulates the link in its best-fit plane.
The ear score is the normal spread, then the triangle shape.
A rejected ear is retried with the next best ear.
Every triangle is checked for its inward winding and its area after the choice.

Triangle changes:

- Material sphere smooth: 2606 to 2438.
- Testing2 smooth: 5116 to 4298.
- me smooth: 7714 to 5020.

Cost:

- The dissolve phase takes 17.5 ms on the sphere, 50.5 ms on Testing2, and 149.0 ms on me.
- The smooth build is 16.8% slower on the sphere, 24.8% on Testing2, and 46.6% on me.
- The medians use five measured passes of the smooth build on all occupied chunks.

Errors:

- The normal error at each removed position is at most 8.0 degrees, equal to the limit.
- The mean error is 0.5 degrees on Testing2, 0.8 on me, and 2.3 on the sphere.
- The colour error is zero on these models, because their occlusion strength is zero.

Hardening:

- The pass detects a concave link in its best-fit plane before it tries a fan.
  A fan cannot cover a notch, so a concave link goes straight to the ear clip.
- An accepted dissolve adds its new diagonals to the seam edge set.
  A later dissolve therefore rejects a diagonal that is already a mesh edge.
- The coverage test uses the link-plane weights.
  The normal and colour error uses the barycentric weights of each triangle plane.
  A tilted triangle then cannot hide its error.

Constraints:

- Flat mode does not run the pass, so every flat hash and the snapshot stay equal.
- The pass keeps one material per triangle.
- Every seam edge and every seam vertex stays in the dissolved surface.
- The dissolved surface stays closed and manifold.

Evidence:

- `tests/marching_dissolve.gd` checks the topology, the seams, the material area, and the normal tolerance.
- `tests/marching_dissolve.gd` also checks a concave link polygon and the grown seam edge set.
- The flat benchmark hashes and the snapshot hash do not change.
- Front screenshots of `me.lve` and `Dragon.lve` show no crack, band, or seam.
  The largest shading change is a soft gradient of about 6% on one head region.

Limit:

- A chunk mesh is open at its own chunk face.
  A vertex on that face carries a boundary edge, so it is a seam vertex.
  Most vertices near a chunk face cannot dissolve.
  Testing2 reaches 16.0% after the concave link fix.
- Two dissolves next to each other can add their normal errors.
  The final surface can differ by more than 8 degrees at a position that a later dissolve retriangulated.
  The limit is therefore per dissolve and not on the final surface.
- The ear clip costs more than a fan, so me now takes 149 ms in the dissolve phase.

## LPM-4: Comparison research

Status: done.

Key findings:

- The viewport style 0 path uses the atlas group and planar region path, not `_greedy_dense`.
  `texture_materials` defaults to true, and the renderer never clears it.
- The base path reduces work:
  - coplanar/planar merge,
  - enclosed chunk cull,
  - sparse row and occupied plane skips,
  - AO,
  - smooth normals,
  - atlas/PBR,
  - export.
- The low-poly path reduces per-cell work:
  - case tables,
  - field splat,
  - shared quad data,
  - packed components,
  - weld and duplicate cleanup.
- There is no fair base vs low-poly measurement on one fixture.
  The base mixed fixture is a translucent checkerboard worst case.
- The low-poly path has dead repair passes.
  `_fill_boundary_ears`, `_pinch_material_seams`, `_collapse_near_hole_vertices`, and `_flip_diagonals` are not called.
- `hard_boundaries` and `per_material` are not used by the renderer.
- The surface cache entry limit counted only non-empty surfaces.
  The entry limit now uses the dictionary size.
- `tests/surface_cache_lifetime` failed when it ran alone.
  It also failed on `64e1418` without the current changes.
  The test used synthetic history keys whose first value set the low-poly style bit.
  That bit changed the shared cache limit to 4096 entries.
  The test now uses a style-0 header and isolates the shared cache.

## Gaps ranked

| Rank | Gap | Impact | Effort | Risk |
| --- | --- | --- | --- | --- |
| 1 | Dead repair passes and unused flags | Low | S | Geometry change if wired |
| 2 | No LOD or draw call batching | Medium at scale | L | Popping |

The coplanar fan merge is done for flat mode and for smooth fans with one shared normal.
A smooth fan with mixed normals keeps the unmerged mesh, because the wider fan changes the interpolation.
The limited dissolve now handles most of those mixed-normal fans.
A vertex that fails the planar, shape, normal, or colour limit keeps the merged mesh.
The strict Testing2 triangle symmetry is no longer required for coplanar faces.
The material coverage stays symmetric.

## Commands

Snapshot test:

```text
godot --headless --path . res://tests/marching_snapshot.test.tscn
```

Material and normal tests:

```text
godot --headless --path . res://tests/marching_material.test.tscn
```

Low-poly export test:

```text
godot --path . -s res://addons/test_kit/run.gd -- export_low_poly
```

Benchmark:

```text
godot --headless --path . res://tests/benchmarks/marching_surface.tscn
```

Marching suite:

```text
godot --path . -s res://addons/test_kit/run.gd -- marching_mesh marching_bridge marching_chunks marching_material marching_snapshot marching_dissolve
```

## Decisions

- The benchmark hash covers position, normal, colour, UV, and index.
- The hash does not cover atlas texel values.
- Smooth normals use area-weighted face normals at each position.
- The atlas uses one 1x1 patch per material with the patch centre as the UV.
- The prototype model files stay untracked.
- The style-0 cache keeps 64 MB and 1024 entries.
- The low-poly cache keeps 256 MB and 4096 entries.
- A frame switch keeps the old chunk mesh until the replacement is ready.
- A document replacement hides the old document at once.
- The surface key hashes the chunk content, not the chunk instance.
- The content key hashes the dense cell grid and the material table.
- Ambient occlusion uses the corrected face normal and a 3-sample outside layer.
- The low-poly export uses one frame atlas and one patch-centre UV per vertex.
- A full rebuild requests only the occupied chunks.
- A slice filters the present neighbours by the slice row range.
- Flat mode merges coplanar fans after the normals and ambient occlusion.
- Smooth mode merges only a fan whose vertex normals all match.
- Coplanar merging may change triangle-level symmetry. Material coverage stays symmetric.
- The limited dissolve runs after the coplanar merge in smooth mode.
- A seam vertex does not dissolve. A seam edge is a boundary edge, a material edge, or a crease above 25 degrees.
- The dissolve keeps the normal at the removed position within 8 degrees and the colour within 0.02.
- The dissolve picks the fan with the lowest maximum normal spread, then the best shape, then an ear clip.
- The dissolve cost is reported in its own benchmark phase.
- The smooth dissolve adds 24% to the Testing2 build and 36% to the me build.

