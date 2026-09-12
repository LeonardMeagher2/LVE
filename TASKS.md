---
max_active: 1
---

# Tools
- [x] floor plane
  - [x] Allow picking on any side of the "floor" plane, not just the top
  - [x] Add option to change the floor plane to a different axis (X, Y, Z)
  - [x] Add option to move the floor plane up and down along the axis
- [ ] Migrate the Transform and Plane tools to plugins
  - [x] Add the Fill plugin (button, connected option)
  - [x] Add the Selection plugin (MenuButton: box, lasso, wand; mode picker, clear, connected)
  - [x] Add the Transform plugin (MenuButton: move, rotate; snap, commit, cancel)
  - [x] Add the Plane plugin (button, axis picker)
  - [x] Register the plugins in the toolbar in order
  - [x] Fix the eyedropper shortcut and tooltip
  - [x] Delete the dead tool scripts, scenes, option widgets, and ToolInfo resources
  - [ ] Ask the user to test the Transform and Plane tools manually
- [ ] Line tool
  - [ ] Click to start, click to end, or click and drag to draw a line
- [ ] Extrude tool
  - [ ] Selection of voxels extruded along plane normal, with a drag to set the distance
- [x] Move tool
  - [x] Remove auto creation of voxel selection object when no voxels were in a selection
  - [x] Add a "commit" button to the move tool, so that the user can move voxels and then commit or cancel the move
  - [x] Switching to another tool while moving voxels should commit the move
- [x] Rotate tool (group with move tool)
  - [x] Selection of voxels rotated around the center of the selection, with a drag to set the angle
  - [x] Add a "commit" button to the rotate tool, so that the user can rotate voxels and then commit or cancel the rotation
  - [x] Switching to another tool while rotating voxels should commit the rotation
- [ ] Scale tool (group with move tool)
  - [ ] Selection of voxels scaled around the center of the selection, with a drag to set the scale
  - [ ] Add a "commit" button to the scale tool, so that the user can scale voxels and then commit or cancel the scale
  - [ ] Switching to another tool while scaling voxels should commit the scale
  - [ ] Add a "uniform scale" option to the scale tool, so that the user can scale voxels uniformly in all directions

# Export/Import
- [ ] Save/load the current document to a json file, including all frames, tags, and palette
- [ ] Export to GLB and OBJ formats
- [ ] Import image files as a voxel grid (png, jpg, bmp, aseprite)
- [ ] Export a sprite sheet of the animation frames
  - [ ] Build the export UI
  - [ ] Render each frame with a transparent background

# Palette
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
- [x] UI for the existing tag data (create, select via dropdown, and delete named frame groups)
- [x] Rename a tag in edit mode (dropdown becomes a name field)
- [x] Change a tag's frame range with the timeline grab handles
- [x] Loop-mode and repeat controls per tag
- [x] Keep a default tag so the base animation has a loop mode
- [x] Adjust tag ranges when frames are removed
- [x] Always show the tag editing controls, drop the edit-mode toggle


# Timeline
- [x] Drag frames on the timeline to reorder them


# Responsive UI
- [ ] Detect narrow layouts and adapt the layout, so the editor can run on a phone
