# Notes

Keep confirmed facts that help with future work. Use short sentences and one dated bullet per learning.
Use Git history for old bug reports and removed designs.

## Lifecycle and data

- 2026-10-05: Free each `UndoRedo` object when its owner is deleted.
- 2026-10-05: Do not call `super` from `_notification()`. Godot calls each inherited version.
- 2026-10-05: Use `NOTIFICATION_POST_ENTER_TREE` for each tree entry. `_ready()` normally runs once.
- 2026-10-05: Wait for every worker task before cleanup. Include cancelled tasks.
- 2026-08-24: An overridden `_ready()` does not call its base version automatically. Connect shared setup to `ready` in `_init()`.
- 2026-08-23: Connect signals to node methods when the receiver can be freed. Lambdas can retain access to freed nodes.
- 2026-08-21: Lambdas capture local values. Use members or arrays for state that a lambda must change.
- 2026-10-16: Dictionaries and PackedFloat32Array values compare by content. They can also be dictionary keys.
- 2026-10-05: Use `is_same()` to compare dictionary references instead of their contents.
- 2026-09-09: `Array[VoxelFrame].duplicate()` keeps its type. Preserve that type when restoring `document.frames`.
- 2026-08-31: Emit typed arrays when signal handlers require them. An untyped array can prevent the handler call.
- 2026-10-16: Before reading an optional null value, call `ConfigFile.has_section_key()`.
- 2026-10-03: `PROPERTY_USAGE_NONE` prevents saving a property. Older files can still load that property.
- 2026-08-20: Export Resource properties that must be saved. Plain variables are not saved.
- 2026-08-23: Guard typed returns against null values. A `Variant` can contain an incompatible value.
- 2026-08-16: `get_script()` returns the most-derived script. Use `get_base_script()` to reach its base script.
- 2026-10-04: Inside a nested class, qualify outer static methods with the outer class name.

## UI and input

- 2026-08-22: Unique node names belong to their owner scene. Resolve subscene names from the subscene instance.
- 2026-08-16: Use `MenuButton.get_popup()`. Connect the popup's `id_pressed` signal after the button is ready.
- 2026-09-09: Set popup checkmarks in the handler. Clicking an item does not toggle its stored state.
- 2026-10-04: Set radio item states explicitly. Popup radio styling does not enforce a group.
- 2026-08-24: Use `set_pressed_no_signal()` to update a button without emitting `toggled`.
- 2026-09-07: For grouped buttons, use `button_pressed` to update the group. `set_pressed_no_signal()` leaves siblings unchanged.
- 2026-08-24: Do not depend on the order of grouped button signals. Defer state synchronization until the signal sequence ends.
- 2026-10-16: Control signals and script input run before native handlers. Use `accept_event()` to stop later native handling.
- 2026-10-10: Button shortcuts run before `_unhandled_input()`. Keep tool-option shortcuts separate from tool-selection shortcuts.
- 2026-08-24: Later siblings receive unhandled input first. A camera control can consume input before a tool.
- 2026-10-05: View rotation handles right-click before tools receive unhandled input.
- 2026-10-04: Retain the viewport before calling a tool. An input callback can detach that tool.
- 2026-10-05: Reject inactive modifier input in `VoxelTool._accepts()`. Edit locks are checked before `handle_input()`.
- 2026-10-16: `SpinBox` supports vertical arrow drags. A new drag can move focus from the previous field.
- 2026-10-16: `SpinBox` applies submitted text later. Close numeric undo groups after that update.
- 2026-08-24: `SpinBox.suffix` changes display text, not the stored value.
- 2026-09-07: `SpinBox.editable = false` blocks user edits. Code can still set its value.
- 2026-09-07: Setting `LineEdit.text` does not emit `text_changed`. Call the handler explicitly in tests.
- 2026-09-07: `OptionButton.select()` does not emit `item_selected`. Call the handler explicitly in tests.
- 2026-09-07: Use explicit cell indices in grids. Prepending a row changes each child's node index.
- 2026-09-07: Before reading rebuilt container rectangles, wait one frame.
- 2026-09-07: For drags across controls, track motion in `_input()`. `gui_input` stops outside the control.
- 2026-09-07: Set drag previews only during a GUI drag. Check `get_viewport().gui_is_dragging()` first.
- 2026-09-07: Implement button drag handling in a Button subclass. The button consumes its press before the parent.
- 2026-10-05: Use the `align_to_largest_stylebox` theme constant to keep button sizes stable across states.
- 2026-08-16: Remove style overrides with `remove_theme_stylebox_override()`. Do not replace them with null.
- 2026-10-17: `String.capitalize()` capitalizes every word. It does not produce sentence case.
- 2026-10-17: A Control below a Node3D draws over its viewport's 3D content. A CanvasLayer at -1 draws behind it.

