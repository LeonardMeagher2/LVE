# Editing UX research

Status: READY.

Date: 2026-10-24.

Sources: 10. Eight are product manuals or product documents. Two are UX sources.

Scope: Brush, Eraser, Line, Paint Brush, Fill, Spray, Box, Lasso, Wand, Move, Rotate, Scale, Copy, Cut, Paste, Eyedropper, Plane, Symmetry.

Out of scope: the Build cursor implementation. Another owner is changing it. This file does not touch that work.

This file compares published tool behavior with current LVE behavior.
It does not authorize behavior changes.
It does not replace the [tool flow maps](../../tool-flows/README.md).
It does not copy source code from Aseprite or any other product.

## How to read this file

Use the evidence labels from the [track index](README.md).

| Label | Meaning in this file |
| --- | --- |
| Documented behavior | A current flow map, a current code symbol, or a published manual shows it. |
| Inference | A reasoned conclusion from the evidence. It is not measured. |
| Proposed experiment | A test or manual task that can confirm or reject a claim. It is not a result. |

Confidence is about evidence strength.
It is not a product priority.

- **High:** three or more independent manuals agree, and current LVE behavior is visible in code or docs.
- **Medium:** two manuals agree, or one manual plus a direct inference.
- **Low:** one manual, an indirect analog, or no direct LVE evidence.

The expectations below come from other editors.
They are not universal defaults.
Voxel workflows can differ from pixel workflows.

## Source register

| ID | Source and version | Sections used | URL | Document date | Access date |
| --- | --- | --- | --- | --- | --- |
| S1 | MagicaVoxel 0.99.7.2, Windows and macOS | Update Log: 0.99.6.2 Rotate Transform Brush, 0.99.5.1 Brush, Selection, Selection Brushes, 0.99.5 Model Editor, 0.99.5.1 Scene Editor. FAQ | <https://ephtracy.github.io/mv_main.html> | Release 2025-07-12 | 2026-10-24 |
| S2 | MagicaVoxel 0.99.7.2 Shortcuts | Select, Edit [Model Editor], Brush [World Editor], Brush [Model Editor], Renderer, Brush Mode, Mirror Mode, Axis Mode | <https://ephtracy.github.io/mv_controls.html> | Release 2025-07-12 | 2026-10-24 |
| S3 | VoxEdit 2025.1 documentation | Modeler: Toolbar, Modes, Mirror. Use Modes & Tools Together: Modes & Tools | <https://docs.sandbox.game/en/creator/voxedit/docs/modeler.md> and <https://docs.sandbox.game/en/creator/voxedit/docs/modeler/use-modes-and-tools-together.md> | Page assets say 2025.1. Page is undated | 2026-10-24 |
| S4 | Aseprite 1.3 documentation, site copyright 2026 | Drawing. Selecting: Add/Subtract/Intersect. Transformations: Transforming Multiple Layers, Frames or Cels. Eyedropper: sample options. Symmetry. Undo History. Edit Menu: Cut, Copy, & Paste. Eraser | <https://www.aseprite.org/docs/drawing/> and <https://www.aseprite.org/docs/selecting/> and <https://www.aseprite.org/docs/transformations/> and <https://www.aseprite.org/docs/eyedropper/> and <https://www.aseprite.org/docs/symmetry/> and <https://www.aseprite.org/docs/undo-history/> and <https://www.aseprite.org/docs/edit-menu/> and <https://www.aseprite.org/docs/eraser/> | Site copyright 2026. Pages are undated | 2026-10-24 |
| S5 | Krita Manual 5.3.0, revision 4e66218 | Transform Tool: Free transform, Continuous Transform. Fill Tool: Tool Options. Color Sampler Tool. Selections: Creating Selections, Editing Selections. Spray Brush Engine: Spray Area. Straight Line Tool. Instant Preview | <https://docs.krita.org/en/reference_manual/tools/transform.html> and <https://docs.krita.org/en/reference_manual/tools/fill.html> and <https://docs.krita.org/en/reference_manual/tools/color_sampler.html> and <https://docs.krita.org/en/user_manual/selections.html> and <https://docs.krita.org/en/reference_manual/brushes/brush_engines/spray_brush_engine.html> and <https://docs.krita.org/en/reference_manual/tools/line.html> and <https://docs.krita.org/en/reference_manual/instant_preview.html> | Manual 5.3.0. Revision 4e66218 | 2026-10-24 |
| S6 | Blender 5.2 LTS Manual | Move. Rotate. Selecting: Selection Modes. Mesh Selecting: X-Ray. Undo & Redo: Undo History. Snapping | <https://docs.blender.org/manual/en/latest/scene_layout/object/editing/transform/move.html> and <https://docs.blender.org/manual/en/latest/interface/selecting.html> and <https://docs.blender.org/manual/en/latest/modeling/meshes/selecting/introduction.html> and <https://docs.blender.org/manual/en/latest/interface/undo_redo.html> and <https://docs.blender.org/manual/en/latest/editors/3dview/controls/snapping.html> | Pages show 2026-10-24 | 2026-10-24 |
| S7 | GIMP 3.2 Manual | 3.9 Airbrush: 3.9.3 Options | <https://docs.gimp.org/3.2/en/gimp-tool-airbrush.html> | Manual 3.2. Page is undated | 2026-10-24 |
| S8 | Goxel 0.15.1 README and official site | Features. About | <https://raw.githubusercontent.com/guillaumechereau/goxel/master/README.md> and <https://goxel.xyz/> | Version 0.15.1. Page is undated | 2026-10-24 |
| S9 | Nielsen Norman Group, Response Times: The 3 Important Limits | Web-Based Application Response Time | <https://www.nngroup.com/articles/response-times-3-important-limits/> | 1993, web update 2014 | 2026-10-24 |
| S10 | Forch, Franke, Rauh, and Krems, Are 100 ms Fast Enough? | Abstract | <https://research.uni-luebeck.de/en/publications/are-100-ms-fast-enough-characterizing-latency-perception-threshol/> | Published 2017-05-18 | 2026-10-24 |

