# Voxel data queries: research notes

Status: READY. Research only. This page changes no engine code, test, roadmap, or `MEMORY.md` entry.
It covers pure data queries for Leonard's Voxel Editor.
It compares current LVE code with public technical sources.
It gives bounded experiments.
It gives no performance guarantee.

## Scope

This page covers five data problems.

1. Voxel and chunk picking with an exact first hit.
2. Local read windows and halos.
3. Snapshots, copy-on-write, and derived caches.
4. Exact uniform sampling of occupied cells without a full gather.
5. Batch writes and storage.

The current core uses 16-cube chunks.
A frame holds a sparse map of chunks.
Each chunk holds a dense grid of material ids and a material table.
The engine is Godot with GDScript.
This page does not assume C++ SIMD or GPU results apply to GDScript.

## Terms

| Term | Meaning |
| --- | --- |
| Query | A read over a frozen frame snapshot. |
| Snapshot | A set of chunk references that a later write cannot change. |
| Derived cache | Data built from a snapshot, such as row masks, counts, or ranks. |
| Read window | The chunk set that a query can read. |
| Halo | The extra cells or chunks that a stencil reads. |
| First hit | The first occupied cell on the ray in traversal order. |
| Rank | The number of occupied cells before a position. |
| Select | The position of the n-th occupied cell. |

## Fact and inference marks

- **Fact (LVE)** means the statement comes from current LVE code or `MEMORY.md`.
- **Fact (source)** means the statement comes from a fetched public source.
- **Fact (source, secondary overview)** means a fetched summary restates a primary source. It is not the primary text.
- **Fact (logic)** means the statement follows from a definition or a proof.
- **Fact (arithmetic)** means the statement follows from a calculation.
- **Fact (GDScript)** means the statement comes from a checked Godot 4.7.2 behavior.
- **Fact (project guide)** means the statement comes from `../../tool-flows/composition.md`.
- **Inference** means this page reasons from facts. It is not measured.
- **Mixed** means the statement has a fact part and an inference part. The text names each part.
- **Unknown** means a measurement is necessary.

The track index uses three labels: Documented behavior, Inference, and Proposed experiment.
This file uses finer labels.
Map them as follows.

- Fact (LVE) is documented behavior.
- Fact (source) is a documented public source.
  It is not project behavior.
- Fact (GDScript) is documented engine behavior.
- Fact (logic) and Fact (arithmetic) are reasoning from definitions.
- Inference is an inference.
- Mixed names both parts.
- Policy is a project decision.
- Each experiment is a proposed experiment.
- No experiment here is a result.

## Current LVE data path

| API | Current behavior | Cost | Invalidation |
| --- | --- | --- | --- |
| `VoxelFrame.get_bounds()` | Returns the union AABB of occupied cells. | Cached. A miss scans each chunk. | Frame dirty flag. A chunk count check catches a raw add or remove. |
| `VoxelFrame.copy_chunks(locations)` | Returns a frame with the same chunk objects. Marks the selected source chunks shared. | Follows the requested locations. No grid copy. | A later source write copies the shared chunk. |
| `Chunk.occupancy_rows()` | Builds 256 row masks and counts. | One 4096-slot grid scan per occupancy revision. | Keyed by `occupancy_revision`. A material-only write keeps it. |
| `SprayOccupancyIndex.build_candidates()` | Counts occupied cells inside a sphere from row masks. Stores `[chunk, start, count]`. | One 256-row pass per non-empty chunk in the query box. | Rebuilds when a chunk row index is stale. |
| `Candidates.candidate(index)` | Binary-searches the chunk records. Then walks chunk rows and scans bits. | O(log chunks) plus up to 256 row checks plus 16 bit checks. | None. It reads the current rows. |
| `VoxelPicking.ray_voxel()` | Slab clip, then cell DDA with strict `<` ties. | One `frame.has` per visited cell. | Bounds cache only. |
| `VoxelFrame.set_cells()` | Buckets by chunk in one pass. Copies each changed chunk once. Compacts once per batch. | One pass over the change set plus one pass per changed chunk. | Clears the serialized record and the color cache. Sets the frame bounds dirty. |

**Fact (LVE):** There is no whole-frame occupancy index.
There is no per-column bound.
There is no per-chunk rank directory.
There is no query-local rank prefix.
There is no chunk-level DDA.

## 1. Picking and the first hit

### 1.1 DDA facts

The fetched Gyurgyik and Kellison overview of Amanatides and Woo describes a grid traversal with one cell step per axis crossing.
One step needs two floating point comparisons and one addition.
**Fact (source, secondary overview).**
The 1987 paper is the primary source for the algorithm.
This page did not parse the PDF.
It does not claim to verify the exact tie choice in the original paper.
**Source note, not a claim about the algorithm.**

