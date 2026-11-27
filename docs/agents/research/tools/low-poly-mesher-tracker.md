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

In progress:

- None.

Open:

- No coplanar merge in the low-poly path.
- No enclosed, empty, or sparse fast path in the low-poly path.
- Low-poly slice ownership can disagree with the slice range.
- Low-poly export uses the base block mesh.
- No ambient occlusion in the low-poly path.

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

Open:

- Ambient occlusion is still absent.

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
| 1 | No coplanar merge in low-poly | Medium-high GPU | L | Watertightness |
| 2 | No enclosed, empty, or sparse fast path | Medium CPU | S | Low |
| 3 | No ambient occlusion | High visual | M | Normal and colour keys |
| 4 | Slice ownership ignores the slice range | Medium correctness | M | Holes at the cap |
| 5 | Low-poly export uses the block mesh | Medium | M | Export tests |
| 6 | Dead repair passes and unused flags | Low | S | Geometry change if wired |
| 7 | No LOD or draw call batching | Medium at scale | L | Popping |

## Commands

Snapshot test:

```text
godot --headless --path . res://tests/marching_snapshot.test.tscn
```

Material and normal tests:

```text
godot --headless --path . res://tests/marching_material.test.tscn
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
