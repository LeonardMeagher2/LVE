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

In progress:

- Dragon frame switching flashes in smooth mode.

Open:

- No coplanar merge in the low-poly path.
- No enclosed, empty, or sparse fast path in the low-poly path.
- Low-poly slice ownership can disagree with the slice range.
- Low-poly export uses the base block mesh.
- No ambient occlusion in the low-poly path.
- Cache lifetime test has a pre-existing isolation failure.

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

## LPM-3: Dragon frame switching

Status: open.

Symptom:

- Switching frames of `Dragon.lve` in smooth mode flashes the model.
- The model disappears, then chunks appear one by one.
- It looks like the renderer recalculates many chunk surfaces.

Facts:

- Dragon uses style 0, smooth normals, 7 frames.
- Each frame holds 74 to 76 chunks and about 51,326 cells.
- One playback frame change causes one `_rebuild`.
- `_rebuild` hides every chunk instance at once.
- A loaded document has independent chunk objects for each frame.
- The surface key uses chunk instance ids and revisions, not content.
- The style-0 cache holds 64 MB and 1024 entries.
- 7 frames * 75 chunks = 525 entries.
- 64 MB holds all frames only when a chunk costs 125 KiB or less.
- The LRU evicts the frame just left first.
- The 3 ms work slice installs about 3 chunks per frame.
- Each miss also builds a material and three textures.

Likely causes:

1. The blank frame comes from the bulk hide.
2. The pop-in comes from the work slice and the install cost.
3. Revisits rebuild when the 64 MB budget cannot hold all frames.

Fix options:

1. Install cache hits before the hide.
   - Hide only the chunks whose new key is a miss.
   - Keep the hard cut for a cold different frame.
   - This is the smallest safe fix.
2. Keep each old chunk until its replacement is installed.
   - This removes the blank on a cold frame.
   - It shows old geometry during the switch.
   - It needs a deliberate change to `tests/drawing_visibility.gd`.
3. Share unchanged chunks across loaded frames.
   - Hash the chunk grid and materials.
   - Reuse the surface when the hash matches.
4. Raise the cache budget or prefetch neighbouring frames.
   - Measure first. Do not guess the budget.

Next measurements:

1. Warm all seven frames. Print `_surface_cache_bytes` and `_surface_cache.size()` after each.
2. Revisit each frame. Print `profile_snapshot()` and `launch`.
3. Count identical chunks between frames.
4. Time `install_us`, `material_us`, and `cache_us`.

Tests:

- Add a warm revisit case: switch back, assert no launch and the exact displayed key.
- Keep the cold different-frame hide test.
- Add a cache budget test for seven frames.

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
- `tests/surface_cache_lifetime` fails when it runs alone.
  It also fails on `64e1418` without the current changes.
  The test assumes an empty cache and the style-0 limit.
  A loaded low-poly document sets the shared low-poly limit to 4096.

## Gaps ranked

| Rank | Gap | Impact | Effort | Risk |
| --- | --- | --- | --- | --- |
| 1 | Dragon frame switch blank and rebuild | High | S-M | Stale geometry |
| 2 | No coplanar merge in low-poly | Medium-high GPU | L | Watertightness |
| 3 | No enclosed, empty, or sparse fast path | Medium CPU | S | Low |
| 4 | No ambient occlusion | High visual | M | Normal and colour keys |
| 5 | Slice ownership ignores the slice range | Medium correctness | M | Holes at the cap |
| 6 | Low-poly export uses the block mesh | Medium | M | Export tests |
| 7 | Dead repair passes and unused flags | Low | S | Geometry change if wired |
| 8 | No LOD or draw call batching | Medium at scale | L | Popping |

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