## Assets and files

- 2026-10-17: Before importing SVG icons, set `importer="svg"` and `type="DPITexture"` in their `.import` files. Otherwise, imports use plain textures. The `dest_files` hash is the MD5 of the `res://` source path.
- 2026-10-06: DPITexture keeps SVG dimensions and renders icons at the viewport scale.
- 2026-10-06: On this Windows display, Godot 4.7.2 reports scale 1.0 and DPI 192 at 200% scaling.
- 2026-10-05: File dialogs filter by extensions. An image label alone does not select image formats.
- 2026-10-05: Load DDS and KTX with Image buffer loaders. Decompress compressed images before reading pixels.
- 2026-08-20: This engine build writes full parent paths and node `unique_id` values. Re-save broken hand-edited scenes in the editor.
- 2026-08-23: Re-read `.tres` files after editor saves. Godot can reorder properties and add script UIDs.
- 2026-08-23: To avoid enum serialization errors, create a temporary Resource and save it with `ResourceSaver`.
- 2026-08-19: Do not copy Aseprite source. It is source-available, not free software.

## Geometry and rendering

- 2026-10-17: `Camera3D.get_camera_projection()` excludes the camera transform. Apply the inverse camera transform before projection. Divide by w, then map normalized coordinates to viewport pixels.
- 2026-10-17: Camera-space points with positive z are behind the camera.
- 2026-10-17: `Geometry2D.triangulate_polygon()` returns counterclockwise triangles. Reverse positive-axis face indices for Godot's clockwise 3D winding.
- 2026-10-17: A zero-area polygon encloses no cells. This includes lasso drags with collinear screen points.
- 2026-08-18: Shift DDA ray origins by +0.5. Voxel cell `c` spans `[c - 0.5, c + 0.5]`.
- 2026-09-07: Use `AABB(cell - Vector3.ONE * 0.5, Vector3.ONE)` for voxel bounds.
- 2026-08-19: The document canvas has no fixed bounds. `VoxelDocument.bounds()` covers all frames.
- 2026-10-08: `AABB.get_support(direction)` returns the farthest corner. Sprite depth includes the farthest view extreme plus one voxel.
- 2026-08-19: Use `AABB.has_volume()` or `has_surface()`. There is no `has_area()` method.
- 2026-08-24: Match orthographic framing with `size = 2 * distance * tan(fov / 2)`. Keep `KEEP_HEIGHT`.
- 2026-10-05: Give independent render viewports separate World3D objects. Use `resource_local_to_scene` for separate scene-instance worlds.
- 2026-10-07: In Godot 4.7.2 Mobile, render new sprite viewports twice before capturing directional shadows.
- 2026-10-06: Use `PROCESS_MODE_ALWAYS` for renderers that must finish work inside disabled workspaces.
- 2026-08-24: Use `Viewport.DEBUG_DRAW_UNSHADED` to preview without shading. No material swap is needed.
- 2026-08-16: Use `BaseMaterial3D.SHADING_MODE_UNSHADED`, not `SHADE_UNSHADED`.
- 2026-08-16: Size mesh arrays to `Mesh.ARRAY_MAX` and index them by array type.
- 2026-08-24: Before `SurfaceTool.add_triangle_fan()`, call `begin(Mesh.PRIMITIVE_TRIANGLES)`.
- 2026-08-16: There is no `Mesh.PRIMITIVE_TRIANGLE_FAN`. Use a triangle strip for a four-vertex quad.
- 2026-08-19: Set `MultiMesh.transform_format` to `TRANSFORM_3D` before adding 3D instances. The default is 2D.
- 2026-09-03: Setting `MultiMesh.instance_count` clears instance data. Use `visible_instance_count` to change visibility without reallocating.
- 2026-10-17: A chunk mesher reads one cell beyond its own chunk. Only cells on a chunk face (local coordinate 0 or `CHUNK_SIZE - 1`) change a neighbor surface.
- 2026-10-17: The chunk surface build dominates drawing latency. The greedy mesh and the planar cleanup with atlas bake each take about half of one build.
- 2026-10-17: Godot sizes its worker pool from the processor count. Independent chunk surfaces can run on most of those threads.
- 2026-10-17: Fragmented materials cost far more than uniform ones. Diagonal material stripes took three times the build time of uniform material blocks.
- 2026-10-17: A chunk mesher scans all 16 rows and columns of each face axis, sign, and layer. An empty chunk costs as much as a full one unless the scan skips empty layers.
- 2026-10-17: The mesher emits faces only for the chunk's own cells. Padded planes 1 through 16 hold exactly those cells, so their occupancy is known before the scan.
- 2026-10-17: The planar cleanup falls back to one quad per cell for four of the 511 three-by-three masks. Those shapes have a self-touching outline.
- 2026-10-17: A one-cell hole raises a 16 by 16 plate from twelve triangles to forty. A diagonal notch raises it to fifty-six.
- 2026-10-17: The sample document uses four materials for 44 voxels. Material count alone does not prevent merging.
- 2026-10-17: A smooth normal depends only on the voxel lattice corner. The mesher and the planar cleanup can both read it from the frame, so flat and smooth can share one merged topology.
- 2026-10-17: A region whose outline visits a corner twice falls back to one quad per cell. A diagonal gap of cells produces that outline.
- 2026-10-17: The greedy mesh merges each plane on its own, so the planar cleanup can only add polygons. A chunk that gains triangles in the cleanup marks a merge failure.
- 2026-10-17: `Geometry2D.triangulate_polygon()` returns an empty array for a unit square at 4096, but it returns both triangles for the same square at -4096. The region triangulator then falls back to one quad per cell, which keeps the correct shape.
- 2026-10-17: An outline that pinches at a corner returns one loop that visits that corner twice. Splitting that loop at the repeated corner yields simple polygons, and a hole that touches the outline becomes a negative piece.

