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
- [x] Line tool and shared brush shapes
  - [x] Add Line to the Pencil and Paint menu
  - [x] Click to start, click to end, or click and drag to draw a line
  - [x] Preview the line before committing one undo action
  - [x] Cancel the preview with Escape or a tool change
  - [x] Add a brush diameter option with a minimum of one
  - [x] Add cube and sphere brush shapes
  - [x] Copy a selection as a brush shape with its original colors
  - [x] Use icons for the brush option controls
  - [x] Select brush shapes with grouped icon buttons
  - [x] Use selected voxels or all frame voxels for the voxel brush
  - [x] Use the selection icon for the voxel brush
  - [x] Add Eraser to the brush menu with the shared diameter and shapes
  - [x] Keep solid Brush and Line previews and outline Eraser previews
  - [x] Separate the shape, size, stroke, and clipboard controls
  - [x] Prepare large brush shapes and strokes on workers
  - [x] Verify volume brushes, selection masks, undo, cancellation, and frame changes
  - [x] Run the full behavior suite
    - 71 tests report a pass. `selection_modes` retains the six known failures.
    - `tag_range` retains its existing grip-text errors.
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
- [x] Scale tool (group with move tool)
  - [x] Selection of voxels scaled around the center of the selection, with a drag to set the scale
  - [x] Add a "commit" button to the scale tool, so that the user can scale voxels and then commit or cancel the scale
  - [x] Switching to another tool while scaling voxels should commit the scale
  - [x] Add a "uniform scale" option to the scale tool, so that the user can scale voxels uniformly in all directions

# Rendering and storage
- [ ] Distribute expensive jobs across the worker threads available on each system
  - [ ] Use chunk work groups for independent matching and edit work
  - [ ] Preserve cancellation, bounded publication, and UI responsiveness
- [x] Group adjacent radio items in the camera menu
- [x] Keep voxel edits fast and report long-running activity
  - [x] Track overlapping foreground and background operations
  - [x] Report surface generation and selection outlines
  - [x] Prepare large transforms, fills, and selection erases on workers
  - [x] Apply voxel changes by chunk and send one preview notification
  - [x] Keep small edits immediate and use the latest drag input
  - [x] Limit sparse scaling to occupied chunk regions
  - [x] Verify completion, cancellation, and context changes
  - [x] Review the full suite and run focused checks for final changes
    - The full run passed 64 tests.
    - The activity test used the wrong clock. The corrected test passes.
    - `selection_modes` retains the six known failures.
    - The new sparse-scale test and the final storage checks pass.
  - Scale 32,768 voxels to 262,144 voxels at 60 FPS:
    - The edit time decreased from 5.95 seconds to approximately 0.98 seconds.
    - The longest edit-frame interval decreased from 57 milliseconds to approximately 31 milliseconds.
    - The edit sends one notification instead of 256 notifications.
    - A windowed run completed rendering in approximately 1.52 seconds.
  - Scaling two distant voxels completed in approximately two milliseconds in a headless run.
- [x] Build cached chunk surfaces and compact document storage
  - [x] Store edits in copy-on-write chunks
  - [x] Share selection snapshots until the next edit
  - [x] Save empty and uniform regions as octree leaves
  - [x] Generate greedy surfaces on worker threads
  - [x] Keep completed surfaces visible during drawing
  - [x] Generate large selection outlines on worker threads
  - [x] Reuse cached surfaces across frames and thumbnails
  - [x] Coalesce thumbnail requests after edit bursts
  - [x] Run the full behavior suite
    - 61 tests pass. `selection_modes` fails six checks on the unchanged project.
- [x] Remove the flat-cell compatibility layer
  - [x] Use the chunk API in all frame callers and tests
  - [x] Remove the legacy resource fixture
  - [x] Run the full behavior suite
- [x] Review names in the storage and rendering code
  - [x] Use names that show each variable's purpose or contents
  - [x] Use a typed frame reference in picking requests
  - [x] Run the full behavior suite
- [x] Bound the surface cache when chunks have no visible faces
  - [x] Evict empty surface entries and clear stale display records
  - [x] Verify repeated enclosed-voxel edits and frame switching
  - [x] Run the full behavior suite

