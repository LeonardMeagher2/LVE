# Low-poly mesher tracker

Date: 2026-11-26.

Branch: `design-k-mesher`.

PR: #84.

## Status

Done:

- The low-poly surface style renders with one material per triangle.
- The material bridge compares full material values.
- The mesher cost fell 2.8x to 15x on the tested scenes.
- The geometry snapshot test is in the suite.
- The benchmark reports phases and the editor viewport settle.

In progress:

- Comparison research between the low-poly path and the base greedy path.

Open:

- Atlas UVs and PBR materials in the low-poly path.
- Smooth normals in the low-poly path.
- Dragon frame switching flashes in smooth mode.

## Constraints

- Keep one material per triangle.
- Keep the strict Testing2 symmetry result.
- Keep the visual design of the current low-poly models.
- Do not hardcode a symmetry plane.
- Keep the old stable mesher available for comparison.

## LPM-1: Atlas UVs and PBR materials

Status: open.

The low-poly builder writes vertex colours only.
It does not write UVs or atlas bytes.
The renderer returns a null material when `atlas_size.x == 0`.
The low-poly path therefore loses metallic, roughness, emission, and transparency.

Plan:

1. Build a `VoxelAtlas` in `VoxelMarchingMeshBuilder`.
2. Add one 1x1 patch for each material that a final vertex uses.
3. Bake the atlas after the mesh pass.
4. Map each vertex material to the centre of its patch UV.
5. Write `Mesh.ARRAY_TEX_UV` and the `atlas_*` arrays.
6. Count the UV bytes in `geometry_bytes`.
7. Test a metal, a rough, an emissive, and a transparent material.
8. Verify that the renderer builds the atlas material and the values reach the mesh.

Acceptance:

- The atlas material uses the expected albedo, ORM, and emission texels.
- The geometry hash changes only by the added UVs.
- The existing marching suite stays green.

Risks:

- The atlas bake can run out of memory.
- A material patch can bleed without padding.
- The renderer must not fall back to vertex colours when the atlas exists.

## LPM-2: Smooth normals

Status: open.

The low-poly builder always rebuilds flat triangle normals.
It ignores `VoxelRenderer` smooth normal settings.

Plan:

1. Add `smooth_normals` and `ao_strength` inputs to the builder.
2. Reuse the base corner normal rule where it fits.
3. Define a smooth normal for edge points, cut points, and cell centres.
4. Keep the flat rule as the default.
5. Verify the strict symmetry result and the watertight tests in both modes.

Acceptance:

- Smooth mode produces shared normals across a smooth surface.
- Flat mode keeps the current snapshot.
- The renderer passes the document setting to the builder.

Risks:

- The low-poly vertices are not lattice corners.
- A smooth normal can change the visible silhouette or the seam pins.
- The material bridge rule must not depend on the normal.

## LPM-3: Dragon frame switching

Status: open.

Symptom:

- Switching frames of `Dragon.lve` in smooth mode flashes the model.
- The model disappears, then chunks appear one by one.
- It looks like the renderer recalculates many chunk surfaces.

Known facts:

- Dragon uses style 0, smooth normals, 7 frames.
- Each frame holds 74 to 76 chunks and about 51,326 cells.
- `VoxelRenderer._rebuild()` hides every chunk at once on a frame change.
- The surface key uses chunk instance ids and revisions, not frame content.
- The style-0 surface cache limit is 64 MB and 1024 entries.

Work:

1. Count the jobs launched by one frame switch.
2. Measure the cache bytes for all seven frames.
3. Check whether earlier frames are evicted, so a return rebuilds them.
4. Decide whether to keep the old frame visible until the first new surface is ready.
5. Add a test that proves the chosen behavior.

Acceptance:

- One switch launches only the surfaces that differ.
- A frame switch does not blank the whole model.
- Revisiting a frame reuses its surfaces when the cache holds them.

Risks:

- The old frame can show stale geometry during a switch.
- A content key can merge chunks that need different shading.
- The cache limit can trade memory for repeated work.

## LPM-4: Comparison research

Status: in progress.

The comparison covers:

- Base greedy features and optimizations.
- Low-poly features and optimizations.
- Shared renderer features.
- Missing features and their impact.

It also covers the Dragon frame-switch path.

The result will update the gap list in this tracker.

## Commands

Snapshot test:

```text
godot --headless --path . res://tests/marching_snapshot.test.tscn
```

Benchmark:

```text
godot --headless --path . res://tests/benchmarks/marching_surface.tscn
```

Marching suite:

```text
godot --path . -s res://addons/test_kit/run.gd -- marching_mesh marching_bridge marching_chunks marching_snapshot
```

## Decisions

- The benchmark hash covers position, normal, colour, and index.
- The hash does not cover UVs yet.
- The prototype model files stay untracked.
- The low-poly limits stay at 256 MB and 4096 entries.