LVE uses the same traversal order.
The step test is `t_max.x < t_max.y and t_max.x < t_max.z`, then `t_max.y < t_max.z`, then Z.
The strict `<` defines the tie rule.
Among tied minima, the later axis in X, Y, Z order wins.
If X and Y tie for the minimum, Y wins.
If all three tie, Z wins.
**Fact (LVE).**

The entry face uses a different code rule.
`_entry_face` keeps the first axis with `near > nearest`.
That rule difference does not by itself prove a defect.
**Fact (LVE).**

Concrete case: a ray from `(-1, -1, -1)` toward the origin along `(1, 1, 1)`, with one voxel at cell `(0, 0, 0)`.
The clipped entry cell is `(0, 0, 0)` on all axes.
The unclipped tie order is Z, then Y, then X.
The outside-AABB neighbors are empty.
The final step into the fully inside cell is X.
`_entry_face` also picks X.
The hit cell and the entry face agree.
**Fact (logic), from the current code path.**

A disagreement is an unverified test hypothesis.
It is not an observed defect.
A dedicated first-hit and entry test for internal edges and clip boundaries can confirm or reject it.
The oracle must separate the initial clip face from the first internal step.
Do not rewrite the tie order without a demonstrated counterexample.
**Policy for this project.**

`MEMORY.md` records the long-distance picking invariant: the bounds clip lets a far ray reach the content.
The composition guide records all 169 current scenes verified across the full attempt and targeted follow-ups.
Keep this behavior.
**Fact (LVE) and project guide.**

### 1.2 A bounding box is not a hit

An AABB contains empty space.
A ray can enter the box and hit no cell.
**Fact (logic).**

Safe uses of an AABB:

- Reject a ray that misses the box. No occupied cell can be hit.
- Clip a full-scene ray to the frame bounds. No occupied cell lies outside.
- Bound a chunk walk. Then a separate `occupied_count == 0` test skips an empty chunk.

Unsafe uses of an AABB:

- Return the box entry cell as a hit.
- Treat a chunk box as a chunk hit for selection.
- Clip a camera ray to a box around the cursor.
- Use a box overlap as proof that a cell is visible.

A near-cursor clip can miss an occluder.
An occupied cell between the camera and the window lies outside the window.
The query cannot see that cell.
A camera pick can then hit a farther cell or no cell.
**Fact (logic).**

`TerrainQueryContext.misses_bounds` avoids this error.
It rejects only when the ray misses the grown local bounds in both directions.
It never returns a hit.
Every read cell of its walk holds a point of the ray.
**Fact (LVE).**
The same reject is not valid for a camera pick over a local snapshot.
The local snapshot does not hold the occluders outside its bounds.

### 1.3 Empty-space skipping

An exact skip must prove that the skipped region holds no occupied cell.
Exact skips in current LVE data:

- A missing chunk.
- A chunk with `occupied_count == 0`.
- A row with a zero mask.
- A ray that misses the occupied bounds.

Inexact skips:

- A low occupancy ratio.
- A near-cursor box.
- A screen-space box that ignores depth.
- A chunk box that is not empty but is mostly empty.

OpenVDB and NanoVDB skip empty space with the tree hierarchy.
A hierarchical DDA steps over nodes that hold no active value.
**Fact (source).**
The default OpenVDB leaf is 8-cube.
Inner nodes hold a direct-access bit mask.
**Fact (source).**

LVE chunks are 16-cube.
A chunk-level DDA is the first possible skip level.
A 4-cube brick mask is a second level.
Each level costs memory and a build pass.
**Inference.**

A skip must preserve traversal order for first-hit parity.
A chunk skip preserves order because it only removes empty chunks.
A row-mask skip along one axis preserves order inside that row.
A nearest-hit BVH query does not necessarily preserve the Amanatides and Woo tie order.
It can return a different cell on an edge or corner ray.
**Inference.**

A chunk pick is the chunk of the first hit cell.
It is not the first chunk box that the ray enters.
A ray can enter a chunk box and hit nothing in that chunk.
**Fact (logic).**

Do not change the current `ray_voxel` kernel in this task.
Use a separate comparator to test a chunk-level variant.

### 1.4 Half cells and modulo

LVE cell `c` spans `[c - 0.5, c + 0.5]`.
The DDA works in cell space after a `+0.5` shift.
**Fact (LVE).**

A world point maps to a cell with `floori(p + 0.5)`.
Without the shift, the point maps to the neighbor at a boundary.
**Fact (LVE).**

