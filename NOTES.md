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
- 2026-10-17: `PackedFloat32Array.resize()` fills new entries with zero. `append_array()` after `resize()` extends beyond those zeros. Use a write cursor to rebuild the array in place.
- 2026-10-17: Dictionary iteration order is hash based. Sort the keys before remapping ids for deterministic serialization.

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
- 2026-10-17: The greedy pass merges every edge-adjacent face of one material. A cleanup region therefore holds cells that touch only at corners, and most loops are single cells.
- 2026-10-17: `Geometry2D.triangulate_polygon()` fans a polygon from its last vertex. A four-point unit square gives `[3, 0, 1, 1, 2, 3]` for every rotation and offset.
- 2026-10-17: A compact row-mask region only beats dictionary hashing when its rectangle is close to its cell count. At ten times more area than cells, the box scan loses.
- 2026-10-18: Comparing packed arrays with `==` is far cheaper than looping over their elements. Use it as a sufficient equality check and fall back to the element compare.
- 2026-10-18: Godot has no `PackedInt16Array`. Packed integer arrays use 32-bit or 64-bit entries.
- 2026-10-18: A bounds rescan over a full 16-cube chunk costs about 0.8 ms. Grow bounds from the written cells instead, and mark them dirty only when an erase lands on a bound.
- 2026-10-18: A seam protection pass and the triangulation that follows need the same region loops. Extract them once and pass them on.
- 2026-10-18: The seam protection must protect turns only. Protecting collinear points adds vertices to the mesh.
- 2026-10-17: A one-cell hole raises a 16 by 16 plate from twelve triangles to forty. A diagonal notch raises it to fifty-six.
- 2026-10-17: The sample document uses four materials for 44 voxels. Material count alone does not prevent merging.
- 2026-10-17: A smooth normal depends only on the voxel lattice corner. The mesher and the planar cleanup can both read it from the frame, so flat and smooth can share one merged topology.
- 2026-10-18: Reuse padded material ids as occupancy for smooth normals. Mark occupied border cells with a nonzero sentinel.
- 2026-10-18: Match `VoxelFrame.has()` with occupancy ids, not colors. Stored transparent cells still contribute to corner normals.
- 2026-10-17: A region whose outline visits a corner twice falls back to one quad per cell. A diagonal gap of cells produces that outline.
- 2026-10-17: The greedy mesh merges each plane on its own, so the planar cleanup can only add polygons. A chunk that gains triangles in the cleanup marks a merge failure.
- 2026-10-17: `Geometry2D.triangulate_polygon()` returns an empty array for a unit square at 4096, but it returns both triangles for the same square at -4096. The region triangulator then falls back to one quad per cell, which keeps the correct shape.
- 2026-10-17: An outline that pinches at a corner returns one loop that visits that corner twice. Splitting that loop at the repeated corner yields simple polygons, and a hole that touches the outline becomes a negative piece.
- 2026-10-18: `Line2D` builds UVs only when `texture_mode` is not `LINE_TEXTURE_NONE`. With `LINE_TEXTURE_TILE` and no texture, `UV.x` is the distance along the line divided by the width, and `tile_aspect` is 1.
- 2026-10-18: Under a perspective camera, two cells share a screen pixel only when they are collinear with the camera. A depth test cannot bucket the projected cell centers. Sample a point on the camera-facing surface of each cell instead. At a 45 degree view the cell center hides behind its own neighbour.
- 2026-10-18: A prepared loop that is one counterclockwise unit square needs no split, hole cut, or simplification. All four points are turns, and the triangle fan is `[3, 0, 1, 1, 2, 3]`.
- 2026-10-18: A prepared unit-square shortcut cut the `draw_latency` planar triangulate stage from 9845 to 3476 us.
- 2026-10-18: The 32-cube, 64-material fixture formed 93 cleanup groups with 768 unit-square loops and no holes.
- 2026-10-18: A frozen differential needs a copy of the region and of its caller. The caller supplies the prepared loops, so the two must stay in step.
- 2026-10-18: Material-rich cleanup measured 24968 to 18496 us flat and 26547 to 19648 us smooth.
- 2026-10-18: Complete material-rich surfaces measured 26384 to 19841 us flat and 27656 to 20807 us smooth.
- 2026-10-18: These A/B medians used nine repeats, two warmups, alternating execution order, and independent group copies.
- 2026-10-18: The unit-square shortcut repeated a 25 percent material-rich gain. Uniform, plate, and hole-heavy changes stayed within noise.
- 2026-10-18: `planar_cleanup` matched frozen polygon points, indices, and order across 527 cases, including all 511 three-by-three masks.
- 2026-10-18: The cleanup checks rejected changed geometry and verified cancellation at entry and during work.

