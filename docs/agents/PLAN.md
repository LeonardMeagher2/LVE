# Over-engineering audit, product lens

Original audit on 2026-10-18 from a code-cleanup lens. Re-analyzed on 2026-10-19
from the product lens. The product is a voxel animation editor: per-voxel PBR
materials, low-poly mesh export to glTF and sprite sheets, tag-based animation,
and an Aseprite-like workflow. Complexity is a defect only when it does not buy
product value.

## Verdicts that changed

### The planar pipeline and the greedy mesh are the product

The 630-line `VoxelPlanarRegion` and the whole mesh pipeline are not
over-engineering. They are the export promise: a 16 by 16 plate exports as twelve
triangles, a chunk as a clean low-poly mesh, and material seams stay crack-free.
A voxel tool that exports one quad per voxel is not competitive. The frozen
527-case differential and the `failed_greed` invariants protect the thing users
buy.

Revised stance: do not cut the Lawson flips as a cleanup item. The triangle
quality of concave merged plates is visible in the exported mesh. The
performance work in TASKS.md is product work. Revisit the maximal-rectangle
rewrite only if export quality or export speed becomes a user complaint.

### The `.lve` format is a product surface, and `.tres` is not obviously safer

The original finding treated the hand-rolled container as cleanup. From the
product lens it does three jobs the engine does not:

- The PNG embedding makes a document shareable as a file with a visible preview.
- The CRC catches corrupt files before they damage a session.
- The pre-scan limits what `bytes_to_var` can do on a user-supplied file.

The counter-argument that `.tres` would be safer does not hold for untrusted
input: a `.res` file can reference scripts and resources, so loading an untrusted
`.tres` is a wider attack surface than the constrained binary container. The
roadmap adds more untrusted input (Aseprite import, OBJ comparison, image
loading), which strengthens the custom container, not weakens it.

Revised stance: keep the format. The 57-line `_variant_end` pre-scan is the ugly
part, but it is doing security work. If it is ever touched, the goal is a
smaller, table-driven decoder, not deletion. Do not plan a `.tres` migration.
The PNG path is a product feature; consider extending it, not shrinking it.

### The per-voxel PBR material system is the differentiator

Per-voxel materials with albedo, metallic, roughness, and emission, exported to
glTF with correct ORM channels and emissive strength, is what separates this
tool from a generic voxel builder. The atlas exists to make that material model
cheap to render and export.

Revised stance: the fixed-grid, no-gutter atlas simplification is still valid,
because it changes no product behavior. But the further step, one
`StandardMaterial3D` per material with no texture, is a product downgrade: it
changes the GLB layout, multiplies material counts, and weakens the export
story. Take the fixed grid, stop there.

### Undo is product trust

A voxel tool that loses a stroke to a bad undo is a tool users abandon. The
double full-chunk snapshots are the simplest design that restores exactly,
including neighbor-face effects. Delta undo is a memory optimization, not a
product fix, and it carries the risk of drift from the live edit.

Revised stance: keep snapshots. Revisit only if history memory becomes a
measured complaint on large models. The product cost of a wrong undo is far
higher than the memory cost of the snapshots.

### The transform gesture math is tool feel

`RotateTool`, `ScaleTool`, `MoveTool`, and `RotSprite` implement snap, magnet,
cardinal-angle exactness, and nearest-neighbor preview sampling. MEMORY.md shows
these were tuned against observed jumps and boundary hits. That is tool feel,
the same category as brush stroke continuity. There is no engine equivalent, and
the roadmap will build more tools (extrude) on the same base.

Revised stance: keep. The only cleanup is the triplicated ray-plane solve, which
is invisible plumbing.

## What actually buys product value

The product lens ranks findings by what the user or the roadmap gets.

### 1. The export path is the storefront. Protect it, then speed it up.