The chunk origin is `VoxelFrame.chunk_position(cell) * CHUNK_SIZE`.
`chunk_position` uses `>> CHUNK_SHIFT`.
A right shift floors toward negative infinity.
**Fact (LVE).**

`% CHUNK_SIZE` is unsafe for a negative cell.
A remainder keeps the sign of the dividend in GDScript.
`-1 % 16` returns `-1`.
`& 15` returns `15` only because `CHUNK_SIZE` is 16 and a power of two.
Do not add a new hardcoded `& 15` or `* 16` world-coordinate path.
Use `VoxelFrame.chunk_position(cell)` and `cell - chunk.origin()` instead.
Use `Chunk.cell_slot(local_cell)` for the flat slot.
The local offset is non-negative and less than `CHUNK_SIZE`.
Keep world coordinates as signed integers.
Do not pack them into a fixed-width field.
**Fact (GDScript) and fact (LVE), checked on Godot 4.7.2.**

A negative literal shift operand fails to parse in GDScript 4.7.2.
Shift a variable instead.
**Fact (GDScript), checked on Godot 4.7.2.**

Even brush sizes have a half-cell center.
`VoxelBrushSize.first_offset`, `last_offset`, and `contains_sphere` encode the alignment.
`SprayOccupancyIndex.SphereSpans` encodes the exact row spans.
A new index must reuse these helpers.
A float recomputation can include or exclude a boundary row.
**Mixed: fact (LVE), inference for a new index.**

The occupancy row order is `row = y + CHUNK_SIZE * z`.
For the current 16-cube layout, that is `row = y + 16 * z`.
The local decode uses `CHUNK_SIZE` and `CHUNK_SHIFT`, not a new constant.
A rank prefix must use the same order to match the frozen reference cell order.
**Fact (LVE).**

### 1.5 Fixed-width packing

`MEMORY.md` records an eight-bit pack with a 64-cell bias.
It limited dense Spray to coordinates from -64 through 191.
**Fact (LVE).**

A sparse document has no fixed coordinate range.
A packed key with a fixed field width can wrap or collide.
A checked pack must reject an out-of-range value.
It must not wrap.
**Inference.**

Use `Vector3i` keys or local slot indices for a new index.
A packed key is a bounded decision.
It needs a range test and a test at extreme coordinates.

## 2. Local read windows and halos

### 2.1 Window contract

A local query is exact only when the window covers the full read set.
Add the stencil halo to the read set.
**Fact (logic).**

The chunk mesher reads one cell beyond its chunk.
A face change needs the face neighbor.
A corner change needs the diagonal neighbor.
`VoxelFrame._crosstalk_offsets` covers all 26 neighbors.
**Fact (LVE).**

A mesh update in Voxel Tools accesses the block and its 26 neighbors.
**Fact (source).**

A sphere query of radius `r` can touch up to `2 * ceil(r / 16) + 1` chunks per axis.
Use the read radius, including the stencil, for `r`.
The extra chunks cover a boundary that the query straddles, and the stencil.
This is a safe bound, not a tight one.
**Mixed: fact (arithmetic), inference from the geometry.**

A symmetry reflection extends the window.
`SprayOccupancyIndex.capture_chunks` covers the search sphere, the spot box, and every active reflection.
**Fact (LVE).**

### 2.2 Window cost

`copy_chunks` keeps the same chunk objects.
It does not copy a grid.
The first write to a chunk copies the grid and the material table.
**Fact (LVE).**

A read-only snapshot of N chunks costs N dictionary entries.
A write to every chunk costs about 16 KB of grid per chunk plus the material table.
**Fact (LVE) and `MEMORY.md`.**

A missing chunk is ignored by `copy_chunks`.
A query must treat a missing chunk as empty.
**Fact (LVE).**

OpenVDB uses a ValueAccessor for a spatially coherent read.
The accessor records the node path of the last read.
The next read walks up from the deepest recorded node.
The docs report about three times faster access for neighboring voxels.
**Fact (source).**
This is a C++ result.
It is not a GDScript guarantee.
**Inference.**
The docs recommend one accessor per read-only thread.
A shared accessor needs a lock and loses most of the gain.
**Fact (source).**

LVE has no path cache.
`SpraySampler.Occupancy` caches the grid of each chunk, so a repeated local read pays one dictionary lookup.
**Fact (LVE).**
A new query can keep the same per-job cache.
Do not add a global mutable accessor.
**Inference.**

### 2.3 Window errors

A near-cursor window is safe for a local surface query.
It is not safe for a camera pick.
The occluder can lie outside the window.
**Inference.**

A window smaller than the stencil returns a different normal or surface.
Test the window size against a full-frame reference.
**Inference.**

A selection mask that is not clipped to the window can make the result depend on cells outside the window.
Clip the mask or pass the full mask.
**Inference.**

