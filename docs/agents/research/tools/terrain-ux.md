# Terrain cursor and brush expectations

Status: READY. Research only.

Date: 2026-10-24.

Project: Leonard's Voxel Editor. Godot 4.7.2. GDScript.

Baseline: current working tree on 2026-10-24. The tree is not a commit.

Access date for every web source: 2026-10-24.

This page records external expectations for Build, Flatten, Smooth, Grab, and the Build cursor.
It does not change runtime code, tests, the roadmap, NOTES, or the existing flow maps.
It does not recommend an SDF migration.
It makes no speed claim.

Read [the Terrain flow map](../../tool-flows/terrain.md) for current behavior.
Read [the tool research index](README.md) for the evidence rules.

## Scope

This page answers five questions.

1. Which results do users expect from Build, Flatten, Smooth, and Grab?
2. Which cursor behavior is normal while idle, held, and draining accepted work?
3. Which cursor behavior is proven by primary manuals, not inferred?
4. Which choices are genuine UX decisions with no industry agreement?
5. Which bounded changes fit the current occupied-cell model?

This page does not own the cursor implementation.
The cursor work is in progress under another owner.
The project choice is already recorded in [the research index](README.md#preserved-project-choices).

## Evidence labels

| Label | Meaning | Required support |
| --- | --- | --- |
| Documented | A cited manual or the current working tree states the behavior. | A source section or a code symbol. |
| Inference | A conclusion from cited facts. | The facts and the reasoning. |
| Hypothesis | An unmeasured expectation. | A test that can reject it. |
| Proposed experiment | A test with a fixture and a pass condition. | No result yet. |

Do not read an inference as documented behavior.
Do not read a hypothesis as a measured result.

## Terms

- **Crossing**: one accepted move from one anchor cell to the next. A stroke A to B to A has two crossings. One dab per crossing does not mean one dab per unique world cell per stroke.
- **Pose**: the cursor transform. Pose cost is not total input cost.
- **Duplicate accepted endpoint**: a new accepted endpoint equal to an earlier queued endpoint, such as A to B to A.

## The edit models differ

| Model | What the tool changes | What the surface is | Examples |
| --- | --- | --- | --- |
| Mesh displacement | Vertex positions. | The edited mesh. | Blender, ZBrush, Nomad. |
| Volumetric voxel | A volume. Tools fill or remove volume. | An extracted surface. | 3D-Coat Voxel mode. |
| Occupied cells | A cell is empty or occupied. Each cell carries a material. | A mesh of the cell set. | Leonard's Voxel Editor. |

The difference controls which expectations transfer.

- A mesh brush moves vertices. A cell brush adds or removes whole cells.
- A mesh falloff is a vertex weight. A cell falloff is a per-cell weight.
- A mesh Flatten projects vertices to a plane. A cell Flatten cuts or fills columns.
- A volumetric tool can blend a smooth surface. A cell tool produces cell-sized steps.
- A mesh or SDF tool has no per-cell material identity. Material preservation is an LVE rule.

Documented facts from the voxel side:

- 3D-Coat states that voxel tools operate over volume, not surface deformation. [P10a]
- 3D-Coat states that voxels are volume building and filling. [P10a]
- 3D-Coat states that voxels do not provide the surface normals that smooth a viewport. Subdivision is necessary. [P10a]
- 3D-Coat Build expands or reduces the surface. Brush alpha does not affect Build. Brush size and intensity do. [P10b]

Inference: the LVE cell grid is closer to 3D-Coat Build than to Blender Draw.
Both add or remove volume under a footprint.
Neither one moves individual vertices.

Do not migrate to SDF from this page.
Inference: an SDF store can change undo records, material ownership, frame data, and deterministic cell writes.
No measured LVE problem in this page requires that change.

## Build, Draw, Clay, and Inflate

The Consequence column is inference when it extends beyond the cited fact.

| Behavior | External evidence | LVE current | Consequence |
| --- | --- | --- | --- |
| Draw builds along the average surface normal. | Blender Draw moves vertices inward or outward from the average vertex normals in the radius. [P5a] | Build adds or removes a cell layer along the surface plane normal. | Build is a cell build, not a vertex draw. |
| Clay flattens while it builds. | Blender Clay is Draw plus sculpt-plane controls. It flattens details as it adds or subtracts. [P5b] | Build has no flatten term. Flatten is a separate tool. | Do not promise Clay behavior from Build. |
| Inflate follows each vertex normal. | Blender Inflate moves vertices along their own normals. [P6a] ZBrush Inflat does the same. [P8a] | Build uses one operation normal for the footprint. | A curved surface can need several strokes. |
| Strength builds over the stroke. | Blender sculpt Strength controls each step, so the effect builds toward the full value. [P4] | `strength` is the whole layer count of one dab. The falloff scales it per voxel. It clamps to 1 through 16. [L1] | A high LVE strength is a larger cell step, not a softer buildup. |
| A fixed plane keeps one orientation. | Blender Plane exposes `Stabilize Normal`. A value of 1 keeps the plane orientation constant for the stroke. [P6d] | Build freezes `_stroke_frame` and `_cursor_frame` at the press. [L2] | A fixed plane is a supported choice in Blender 5.2 Plane. It can produce steps on a slope. |

Documented LVE facts:

- Build uses one fixed operation plane for the stroke. [L2]
- The plane never follows a grown height. [L2]
- LVE has no user height setting. Build and Flatten read at most 64 cells for each support lookup. [L3]
- Progress is keyed by the logical column. [L4]
- A stationary press applies one dab. Extra hold time adds no cell. [L2]

Inference: repeated passes over one column add layers at the column, not at the pointer height.
The result can look like terraces or waves at the footprint edge.
This page does not measure that result.

## Flatten

| Behavior | External evidence | LVE current | Consequence |
| --- | --- | --- | --- |
| The plane can follow the local area. | ZBrush Flatten uses a plane set by the area under the brush center. The page warns that the plane can shift with strokes or alphas. [P8a] | Flatten freezes the operation plane at the press. [L2] | LVE trades local follow for repeatable columns. |
| The user can set the plane. | 3D-Coat Plane sets the plane with the right mouse button. New strokes face the camera. [P10b] | LVE uses the press surface read or the floor. | A user-set plane is a separate feature, not a bug fix. |
| The brush has a height range. | Blender Plane has Height and Depth limits above and below the plane. [P6d] | Flatten settles within `FLATTEN_THRESHOLD` 0.5. It cuts above and fills one layer below. [L5] | LVE has a threshold, not a height and depth range. |
| Fill keeps the local material. | No mesh manual defines a per-cell material. | Fill copies the full material of the local support. Cut writes transparent. [L5] | This rule is LVE-specific. External manuals cannot validate it. |

The Blender 5.2 Plane settings are candidate evidence. They show one implementation. They are not a rule for all apps.

Inference: the fixed plane is the main difference from ZBrush.
It removes the shifting-plane warning.
It also removes the local average that ZBrush uses.
Keep the fixed plane until a measured case needs a re-read mode.

## Smooth

| Behavior | External evidence | LVE current | Consequence |
| --- | --- | --- | --- |
| Smooth is a repeated relaxation. | Blender Smooth has Laplacian and Surface modes, shape preservation, and iterations per brush step. [P6b] | Smooth builds one field per mask and rounds it by the pass count of each cell. [L6] | Repeated dabs are expected to relax the surface. |
| Strength depends on resolution. | Blender states that Smooth strength is relative to mesh density. A denser mesh needs more strength. [P6b] ZBrush states that the smooth scale depends on the subdivision level. [P8b] | LVE uses a cell field and a radius-based depth. | Do not copy a mesh-density rule into cells. |
| Borders can be preserved. | ZBrush has a Groups Border smooth mode. It respects group borders. [P8b] | Smooth fill keeps the nearest local support material. [L6] | Material preservation has a similar goal, not the same mechanism. |
| Spacing is distance-based in mesh tools. | Blender Space and Nomad apply dabs by spacing. Blender Dots depends on stroke speed. [P2][P11a] | Smooth consumes a crossed anchor cell. A ray miss consumes spacing and applies no edit. The base input skips a pick equal to `_last_target`. [L6][L11] | Do not map a spacing slider onto the cell path without a decision. |

Documented LVE facts:

- Smooth uses a view-facing cursor plane and re-reads the operation plane per dab. [L6]
- A camera change ends the Smooth gesture. [L6]
- A ray miss consumes the spacing and applies no Smooth edit. [L6]
- The base `VoxelTool.handle_input` calls `_apply_stroke_to` only when `pick.target != _last_target`. [L11]
- Terrain `_frame_drag` returns a cell from the frozen cursor plane. [L13]

Documented: a pointer move inside one cell does not reach `_apply_stroke_to` in the base input path. [L11]
The user request is a faster Build cursor for continuous pointer motion. It is not a request to change the Smooth tool.
LVE chooses deterministic press and crossed-cell behavior. This is a project choice. The Blender and Nomad spacing evidence is separate. It does not define the LVE path.
Smooth-tool spacing remains a separate policy question.

## Grab

| Behavior | External evidence | LVE current | Consequence |
| --- | --- | --- | --- |
| The source set is fixed at the press. | Blender Grab moves only the vertices under the brush at the stroke start. [P6c] Nomad Grab selects at the start and keeps that selection. [P11a] | `GrabTool._capture_gesture` collects ball sources at the press. [L7] | LVE matches the fixed-source family. |
| Drag can keep adding sources. | Nomad Drag keeps updating what is inside the radius during the stroke. [P11a] | LVE uses the captured sources only. | Do not switch to Drag behavior without a measured need. |
| Pressure can be unsupported. | Blender Grab does not support size or strength pressure. Its Normal Radius is visual only. [P6c] | LVE Grab uses no strength and hides the strength option. [L7] | No pressure support is consistent with Blender Grab. |
| The latest target wins. | Blender Grab follows the cursor. | LVE queues the latest absolute delta while a job runs. [L7] | This is an absolute target, not an accumulated path. Keep it. |
| The drag is bounded. | The cited Grab pages state no cell limit. | LVE clamps the brush radius to 32 cells and the drag to 48 cells. [L7] | The limit is a project rule. State it in the UI help. |

Inference: LVE Grab is a proportional stretch on a view-facing plane.
It is not a soft brush and not an incremental snake.
Do not add a strength or pressure model to Grab without a measured case.

## Cursor states

The Requirement column is a design requirement, not current behavior.

| State | Industry evidence | LVE current | Requirement |
| --- | --- | --- | --- |
| Idle hover | Blender shows a circle whose radius matches the brush size. The cursor can be disabled. [P1] ZBrush shows an inner ring around the draw cursor. The inner ring size shows Focal Shift. [P7] Nomad can show or hide the circle and show a center dot. [P12] | `_pose_build_idle` uses the entered face or the floor plane. It runs no surface read, no map, and no terrain copy. [L8] | Pose from the pointer ray and the plane. Do not predict cells. |
| Held | The brush cursor stays at the pointer during the stroke. Nomad has a "Show circle while sculpting" option. [P12] | `_pose_build_footprint` runs on the input event. The drain does not move it. [L8] | Follow the pointer. Do not follow the job result. |
| Drain | The cited cursor and stroke pages do not define a drain cursor. | `_pose_build_footprint_from_pointer` uses the frozen cursor plane. It never recaptures the press. [L8] | Keep the input pose while the queue drains. |
| Camera navigation | Nomad uses the Alt key and empty-space drag. [S4] | LVE uses Alt plus left drag, Shift plus left drag, middle drag, and right drag. [L9] | Navigation must not edit. Hide or hold is a UX decision, not a current contract. |
| Color | Blender has user-set cursor and inverse colors. [P1] Nomad has an indicator color. [P12] The cited cursor pages do not tie color to job progress. | `FOOTPRINT_COLOR` is `Color.WHITE`. It is set once on the cloned material. [L8] | Keep one neutral color. Do not tint by job, progress, or paint color. |

Documented LVE facts:

- The Build cursor is one cached line mesh per radius. [L8]
- The material is opaque, unshaded, and has no depth test. [L8]
- The leaf has one mirror per active symmetry mask. [L8]
- The idle cursor is a separate leaf. A late hover result cannot replace it. [L8]
- Build stores the live pointer position on each input event. `_pose_build_visual` intersects that ray with the plane. [L8]
- Flatten, Smooth, and Grab keep their active policies. [L2]

Inference: the Build ring needs only the pointer ray, the frozen plane, the radius, and the mask count.
It does not need the sample map, the occupancy read, or the next cells.
This is why the ring can stay responsive while a dab job runs.

## Evidence for a lightweight cursor independent of terrain prediction

### Documented

- Blender states that the cursor is a circle in the 3D viewport. The radius matches the brush size. [P1]
- Blender states that the cursor can be disabled. [P1]
- Blender states that the cursor can show a falloff gradient inside the circle. [P1]
- Blender states that the cursor has an add color and an inverse color. [P1]
- ZBrush states that the draw cursor has an inner ring. The inner ring size shows Focal Shift. [P7]
- Nomad states that the user can show or hide the circle while sculpting. [P12]
- Nomad states that the user can show a small dot at the brush center. [P12]
- Blender states that spacing controls the distance between dabs. [P2]
- Nomad states that spacing controls the distance between dabs during a drag. [P11a]

### Inference

- A radius ring needs the pointer pose and the brush radius.
- A falloff ring needs the falloff curve, not the edited cells.
- A ring does not need the sample map or the next occupied cells.
- The cited manuals describe the cursor as a display overlay. They do not describe a prediction mesh.
- Therefore a lightweight ring is normal practice, not a reduced feature.

### Limit

- The manuals do not prove that a terrain-predicting cursor is wrong.
- They show that a radius-only cursor is common.
- No official developer architecture page for a brush cursor was reachable on 2026-10-24. This page uses the manual wording as primary evidence.
- A flat ring shows the brush plane. It does not show the local surface.
- LVE uses a fixed plane for Build and Flatten. A flat ring on that plane is consistent with the edit rule.

### Hypothesis

A ring that reads only the pointer ray and the frozen plane will stay responsive during a large dab job.
A test can confirm this without a speed claim.

## Mask, symmetry, boundaries, materials, cancel, and undo

| Area | External evidence | LVE current | Review note |
| --- | --- | --- | --- |
| Mask | Blender Auto-Masking can filter by topology, face set, mesh boundary, cavity, or view normal. The mask resets each stroke. [S2] | The frozen edit context filters destination cells. [L2] | LVE has no view-normal auto-mask. Do not add one now. |
| Symmetry | Blender mirrors strokes across local axes. Feather reduces strength at the symmetry planes. [S1] | Sample maps mirror every active mask. Duplicate anchors resolve to one owner. The strongest claim wins, and the last anchor wins. [L10] | No double strength at the plane. Feather is absent. |
| Front faces | Blender has `Front Faces Only`. It affects only vertices that face the viewer. [P4] Front-face falloff is not available in Sculpt Mode. [P3] | The selection is a set of voxel cells. It cannot distinguish the front and back face of one cell. [L12] | A far-side write is a policy question, not a proven bug. Measure it. |
| Boundaries | Blender can mask mesh boundaries and face-set boundaries. [S2] | Build and Flatten read 64 cells. Smooth reads `depth_for(radius)`. [L3] | The depth is bounded. The bound is not a front-face rule. |
| Materials | The mesh manuals have no per-cell material. | Build Add uses the captured material. Remove writes transparent. Flatten fill copies the local support. Smooth fill keeps the local support. Grab keeps the source material. [L5][L6][L7] | These rules are the LVE contract. Do not change them for cursor work. |
| Cancel | Blender and Nomad expose undo history. [S3][S5] The cited manuals do not define mid-stroke cancel. | Escape, a context change, or a history change cancels the open stroke and restores the start snapshots. [L2] | LVE defines a cancel path that the cited manuals do not. Keep it. |
| Undo | Blender records actions in Undo History. [S3] Nomad has a memory-bounded history stack. [S5] | One action is recorded at stroke close, if cells changed. [L2] | Keep one action per stroke. Do not add per-dab undo. |

Documented: `EditContext.selection` is a dictionary keyed by cell. It has no face key. [L12]

Inference: symmetry overlap is already deterministic in LVE.
A mirrored sample that lands on the same anchor replaces the earlier sample.
It does not add a second layer.
This differs from Blender Feather, which softens the overlap.

## Genuine UX decisions

These are decisions, not consensus.
The sources show different answers.

| Decision | Evidence for one side | Evidence for the other side | Recommendation |
| --- | --- | --- | --- |
| Cursor shows radius only, or predicts the result | Blender, ZBrush, and Nomad show a radius or falloff cursor. [P1][P7][P12] | The cited cursor pages show no full result preview. | Keep radius only. Do not predict terrain. |
| Pressure changes size or strength | Blender and Nomad support pressure. [P4][P11b] | Blender Grab does not support size or strength pressure. [P6c] | Defer pressure. It conflicts with deterministic press and accepted crossings. |
| Spacing is a control, or implicit | Blender, ZBrush, and Nomad expose spacing. [P2][P9a][P11a] | LVE applies one dab per accepted crossing. | Keep implicit spacing. Document it. Do not add a slider now. |
| A held stroke sprays, or stops | Blender Airbrush sprays while held. Blender Dots does not. [P2] ZBrush Dots depends on mouse movement. [P9b] | LVE applies one dab on press and none on hold. [L2] | Keep no stationary edit. This is a project choice. |
| Front faces are filtered, or cell selection is the only gate | Blender offers `Front Faces Only`. [P4] | LVE selection stores voxel cells, not faces. [L12] | Measure a thin wall with a cell mask. Do not add an automatic toggle. |
| Symmetry overlap feathers, or dedupes | Blender Feather reduces strength at the plane. [S1] | LVE resolves duplicate anchors to one owner. [L10] | Keep dedupe. Feather is a later option. |
| Anchored stroke resizes one dab | Blender Anchored makes one dab and drag resizes it. [P2] ZBrush DragDot places one dab at the drag end. [P9b] | LVE press and drag build a path. | Defer anchored strokes. They need a new gesture and cancel rule. |

## Recommendations

Ranked by user impact and implementation cost.
All items preserve the current edit semantics.
The impact and cost values are estimates, not measurements.

| Rank | Change | User impact | Cost | Correctness risk | Evidence |
| --- | --- | --- | --- | --- | --- |
| 1 | Finish the lightweight Build footprint cursor for idle, held, and drain. | High | Low | Low | Documented cursor behavior. [P1][P7][L8] |
| 2 | Keep the cursor color neutral and independent of job state. | Medium-high | Low | Low | The cited cursor pages do not tie color to job progress. [P1][P7][P12] |
| 3 | Verify duplicate accepted endpoint handling for queued segments. | Unknown until measured | Low-medium | High | Base input skips same-cell targets. The risk is A to B to A while a worker is busy. [L11][L13] |
| 4 | Measure cell-mask boundary behavior at a thin wall. | Medium | Medium | Medium | Selection stores cells, not faces. [L12] |
| 5 | Document implicit spacing and no-hold-edit behavior. | Medium | Low | Low | Project choice. [L2] |
| 6 | Defer pressure and anchored strokes. | Low now | High | High | Mixed manual support. [P4][P6c] |

### 1. Finish the lightweight Build footprint cursor

- Keep one cached ring mesh per radius.
- Pose it from the pointer ray and the frozen plane.
- Use the same pose path for idle, held, and drain.
- Do not run a surface read, a map, or a terrain copy on pointer move.
- Recommend hiding the ring during camera navigation. This is a UX recommendation, not a sourced user choice or a current contract.
- Pass condition: pose and ring geometry cost do not depend on frame contents.
- Measure total input cost separately. Picking and ray distance are part of that total.

This is current owner work. Do not duplicate it.
The user request is a faster Build cursor for smooth, continuous pointer motion. It is not a request to change the Smooth tool.
This page does not measure speed.

### 2. Keep the cursor neutral and state-free

- Set the color once on the cloned material.
- Do not tint by paint color, job progress, or a completed cell result.
- Clear the ring on cancel and document change.
- Pass condition: the color is identical in idle, held, drain, and cancel.

This follows the user choice.
Blender allows user colors, so fixed neutral is a project choice, not an industry rule.

### 3. Verify duplicate accepted endpoint handling

- Documented: the base input already skips a pick equal to `_last_target`. [L11]
- Do not assume that every same-cell pointer move adds queue work. Trace the actual input chain first.
- Measure queue work before any optimization. Use a long stroke and a busy worker.
- Risk: A to B to A while a worker is busy. `_path_anchor` is the last accepted endpoint. [L13]
- A drain-side anchor, such as `FrameData.last_drained_path_anchor` in active work, can lag the last accepted queued endpoint.
- An early-out must compare against the last accepted queued endpoint, not the drained anchor.
- The return to A must stay in the queue. A to B to A has two crossings.
- Proposed experiment: confirm that A to B applies and B to A applies once each while a worker is busy.
- Pass condition: no accepted crossing is dropped.
- Prerequisite: measured queue work is nonzero. If it is zero, close the question.
- Pass condition: a duplicate endpoint does not remove a needed return crossing.

This is a proposal. No test has run.
This is not a proven low-risk performance win.

### 4. Measure cell-mask boundary behavior at a thin wall

- Fixture: a one-cell wall. The cell mask includes the wall cell. The cell mask excludes cells behind the wall.
- Do not use a front-face selection. The current mask cannot select a face. [L12]
- Check Build Add and Flatten fill.
- Measure whether any cell behind the wall changes.
- Record the brush normal and whether the far cell is hidden from the press ray.
- Do not add an automatic front-face-only toggle.
- Do not change accepted semantics.
- Pass condition: the result is recorded. A no-write result is not required before a policy decision.

Inference: the cell mask can exclude the far cells. It cannot express "front face only".
The result is a UX decision, not a bug report.

### 5. Document implicit spacing and no-hold-edit

- State that a press applies one dab.
- State that a hold adds no dab.
- State that each accepted crossing applies at most one dab.
- State that a return crossing A to B to A stays in the queue.
- State that spacing is implicit, not a slider.
- Pass condition: a user can predict the result of a press, a hold, and a slow drag.

### 6. Defer pressure and anchored strokes

- Pressure needs a capture rule, a UI, and a new test matrix.
- Anchored strokes need a new gesture and a new cancel rule.
- The cited sources do not measure user demand for either in a cell editor.
- Revisit only after a measured request or a measured problem.

## Manual validation checklist

Run these checks by hand on one build.
Record the build, the radius, and the mask count.

1. Prepare a flat floor, a slope, a three-step stair, a one-cell wall, a hole, and an empty floor.
2. Set radius 1, 8, and 32. Set 0, 1, and all 8 symmetry masks.
3. Move the pointer over each surface without a press. Check that the ring follows the pointer and the plane.
4. Move the pointer across a step and a hole. Check that the ring does not jump to a predicted cell.
5. Press and hold still for two seconds. Check that exactly one dab applies.
6. Drag slowly inside one cell. Check that the Build cursor pose follows the pointer and no extra dab applies.
7. Drag fast across many cells. Check that each accepted crossing applies once.
8. Release after a long fast stroke. Check that the ring keeps the pointer pose while the queue drains.
9. Check that the ring color does not change during the drain.
10. Navigate with Alt, Shift, middle drag, and right drag during hover and during a stroke. Check that no terrain edit occurs.
11. Apply a partial selection and a symmetry mask. Check that the ring clips and that the plane overlap does not double the layer.
12. Build a one-cell wall. Use a cell mask that includes the wall and excludes the far cells. Measure whether the far side changes. Record the brush normal and the exact cell.
13. Flatten a two-material column. Check that the fill keeps the local material.
14. Smooth a two-material surface. Check that the support material remains.
15. Press Escape during a stroke and during a drain. Check that the cells roll back and no undo action remains.
16. Undo one completed stroke. Check that one action removes the whole stroke.
17. Record pose time and total input time for idle, held, and drain at radius 32 with all masks. Keep the numbers as measurements, not promises.

## Source list

### Primary sources

The Blender footer date is a documentation build date, not a proven content revision date. Treat it as a build and access date.

| ID | Source and section | URL | Version or date | Access |
| --- | --- | --- | --- | --- |
| P1 | Blender Manual, Sculpting and Painting, Brush, Cursor | https://docs.blender.org/manual/en/latest/sculpt_paint/brush/cursor.html#cursor | Blender 5.2 LTS Manual. Footer build 2026-10-24. | 2026-10-24 |
| P2 | Blender Manual, Brush, Stroke: Stroke Method, Spacing, Airbrush, Anchored, Spacing Distance | https://docs.blender.org/manual/en/latest/sculpt_paint/brush/stroke.html#stroke | Blender 5.2 LTS Manual. Footer build 2026-10-24. | 2026-10-24 |
| P3 | Blender Manual, Brush, Falloff: Falloff Shape, Normal Falloff | https://docs.blender.org/manual/en/latest/sculpt_paint/brush/falloff.html#falloff | Blender 5.2 LTS Manual. Footer build 2026-10-24. | 2026-10-24 |
| P4 | Blender Manual, Brush Settings: General, Advanced | https://docs.blender.org/manual/en/latest/sculpt_paint/brush/brush_settings.html#sculpt-tool-settings-brush-settings-general | Blender 5.2 LTS Manual. Footer build 2026-10-24. | 2026-10-24 |
| P5 | Blender Manual, Sculpting, Brushes: P5a Draw, P5b Clay | P5a https://docs.blender.org/manual/en/latest/sculpt_paint/sculpting/brushes/draw.html#draw, P5b https://docs.blender.org/manual/en/latest/sculpt_paint/sculpting/brushes/clay.html#clay | Blender 5.2 LTS Manual. Footer build 2026-10-24. | 2026-10-24 |
| P6 | Blender Manual, Sculpting, Brushes: P6a Inflate, P6b Smooth, P6c Grab, P6d Plane | P6a https://docs.blender.org/manual/en/latest/sculpt_paint/sculpting/brushes/inflate.html#inflate, P6b https://docs.blender.org/manual/en/latest/sculpt_paint/sculpting/brushes/smooth.html#smooth, P6c https://docs.blender.org/manual/en/latest/sculpt_paint/sculpting/brushes/grab.html#grab, P6d https://docs.blender.org/manual/en/latest/sculpt_paint/sculpting/brushes/plane.html#plane | Blender 5.2 LTS Manual. Footer build 2026-10-24. The 5.2 index lists Plane. The old Flatten URL returns 404. | 2026-10-24 |
| P7 | Maxon ZBrush Help, Draw palette: Draw Size, Focal Shift, Z Intensity | https://help.maxon.net/zbr/en-us/Content/html/reference-guide/draw/draw.html | Legacy ZBrush help. Page text refers to ZBrush 4R5. The pages show ZBrush 2021, 2022, and 2023 links. No page date. | 2026-10-24 |
| P8 | Maxon ZBrush Help: P8a Sculpting Brushes, P8b Smooth | P8a https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/sculpting-brushes/sculpting-brushes.html, P8b https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/sculpting-brushes/smooth/smooth.html | Legacy ZBrush help. No page date. | 2026-10-24 |
| P9 | Maxon ZBrush Help: P9a Stroke Modifiers, P9b Strokes | P9a https://help.maxon.net/zbr/en-us/Content/html/reference-guide/stroke/modifiers/modifiers.html, P9b https://help.maxon.net/zbr/en-us/Content/html/user-guide/3d-modeling/sculpting/sculpting-brushes/strokes/strokes.html | Legacy ZBrush help. No page date. | 2026-10-24 |
| P10 | 3DCoat Documentation: P10a Voxel mode, P10b Voxel Tools | P10a https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode, P10b https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/voxel-tools | 3DCoat 2021 to 2022 era. Pages by Carlos, 2022-09-19 and 2022-09-21. | 2026-10-24 |
| P11 | Nomad Sculpt Manual: P11a Stroke, P11b Pressure | P11a https://nomadsculpt.com/manual/stroke, P11b https://nomadsculpt.com/manual/pressure | Undated manual. Site offers Nomad 2.12.1. | 2026-10-24 |
| P12 | Nomad Sculpt Manual, Settings: Cursor. Show circle while sculpting, Show small dot, Color. | https://nomadsculpt.com/manual/settings | Undated manual. Site offers Nomad 2.12.1. | 2026-10-24 |

### Supporting sources

| ID | Source and section | URL | Version or date | Access |
| --- | --- | --- | --- | --- |
| S1 | Blender Manual, Sculpting, Symmetry: Mirror, Feather | https://docs.blender.org/manual/en/latest/sculpt_paint/sculpting/tool_settings/symmetry.html#symmetry | Blender 5.2 LTS Manual. Footer build 2026-10-24. | 2026-10-24 |
| S2 | Blender Manual, Sculpting, Controls: Auto-Masking | https://docs.blender.org/manual/en/latest/sculpt_paint/sculpting/controls.html#auto-masking | Blender 5.2 LTS Manual. Footer build 2026-10-24. | 2026-10-24 |
| S3 | Blender Manual, Interface, Undo and Redo: Undo History | https://docs.blender.org/manual/en/latest/interface/undo_redo.html#undo-redo | Blender 5.2 LTS Manual. Footer build 2026-10-24. | 2026-10-24 |
| S4 | Nomad Sculpt Manual, Camera: Controlling the camera, Desktop controls | https://nomadsculpt.com/manual/camera | Undated manual. Site offers Nomad 2.12.1. | 2026-10-24 |
| S5 | Nomad Sculpt Manual, History: History, History limit | https://nomadsculpt.com/manual/history | Undated manual. Site offers Nomad 2.12.1. | 2026-10-24 |

Primary source count: 12 entries, 20 URLs.
Supporting source count: 5 entries, 5 URLs.
Total: 17 entries, 25 URLs.

## Project evidence

- [L1] `plugins/Terrain/TerrainToolSettings.gd`, `radius`, `strength`, `falloff`, `build_mode`.
- [L2] `plugins/Terrain/TerrainTool.gd`, `_pick_start`, `_run_dab`, `_plane_point`, `_end`, `_settle_dabs`, `_cancel_edit`.
- [L3] `plugins/Terrain/TerrainPreview.gd`, `footprint_depth`.
- [L4] `plugins/Terrain/TerrainPrep.gd`, `progress_key`, `accumulated`, `collect_steps`.
- [L5] `plugins/Terrain/TerrainGeometry.gd`, `flatten_action`.
- [L6] `plugins/Terrain/TerrainPreview.gd`, `compute_smooth_fields`, `plugins/Terrain/TerrainPrep.gd`, `smooth_surface_frame`.
- [L7] `plugins/Deform/GrabTool.gd`, `_capture_gesture`, `_make_job`, `GrabJob`, `GRAB_MAX_DISTANCE`.
- [L8] `plugins/Terrain/TerrainTool.gd`, `FOOTPRINT_COLOR`, `_setup_build_footprint`, `_build_build_footprint_mesh`, `_pose_build_footprint`, `_pose_build_idle`, `_pose_build_visual`, `_pose_build_footprint_from_pointer`, `handle_input`.
- [L9] `ui/Viewport/Viewport.gd`, `_view_drag_mode`, `_input`.
- [L10] `plugins/Terrain/TerrainGeometry.gd`, `resolve_samples`, `plugins/Terrain/TerrainPreview.gd`, `compute_sample_map`.
- [L11] `Globals/State/Tools/VoxelTool.gd`, `handle_input`, `_last_target`, `_apply_stroke_to`.
- [L12] `Globals/State/Document/VoxelFrame.gd`, `EditContext.selection`, `EditContext.expand`.
- [L13] `plugins/Terrain/TerrainTool.gd`, `_frame_drag`, `_path_anchor`.

The working tree has active edits in these files.
The Terrain input chain is changing. Recheck it before a claim about same-cell motion.
Recheck each symbol before a code change.

## Caveats and non-claims

- This page does not measure speed.
- This page does not prove that a lightweight cursor is faster.
- This page does not prove that a terrain-predicting cursor is wrong.
- This page does not prove that LVE needs pressure, spacing, feather, or anchored strokes.
- This page does not recommend an SDF migration.
- This page does not define a new cursor architecture.
- This page does not change the current tool policies.
- The ZBrush help is legacy. Its page text refers to ZBrush 4R5. Current ZBrush behavior can differ.
- The 3DCoat pages are from 2022. Current 3DCoat behavior can differ.
- The Nomad manual is undated. Its current app version can differ from the page.
- The Blender footer date is a documentation build date. It is not proof of a content revision.
- Blender 5.2 lists Plane and omits Flatten from the brush index.
- Blender front-face falloff is not available in Sculpt Mode. `Front Faces Only` is a separate setting.
- The cited manuals do not describe internal cursor meshes or remesh work.
- Mesh and SDF manuals cannot validate per-cell material preservation.
- Selection stores voxel cells, not faces. A front-face-only rule is not available today.
- The fixed Build plane, the neutral cursor, and the no-hold-edit rule are project choices.
- The camera-navigation hide rule is a recommendation. No cited source or current code contract requires it.
- Pose cost is not total input cost. Picking and ray distance are separate.
- The duplicate endpoint experiment is a proposal. No test has run.
- The Terrain input chain is changing. Recheck it before a same-cell claim.

## Open questions

1. Does any Terrain path reach `_apply_stroke_to` with a target equal to `_last_target`?
2. How much queue work does A to B to A create while a worker is busy?
3. Does a drain-side anchor lag the last accepted endpoint?
4. Does the Build ring stay responsive while a large dab job runs?
5. Can a cell mask plus brush normal avoid a far-side write at a thin wall?
6. Does a symmetry overlap add one layer or two?
7. Does the ring hide during camera navigation today?
8. Which cursor state is visible after a cancelled stroke?
