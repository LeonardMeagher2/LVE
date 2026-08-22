---
max_active: 1
---

# Tools
- [ ] Fix the move tool
  - [ ] After a move, the selection must keep the moved cells. It now keeps the old coordinates, so a second grab misses.
  - [ ] Show a gizmo so the destination is visible before release
  - [ ] Show a gizmo for rotation with snapping
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