## 3. Snapshots, copy-on-write, and derived caches

### 3.1 Current facts

`capture()` duplicates the chunk dictionary and marks every chunk shared.
`copy_chunks` marks only the selected source chunks shared.
`Chunk.copy()` copies the grid and the material table.
It shares `_occupancy_rows`.
**Fact (LVE).**

`occupancy_revision` moves only when a cell appears or disappears.
`voxel_revision` moves on every write.
`serialized_record` and `positions_by_color` clear on every write.
**Fact (LVE).**

A chunk sets `bounds_dirty` only when an erase lands on a bound.
The frame sets `_bounds_dirty` on every `set_cell` and `set_cells`.
`invalidate_bounds` repairs the bounds only.
It does not repair a raw grid write or copy-on-write metadata.
**Fact (LVE).**

### 3.2 Cache keys

| Cache depends on | Key | Survives a material repaint | Survives an occupancy change |
| --- | --- | --- | --- |
| Occupancy only | `occupancy_revision` | Yes | No |
| Materials or colors | `voxel_revision` | No | No |
| Frozen snapshot | Object identity | Yes | Not applicable |
| Live chunk identity | Do not use | No | No |

A copy-on-write copy changes the chunk object.
A live cache keyed by location must also check the object or the revision.
A cache keyed by object identity misses after a copy.
Use the revision number for a live cache.
**Inference from the copy path.**

A raw grid write cannot trust either revision.
Use the frame write methods.
**Fact (LVE).**

### 3.3 Immutable sharing

`OccupancyRows` is immutable after the build.
A copy-on-write copy shares it.
**Fact (LVE).**

A sparse row list can be a field of `OccupancyRows`.
The existing build, install, and share path then covers it.
**Mixed: fact (LVE) pattern, inference for a new field.**

A cache build that can span many chunks must check cancel every 4096 slots.
**Fact (LVE) for the multi-chunk builds.**

### 3.4 Invalidation rules

| Event | Occupancy rows | Material cache | Bounds |
| --- | --- | --- | --- |
| Material repaint | Keep | Drop | Frame dirty |
| Add or remove a cell | Drop | Drop | Frame dirty |
| Erase on a bound | Drop | Drop | Frame and chunk dirty |
| Chunk copy | Share | Share | Copy |
| Chunk drop | Drop | Drop | Frame dirty |
| Raw grid write | Invalid | Invalid | Invalid |

The E2 sparse row list can live in `OccupancyRows`.
The occupancy rows column then covers it.
The query-local prefix from E1 lives only for one sample.
It needs no invalidation.

A material-only repaint keeps the occupancy revision.
The row index survives with no rebuild.
**Fact (LVE).**

## 4. Exact uniform sampling without a full gather

### 4.1 Current method

The indexed Spray path counts occupied cells inside the search sphere from row masks.
It stores one record per chunk: the chunk, the start rank, and the count.
It draws distinct ranks with a lazy partial Fisher-Yates shuffle.
It maps a rank to a cell with a chunk binary search, a row walk, and a bit scan.
**Fact (LVE).**

This is uniform over the candidate set, given a uniform `randi_range`.
It is exact over the occupied cells inside the sphere, conditional on the selection.
It is not a constant-time query.
One candidate lookup can walk 256 rows.
**Fact (LVE).**

The work counters are `rows_scanned`, `rank_rows`, `rank_calls`, `index_builds`, `index_grid_reads`, and `index_build_slots`.
**Fact (LVE).**

### 4.2 Rank and select

A bitvector with a directory answers rank and select.
A two-level directory holds block counts and a popcount inside the block.
**Fact (logic), described by the rank and select sources.**

A 16-cube chunk has 256 row masks.
The row counts are the first directory level for a whole-chunk query.
**Inference from the current row index.**

The Spray query clips each row to a sphere span.
The clipped count is not the full row count.
A per-chunk full-row prefix is not exact for a sphere.
**Fact (logic).**

Build a query-local prefix from the clipped counts in the count pass.
Then select can binary-search the prefix and scan at most 16 bits.
**Inference from the current count pass.**

LVE already uses a 4-bit popcount table for 16-bit row masks.
A query-local prefix can reuse it.
**Fact (LVE).**

Memory is 1028 bytes per non-empty chunk in the query box for one sample.
It is not a per-chunk revision cache.
Discard it with the sample.
**Mixed: fact (arithmetic), inference for a query cache.**

A 16-bit form is 514 bytes.
LVE has no `PackedInt16Array`.
Use `PackedInt32Array` or a manual byte encoding.
**Fact (LVE).**