## Materials and export

- 2026-10-16: StandardMaterial3D ignores `orm_texture`. Bind the finish atlas to metallic and roughness textures. Read metallic from blue and roughness from green.
- 2026-10-16: With the default emission add mode, keep the emission color black. The texture supplies the emission.
- 2026-10-16: For glTF emission, use white emission and multiply mode. glTF multiplies its emission factor and texture.
- 2026-10-16: Godot 4.7.2 embeds atlas PNGs in GLB files. HDR emission uses `KHR_materials_emissive_strength`.
- 2026-10-16: Allow one byte of error when checking Image texture samples.
- 2026-10-16: Compare stored material floats with `is_equal_approx()`. Packed storage uses 32-bit float precision.
- 2026-10-16: `Color.TRANSPARENT` has white RGB and zero alpha. Four zero values give transparent black.
- 2026-10-04: Check exported geometry through ImporterMesh arrays. Runtime mesh compression changes positions and normals.
- 2026-10-04: Godot marks glTF animation names as looping when they start or end with `loop` or `cycle`.
- 2026-10-04: Use nonzero rest scales for frame meshes. Zero rest scales cause glTF quaternion errors.
- 2026-10-04: Disable immutable-track removal when importing flipbook animations. It can remove inactive frames.
- 2026-10-04: Convert voxel sRGB colors to linear before exporting glTF vertex colors.
- 2026-10-04: In Godot 4.7.2, two primitives sharing a material enable its imported vertex-color flags.
- 2026-08-21: AnimationPlayer tracks resolve paths from `root_node`, not directly from the player.
- 2026-10-04: Convert Aseprite JSON tag repeat counts from strings to integers.
- 2026-10-06: Sprite JSON frame names use `<tag>_<frame>`. Multiple views append `_<view>` to frame and tag names. Preserve spaces in tags.

## Tools and undo

