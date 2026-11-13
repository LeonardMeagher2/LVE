# Tool research synthesis

Date: 2026-10-24.

Status: all four research reports are READY.
This page is an index and synthesis.
It does not authorize behavior changes.
It does not replace the [tool flow maps](../../tool-flows/README.md).

The reports cite overlapping sources.
This index gives no unique source count.
All external links were accessed on 2026-10-24.
Version labels follow the reports.

## Evidence labels

| Label | Meaning | Required support |
| --- | --- | --- |
| Documented behavior | Current LVE code, a current flow map, a manual, or engine documentation shows it. | A source symbol, a flow-map section, or a cited source. |
| Inference | A reasoned conclusion from cited facts. It is not measured. | The facts and the reasoning. |
| Proposed experiment | A bounded test with a fixture and a pass condition. | No result yet. |

Do not read an inference as documented behavior.
Do not read a proposed experiment as a result.
Do not treat a source number from another engine as an LVE speed claim.

## Executive findings

1. A simple cursor overlay is normal practice.
   The cited Blender, ZBrush, and Nomad manuals show a radius or falloff display.
   A terrain-prediction mesh is not required to display brush extent. This is a design inference.
   The cited manuals do not prove closed-source cursor internals.
   The fixed white neutral color is an LVE user choice, not an industry rule.
   This supports the current Build leaf. It does not prove the latest cursor code is green.
   [Blender cursor manual](https://docs.blender.org/manual/en/latest/sculpt_paint/brush/cursor.html#cursor)

2. Make the units explicit.
   Spray has a spot count, a spot diameter, a search width, and implicit spacing.
   The current tooltips define them.
   A read-only summary can show them at a glance.
   [Blender stroke manual](https://docs.blender.org/manual/en/latest/sculpt_paint/brush/stroke.html#stroke)

3. Use local data and cached read views.
   `copy_chunks`, occupancy rows, and bounded local contexts match public sparse-data practice.
   A local window is exact only when it covers its full stencil halo.
   [Voxel Tools performance](https://voxel-tools.readthedocs.io/en/latest/performance)
   [OpenVDB overview](https://www.openvdb.org/documentation/doxygen/overview.html)

4. Measure the edit-to-render path end to end.
   Track pointer input, preview, first model surface, undo commit, and settle.
   Undo capture, worker contention, and GPU upload can dominate a worker win.
   [Godot thread-safe APIs](https://docs.godotengine.org/en/stable/tutorials/performance/thread_safe_apis.html)

5. Prefer small composable policies.
   Do not add a universal tool hierarchy, registry, or event bus.
   Current tools keep different capture, cancel, and undo rules.
   See the [composition guide](../../tool-flows/composition.md).

## Family map

| Family | Current policy | Intentional difference | Report |
| --- | --- | --- | --- |
| Brush, Eraser, Paint Brush | Press and drag queue accepted centers. One stroke action. Cursor preview stays separate from model install. | No universal spacing rule. Accepted centers are not replaced by a newer preview. | [Editing](editing-ux.md) |
| Line | Anchor, preview, then commit. Release, second click, or Enter commits. A switch drops the preview. | A line is not accepted until the user confirms it. | [Editing](editing-ux.md) |
| Fill | Six-face flood or global exact material match. Selection blocks traversal and matching. | Exact material match is current. No region preview is current policy. | [Editing](editing-ux.md) |
| Spray | Spot count, spot diameter, and search width are separate. Sampling is volumetric. Accepted intents keep order. | Volume versus Surface policy needs a decision. Speed counts spot centers per press or accepted brush-cell change, not per second. | [Editing](editing-ux.md) |
| Box, Lasso, Wand | Replace, add, subtract. Box and Lasso use a screen shape. Wand uses a seed and a material match. | No intersect mode. Wand ignores depth and empty-cell options. | [Editing](editing-ux.md) |
| Move, Rotate, Scale | Live preview. Release leaves the transform pending. One action. | Pending release is a project choice. Undo labels are generic today. | [Editing](editing-ux.md) |
| Copy, Cut, Paste | Copy has no model write. Cut has one action. Paste previews, then commits one action. | Paste is a placement mode with explicit commit and cancel. | [Editing](editing-ux.md) |
| Eyedropper, Plane, Symmetry | Eyedropper picks the full material. Plane and Symmetry change state only. | Full material pick is the default. Color-only pick is a product decision. | [Editing](editing-ux.md) |
| Build, Flatten, Smooth | Build uses a fixed stroke plane. A press applies one dab. Accepted crossings stay deterministic. | No stationary Terrain. No pressure or anchored stroke. The single white all-state Build ring is implemented. All 20 affected Terrain scenes passed. | [Terrain](terrain-ux.md) |
| Grab, Pose | Grab keeps an absolute target on one baseline. Pose bends the connected limb around a joint on one baseline. | Pose has no twist and no joint chain. Both commit one action on release. | [Terrain](terrain-ux.md) |

## Ranked experiments

1. Query-local clipped-count prefix.
   Hypothesis: the count pass can store a 257-entry prefix per chunk.
   Select can then binary-search the prefix and scan at most 16 bits.
   Current mechanism: `SprayOccupancyIndex.Candidates.candidate` walks rows.
   Measure `rank_rows`, prefix steps, and bit steps at 1, 4, 16, and 64 spots.
   Use the frozen Spray reference. Require the same cells in the same order.
   Risk: 1028 bytes per non-empty chunk for one sample. A full-row prefix is not exact for a sphere.
   Evidence: Voxel queries E1 and the rank/select paper.
   [Rank and select paper](https://arxiv.org/abs/2509.17819)

2. Sparse occupied-row list.
   Hypothesis: a wide sparse search has few occupied rows per chunk.
   A compact row list can skip the 256-row loop.
   Current mechanism: `OccupancyRows` already holds masks and counts.
   Measure `rows_scanned`, `rows_nonzero`, and row-list bytes.
   Use a per-chunk threshold. Keep the dense path as the control.
   Risk: list build and branch cost can exceed the saved row checks.
   Evidence: Voxel queries E2 and the current sparse chunk layout.

3. Five-moment profiling before priority or memory-cache changes.
   Hypothesis: the visible bottleneck is unknown.
   Current mechanism: main-thread reap averages about 1 ms.
   The finer atlas upload split is conditional. Worker atlas bake is 90 percent distinct.
   Low-priority chunk jobs are a deliberate reserve for accepted edit jobs.
   Promoting the viewport can starve edit jobs. The shared surface cache and global job limit complicate the test.
   Measure pointer, preview, first surface, undo, and settle. Add pipeline counters and slot wait.
   Evidence: Rendering experiments 1, 2, and 4.
   [Godot WorkerThreadPool](https://docs.godotengine.org/en/stable/classes/class_workerthreadpool.html)
   [NN/g response times](https://www.nngroup.com/articles/response-times-3-important-limits/)

4. Transform pending hint and specific undo labels.
   Hypothesis: pending release is unclear. A generic `Stroke` label is hard to find.
   Current mechanism: release leaves the transform pending. Enter, switch, or context change commits.
   Measure user error and recovery time. No edit behavior changes.
   Risk: tests and docs that expect `Stroke` must change.
   Evidence: Editing recommendations 2 and 3.

5. Compact Spray units readout.
   Hypothesis: numeric fields hide the count, diameter, and search width.
   Current mechanism: tooltips define the three values. Sampling does not change.
   Measure comprehension and setup time.
   Risk: the summary can crowd a narrow option bar.
   Evidence: Editing recommendation 4.

## Optional product decisions

These are decisions, not proven must-have roadmap items.

- Add selection intersect.
- Add fuzzy fill tolerance. The scope across all nine PBR channels needs a decision.
- Add Surface-only Spray. The volume versus Surface policy needs a decision.
- Add a time-based airbrush. This changes the deterministic cell rate.
- Add pressure or anchored strokes. Both need a new gesture and cancel rule.

## Preserved choices

- Terrain press and crossed-cell behavior stay deterministic.
- Build keeps a fixed stroke plane.
- No stationary Terrain dab.
- Accepted edits are never dropped.
- Accepted queues are not replaced by the latest preview.
- Grab keeps its absolute target.
- The Build cursor stays fixed and neutral in all states. The single white ring is implemented.
- The project keeps modular composition. No universal framework or blanket inheritance.
- Node data lifetime stays an explicit policy. It is not a framework.
- No SDF migration without a concrete measured need.

## Non-claims

- The research reports ran no engine test and no benchmark.
- Existing `MEMORY.md` measurements are not research benchmarks.
- The 169-scene verification is from the prior task. The latest Build cursor change has a separate 20-scene batch.
- The latest Build cursor change is implemented. All 20 affected Terrain scenes passed with 0 errors. The cursor source passed final read-only review. The research reports made no engine benchmark. Runtime validation is separate. See the [composition verification](../../tool-flows/composition.md#verification).
- The Build cursor request is not a Smooth tool change. The base input already skips some same-cell moves, so duplicate-endpoint overhead is only a conditional profiling idea, and A to B to A is a legitimate accepted backtrack that must be preserved.
- No speed promise follows from C++, SIMD, GPU, OpenVDB, or the 2012 JavaScript meshing numbers.
- `material_override` blocks only the Mesh-stage precompile. It is not proof of a Draw stutter. The Surface stage can still compile.
  [Godot pipeline compilations](https://docs.godotengine.org/en/stable/tutorials/performance/pipeline_compilations.html)
- Undo covers the whole stroke. It is not per batch.
- A cell selection is not a face selection. Surface, front-face, and occlusion rules differ.
- A point membership test can be O(1). Arbitrary region count, rank, or selection needs an index.
- The source DDA corner case is not a proven bug. Clipped entry and internal ties use different rules.
  [Amanatides and Woo paper](https://www.cse.yorku.ca/~amana/research/grid.pdf)
- A Blender manual build date is not a content revision date.
- The cited manuals do not prove closed-source cursor internals.

## Reports

- [Editing UX](editing-ux.md)
- [Terrain UX](terrain-ux.md)
- [Voxel queries](voxel-queries.md)
- [Rendering workers](rendering-workers.md)