A 2025 C++ implementation reports 0.78 percent space overhead and worst-case constant query time.
That result is for a C++ bitvector on its test hardware.
It is not a GDScript guarantee.
**Mixed: fact (source), inference for LVE.**

### 4.3 Weighted chunks

A chunk weight can be its exact candidate count.
A chunk choice proportional to the count, then a uniform cell inside, is uniform over cells.
**Inference from the definition of weighted sampling.**

Sampling chunks without replacement needs a weighted algorithm, such as a weighted reservoir method.
The weight interpretation matters.
**Fact (source).**

Sampling chunks with replacement can repeat a chunk.
The sampler must then avoid duplicate cells.
That is extra work.
**Inference.**

A weighted chunk scheme changes the random draw order.
It changes which cells a seed picks, even when the distribution stays uniform.
That is a behavior change.
It is not an optimization.
**Inference.**

Decision rule: keep the frozen draw order unless the owner accepts a new reference.
**Policy for this project.**

### 4.4 Rejection sampling

Rejection picks a uniform cell in the sphere and tests occupancy.
It repeats until it finds an occupied cell.
It is exact when the trials are independent and uncapped.
**Inference from the method.**

The expected trial count is the sphere volume divided by the occupied count.
A model with one percent occupancy needs about 100 trials per cell.
A model with 0.1 percent occupancy needs about 1000.
**Fact (arithmetic).**

A trial costs a chunk lookup and a grid read.
It is not free.
**Inference.**

A fixed trial cap makes the result biased or incomplete.
A gather fallback makes the cost data-dependent.
**Inference.**

Rejection is a decision for sparse scenes.
It is not a free optimization.
**Policy for this project.**

### 4.5 Selection and arbitrary masks

A selection is a predicate.
The current code builds per-chunk masks in O(selection).
A row test is then one mask AND.
**Fact (LVE).**

A point occupancy or mask membership test can be O(1) average.
`VoxelFrame.has` does one chunk dictionary lookup and one grid slot read.
**Fact (LVE).**

A width-1 eligible lookup can be O(1) if a prebuilt index names a candidate.
**Inference.**

An arbitrary spatial region count, rank, or selection has no constant-time query without an adequate preindex.
A precomputed index for that predicate costs O(cells) to build.
It must be invalidated on mutation.
The output size can also make the work non-constant.
**Inference.**

NeuralVDB is a public example of the cost of an arbitrary model.
Online random access by inference is too slow for real time.
The recommended path decodes to a VDB first.
**Fact (source).**

Do not claim a constant-time query for an arbitrary spatial region count, rank, or selection.
Do not claim a constant-time intersection with the whole model.
A point occupancy or mask membership test can be O(1) average.
**Policy for this project.**

### 4.6 Random source and cell order

Copy the random generator state for a worker.
Commit the final state only when the result is adopted.
**Fact (LVE) and `MEMORY.md`.**

The current sampler draws one `randi_range` per spot.
A new sampler must keep the same number and order of draws for parity.
**Fact (LVE).**

A different chunk order changes the rank-to-cell map.
The distribution can stay uniform.
The seed output changes.
**Inference.**

Test parity with the frozen reference.
Compare the cell sets and the cell order.
Do not compare only the counts.
**Policy for this project.**

## 5. Batch writes and storage

### 5.1 Current write path

`set_cells` buckets the change set by chunk in one pass.
A last-chunk cache avoids most repeated dictionary lookups.
**Fact (LVE).**

It copies each changed chunk once.
A batch that covers a whole chunk with one material writes one grid fill and one table entry.
A partial uniform batch writes one appended row when the chunk already shares rows.
It compacts at most once per batch.
**Fact (LVE).**

It returns each changed chunk and the crosstalk neighbors of the changed faces.
**Fact (LVE).**

### 5.2 Source comparison

Voxel Tools states that per-voxel `set_voxel` pays block lookup, a map lock, a block lock, a channel decode, and a notification.
Bulk `do_box`, `do_sphere`, and `paste` amortize these costs.
**Fact (source).**

OpenVDB stores a tile value for a whole node.
A tile is one value for a block of voxels.
**Fact (source).**

`VoxelBuffer` has a uniform channel compression.
It stores one value for the whole channel.
**Fact (source).**

LVE's bulk fill is the same idea at chunk scale.
The sources support the design.
They do not prove a GDScript speedup.
**Inference.**

### 5.3 Rules for a new data tool

1. Build a change dictionary.
2. Call `set_cells` once per batch.
3. Keep the batch bounded.
4. Use the existing slice or cursor policy.
5. Do not change the return contract. The renderer needs the neighbors.
6. Clear derived caches on the same revision as the write.