## Threading

- 2026-10-18: Godot creates one global `WorkerThreadPool` at startup, sized to `OS.get_processor_count()`. The setting `threading/worker_pool/max_threads` defaults to -1, which means the core count.
- 2026-10-18: All pool tasks share one FIFO queue. An idle worker takes the next task. There is no core affinity and no per-task assignment.
- 2026-10-18: Low-priority tasks are limited to `threading/worker_pool/low_priority_thread_ratio` of the pool. The default is 0.3. High-priority tasks can use every thread.
- 2026-10-18: The pool does not preempt a task and has no cancel call. A task runs to completion, so the caller sets its own cancel flag.
- 2026-10-18: `wait_for_task_completion()` blocks the main thread on a semaphore. A pool thread that waits processes other tasks instead.
- 2026-10-18: `add_group_task()` gives each call an index from an atomic counter. Workers pull the next index, so the work balances without a fixed split.
- 2026-10-18: `WorkerThreadPool.get_thread_count()` is not bound to GDScript. Use `OS.get_processor_count()` as the proxy.
- 2026-10-18: A low-priority task cannot use most of the threads. Surface builds that pass `high_priority = false` run on about 30 percent of the pool.

## Materials and export

- 2026-10-16: StandardMaterial3D ignores `orm_texture`. Bind the finish atlas to metallic and roughness textures. Read metallic from blue and roughness from green.
- 2026-10-16: With the default emission add mode, keep the emission color black. The texture supplies the emission.
- 2026-10-16: For glTF emission, use white emission and multiply mode. glTF multiplies its emission factor and texture.
- 2026-10-16: Godot 4.7.2 embeds atlas PNGs in GLB files. HDR emission uses `KHR_materials_emissive_strength`.
- 2026-10-16: Allow one byte of error when checking Image texture samples.
- 2026-10-18: `Image.set_data(width, height, use_mipmaps, format, data)` takes row-major bytes with pixel (0,0) first. Filling a buffer and calling it once matches `set_pixelv` byte for byte.
- 2026-10-18: `set_pixelv` quantizes a channel by truncation, as `int(clampf(value * 255.0, 0.0, 255.0))`. `Color.to_rgba32()` is not equivalent: it packs another byte order and its low byte is alpha.
- 2026-10-18: `PackedByteArray.encode_u32` writes little-endian, so the first byte of a packed RGBA value is red.
- 2026-10-18: An atlas holds one patch per distinct material. `add_patch` deduplicates by material content and every caller passes a one-by-one patch.
- 2026-10-18: A `-s` SceneTree script has no autoloads, so `State` and other singletons do not resolve. Only global `class_name` types do. Load such a script from a test scene instead.
- 2026-10-18: This project treats the GDScript warning "type inferred from a Variant" as an error. Declare the type explicitly when a function returns Variant.
- 2026-10-18: The greedy face rule is: the cell is occupied, and the neighbor has alpha below one or a different color. The merge itself does not change which cells are grouped.
- 2026-10-18: A batch write that takes the chunk origin as an argument, compares the material once, and merges the bounds once per chunk cut the per-cell write from 3.7 to 2.60 us at diameter 64.
- 2026-10-18: The sphere brush cursor at diameter 64 built a 137376-cell mesh in 1022824 us. Showing the box above 4096 pattern cells cut it to 49923 us, which is the one-time pattern build.
- 2026-10-18: A frame-gap measurement must reset its frame mark when it starts. Otherwise the first measured frame counts the idle time since the last measured frame, and a slow setup step appears as a slow frame.
- 2026-10-18: Record visible completion after the renderer settles. An edit-worker completion time excludes the remaining surface builds.
- 2026-10-18: Holding a stamp while the viewport is behind does not help. It delays the work, which then lands in fewer and larger frames. The large-drag gap went from 8 to 16 ms and the small drag from 7 to 15 ms.
- 2026-10-18: A maximum-diameter brush stroke costs about one second because it touches a quarter of a million cells. The stamp and the write are inherent to the footprint, so responsiveness must come from spreading the work, not from shortening it.
- 2026-10-18: The number of in-flight surface jobs does not reliably change the settle time or the frame gap. Two sweeps of limits 2, 4, 6, and 8 disagreed on the sign of the gap effect, and the run to run spread was wider than the effect.
- 2026-10-18: A vertex dedup key must match the shading. A flat normal depends on the plane, so faces meeting at a corner keep separate vertices. A smooth normal depends only on the lattice corner, so those faces share one vertex. Keying on the patch alone merges flat faces, and keying on the group alone splits smooth corners.
- 2026-10-18: A chunk that holds one cell costs 18138 tracked bytes, 16384 of it the grid reservation. The cost is per chunk, not per cell.
- 2026-10-18: A maximum-diameter brush drag is bounded by the write and the chunk rebuilds, not by the stamp loop. The stamp grows linearly with the center count, but `set_cells` already receives the deduped union.
- 2026-10-18: A chunk holds one material table entry per occupied cell, so a write changes one cell. A bulk fill that points every cell at one entry is legal only with an explicit flag and a split before the next single-cell write. Without it, one voxel repaints the whole chunk.
- 2026-10-18: Iterating an `Array` of keys is about twice as fast as iterating the `Dictionary` itself. When a loop needs the keys alone, take `keys()` once and iterate that array. The order is the insertion order, so the two agree.
- 2026-10-18: Measure a job's own cost by running that job alone, not by reading a settle time. The maximum-diameter settle varied 0.90 to 1.23 s run to run, while the same job measured alone read 1.28 s and 1.02 s for its two variants.
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
- 2026-10-18: `UndoRedo` signals only `undo()` and `redo()` calls. Emit `State.history_changed` after every commit to refresh the history buttons.
- 2026-09-07: Selection does not support Shift-to-add. The Clear button stays enabled for an empty selection.

## Tests and processes

- 2026-10-18: Pass `--screen 1` to child tests to use the second monitor. Verified with `DisplayServer.window_get_current_screen()`.
- 2026-09-07: The harness adds `Main.tscn` from `_enter_tree()` with a deferred call. Each test uses the full editor.
- 2026-10-17: Normal behavior tests skip startup document restoration. `Main.gd` restores documents only for application sessions unless forced.
- 2026-08-19: The harness waits two frames before each test body. Add other waits only where the test needs them.
- 2026-10-17: `step()` waits for its callable. Follow the test-writing rules and put waits between steps.
- 2026-10-05: Use wall-clock time for elapsed-time checks. Headless scene timers do not guarantee elapsed wall time.
- 2026-10-17: Compare performance numbers inside one run. Repeat runs on a loaded machine differ by more than a factor of two.
- 2026-08-21: A Timer continues while test code awaits. Use its timeout signal to fail stalled tests.
- 2026-08-23: A parse error can prevent a test from exiting. The suite runner stops that child after 30 seconds.
- 2026-10-17: `var x := <Variant expression>` does not compile. The value has no set type. Write an explicit type such as `var base: int`.
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
