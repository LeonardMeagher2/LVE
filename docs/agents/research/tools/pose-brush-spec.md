# Pose Brush: Behaviour Specification

This document gives the behaviour and the options of the voxel Pose brush. It contains no implementation detail.
Blender facts come from the pages in [References](#references). A claim that I could not confirm carries the word "unconfirmed".
Current shipped behavior is in [Deform tool flows](../../tool-flows/deform.md#pose). This page records design history.

## 1. Purpose

The Pose brush bends the occupied cells inside the brush about a joint.
It gives an armature-like result without a rig [R1].
The user poses a limb one brush span at a time, then commits the result as one stroke.

## 2. The gesture

- The pointer shows a ring of cells. The ring diameter equals the brush size [R2].
- On press, the brush captures the occupied cells inside the brush ball. The captured set stays fixed for the stroke, as with Grab [R5].
- On drag, the pointer sets the bend angle only. The joint stays still.
- On release, the stroke commits as one undo action.
- On Escape, every captured cell returns to its first position. The stroke adds no undo action.
- Radial pointer motion, toward or away from the joint, changes no angle.

## 3. The joint

- The joint is one point in cell space. It is the only centre of rotation.
- The brush takes the occupied cells inside the brush ball. This set is the limb.
- The captured set joins cells through the Connected neighbor set. On uses faces. Off adds edges and corners.
- The joint search walks the brush ball through occupied cells. With Connected on, it uses the six face neighbors. Off adds every edge and corner neighbor.
- The bound keeps the walk local, so a connected model cannot send it across the whole frame.
- The joint is that entry cell, so it always sits on an occupied cell of the limb.
- Before the press, the cursor shows the joint as a dot and the bone from the joint to the picked cell. Blender shows its pose origin as a white line on the brush cursor [R1].
- During the drag, the joint stays drawn on top of the preview.
- A press on an empty cell shows no joint and starts no stroke.

## 4. Affected region

Every occupied cell inside the brush on the tip side of the joint moves.
The brush joins face neighbors when Connected is on.
Off adds edge and corner neighbors, as Blender's Connected Only does when it is off [R1].

Tradeoff: a local bend keeps the rest of the model still. A long limb bends one
brush span per stroke, so the user moves the brush along the limb.

## 5. The rotation

- The axis is the view direction through the joint. The bend therefore lies in the screen plane.
- A mirrored copy turns about the mirror of that axis, by the mirror of the angle. The bend of a copy can therefore leave the screen plane, so the two sides stay exact mirrors from any view.
- The axis passes through the joint and does not move during the stroke.
- The arm runs from the joint to the pointer. The angle is the screen angle from the bone to that arm, so the tip lands under the pointer.
- Radial pointer motion, toward or away from the joint, changes no angle.
- No option caps the angle. The fit is the only limit.
- When the pointer leaves the viewport, the angle holds at its last value. The stroke continues.
- When the view looks along the limb axis, the same rule gives a twist about that axis. The joint does not move, so the limb keeps its length.
- A twist changes the silhouette only if the limb cross-section is not round. The preview shows the result before the release.

## 6. Joint blend

- The brush gives each moved cell a share of the full angle.
- The share grows with the distance from the joint along the limb. The joint cell stays. The share reaches 1 at the near edge of the band. The base ends the walk, so its side neighbors are not captured. Cells behind the joint are not captured.
- The edge falloff sets the width of the blend band. Blender's falloff curve maps distance to brush strength in the same way [R3].
- At falloff 0, the band is one cell wide. The limb folds with a sharp crease at the joint.
- At falloff 1, the half width reaches the brush size, and it stops at two cells. The limb bends in an arc without shearing the rest.
- The capture never reaches past the joint or the limb tip.
- A sharp crease keeps the cells on the outer side and pinches the inner side. The brush adds no cell to close the pinch.
- Blender's Hardness sets how near the edge the falloff starts [R6]. This editor uses the shared edge falloff for the same purpose.

## 7. Materials

- A moved cell keeps its own material. The brush never copies the material of a neighbour.
- Cells that the bend leaves behind become empty. The brush adds no cell.
- When two moved cells land on one cell, the cell farther from the joint keeps its material. The user aims at the tip.
- A cell outside the selection keeps its material and its position.

## 8. Options

| Option | Range or values | Default | Effect |
| --- | --- | --- | --- |
| Brush size | 1 to 32 cells, as a diameter | 4 | Sets the ring and the captured set. Blender states that only Size and Auto-Masking change this brush [R1]. |
| Edge falloff | 0 to 1 | 0.5 | Sets the width of the joint neck (section 6) [R3]. |
| Connected | on or off | off | Limits the joint search and the captured set to the six face neighbors. Off adds edge and corner contacts. |
| Snap | on or off | off | Rounds the requested angle to a quarter turn before the fit (section 5). |
| Mirror planes | X, Y, Z | as set | Repeats the bend through each active plane [R4]. |

The brush size and the edge falloff are the shared inputs of the tool set.
The cell selection is not an option. It always limits the brush, like the transform tools.

## 9. Limits and edge cases

- **Limb larger than the brush.** Only the cells inside the brush move. The user moves the brush along the limb for the next span. The joint still sits at the brush edge.
- **Limb that touches unrelated geometry.** A shared face connects the shapes. With Connected off, a shared edge or corner also connects them.
- **Bend that leaves the writable slice or the document limit.** The brush lowers the angle until every moved cell fits. If no angle fits, the brush shows a blocked state and the stroke does nothing.
- **Bend that leaves the selection.** Only selected cells move. An unselected occupied cell blocks the bend. The brush lowers the angle until no moved cell lands on one.
- **No selected cell in the picked set.** The brush shows a blocked state and starts no stroke.
- **Symmetry.** The brush repeats the bend on each mirrored copy. Each active X, Y, and Z plane gives one copy [R4]. Each copy turns the mirror of the primary turn about the mirror of the primary axis, so the result stays an exact mirror from any view. It lowers one angle for all copies. An obstacle on one side limits both sides.
- **Cell on a mirror plane.** A cell that maps to itself counts once.
- **Escape during a drag.** The preview clears at once. The cells return to their first position.

## 10. Behaviour that this editor must not copy

- **Scale/Translate and Squash/Stretch deformation types** [R1]. A voxel limb cannot stretch without added or removed cells.
- **Face Sets and Face Sets FK rotation origins** [R1]. This editor has no face sets. The brush is the unit.
- **Max Element Distance** [R1]. Cells are adjacent or not adjacent, so no search distance is necessary.
- **Auto-masking** [R1]. The editor uses an explicit cell selection.
- **A free-moving root**, which Blender permits when Keep Anchor Point is off and which gives snake-like shapes [R1]. That behaviour duplicates Grab. The Pose brush always keeps the root fixed.
- **The IK solver** [R7]. A solver balances many segments against a target. The editor turns one rigid limb about one joint, so it needs no solver.
- **Symmetry Feather** [R4]. Feather needs a continuous strength value. A voxel cell is occupied or empty.
- **The cloth deformation target** [R1]. A voxel document has no cloth.

## References

- [R1] Pose brush, Blender 5.3 Manual: https://docs.blender.org/manual/en/latest/sculpt_paint/sculpting/brushes/pose.html
- [R2] Cursor, Blender 5.3 Manual: https://docs.blender.org/manual/en/latest/sculpt_paint/brush/cursor.html
- [R3] Falloff, Blender 5.3 Manual: https://docs.blender.org/manual/en/latest/sculpt_paint/brush/falloff.html
- [R4] Symmetry, Blender 5.3 Manual: https://docs.blender.org/manual/en/latest/sculpt_paint/sculpting/tool_settings/symmetry.html
- [R5] Grab brush, Blender 5.3 Manual: https://docs.blender.org/manual/en/latest/sculpt_paint/sculpting/brushes/grab.html
- [R6] Shape, Blender 5.3 Manual: https://docs.blender.org/manual/en/latest/sculpt_paint/brush/shape.html
- [R7] Inverse Kinematics, Blender 5.3 Manual: https://docs.blender.org/manual/en/latest/animation/armatures/posing/bone_constraints/inverse_kinematics/introduction.html

## Research notes

- The Brush Settings parent page has no settings text in the current manual. It lists subpages only. The 4.2 page does the same, so I used the subpages [R2], [R3], and [R6].
  See https://docs.blender.org/manual/en/4.2/sculpt_paint/sculpting/tool_settings/brush_settings.html
- The page https://docs.blender.org/manual/en/latest/sculpt_paint/sculpting/brush/brush_settings.html does not exist. The server returns 404.
- The Size, Strength, and Normal Radius links on the Grab page point to anchors on that parent page. Their definitions are therefore unconfirmed here [R5].
- The rotation axis of Blender's Ctrl twist is unconfirmed. The Pose page states only that Ctrl applies a twist rotation and disables IK segments [R1].
- The default values in section 8 are choices for this editor. Blender states no default for them on the cited pages.

## Current behaviour

The shipped Pose rules are in [Deform tool flows](../../tool-flows/deform.md#pose).
This page records the design research and the Blender evidence.