A bulk fill must set the shared flag.
A later single-cell write must split the shared entry first.
**Fact (LVE) and `MEMORY.md`.**

## 6. Composition without shared policy

A query is a pure read.
It takes a frozen snapshot, a region, and a predicate.
It returns cells, counts, or ranks.
**Fact (LVE).**

A query does not own an edit handle, an undo action, a cancel flag, or a publication gate.
The tool owns those.
This follows the composition guide rules 1, 2, 4, 5, and 6.
**Fact (project guide).**

Two tools can call the same query with different regions and predicates.
The query returns data.
Each tool decides when to cancel, what to commit, and when to publish.
**Inference from the guide.**

A shared cache is data, not policy.
It is keyed by a revision or by a frozen snapshot identity.
It does not decide whether a result is stale.
**Inference.**

Do not add a query base class, a registry, an event bus, or a universal flag set.
A new query can be a static helper or a small `RefCounted` context.
`SprayOccupancyIndex` and `TerrainQueryContext` are current examples.
**Fact (LVE).**

A tool that needs a different completion rule keeps its own rule.
**Fact (project guide).**

This is why new tools compose queries without sharing policy.

## 7. Ranked experiments

Each experiment is bounded.
Each has a hypothesis, a consumer, a work counter, an oracle, and a memory or build tradeoff.
The rank orders experiments by expected value and risk.
It is not a finding score.
Do not change the active TerrainRoot kernel in any experiment.

### E1. Query-local clipped-count prefix

**Rank: 1.**

**Hypothesis:** The count pass already visits every row and computes the clipped count.
A skipped row has a clipped count of zero.
Store those counts in a 257-entry query-local prefix for each chunk record.
Then `candidate()` can binary-search the prefix and scan at most 16 bits.
It no longer walks up to 256 rows and recomputes spans for every candidate.

**Consumer:** `SprayOccupancyIndex.Candidates.candidate` and `_nth_chunk`.
The prefix is built in `_count_chunk` for the same sample.

**Work counter:** `rank_rows` from the current report.
Add `rank_prefix_steps` and `rank_bit_steps`.
Measure one, four, sixteen, and sixty-four spots.
Measure a sparse fixture and a dense fixture.

**Oracle:** The frozen `tests/spray_reference.gd` sampler.
Use the same seed.
Require the same cells in the same order.
Add a brute-force rank and select test over random 16-bit masks and spans.

**Memory and build:** 1028 bytes per non-empty chunk in the query box for one sample.
The count pass builds it, so the extra build is 256 additions and 256 stores per chunk.
It is not a per-chunk revision cache.
Do not share it across queries with different centers, sizes, or selections.
A full-row prefix is not exact for a sphere.

**Bound:** Stop if `rank_rows` is not the dominant counter.
Stop if the prefix memory for the query box is too high.

### E2. Sparse occupied-row list

**Rank: 2.**

**Hypothesis:** Most chunks in a wide search have few occupied rows.
A compact list of nonzero row indices lets the count and select skip the 256-row loop.
A chunk with eight occupied rows pays eight row checks, not 256.

**Consumer:** `SprayOccupancyIndex._count_chunk` and `_nth_chunk`.
The same list can serve `SpraySampler.footprints_scan`.

**Work counter:** `rows_scanned` from the current report.
Add `rows_nonzero` and `row_list_bytes`.
Measure a sparse model with one to eight occupied rows per chunk.
Measure a dense model as the control.

**Oracle:** The frozen Spray reference.
Add a count equality test between the list path and the full-row path.
Require the same total and the same ranked cells.

**Memory and build:** Up to 256 bytes per chunk, plus one count.
Store the list in `OccupancyRows` next to `masks` and `counts`.
The existing `occupancy_revision` check and COW sharing then apply.
No second cache is necessary.
Build it from the 256 row counts in one pass.
Store the list only when the nonzero count is below a threshold.
A dense chunk keeps the full row path.
This is a per-chunk decision, not a universal mode.

**Bound:** Measure chunks with 1, 8, 32, and 128 occupied rows.
Stop if the list build or the branch costs more than the saved row checks.

### E3. Local read-window halo contract

**Rank: 3.**

**Hypothesis:** A local query can differ from the full-frame result when its window misses part of the read set or the stencil halo.
A window that covers both returns the same result.
A window that is one chunk too small can change a surface or a normal.
A camera pick over a near-cursor window can miss an occluder.

**Consumer:** `TerrainPreview.fit_read_locations`, `TerrainPreview.map_read_locations`, and `SpraySampler.capture_chunks`.
This is a test-only experiment.
Do not change the current Terrain kernel.

**Work counter:** `bounds_queries`, `bounds_rejects`, and `grid_reads`.
Add `cells_outside_window`.
A valid window must report zero.