- 2026-08-19: Brush strokes connect consecutive picks and include the final cell.
- 2026-08-19: Pixel-perfect strokes hold a pending cell to prevent gaps. Flush that cell on release.
- 2026-08-23: Under angled views, projected cell centers can pick neighboring cells. Use the actual picking functions in tests.
- 2026-10-17: Screen selection includes cells behind its shape. Empty-cell selection uses the frame bounds and the empty-cell option.
- 2026-10-17: For Box and Lasso in Replace mode, an empty click clears the selection when empty-cell selection is disabled.
- 2026-09-12: After each transform update, erase the exact previous preview cells. Avoid scanning a padded volume.
- 2026-09-12: For rotation drags at the pivot, use camera-right projected onto the rotation plane as the fallback direction.
- 2026-09-12: Align smooth single-axis rotations from their actual output bounds. Predicted bounds can make previews jump near cardinal angles.
- 2026-09-12: Use exact rotation at cardinal angles. Test the smooth path near those angles, not exactly on them.
- 2026-09-12: Grid-aligned camera rays can hit voxel boundaries. Keep picking test fixtures away from those boundaries.
- 2026-10-15: `VoxelTool.end_stroke()` records "Stroke" and takes no name. Override it for a different undo name.
- 2026-10-17: During palette drags, distinguish local edits from external changes. Material matching can change the selected index mid-drag.
- 2026-09-09: Use `UndoRedo.MERGE_ENDS` for repeated drag updates. It keeps the first undo and last redo.
- 2026-08-19: Use `UndoRedo.commit_action(false)` when the change is already applied.
- 2026-09-09: Emit state signals from undo callbacks. The UI does not observe `UndoRedo.version_changed`.
- 2026-09-07: Selection does not support Shift-to-add. The Clear button stays enabled for an empty selection.

## Tests and processes

- 2026-09-07: The harness adds `Main.tscn` from `_enter_tree()` with a deferred call. Each test uses the full editor.
- 2026-10-17: Normal behavior tests skip startup document restoration. `Main.gd` restores documents only for application sessions unless forced.
- 2026-08-19: The harness waits two frames before each test body. Add other waits only where the test needs them.
- 2026-10-17: `step()` waits for its callable. Follow the test-writing rules and put waits between steps.
- 2026-10-05: Use wall-clock time for elapsed-time checks. Headless scene timers do not guarantee elapsed wall time.
- 2026-10-17: Compare performance numbers inside one run. Repeat runs on a loaded machine differ by more than a factor of two.
- 2026-08-21: A Timer continues while test code awaits. Use its timeout signal to fail stalled tests.
- 2026-08-23: A parse error can prevent a test from exiting. The suite runner stops that child after 30 seconds.
- 2026-08-24: Check errors inside expectation expressions. An error before `expect()` runs can leave no failed check.
- 2026-10-17: `press_option()` matches the raw tooltip text, including its letter case.
- 2026-10-07: For viewport-coordinate clicks, pass `true` to `push_input()` to skip display-scale conversion.
- 2026-08-23: Send action keys to `get_tree().root` so they reach editor-wide handlers.
- 2026-09-07: Activate tools through toolbar buttons. Set options through their controls or `press_option()`.
- 2026-09-07: Use `VoxelPicking.NONE`, not the removed `State.NONE`.
- 2026-10-17: Run suites without another Godot instance using this project. Clipboard and popup checks can fail when instances overlap.
- 2026-10-16: To detect hidden GDScript warnings, set `debug/gdscript/warnings/<name>=2`. This turns the warning into a load error.
- 2026-09-07: End GDScript files with a newline. Missing newlines can cause lambda parse errors.
- 2026-09-07: If a test fails to parse after a final step lambda, add a trailing statement.
- 2026-08-23: Avoid array slice syntax such as `arr[0:1]` in this build. Use `slice()` or an array literal.
- 2026-08-16: Use basis columns for camera directions: `basis.x`, `basis.y`, and `-basis.z`.
- 2026-08-16: Use `Vector2`, not `Point2`. Build axis vectors by setting a Vector3 component.
- 2026-08-16: Use `FileDialog.ACCESS_USERDATA`, not `ACCESS_USER_DIR`.
- 2026-08-16: Handle viewport GUI input through `SubViewportContainer.gui_input`, not `SubViewport.input_event`.
- 2026-08-16: `OS.create_process()` does not capture child output in this build. Use `OS.execute()` for blocking capture.
- 2026-08-16: In this build, `OS.execute()` puts captured text in one output-array element. Its return value is the exit code.
- 2026-08-23: Use `OS.execute_with_pipe(..., false)` for nonblocking output capture and a process ID.
- 2026-10-16: Drain child output pipes to prevent blocking. Alternatively, capture Godot output with `--log-file`.
- 2026-10-16: Windows can reuse process IDs. Do not rely on a reused ID alone to identify a finished child.