The glTF export already delegates to the engine `GLTFDocument` and
`AnimationPlayer`. The remaining hand-rolled parts (weld, name mangling,
rest-scale markers) are frozen by tests and are workarounds for documented
engine quirks. None of them is over-engineering.

The product opportunity is not simplification; it is export performance and
export trust. The planar cleanup and greedy scan are the measured export cost
(TASKS.md has open tasks on both). Every millisecond of export time on a large
model is a user-facing cost. The weld question, whether the epsilon path ever
fires given the exact vertex dedup upstream, is worth a measured check because
it sits in the export hot path and may be dead weight in the product's most
visible moment.

### 2. Drawing responsiveness is the product on the roadmap.

TASKS.md keeps "Keep drawing responsive on large models" active with measured
gaps. The `VoxelRenderer` per-renderer signature repetition (four renderers
each recompute the same keys) and the `VoxelPreview` parallel cache are both
in this path. A shared surface-key coordinator and a single material factory
are product work: they reduce the duplicate main-thread and worker-thread cost
on every stroke in every viewport.

Revised stance: promote the B3 preview collapse and the shared-signature
change from "cleanup" to "drawing-latency work." Land them under the active
TASKS.md task, measure with `draw_latency`, and do not take a gain the
measurements do not confirm.

### 3. File format work is import-ecosystem work.

The roadmap adds Aseprite import and image loading. Every untrusted file that
enters the tool needs the same containment the `.lve` pre-scan provides. The
product move is to make the safe-loading path a shared, tested component that
the Aseprite importer reuses, not to replace it with `.tres`. That is the only
version of the A1 finding that survives the product lens.

### 4. The `State.gd` split is roadmap enabler, not a defect fix.

The 18-signal bus and the god-object are invisible to the user. The product
value of splitting them is lower per-feature cost for the roadmap items:
Aseprite import needs a clean document-load path, onion skinning needs
frame-change signals, extrude needs a clean tool base. The `cells_changed` /
`chunks_changed` merge is safe, small, and removes a real duplication.

Revised stance: do the signal merge now. Do the larger split when a roadmap
item needs the seam, not before.

### 5. UI cleanup is cheap polish, not strategy.

The `ValueButton` SpinBox core, the palette picker `_input` hit-test, the dead
swatch redraws, the status-bar poll, and the scale poll are all real, but none
changes what the user gets. They are the cheapest items on the list.

Revised stance: batch them as one small polish pass. The `ValueButton`
`SpinBox` subclass is the largest and the only one with a tested contract, so
keep it in the batch but verify `material_controls` after. Do not schedule the
UI pass as a product milestone.

## Revised priority list

Ordered by product value, not by lines removed.

1. Protect and speed the export path. Measure the weld; keep the pipeline.
   (TASKS.md performance tasks.)
2. Land the drawing-latency items under the active task: shared surface keys,
   single material factory, preview cache simplification. Measure with
   `draw_latency`.
3. Make safe file loading a shared, tested component for the Aseprite import.
   Keep the `.lve` container and the PNG preview.
4. Merge `cells_changed` and `chunks_changed`. Defer the larger `State` split
   until a roadmap item needs it.
5. One small UI polish batch: signal merge already done above, status-bar
   Timer, swatch redraws, picker hit-test, scale poll, undo helper dedup,
   ray-plane dedup. Verify affected tests.
6. Fixed-grid atlas without gutters. Verify `export_atlas` and viewport texels.
   Do not take the per-material-material route.
7. Lawson flips and delta undo: parked. Revisit only on a measured user-facing
   problem.

## What the product lens removes from the original plan

- The `.tres` migration is dropped. The security argument reversed.
- The Lawson flip cut is dropped from the active list. It is visible in the
  exported mesh.
- The per-material `StandardMaterial3D` route is dropped. It weakens the export
  story.
- Delta undo is parked. Undo correctness outranks history memory.
- The planar rewrite is parked. It is the product's core differentiator and is
  already under measured performance work.