**Oracle:** The full-frame query on the same snapshot.
Compare the cell set, the count, and the order where the consumer depends on order.
Include a fixture with an occluder just outside the window.

**Memory and build:** The window holds chunk references, not grids.
A larger halo costs more references and more first-write copies.
A smaller halo that misses the stencil is faster and wrong.
Measure the chunk count of each window.

**Bound:** Test one, two, and three chunk halos around a known radius.
Stop when the result matches the full-frame oracle and the next smaller halo fails.

### E4. Chunk-level empty-space skip for picking

**Rank: 4.**

**Hypothesis:** A long ray in a sparse model crosses many empty chunks.
A chunk-level DDA with an `occupied_count == 0` test can skip them.
The cell DDA then runs only inside non-empty chunks.
The number of cell steps falls.

**Consumer:** A separate pick comparator.
Do not modify `VoxelPicking.ray_voxel` or the Terrain query path.
A future tool can adopt the comparator after the result is known.

**Work counter:** Add `cell_steps`, `chunk_steps`, and `has_calls`.
Compare with the current `ray_voxel` on the same rays.

**Oracle:** The current `ray_voxel` on the same frame.
Require the same hit cell and the same entry vector.
Include rays that hit a cell edge, a cell corner, a chunk corner, and a ray that starts inside a chunk.
Include a ray that enters an empty chunk box and hits nothing.

**Memory and build:** No new storage.
`occupied_count` already exists.
The chunk DDA adds one dictionary lookup per chunk.
A short ray inside one chunk pays that cost for no gain.

**Bound:** Test rays that cross 1, 4, 16, and 64 chunks.
Stop if the chunk DDA is slower for short rays and the long-ray gain is small.
Do not add a 4-cube brick mask before this result is known.

### E5. Batch write coalescing for query results

**Rank: 5.**

**Hypothesis:** A query that returns a change dictionary and writes once per batch cuts chunk copies, compactions, and bounds merges.
A per-cell write repeats those costs.

**Consumer:** A new data tool that writes query results.
Do not change the current Terrain or Spray write path.
Use a test harness with counters.

**Work counter:** Add `set_cells_calls`, `cells_written`, `chunk_copies`, `compactions`, and `bounds_merges`.
Measure a per-cell loop against one `set_cells` call on the same change set.

**Oracle:** The final frame content must match the per-cell reference.
The changed-chunk set must match the union of the per-cell chunks and their crosstalk neighbors.
The chunk revisions can differ, because `set_cell` and `set_cells` count writes differently.
A revision is a counter, not content.
Do not compare it for equality.
**Fact (LVE) for the counter rule.**

**Memory and build:** One change dictionary of N cells.
Peak memory follows the batch, not the whole model.
A larger batch delays the first visible write.
Use the existing slice or cursor policy.
Do not add a new completion rule.

**Bound:** Test 64, 512, 4096, and 32768 cells.
Stop if the batch peak memory or the first-write delay breaks the current budget.

## 8. Limits and non-goals

- This page reads no third-party source code.
  It uses documentation and paper text only.
- No other voxel editor architecture document was used.
  Voxel Tools is a voxel engine, not an editor.
  It is the closest public match.
- This page runs no benchmark.
  All source numbers are source numbers.
- A paper result is a conclusion for its data and hardware.
  It is not a guarantee for GDScript.
- The current TerrainRoot kernel is not touched.
- The current `ray_voxel` kernel is not touched.
- No engine, test, roadmap, or `MEMORY.md` change is part of this page.
- An AABB is not a first-hit proof.
- A near-cursor clip is not a camera pick.
- A fixed-width world key is not safe for sparse data.
- A modulo on a negative cell is not the same as a floor.
- A point occupancy or mask membership test can be O(1) average.
- An arbitrary spatial region count, rank, or selection has no invented constant-time query without an adequate preindex or a fixed output size.
- Do not claim a constant-time intersection with the whole model.
- There is no single universal tool framework.
- Approximate sampling is a product decision.
  It is not an optimization.

## 9. Sources

All listed pages were fetched on 2026-10-24.
The fetch tool cannot parse the 1987 PDF.
The 1987 paper is the primary source for the algorithm.
The fetched Gyurgyik and Kellison overview is secondary context for the initialization and step rules.
This page does not claim that the overview verifies the exact tie choice in the original paper.
A section name follows each URL.
The 1987 paper is not a current performance source.

1. Zylann, Voxel Tools for Godot, "Performance".
   https://voxel-tools.readthedocs.io/en/latest/performance
   Sections: Threads, Voxel iteration order, Access to voxels from different threads, Editing voxels efficiently.
   No publication date shown.
