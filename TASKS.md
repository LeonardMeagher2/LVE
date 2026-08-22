---
max_active: 1
---

# Tools
- [x] Fix the move tool
  - [x] Voxels move live during the drag, so the moved cells stay grabbable
  - [x] Displaced voxels are stored and restored on the next drag, so sweeping destroys nothing
  - [x] A click on the selection commits. A click outside cancels and restores.
- [x] A selection is an edit mask. All tools edit only inside it.
  - [x] With no selection, the move tool moves all cells.
  - [x] The select tool click cancels an existing selection or makes a one-cell selection.
  - [ ] Extend the mask to more tools as they are added
- [ ] Brushing drawing plane should not depend on the starting location of the brush, but only on the view direction. This is to avoid having different voxel starting locations paint on different planes, it's confusing and not intuitive.


# Palette
- [ ] Drag to reorder palette swatches (add/remove are done)
- [ ] Preset palettes (load/save)
- [ ] Default palette for new documents
- [ ] Adding a color should be manual not automatic


# Selection
- [ ] Copy selection to clipboard
- [ ] Paste selection at an offset
- [ ] First mode: select a flat section on the press plane
- [ ] After the section is set, expand the volume along the 3rd axis by dragging the mouse. Might be good to even auto rotate the view if the 3rd axis isn't easily visible. The 3rd axis is the one perpendicular to the press plane.
- [ ] Visual feedback for both phases


# Symmetry
- [ ] Symmetry axis + plane toggle
- [ ] Mirror brush/paint strokes across the plane
- [ ] Mirror a selection across an axis
- [ ] Mirror in place and to a copy


# Primitives
- [ ] Sphere, box, cylinder fill primitives in a tool menu
- [ ] Place a saved voxel file as a stamp


# Onion skinning
- [ ] Ghost previous/next frames behind the current frame
- [ ] toggle and strength control


# Animation Tags
- [ ] UI for the existing tag data (create, edit, delete named frame groups)
- [ ] Loop-mode and repeat controls per tag


# Responsive UI
- [ ] Make the panels adjustable in size (resizable splitters between the left, center, and right panes)
- [ ] Detect narrow layouts and adapt the layout, so the editor can run on a phone
