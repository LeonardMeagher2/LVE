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
  - [x] Pressing Delete erases the voxels inside the selection from any tool.
- [x] Brushing drawing plane should not depend on the starting location of the brush, but only on the view direction. This is to avoid having different voxel starting locations paint on different planes, it's confusing and not intuitive.
  - [x] The plane axis comes from the camera forward, not the per-pixel ray normal
  - [x] The painted layer stays anchored to the clicked voxel

# Export/Import
- [ ] Save/load the current document to a json file, including all frames, tags, and palette
- [ ] Export to GLB and OBJ formats
- [ ] Import image files as a voxel grid (png, jpg, bmp, aseprite)

# Palette
- [ ] Drag/Drop to reorder palette swatches (add/remove are done)
- [ ] Preset palettes (load/save)
- [ ] Default palette for new documents (can set palette as the default any time)
- [ ] Adding a color should be manual not automatic


# Selection
- [x] Box and lasso select every cell in the region, including empty space
- [x] With a selection active, edits stay inside the selected cells
- [x] Wand select selects all connected voxels of one color
  - [x] Shift click adds a region to the selection
  - [x] A click on empty space clears the selection
- [x] Lasso select selects a freeform area on the press plane
  - [x] The loop selects the cells inside it, including empty cells
  - [x] Shift drag unions with the current selection
  - [x] A click without a drag selects one cell or cancels the selection
- [x] Selections render as continuous outline lines; edges buried or inside flat surfaces render none
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