# Export/Import
- [x] Export voxel meshes and animation clips as glTF and GLB
  - [x] Add an export button with its own icon and file dialog
  - [x] Reuse greedy meshing and build export meshes on a worker
  - [x] Preserve frame delays, empty frames, colors, and tag names
  - [x] Bake tag directions and finite repeats into stepped scale tracks
  - [x] Verify glTF and GLB import with the focused export test
  - [x] Verify imported vertex-color flags and shared materials across all surfaces
  - [x] Center all frame meshes with one shared offset
  - [x] Export only tag clips and preserve infinite looping on Godot import
  - [x] Move the exporter and its MenuBar control into a dedicated plugin
  - [x] Use core glTF scale animation with no animation-method selection
  - [x] Verify frame switches, delays, and looping with scale tracks
  - [x] Merge same-color coplanar export faces across chunk boundaries
  - [x] Weld epsilon-close vertices before and after export simplification
  - [x] Preserve sharp normals and color boundaries during welding
  - [x] Verify color boundaries, cavities, sparse shapes, and triangle reductions
  - See [GLTF_EXPORT.md](GLTF_EXPORT.md) for the format and import settings.
- [x] Open PNG images as voxel documents
  - [x] Clip pixels below 0.5 alpha and make retained pixels opaque
  - [x] Fill the palette with distinct retained image colors
  - [x] Center occupied content on the nearest origin-aligned voxel grid
  - [x] Read matching Aseprite JSON sidecars in array and hash formats
  - [x] Preserve frame timing, trim offsets, tag ranges, directions, and repeats
  - [x] Honor the example's custom `no_loop` tag marker
  - [x] Use one centering offset across animation frames
  - [x] Prepare images and voxel frames on workers
  - [x] Verify PNG loading, black swatches, cancellation, and the Dog example
  - [x] Use a self-contained Aseprite fixture for the behavior test
  - The final full run reported 79 passes and the six known windowed selection failures.
  - The Dog fixture was removed during the run. The self-contained Aseprite rerun passes.
- [ ] Import other image formats (jpg, bmp, aseprite files)
- [ ] Export a sprite sheet of the animation frames
  - [ ] Build the export UI
  - [ ] Render each frame with a transparent background

# Palette
- [x] Initialize black swatch backgrounds and tooltips
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
- [x] Preselect mode buttons from the stored selection state
  - [x] Keep the buttons synchronized when the tool or mode changes
  - [x] Verify the selection mode state and behavior tests
- [x] Prepare large wand selections as batched worker jobs
  - [x] Reuse the fill matching and connected search
  - [x] Publish one complete selection with undo and context cancellation
- [x] Copy selected voxels or all frame voxels to the clipboard
- [x] Paste voxels at an offset with a preview and one undo action
  - [x] Share Copy and Paste controls across Brush, Selection, and Transform
  - [x] Add Cut, Copy, Paste, and Delete controls to the shared editing plugin
  - [x] Add Ctrl+X, Ctrl+C, Ctrl+V, and Delete shortcuts
  - [x] Cut a selection or the whole frame with one undo action
  - [x] Delete selected voxels with the Delete key and one undo action
  - [x] Preserve voxel colors and relative positions across documents
  - [x] Prepare large copies and paste previews on workers
  - [x] Cancel paste previews on tool and frame changes
  - [x] Remove paste previews after the input event finishes
  - [x] Retain the input viewport when a tool detaches during its input handler
  - [x] Verify Cut, Delete, paste input, undo, cancellation, and large clipboard operations
    - The full run reported 73 passes and the known `selection_modes` failure.
    - The surface-cache test used a scene changed during the run. Its focused rerun passes.
    - The windowed paste, Cut, and Delete tests pass.
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
- [x] Snap playback to the selected tag bounds
  - [x] Start forward and reverse playback at the correct boundary
  - [x] Resnap when the selected tag changes during playback
  - [x] Bound current frame indices and handle single-frame tags
  - [x] Support reverse ping-pong playback and export
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