The manuals describe user-visible behavior.
This file does not infer the internal design of MagicaVoxel, VoxEdit, Aseprite, Krita, or GIMP from their manuals.

## Current LVE inventory

| Family | Tools | Current policy summary | Evidence |
| --- | --- | --- | --- |
| Stamp strokes | Brush, Paint Brush | Press opens one edit. Drag queues stamp centers. Release or switch commits one `Stroke` or `Erase` action. | [Drawing, Brush and Paint Brush](../../tool-flows/drawing.md#brush-and-paint-brush) |
| Staged line | Line | Anchor, preview, then commit. Release, second click, or Enter commits. Escape or switch drops the preview. | [Drawing, Line](../../tool-flows/drawing.md#line) |
| Region search | Fill | Six-face flood or all matching cells. Selection blocks traversal. No region preview. | [Drawing, Fill](../../tool-flows/drawing.md#fill) |
| Sampled spots | Spray | Speed is spots per press or brush cell. Spot diameter is the painted sphere. Search width is the sampled area. | [Drawing, Spray](../../tool-flows/drawing.md#spray) |
| Screen and material selection | Box, Lasso, Wand | Replace, add, subtract. Box and Lasso use a screen shape. Wand uses a seed and a material match. | [Selection](../../tool-flows/transform-selection.md#selection-box-lasso-and-wand) |
| Baseline displacement | Move, Rotate, Scale | Press captures a source. Preview writes the live frame. Release leaves the transform pending. | [Transform](../../tool-flows/transform-selection.md#transform-move-rotate-and-scale) |
| Clipboard | Copy, Cut, Paste | Copy has no model write. Cut records one `Cut`. Paste previews the cursor, then installs one `Paste`. | [Clipboard](../../tool-flows/transform-selection.md#clipboard-copy-cut-and-paste) |
| Utilities | Eyedropper, Plane, Symmetry | State-only except Eyedropper. Eyedropper records `Set Material`. Plane and Symmetry record no undo action. | [Utility tools](../../tool-flows/shared-and-utilities.md#utility-tools) |

Current LVE settings add these exact values:

- Brush and Paint Brush diameter: 1 through 64 cells. Shape: cube, sphere, or copied selection.
- Spray spot diameter: 1 through 64 cells. Default 1.
- Spray search width: 1 through 64 cells. Default 9.
- Spray speed: 1 through 64 distinct spot centers per press or brush cell. Default 8.
- Selection modes: replace, add, subtract. No intersect.
- Transform rotate snap: quarter turns, or 1 degree steps with a 2 degree magnetic pull.
- Symmetry origin snaps to half units.

Evidence: [StampToolSettings](../../../plugins/brush/StampToolSettings.gd), [PaintToolSettings](../../../plugins/paint/PaintToolSettings.gd), [SelectionToolSettings](../../../plugins/selection/SelectionToolSettings.gd), [TransformToolSettings](../../../plugins/Transform/TransformToolSettings.gd), [State](../../../Globals/State/State.gd).

## Top findings

1. LVE matches the core add, erase, paint, line, fill, and transform expectations. The clearest control gap is the missing selection intersect mode [S4][S5][S6].
2. LVE Spray separates spot count, spot diameter, and search width. The controls show a number and an icon. Their tooltips explain the values, but the units are not visible at a glance [S5][S7].
3. LVE Fill matches exact materials. Krita offers tolerance, spread, and gap closing. This is a likely gap for fuzzy fills [S5].
4. LVE transform release leaves the edit pending. Blender confirms with the left mouse button. The pending state needs a clear hint [S6].
5. LVE transform undo is named `Stroke`. Blender names actions in the undo history. A tool name is easier to find [S6].
6. LVE already keeps cursor preview separate from model install. This matches the main performance lesson from Krita and the latency studies [S5][S9][S10].

## Published behavior by family

### Brush, Eraser, and Paint Brush

MagicaVoxel separates attach, erase, and paint brushes [S1][S2].
The attach brush adds voxels.
The erase brush removes voxels.
The paint brush changes the color of existing voxels.
MagicaVoxel also lets selection limit which voxels a brush can change [S1].

Aseprite separates pencil, eraser, and brush settings [S4].
The eraser removes pixels to the background color or to transparency.
The pencil paints with the foreground color.
Brush type and size are visible context-bar settings.

LVE matches the main split.
Brush PENCIL adds in front of the clicked face.
Brush ERASER writes only cells that the frame already holds.
Paint Brush requires a hit and recolors existing cells.
Each stroke records one undo action.

Difference: the LVE policy table says Brush does not require a hit [Drawing, Brush and Paint Brush](../../tool-flows/drawing.md#brush-and-paint-brush).
The MagicaVoxel notes describe face, box, and line brush modes [S1].
They do not state an empty-space add rule.
The LVE hit rule is visible, but it is not clearly a defect.

### Line

Krita uses press, drag, and release for a straight line [S5].
The preview option shows the line before release.
Shift constrains the angle to 15 degree steps.
Alt moves the line while the button is held.

MagicaVoxel has a line brush mode [S1][S2].
The line shape is one of the brush modes, not a separate preview transaction.

LVE uses a staged line [Drawing, Line](../../tool-flows/drawing.md#line).
The first press sets the anchor.
The drag or second click sets the endpoint.
Release, second click, or Enter commits one `Line` action.
Escape, a context change, or a switch drops the preview.
The preview does not change the document and adds no undo action.

This is a strong match to the preview-first expectation.
Difference: this file found no documented angle-constraint modifier in LVE.
Krita documents Shift for 15 degree steps [S5].
That is a possible gap, not a proven defect.

### Fill

Krita documents contiguous fill and similar-color fill [S5].
The fill tool has a threshold, a spread, a close-gap value, and a selection-boundary option.
The selection can act as an extra boundary.

LVE Fill has two search modes [Drawing, Fill](../../tool-flows/drawing.md#fill).
`connected` true floods the six face neighbors.
`connected` false scans every occupied cell with the same material.
A non-empty selection blocks traversal and matching.
The search reads the selection when it processes each seed.

LVE matches the selection-boundary behavior.
Difference: LVE has no tolerance or similar-material threshold.
It matches the exact material.
This is a likely gap for users who expect a fuzzy bucket fill.
It can also be an intentional voxel policy, because voxel materials are discrete.

Difference: LVE Fill has no region preview [Drawing, Fill](../../tool-flows/drawing.md#fill).
The cursor is a static outline.
The Krita page does not document a region preview before the fill [S5].
The missing preview is a current LVE policy, not a TODO.

### Spray

Krita's spray engine separates three ideas [S5].
The spray area has a diameter.
The particle amount is a count or a density.
The spacing changes the distance between spray dabs.

GIMP separates rate and flow [S7].
The airbrush has a Motion only option.
When Motion only is off, the airbrush can keep applying color while the pointer is stationary.
Rate controls the speed of application over time.

MagicaVoxel has a surface mode for some brushes [S1].
The `Su` mode operates on the surface only.

LVE Spray separates three different values [Drawing, Spray](../../tool-flows/drawing.md#spray).
`speed` is the number of distinct spot centers per press or per brush cell.
`spot_diameter` is the diameter of each painted spot.
`spray_size` is the width of the search area that supplies spot centers.
A spot diameter above one can paint more voxels than the speed count.
The search width is not the painted area.
The cursor shows the sampled cells, not the search sphere.

LVE samples existing voxels inside the search sphere.
Each spot paints every existing voxel inside its own sphere.
This is volume sampling, not surface-only sampling.
The press paints the batch that the cursor shows when the token is valid.
A drag accepts one batch per brush cell.

The three-value split matches the Krita separation of area, amount, and spacing.
Difference: LVE speed is a count per cell, not a time-based rate.
GIMP documents a time-based stationary airbrush [S7].
This difference needs a product decision.

### Selection

Aseprite documents replace, add, subtract, and intersect [S4].
The modifiers are visible in the context bar.
Krita documents replace, add, subtract, intersect, and symmetric difference [S5].
Blender documents set, extend, subtract, invert, and intersect [S6].
MagicaVoxel documents Shift to add and Shift plus Alt to subtract [S1][S2].

LVE documents replace, add, and subtract [Selection modes](../../tool-flows/transform-selection.md#selection-combine-modes).
It has no intersect mode.
ScreenSelection subtract also adds covered previous selected cells to the region.
Wand subtract does not add covered previous selected cells.
This difference is documented and intentional.

Box and Lasso use a screen shape [Selection](../../tool-flows/transform-selection.md#selection-box-lasso-and-wand).
Box uses a screen rectangle.
A click smaller than 7 pixels uses a 7 pixel square.
Lasso samples the pointer path at 6 pixel steps and stops at 512 points.
The camera and options are captured after the outline finishes.

Wand uses a picked occupied cell as its seed.
It uses a six-face flood or a full scan.
It matches one material.
The current selection is not a barrier.
It ignores `depth_test` and `include_empty`.
The options bar hides those controls for the wand.

MagicaVoxel offers Box Select, Rect Select, and Region Select [S1].
Box Select selects voxels in a box.
Rect Select selects voxels in a screen rectangle.
Region Select selects by same volume, same face, or same color.
This is a useful comparison for LVE Box, Lasso, and Wand.

Visibility and depth:

- LVE Box and Lasso have `depth_test` true by default [SelectionToolSettings](../../../plugins/selection/SelectionToolSettings.gd). Hidden voxels behind visible voxels drop out.
- LVE Box and Lasso have `include_empty` false by default. A true value keeps empty cells inside the frame bounds.
- LVE Wand ignores both options.
- Blender uses X-Ray to select occluded geometry [S6]. X-Ray is a view mode, not a per-tool option.
- Aseprite selects the active cel only [S4].

### Move, Rotate, and Scale

Blender confirms a move with the left mouse button [S6].
The transform stays modal until confirmation.
Krita documents Escape as a cancel key in its continuous transform flow [S5].
Aseprite commits a multi-cel transform by clicking outside the selection [S4].

LVE uses one shared transform lifecycle [Transform](../../tool-flows/transform-selection.md#transform-move-rotate-and-scale).
Press captures a source frame and a selection snapshot.
A preview writes the live frame.
Release leaves the transform pending.
Enter, the option bar, a context change, or a tool switch commits.
Escape cancels and restores the start.
The undo action name is `Stroke`.

Move uses a view-plane offset in whole cells.
Rotate uses an angle around the bounds center on the view axis.
Scale uses a factor from a view-plane reference vector.
There is no transform gizmo.
There is no duplicate mode.
There is no destination mask.

The snap rules match a voxel editor.
Move snaps to whole cells.
Rotate snaps to quarter turns, or to 1 degree steps with a 2 degree magnetic pull.
Scale snaps to 0.0001 and clamps to `MIN_SCALE`.
Blender documents snapping as a separate control [S6].
Krita documents Shift for aspect ratio and Ctrl for skew [S5].
The LVE rules are stricter, and that is appropriate for voxels.

### Copy, Cut, and Paste

Aseprite documents Cut, Copy, and Paste as edit-menu commands [S4].
Krita documents copy and paste shortcuts for selections [S5].
Blender records actions in an undo history [S6].

LVE separates the three commands [Clipboard](../../tool-flows/transform-selection.md#clipboard-copy-cut-and-paste).
Copy captures a frame copy and a selection snapshot.
Copy writes no model cells and adds no undo action.
Cut restores a snapshot with transparent cells and records one `Cut` action.
Paste imports a pattern, previews it on the cursor, and installs only on commit.
Paste commits on click or Enter.
Paste cancels on Escape or a tool switch.
Paste records one `Paste` action.

Difference: LVE Paste is a placement mode with an explicit preview [Paste placement](../../tool-flows/transform-selection.md#paste-placement).
The Aseprite and Krita pages describe Paste as a command, not a placement transaction [S4][S5].
LVE gives the user a clear commit and cancel point.
This is an intentional difference and a useful one.

### Eyedropper

Aseprite picks the foreground or background color [S4].
It can sample all layers, the current layer, or the first reference layer.
It can pick RGB, HSV, or HSL values.
Krita samples a color from all visible layers or the active layer [S5].
It can average a radius and blend the sampled color with the current color.
MagicaVoxel uses Alt plus left button to pick a voxel color [S2].
Its renderer uses Alt plus left button to pick a voxel material [S2].

LVE copies the full material of the picked cell [Eyedropper](../../tool-flows/shared-and-utilities.md#eyedropper).
The material includes color, emission, metallic, and roughness.
The tool changes no cells.
It records one `Set Material` action.
An exact palette match selects the matching swatch.
An absent material selects no swatch.

Difference: LVE has one pick behavior, the full material.
Aseprite and Krita have color-only pickers with sampling options [S4][S5].
MagicaVoxel separates color pick and material pick [S2].
LVE is closer to the material pick.
This is an intentional difference.
A color-only modifier is a possible product decision.

### Plane and Symmetry

LVE Plane moves the floor plane [Plane](../../tool-flows/shared-and-utilities.md#plane).
A drag sets `State.floor_index`.
The X, Y, and Z keys set `State.floor_axis`.
The grid and ground picking follow the plane.
The tool opens no edit and records no undo action.

LVE Symmetry shows the mirror planes and moves their origin [Symmetry](../../tool-flows/shared-and-utilities.md#symmetry).
The X, Y, and Z keys toggle one axis.
A drag moves the origin.
The origin snaps to half units.
An open edit freezes its symmetry context.
The tool opens no edit and records no undo action.

Aseprite symmetry has horizontal and vertical axes [S4].
The user drags on-screen handles to move an axis.
A menu action resets the axis to the center.
The axis can sit in the middle of a pixel.
MagicaVoxel has mirror X, Y, and Z modes [S2].
It also has axis modes and a diagonal symmetry command [S1].
VoxEdit has mirror toggles for X, Y, and Z [S3].

LVE matches the axis toggles and the visible planes.
The LVE option bar also has origin spin boxes and a Reset button [Symmetry options](../../../plugins/Symmetry/Options.gd).
Aseprite documents a reset action and a draggable axis [S4].
Difference: LVE Symmetry records no undo action.
This is a state-only policy, not a missing control.

## Comparison table

Read `Gap` as a likely unmet expectation.
Read `Intentional` as a current LVE choice that needs a product decision before change.
Read `Open` as a question that this research cannot settle.

| Area | What users likely expect | Evidence | Current LVE behavior | Gap or intentional difference | Confidence |
| --- | --- | --- | --- | --- | --- |
| Brush add | Press adds at the aimed face. Drag continues the stroke. | S1 Brush, S2 Brush, S4 Drawing | PENCIL adds in front of the clicked face. Release or switch commits one `Stroke`. Escape aborts. | Parity. LVE Brush does not require a hit. That is a visible difference. | High |
| Eraser | Removes only existing cells. Result is transparent. | S4 Eraser, S1 Erase brush | Eraser writes only existing cells. It uses a transparent material. One `Erase` action. | Parity. | High |
| Line | Preview the path. Release confirms. Escape cancels. Shift constrains the angle. | S5 Straight Line Tool, S1 Line brush mode | Anchor, preview, release or second click or Enter commits. Escape, context, or switch drops. No documented angle modifier. | Gap for angle constraint. Intentional for switch drop. | Medium |
| Paint Brush | Recolor existing cells. Require a hit. | S1 Paint brush, S4 Drawing | Requires a hit. Recolors existing cells. One `Stroke` action. | Parity. | High |
| Fill | Contiguous flood or global match. Selection as boundary. Tolerance for similar colors. | S5 Fill Tool | Six-face flood or all matching. Selection blocks traversal and matching. Exact material match. No tolerance. No region preview. | Gap for tolerance. Intentional for no region preview. | High for barrier, Medium for tolerance |
| Spray | Count, spot size, and search area are separate. Airbrush can keep painting while held. | S5 Spray Brush Engine, S7 Airbrush, S1 Surface mode | Speed is spots per press or cell. Spot diameter is the painted sphere. Search width is the sampled area. Samples exposed voxels only. | Open for time-based flow. Intentional for surface sampling. | High for distinctions, Medium for expectation |
| Box and Lasso modes | Replace, add, subtract, intersect. | S4 Selecting, S5 Selections, S6 Selecting, S1 Selection Brushes | Replace, add, subtract. No intersect. ScreenSelection subtract also adds covered selected cells. Wand subtract does not. | Gap for intersect. Intentional for subtract detail. | High |
| Wand | Connected flood or global match. Material match. Combine modes. | S5 Selections, S1 Region Select | Six-face flood or full scan. Exact material. Current selection is not a barrier. Ignores depth and empty options. | Gap for tolerance. Intentional for exact material. | Medium |
| Visibility and depth | Select visible only or select through. Use an explicit toggle. | S6 X-Ray, S1 Rect Select, S4 Selecting | Box and Lasso have `depth_test` true by default. `include_empty` is optional. Wand ignores both. | Gap for Wand parity. Intentional for per-tool option. | Medium |
| Transform commit | Release or click confirms. Escape cancels. Exact values are available. | S6 Move, S5 Transform, S4 Transformations | Release leaves the transform pending. Enter, option bar, context, or switch commits. Escape cancels. No gizmo. | Intentional for pending release. Gap for a weak pending hint. | High for difference, Medium for gap |
| Transform snap | Grid snap, angle snap, uniform scale. | S6 Snapping, S5 Transform, S1 Rotate snap | Whole-cell move. Quarter-turn or 1 degree rotate. 0.0001 scale. Uniform option. | Parity. | High |
| Clipboard | Copy has no change. Cut has one undo. Paste has a commit and cancel point. | S4 Edit Menu, S5 Selections | Copy has no undo. Cut has one `Cut`. Paste previews, then commits one `Paste`. Escape or switch cancels. | Intentional for paste placement mode. | High for policy, Medium for expectation |
| Undo names | History names the action. | S6 Undo History | Transform action is `Stroke`. Cut is `Cut`. Paste is `Paste`. Selection names are specific. | Gap for transform name. | Medium |
| Eyedropper | Pick color. Sampling options. Sometimes pick material. | S4 Eyedropper, S5 Color Sampler, S2 Alt pick | Picks the full material. Records `Set Material`. Exact palette match. No cell change. | Intentional for full material. Open for a color-only modifier. | High for policy, Medium for expectation |
| Plane | Visible ground or grid. Move it. Switch axis. | S6 3D Cursor, S1 Ground reference | Drag sets floor index. X, Y, Z set axis. Grid and picking follow. No undo. | Intentional for state-only. No undo action. | Low |
| Symmetry | X, Y, Z toggles. Visible planes. Draggable origin. Reset to center. | S4 Symmetry, S2 Mirror Mode, S3 Mirror | X, Y, Z toggle. Planes are visible. Drag moves origin. Half-unit snap. Reset and origin fields exist. Frozen per edit. No undo. | Parity for controls. Intentional for no undo. | High |
| Feedback latency | Cursor reacts under 0.1 second. Long jobs show progress and cancel. | S9 Response Times, S10 100 ms study, S5 Instant Preview | Cursor preview is separate from model install. Jobs use workers and inline limits. Operation status exists. | Open for measured latency. This file has no measurement. | Low |

## What the performance evidence shows

| Pattern | Source | User-visible effect | Current LVE equivalent | Limit of the claim |
| --- | --- | --- | --- | --- |
| GPU ray casting and shader brushes | S1 Model Editor | Edits and view updates stay responsive on large models. | Chunk jobs and worker pool. | The manual does not prove an internal design. Do not copy it as a requirement. |
| Lower editor-mode switch latency | S1 Scene Editor | The user waits less when changing modes. | Plugin mount and unmount. | The manual gives no measurement. |
| Compressed undo with a 100 command limit | S1 Model Editor | Undo history fits in memory. | Godot `UndoRedo`. | LVE has no published command limit in this file. |
| Sparse scene storage | S8 Features and About | Large scenes do not reserve a dense volume. | Sparse chunks. | LVE makes no unlimited-size claim. |
| Lower-resolution instant preview | S5 Instant Preview | The user sees feedback while the full stroke computes. | Cursor preview is separate from model install. | LVE does not use a lower-resolution model preview. |
| Action-named undo history | S6 Undo History | The user can identify the last action. | Some LVE actions are named. Transform is generic. | This is a UX comparison, not a performance claim. |
| 0.1 second direct-manipulation limit | S9 Response Times | A result under 0.1 second feels immediate. | Not measured. | The guideline is old and general. |
| About 60 ms mouse latency perception | S10 Abstract | Mouse users can notice latency below 100 ms. | Not measured. | The study uses a simple mouse task, not a voxel editor. |

The performance evidence supports one rule.
Keep cursor feedback immediate and separate from the full job.
LVE already does this for Brush, Line, Spray, and Paste.
Do not infer speed from fewer graph nodes.
Measure the complete flow before a performance change.

## Answers to the track questions

### Which input paths cause unpredictable edits?

1. Fill has no region preview. The user cannot see the region before the press. This is a current policy.
2. Transform release leaves the edit pending. A user can think the edit is complete when it is not.
3. Spray press paints the batch that the cursor shows. A stale surface of another cell never paints. This is safe, but the rule is invisible.
4. Box and Lasso subtract keeps covered selected cells for ScreenSelection. Wand subtract does not. The same mode label can produce different results.
5. Wand ignores `depth_test` and `include_empty`. The options bar hides both controls. A user who switches from Box to Wand can lose those filters.

### Which feedback is needed before a press?

- Brush and Paint Brush need the footprint and the symmetry mirrors.
- Line needs the full path preview.
- Box and Lasso need the screen band.
- Wand needs a clear seed and a material match.
- Transform needs the source bounds and the pending offset, angle, or factor.
- Paste needs the cursor pattern and the destination selection.
- Fill needs at least a clear statement that the region is unknown until the search runs.
- Spray needs the sampled cells and the search area. The search area is not the same as the painted spots.

### Which changes preserve accepted edits?

- Brush, Paint Brush, Fill, and Spray finish or keep accepted work on a switch.
- Line drops a pending preview on a switch. A line is not accepted until the user confirms it.
- Paste cancels on a switch. Paste is not accepted until the user confirms it.
- Transform commits on a context change and on a switch.
- A selection tool applies a held outline on a switch.
- Spray keeps accepted intents in order. A repeat of the last sample is compacted. Other accepted cells stay.

Research supports explicit commit and cancel points.
It does not support a universal queue or a universal commit-on-release rule.

## Preserved LVE choices

These choices are explicit.
Do not change them from this research.

| Choice | Current behavior | Why research does not override it |
| --- | --- | --- |
| Deterministic Terrain press and crossed cells | A press and crossed cells decide the edit. The tool does not use stationary time flow. | GIMP airbrush flow is a different interaction model [S7]. It is not evidence for Terrain. |
| Build fixed plane mound | Build builds on a fixed plane. | No source in this file compares a fixed-plane mound with a surface-normal mound. |
| Spray surface sampling | Spray samples exposed voxels only. It keeps a spot center and a painted cell only when one face neighbor is empty. | MagicaVoxel has a surface mode [S1]. LVE uses an exposed-face rule, not a view-dependent surface mode. |
| Accepted edits never drop | Accepted Spray intents and stroke centers are not discarded. | No source in this file requires accepted work to be dropped when a preview changes. |
| Circle Build cursor is neutral and non-predictive | The cursor does not predict the next mound. | A predictive preview is a design choice. The latest request is in progress under another owner. |
| Transform release leaves the edit pending | Release is not a commit. | Blender confirms with the left mouse button [S6]. LVE uses a different commit boundary. |

## Open product decisions

These are decisions, not defaults.
Research shows an alternative.
It does not prove a requirement.

| Decision | Research signal | Current LVE choice | What a decision must settle |
| --- | --- | --- | --- |
| Spray time flow | GIMP airbrush can apply color while the pointer is stationary when Motion only is off [S7]. | Speed is a count per press or cell. | Add a time-based mode, or keep the deterministic cell rate. |
| Transform release | Blender confirms on left mouse button [S6]. Aseprite commits by clicking outside [S4]. | Release leaves the transform pending. | Make release commit, or keep pending and improve the hint. |
| Selection intersect | Krita, Blender, and Aseprite document intersect [S4][S5][S6]. | Replace, add, subtract only. | Add intersect, or keep three modes. |
| Fill tolerance | Krita has threshold, spread, and close gap [S5]. | Exact material match. | Add a tolerance for material similarity, or keep exact matching. |
| Eyedropper color-only | Aseprite and Krita pick color with sampling options [S4][S5]. | Pick the full material. | Add a modifier or option, or keep material-only picking. |
| Line angle constraint | Krita uses Shift for 15 degree steps [S5]. | No documented angle modifier. | Add a constraint, or keep free angles. |
| Surface-only Spray | MagicaVoxel has a surface mode [S1]. | Exposed-face sampling is unconditional. | Add a volume option, or keep surface-only. |
| Plane and Symmetry undo | LVE uses state-only utilities with no undo. | No undo action. | Add undo, or keep state-only behavior. |

## Ranked UX recommendations

Ranking method follows the [track index](README.md): impact, effort, correctness risk, and Godot 4.7.2 portability.

These are candidates.
They are not approved changes.
Each one needs a product decision before code.

| Rank | Candidate | Impact | Effort | Correctness risk | Godot portability | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Add selection intersect | High | Medium | Medium | High | S4, S5, S6, S1 |
| 2 | Name transform undo actions | Medium | Low | Low | High | S6 |
| 3 | Show a pending transform hint | Medium | Low | Low | High | S6, S5, S4 |
| 4 | Add a compact Spray readout | Medium | Low | Low | High | S5, S7 |
| 5 | Add an optional color-only Eyedropper pick | Medium | Low | Low | High | S4, S5, S2 |
| 6 | Measure press-to-preview latency | High | Medium | Low | High | S9, S10, S5 |

### 1. Add selection intersect

**Evidence.** Aseprite documents replace, add, subtract, and intersect [S4].
Krita documents replace, add, subtract, intersect, and symmetric difference [S5].
Blender documents set, extend, subtract, invert, and intersect [S6].
MagicaVoxel documents add and subtract modifiers [S1][S2].

**Fit to current flow.** Add one value to `SelectionToolSettings.SelectMode`.
Apply it in the mode step of `ScreenSelection.Job.run` and `WandJob.run`.
Keep the existing subtract detail for ScreenSelection.
Keep the existing Wand subtract rule.

**Tradeoff.** One more mode adds UI and test cases.
Subtract and intersect can be confused near empty cells.
The mode must apply after symmetry expansion, as the current modes do.

**Validation.** Manual task: make two overlapping box selections, choose Intersect, and check that only the overlap remains.
Test: add an `intersect_overlap` case to `tests/selection_modes.tscn`.
Check replace, add, subtract, and intersect in one order and in a different order.

**Confidence.** High.

### 2. Name transform undo actions

**Evidence.** Blender shows action names in the Undo History [S6].
The current LVE transform action is `Stroke` [Transform](../../tool-flows/transform-selection.md#transform-move-rotate-and-scale).

**Fit to current flow.** Pass `Move`, `Rotate`, or `Scale` through `_end` to `close_stroke` in `_commit_now`.
Keep one action per transform.
Keep the same restore and cancel behavior.

**Tradeoff.** Tests or docs that expect `Stroke` must change.
Old undo labels can differ from new labels in one session.
The change is small and local.

**Validation.** Manual task: move a selection, open the undo history, and check the label.
Test: add an action-name case to `tests/transform_workflow.tscn`.
Check Move, Rotate, and Scale.
Check that Escape still records no action.

**Confidence.** Medium to High.

### 3. Show a pending transform hint

**Evidence.** Blender confirms a move with the left mouse button [S6].
Krita documents Escape as a cancel key in its continuous transform flow [S5].
Aseprite commits by clicking outside the selection [S4].
LVE release leaves the transform pending [Transform](../../tool-flows/transform-selection.md#transform-move-rotate-and-scale).

**Fit to current flow.** Use `TransformToolSettings.transforming` and the existing commit and cancel buttons.
Show a short hint after release: `Pending: Enter to apply, Esc to cancel`.
Keep the hint visible until commit or cancel.

**Tradeoff.** The option bar gets one more line.
The hint can overlap a small viewport.
The change does not alter the commit boundary.

**Validation.** Manual task: drag Move, release, check the hint, press Enter, and check one undo action.
Repeat with Escape and check the start state.
Check the hint on Move, Rotate, and Scale.

**Confidence.** Medium.

### 4. Add a compact Spray readout

**Evidence.** Krita names the spray area, particle amount, and spacing [S5].
GIMP names Motion only, Rate, and Flow [S7].
LVE uses numeric fields with icons and tooltips for spot diameter, search width, and speed [Paint options](../../../plugins/paint/Options.gd).
The tooltips already give the exact definitions.

**Fit to current flow.** Add one read-only summary label to the Spray section.
Use a short form such as `8 spots, 1 px spot, 9 px search`.
Read the three existing values in the `_sync` function.
Do not change the fields or the tooltips.

**Tradeoff.** The option bar gets one more text item.
The summary must update when a value changes.
The summary can crowd a narrow option bar.
No write or sampling behavior changes.

**Validation.** Manual task: set speed 1 and then 8, press once, and count the spots.
Set spot diameter 1 and then 3, and check the painted sphere.
Check that the search width changes the sampled area, not the spot size.
Check that the summary matches the three controls after each change.

**Confidence.** Medium.

### 5. Add an optional color-only Eyedropper pick

**Evidence.** Aseprite picks color with RGB, HSV, or HSL options [S4].
Krita samples color with a radius and a blend amount [S5].
MagicaVoxel separates color pick from material pick [S2].
LVE picks the full material [Eyedropper](../../tool-flows/shared-and-utilities.md#eyedropper).

**Fit to current flow.** Add a modifier or an option-bar toggle.
The current `EyedropperTool.apply` reads four material values.
A color-only pick reads the color value and leaves emission, metallic, and roughness unchanged.
Keep `Set Material` as one undo action.
Keep the palette match behavior.

**Tradeoff.** Two pick modes add a discoverability problem.
A modifier can conflict with camera or selection input.
The option bar must show which mode is active.
The default must stay full material until a product decision.

**Validation.** Manual task: pick a cell with emission or metallic, use color-only, and check that only the color changes.
Use the full pick and check that all four values change.
Test: add a `color_only_pick` case to `tests/material_painting.tscn`.
Check the palette swatch match after each mode.

**Confidence.** Medium.

### 6. Measure press-to-preview latency

**Evidence.** NN/g sets 0.1 second as the direct-manipulation limit [S9].
A 2017 mouse study reports perception thresholds near 60 ms [S10].
Krita uses a lower-resolution preview while the full stroke computes [S5].

**Fit to current flow.** Add timestamps at press and at preview install.
Use the existing `VoxelPreview` and `State.run_edit_job` boundaries.
Measure Brush, Spray, and Transform at 256 cubed, or at the largest supported document size.
Report p50 and p95 for press to cursor preview and press to model install.

**Tradeoff.** Instrumentation adds code and test time.
The result can show a problem without a fix.
Do not add a lower-resolution model preview before the measurement.

**Validation.** Proposed experiment: 100 strokes per tool at that size.
Pass condition: p95 press-to-preview is below 100 ms.
Target: p95 press-to-preview is below 60 ms for mouse input.
If p95 press-to-install exceeds 1 second, add a progress or cancel hint.
Keep the current cursor preview separate from the model install.

**Confidence.** Medium.

## Unverified assumptions and limits

1. This file did not run the editor or the test suite. Current behavior comes from the flow maps and code reading.
2. This file did not measure latency, memory, or frame time. All performance statements are source claims or inferences.
3. The manuals describe user-visible behavior. This file does not claim to know the internal design of closed-source editors.
4. VoxEdit documentation is image-heavy. Some modifier details are not in the text.
5. Aseprite pages do not state a patch version. This file treats them as 1.3 documentation. The source date is the site copyright year.
6. The Krita manual is version 5.3.0. The current Krita release can be newer.
7. MagicaVoxel documentation is a changelog, not a task-by-task manual. Some behavior comes from update notes.
8. Goxel has no full task manual. The source is its README and official site.
9. The 0.1 second and 60 ms limits come from general interaction studies. They are not voxel-editor measurements.
10. This file did not inspect Aseprite source code. It used published manuals only.
11. The Build cursor implementation is outside this file. Another owner is changing it.
12. The source count is 10. Eight are product manuals or product documents. Two are UX sources.

## Access log

All URLs were fetched on 2026-10-24.

| ID | Fetch result |
| --- | --- |
| S1 | Read the official MagicaVoxel readme page, including the update log and FAQ. |
| S2 | Read the official MagicaVoxel shortcuts page. |
| S3 | Read the VoxEdit Modeler and Use Modes & Tools Together pages. |
| S4 | Read the Aseprite Drawing, Selecting, Transformations, Eyedropper, Symmetry, Undo History, Edit Menu, and Eraser pages. |
| S5 | Read the Krita Transform, Fill, Color Sampler, Selections, Spray, Line, and Instant Preview pages. |
| S6 | Read the Blender Move, Selecting, X-Ray, Undo, and Snapping pages. |
| S7 | Read the GIMP Airbrush page. |
| S8 | Read the Goxel README and official site. |
| S9 | Read the NN/g response-time article. |
| S10 | Read the University of Luebeck publication record and abstract. |

## Change log

- 2026-10-24: First READY version. Ten sources. No code or test changes.