2. Zylann, Voxel Tools for Godot, API reference for `VoxelTool` and `VoxelBuffer`.
   https://voxel-tools.readthedocs.io/en/latest/api/VoxelTool/
   https://voxel-tools.readthedocs.io/en/latest/api/VoxelBuffer/
   Sections: `raycast`, `do_box`, `do_sphere`, `copy`, `paste`, `is_area_editable`, `Compression`, `copy_channel_from_area`.
   No publication date shown.
3. OpenVDB 13.1.0 documentation, "OpenVDB Overview".
   https://www.openvdb.org/documentation/doxygen/overview.html
   Sections: The Tree, Sparse Values and Voxels, Iterators, Value Accessor.
   No publication date shown.
4. Braithwaite, W. and Museth, K., "Accelerating OpenVDB on GPUs with NanoVDB".
   NVIDIA Technical Blog, 2020-08-20.
   https://developer.nvidia.com/blog/accelerating-openvdb-on-gpus-with-nanovdb
   Sections: Introduction to NanoVDB, Rendering, Collision detection, Benchmarks.
5. Museth, K., "NanoVDB: A GPU-Friendly and Portable VDB Data Structure For Real-Time Rendering And Simulation".
   ACM SIGGRAPH 2021 Talks, July 2021.
   DOI 10.1145/3450623.3464653.
   https://research.nvidia.com/labs/prl/publication/nanovdb
6. Zellmann, S., Jaros, M., Amstutz, J., and Wald, I., "GPU Volume Rendering with Hierarchical Compression Using VDB".
   arXiv:2504.04564v1, 2025-04-06.
   https://arxiv.org/html/2504.04564v1
   Sections: 2.2 Hierarchical Volume Representations, 2.3 VDB Grid Representation.
7. Amanatides, J. and Woo, A., "A Fast Voxel Traversal Algorithm for Ray Tracing".
   Eurographics '87, 1987.
   https://www.cse.yorku.ca/~amana/research/grid.pdf
   Plus Gyurgyik, C. and Kellison, A., "An Overview of the Fast Voxel Traversal Algorithm".
   Secondary context, not the original paper.
   https://github.com/cgyurgyik/fast-voxel-traversal-algorithm/blob/master/overview/FastVoxelTraversalOverview.md
   Sections: Initialization, Incremental traversal, 3-dimensional case.
8. Zhou, D., Andersen, D. G., and Kaminsky, M., "Space-Efficient, High-Performance Rank & Select Structures on Uncompressed Bit Sequences".
   SEA 2013, pages 151 to 163.
   https://www.cs.cmu.edu/~dga/papers/zhou-sea2013-abstract.html
   Plus Kurpicz, F., Rigi-Luperti, N., and Sanders, P., "Theory Meets Practice for Bit Vectors Supporting Rank and Select".
   arXiv:2509.17819, 2025-09-22.
   https://arxiv.org/abs/2509.17819
9. Efraimidis, P. S., "Weighted Random Sampling over Data Streams".
   arXiv:1012.0256v2, 2015-07-28. First version 2010-12-01.
   https://arxiv.org/abs/1012.0256
10. Chambi, S., Lemire, D., Kaser, O., and Godin, R., "Better bitmap performance with Roaring bitmaps".
    Software: Practice and Experience 46(5), pages 709 to 719, May 2016.
    arXiv:1402.6407v10.
    https://arxiv.org/abs/1402.6407

Source notes:

- The Voxel Tools pages describe a C++ module.
  Their thread and lock details do not apply to GDScript directly.
- The OpenVDB and NanoVDB pages describe C++ and GPU structures.
  Their memory layout does not apply to `PackedInt32Array` directly.
- The rank and select papers use bitvectors.
  LVE chunks are mutable between revisions.
- The Roaring paper covers compressed bitmap indexes.
  LVE already uses 16-bit row masks, which fit a 16-cube chunk.
  Roaring is context for sparse sets, not a required change.
- The weighted sampling paper covers stream algorithms.
  It does not define the LVE seed contract.

## 10. Open questions

1. Does a query-local clipped-count prefix beat the linear row walk on the real Spray fixtures?
   Measure E1 before any code change.
2. Does a sparse row list help the sparse fixtures without a dense regression?
   Measure E2 with a per-chunk threshold.
3. Which local windows are too small for the current Terrain stencils?
   Measure E3 on the fit and map regions.
4. Does a chunk-level DDA help long camera rays in sparse models?
   Measure E4 with a shadow comparator.
5. Does a single `set_cells` call keep the current first-write delay?
   Measure E5 with the existing slice budget.

No answer here is a performance claim.
Each answer needs a measured run in one process.
