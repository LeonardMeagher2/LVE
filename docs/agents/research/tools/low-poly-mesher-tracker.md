# Low-poly mesher tracker

Date: 2026-11-26.

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

In progress:

- None.

Open:

- No coplanar merge in the low-poly path.
- Dead repair passes and unused flags remain in the builder.
- No LOD or draw call batching.

## Constraints

- Keep one material per triangle.
- Keep the strict Testing2 symmetry result.
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
| 1 | No coplanar merge in low-poly | Medium-high GPU | L | Watertightness and symmetry |
| 2 | Dead repair passes and unused flags | Low | S | Geometry change if wired |
| 3 | No LOD or draw call batching | Medium at scale | L | Popping |

The coplanar study recommends a local fan merge after the weld, in flat mode only.
Group by one material ID, one normal, and one plane.
Replace an interior fan with a triangulation of its link.
Keep every boundary vertex.
Skip smooth mode, concave or non-manifold links, and mixed materials.
The strict Testing2 triangle symmetry is the remaining risk.
Measure before you accept a general merge.

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
godot --path . -s res://addons/test_kit/run.gd -- marching_mesh marching_bridge marching_chunks marching_material marching_snapshot
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
