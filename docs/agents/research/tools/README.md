# Tool research index

Date: 2026-10-24.

This page indexes the research reports.
It does not authorize behavior changes.
It does not replace the [tool flow maps](../../tool-flows/README.md).

The reports cite overlapping sources.
All external links were accessed on 2026-10-24.

## Evidence labels

| Label | Meaning | Required support |
| --- | --- | --- |
| Documented behavior | Current LVE code, a current flow map, a manual, or engine documentation shows it. | A source symbol, a flow-map section, or a cited source. |
| Inference | A reasoned conclusion from cited facts. It is not measured. | The facts and the reasoning. |
| Proposed experiment | A bounded test with a fixture and a pass condition. | No result yet. |

Do not read an inference as documented behavior.
Do not read a proposed experiment as a result.
Do not treat a source number from another engine as an LVE speed claim.

## Reports

| Report | Subject |
| --- | --- |
| [Editing UX](editing-ux.md) | Tool families, feedback, and product decisions. |
| [Terrain UX](terrain-ux.md) | Build, Flatten, Smooth, Grab, and cursor behavior. |
| [Voxel queries](voxel-queries.md) | Picking, read windows, snapshots, sampling, and batch writes. |
| [Rendering workers](rendering-workers.md) | Worker jobs, previews, surfaces, and cancellation. |
| [Performance plan](performance-plan.md) | Measured costs and remaining performance work. |
| [Marching benchmark](marching-surface-benchmark.md) | Low-poly geometry, constraints, decisions, and costs. |
| [Pose brush spec](pose-brush-spec.md) | Pose design research. Current behavior is in the deform flow map. |

## Preserved choices

- Terrain press and crossed-cell behavior stay deterministic.
- Build keeps a fixed stroke plane. There is no stationary dab.
- Accepted edits and accepted queues are never dropped.
- Grab keeps its absolute target.
- The Build cursor stays fixed and neutral in all states.
- The project keeps modular composition. There is no universal framework.
- Node data lifetime is an explicit policy.
- There is no SDF migration without a concrete measured need.

## Non-claims

- The research reports ran no engine test and no benchmark.
- Existing `MEMORY.md` measurements are not research benchmarks.
- No speed promise follows from C++, SIMD, GPU, OpenVDB, or the 2012 JavaScript meshing numbers.
- `material_override` blocks only the Mesh-stage precompile. The Surface stage can still compile.
- Undo covers the whole stroke. It is not per batch.
- A cell selection is not a face selection.
- A point membership test can be O(1). Arbitrary region count, rank, or selection needs an index.
- The source DDA corner case is not a proven bug.
- A Blender manual build date is not a content revision date.
- The cited manuals do not prove closed-source cursor internals.
