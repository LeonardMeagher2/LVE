---
max_active: 1
---

# Viewport
- [x] Move the view controls into the control bar as a camera menu
  - [x] Axis views: top, bottom, front, back, left, right, isometric
  - [x] Perspective/Ortho toggle that keeps the framing
  - [x] Unshaded toggle via the viewport debug draw mode
  - [x] Pan mode toggle: left-drag pans instead of painting


# Tools
- [ ] floor plane
  - [ ] Allow picking on any side of the "floor" plane, not just the top
  - [ ] Add option to change the floor plane to a different axis (X, Y, Z)
  - [ ] Add option to move the floor plane up and down along the axis
- [ ] Line tool
  - [ ] Click to start, click to end, or click and drag to draw a line
- [ ] Extrude tool
  - [ ] Selection of voxels extruded along plane normal, with a drag to set the distance
- [ ] Move tool
  - [ ] Remove auto creation of voxel selection object when no voxels were in a selection
  - [ ] Add a "commit" button to the move tool, so that the user can move voxels and then commit or cancel the move
  - [ ] Switching to another tool while moving voxels should commit the move
- [ ] Rotate tool (group with move tool)
  - [ ] Selection of voxels rotated around the center of the selection, with a drag to set the angle
  - [ ] Add a "commit" button to the rotate tool, so that the user can rotate voxels and then commit or cancel the rotation
  - [ ] Switching to another tool while rotating voxels should commit the rotation
- [ ] Scale tool (group with move tool)
  - [ ] Selection of voxels scaled around the center of the selection, with a drag to set the scale
  - [ ] Add a "commit" button to the scale tool, so that the user can scale voxels and then commit or cancel the scale
  - [ ] Switching to another tool while scaling voxels should commit the scale
  - [ ] Add a "uniform scale" option to the scale tool, so that the user can scale voxels uniformly in all directions
- [x] Add undo and redo buttons to the toolbar
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
- [ ] Adding a color should be manual not automatic
- [ ] Palette should allow duplicate colors
- [ ] Modifying the palette should add undo/redo support
- [ ] Drag to select multiple swatches
- [ ] Dragging a selection of swatches moves them to a new location in the palette
- [ ] Palette toolbar
  - [ ] Add/Remove
  - [ ] Load/Save/Set default palette
  - [ ] Sort
    - [ ] reverse
    - [ ] By hue, saturation, and brightness
    - [ ] By Red, Green, Blue
  - [ ] Create gradient between first and last selected swatches replacing the selected swatches between them


# Selection
- [x] Fix UI bug where disabled "clear seletion" button changes size
- [x] Box and lasso select every cell in the region, including empty space
- [x] With a selection active, edits stay inside the selected cells
- [x] Wand select selects all connected voxels of one color
  - [x] Shift click adds a region to the selection
  - [x] A click on empty space clears the selection
- [x] Lasso select takes the swept tiles plus the area the point loop encloses
  - [x] The drag selects the crossed tiles, including empty cells
  - [x] The loop also fills the cells inside it on the press plane
  - [x] Shift drag unions with the current selection
  - [x] A click without a drag selects one cell or cancels the selection
  - [x] The whole growing selection stays visible during the drag
- [x] Selections render as continuous outline lines; edges buried or inside flat surfaces render none
- [x] Selection modes in the tool option bar
  - [x] Replace mode makes each drag start a fresh selection
  - [x] Additive mode adds the drag result to the selection
  - [x] Subtractive mode takes the dragged cells out of the selection
  - [x] An empty click cancels the selection in every mode
  - [x] Shift drag adds in any mode; pixel perfect lives as the pencil option
- [ ] Copy selection to clipboard
- [ ] Paste selection at an offset
- [ ] First mode: select a flat section on the press plane
- [ ] After the section is set, expand the volume along the 3rd axis by dragging the mouse. The 3rd axis is along the normal of the press plane. The drag distance sets the depth of the volume.
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
