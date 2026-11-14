# Pose Brush: Behaviour Specification

This document gives the behaviour and the options of the voxel Pose brush. It contains no implementation detail.
Blender facts come from the pages in [References](#references). A claim that I could not confirm carries the word "unconfirmed".

## 1. Purpose

The Pose brush bends one limb of occupied cells about a joint.
It gives an armature-like result without a rig [R1].
The user poses a limb or corrects its proportions, then commits the result as one stroke.

## 2. The gesture

- The pointer shows a ring of cells. The ring diameter equals the brush size [R2].
- On press, the brush captures the cells that the ring touches. The captured set stays fixed for the stroke, as with Grab [R5].
- On drag, the pointer sets the bend angle only. The joint stays still.
- On release, the stroke commits as one undo action.
- On Escape, every captured cell returns to its first position. The stroke adds no undo action.
- Radial pointer motion, toward or away from the joint, changes no angle.

## 3. The joint

- The joint is one point in cell space. It is the only centre of rotation.
- The brush takes the occupied cells that touch the ring. This set is the limb.
- The brush walks the connected cells from the picked cell and stops at the brush radius. The farthest cell of that walk is the joint.
- The bound keeps the walk local, so a connected model cannot send it across the whole frame.
- The joint is that entry cell, so it always sits on an occupied cell of the limb.
- Before the press, the cursor shows the joint as a dot and the bone from the joint to the picked cell. Blender shows its pose origin as a white line on the brush cursor [R1].
- During the drag, the joint stays drawn on top of the preview.
- A press on an empty cell shows no joint and starts no stroke.

## 4. Affected region

Every occupied cell on the tip side of the joint moves.
The brush uses face-connected cells only, as Blender's Connected Only does [R1].

Tradeoff: a limb keeps the silhouette smooth. It moves every connected cell, so a touching shape moves too. A cell selection keeps the bend local.

## 5. The rotation

- The axis is the view direction through the joint. The bend therefore lies in the screen plane.
- The axis passes through the joint and does not move during the stroke.
- The arm runs from the joint to the pointer. The angle is the screen angle from the bone to that arm, so the tip lands under the pointer.
- Radial pointer motion, toward or away from the joint, changes no angle.
- No option caps the angle. The fit is the only limit.
- When the pointer leaves the viewport, the angle holds at its last value. The stroke continues.
- When the view looks along the limb axis, the same rule gives a twist about that axis. The joint does not move, so the limb keeps its length.
- A twist changes the silhouette only if the limb cross-section is not round. The preview shows the result before the release.

## 6. Joint blend

- The brush gives each moved cell a share of the full angle.
- The share grows with the distance from the joint along the limb. It runs from 0 at the far edge of the band to 1 at its near edge.
- The edge falloff sets the width of the blend band. Blender's falloff curve maps distance to brush strength in the same way [R3].
- At falloff 0, the band is one cell wide. The limb folds with a sharp crease at the joint.
- At falloff 1, the half width reaches the brush size, and it stops at two cells. The limb bends in an arc without shearing the rest.
- The band never reaches past the limb root or the limb tip.
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
| Mirror planes | X, Y, Z | as set | Repeats the bend through each active plane [R4]. |

The brush size and the edge falloff are the shared inputs of the tool set.
The cell selection is not an option. It always limits the brush, like the transform tools.

## 9. Limits and edge cases

- **Limb larger than the view.** Every connected cell moves. The user must use a cell selection. The joint still sits at the brush edge.
- **Limb that touches unrelated geometry.** A shared face makes one limb, so the bend moves both shapes.
- **Bend that leaves the writable slice or the document limit.** The brush lowers the angle until every moved cell fits. If no angle fits, the brush shows a blocked state and the stroke does nothing.
- **Bend that leaves the selection.** Only selected cells move. An unselected occupied cell blocks the bend. The brush lowers the angle until no moved cell lands on one.
- **No selected cell in the picked set.** The brush shows a blocked state and starts no stroke.
- **Symmetry.** The brush repeats the bend on each mirrored copy. Each active X, Y, and Z plane gives one copy [R4]. It lowers one angle for all copies, so the result stays symmetric. An obstacle on one side limits both sides.
- **Cell on a mirror plane.** A cell that maps to itself counts once.
- **Escape during a drag.** The preview clears at once. The cells return to their first position.

## 10. Behaviour that this editor must not copy

- **Scale/Translate and Squash/Stretch deformation types** [R1]. A voxel limb cannot stretch without added or removed cells.
- **Face Sets and Face Sets FK rotation origins** [R1]. This editor has no face sets. The limb is the unit.
- **Max Element Distance** [R1]. Cells are adjacent or not adjacent, so no search distance is necessary.
- **Connected Only as an option** [R1]. A merged set would move geometry that the user did not pick. The editor always uses face connection.
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

## Final rules after the playable builds

These rules supersede the earlier sections where they differ. They match the
shipped tool.

- The joint comes from the connected cells, not from a fixed offset or an axis
  estimate. The search walks the limb from the press and stops at the brush
  radius. It does not walk back. The joint is the farthest cell of that walk,
  so it always sits on an occupied cell.
  The bound keeps the walk local, so a connected model cannot send the search
  across the whole frame.
- The pointer is the tip of the bone. The arm runs from the joint to the pointer,
  and the angle is the screen angle from the bone to that arm. A travel-based
  angle leaves the tip off the pointer.
- The cursor shows the joint and the bone. It shows no cell count.
- The option bar holds the size and the falloff, shared with Grab. Blend passes,
  joint count, joint offset, and the angle limit are gone. A
  single rigid turn is easier to predict, and the falloff already softens the
  joint neck.
- The cell selection limits the limb search and the captured cells. The moved
  cells may land outside it, and the selection then follows them. The transform
  tools work this way: a transform moves the selection, and a write filter on the
  destination would make a small selection unmovable. Grab keeps the same rule.
- A drag that returns to its first position restores the press selection.
- A turn is a rigid resample. Each destination cell samples one source cell, and
  each source that the resample misses writes exactly one cell. A source never
  draws a line to its destination. A line fill turns a thin limb into a solid fan
  on a wide brush.