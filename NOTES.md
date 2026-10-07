# NOTES.md

This file records confirmed, non-obvious facts learned while working on Voxi. Record a new learning during the task that finds it. Use one bullet per learning. Start the bullet with the date. Keep the sentence short and in STE.

## Godot API changes

- 2026-10-07: In Godot 4.7.2 Mobile, a new sheet viewport needs two renders before capture includes directional shadows.
- 2026-10-06: Godot 4.7.2 on Windows returns scale 1.0 and DPI 192 for this 200% display.
- 2026-10-06: DPITexture imports retain SVG dimensions and rasterize icons at the viewport scale.
- 2026-10-06: A disabled workspace stops renderer processing unless the renderer uses `PROCESS_MODE_ALWAYS`.
- 2026-10-05: For independent frame renders, give each viewport its own `World3D`. `resource_local_to_scene` creates a world per scene instance.
- 2026-10-05: `VoxelTool` checks edit locks before `handle_input()`. Inactive modifier tools must reject events in `_accepts()`.
- 2026-10-05: `SceneTreeTimer` expiry does not guarantee elapsed wall time during headless tests.
- 2026-10-05: `UndoRedo` inherits `Object`. Free it when its owner is deleted.
- 2026-10-05: `_notification()` runs for each script in the inheritance chain. Do not call `super` from this method.
- 2026-10-05: `NOTIFICATION_POST_ENTER_TREE` runs on each tree entry. `_ready()` runs once unless `request_ready()` is called.
- 2026-10-05: Wait for every WorkerThreadPool task, including cancelled tasks, to release the task's allocated resources.
- 2026-10-05: Windows and embedded `FileDialog` controls filter by extensions. An image label does not select image formats.
- 2026-10-05: DDS and KTX files use `Image` buffer loaders. If an image is compressed, decompress it before reading pixels.
- 2026-10-05: `align_to_largest_stylebox` uses the largest button margins across states. It is a theme constant.
- 2026-10-05: View rotation consumes right-click in `_input()` before tools receive `_unhandled_input()`.
- 2026-10-05: `is_same()` compares dictionary references. Use it with read-only patterns to avoid content comparisons.
- 2026-10-04: Aseprite exports JSON tag repeat counts as strings. Convert the `repeat` field to an integer.
- 2026-10-04: An input callback can detach its tool. Retain the viewport before calling the tool.
- 2026-10-04: Nested GDScript classes must use the outer class name to call its static methods.
- 2026-10-04: Runtime mesh compression changes positions and normals. Use `ImporterMesh` arrays to verify exported geometry.
- 2026-10-04: Animated visibility pointers require a defined `KHR_node_visibility` object, including on initially visible nodes.
- 2026-10-04: Godot 4.7.2 exports and imports visibility tracks with `KHR_node_visibility` and `KHR_animation_pointer`.
- 2026-10-04: Godot enables glTF animation loops for names that start or end with `loop` or `cycle`.
- 2026-10-04: Godot 4.7.2 configures glTF materials before reading the first primitive's vertex colors. Two shared-material primitives enable vertex colors.
- 2026-10-04: `GLTFDocument` exports vertex colors without color conversion. Convert voxel sRGB colors to linear colors before export.
- 2026-10-04: Zero-scale rest transforms cause glTF quaternion errors. Non-zero rest scales preserve zero-scale animation keys.
- 2026-10-04: Immutable-track removal can remove inactive flipbook frames from clips. Disable this option to preserve clip changes.
- 2026-10-04: `PopupMenu` radio items change appearance only. Set their checked states to enforce groups.
- 2026-10-03: `PROPERTY_USAGE_NONE` excludes a property from resource saves. Existing resource files can still load that property.

- 2026-08-16: `Mesh.PRIMITIVE_TRIANGLE_FAN` does not exist. Use `PRIMITIVE_TRIANGLE_STRIP` for a 4-vertex quad.
- 2026-08-24: `SurfaceTool.add_triangle_fan(vertices)` builds a fan in one call. It errors with "!begun" unless `begin(Mesh.PRIMITIVE_TRIANGLES)` runs first.
- 2026-08-16: `BaseMaterial3D.SHADE_UNSHADED` is now `SHADING_MODE_UNSHADED`.
- 2026-08-16: `add_surface_from_arrays` takes a plain `Array` sized to `Mesh.ARRAY_MAX`, indexed by array type.
- 2026-08-16: `Point2` does not exist. Use `Vector2`.
- 2026-08-16: `FileDialog.ACCESS_USER_DIR` does not exist. Use `access = FileDialog.ACCESS_USERDATA`.
- 2026-08-16: `MenuButton.popup` and `set_popup()` do not exist. Use `mb.get_popup()`.
- 2026-08-16: `SubViewport.size_owns_texture` is Godot 3 only.
- 2026-08-16: `SubViewport.input_event` is removed. Capture input on `SubViewportContainer.gui_input`.
- 2026-08-16: `add_theme_stylebox_override("normal", null)` errors. Use `remove_theme_stylebox_override("normal")`.
- 2026-08-16: `Object.get_constant_list()` is removed.
- 2026-08-16: `Camera3D.right` and `.up`, `Basis.right` and `.up` are removed. Use basis columns: `camera.basis.x`, `camera.basis.y`, `-camera.basis.z`.
- 2026-08-16: No change: `Mesh.PRIMITIVE_LINES` (=1), `BaseMaterial3D.TRANSPARENCY_ALPHA`, `SubViewport.size_changed`.
- 2026-08-16: `OS.create_process` does not inherit the child's output in this build. Use `OS.execute` with an output array to capture it.
- 2026-08-16: `OS.execute` returns the child output as one array element. That element holds the whole text with `\r\n` line endings.
- 2026-08-16: `get_script()` returns the most-derived script, even inside a base-script method. Use `get_script().get_base_script()` to reach the base script. Type the result explicitly; `:=` cannot infer through that chain.
- 2026-08-16: `Vector3.from_axis()` does not exist. Build an axis vector by setting one component of `Vector3.ZERO` to `1.0`.
- 2026-08-19: `UndoRedo.commit_action(false)` registers the action without running the do methods. Use it when the do state already exists.
- 2026-08-19: `MultiMesh.transform_format` defaults to `TRANSFORM_2D` (=0). Use `TRANSFORM_3D` (=1) for 3D instances. The scene saver drops properties equal to the default, so write the non-default value in `.tscn`.
- 2026-08-19: `AABB` has `has_volume()` and `has_surface()`, not `has_area()`. An empty `AABB` has a zero `size`.
- 2026-08-19: The document canvas is unbounded. `VoxiDocument.bounds()` returns an `AABB` over all frames. `grid_size` and `in_bounds` are removed.
- 2026-08-20: `ResourceSaver` persists only `@export` properties. A plain `var` is dropped from the saved `.tres`. `VoxelFrame.cells` is now `@export`.
- 2026-08-20: This Steam build writes `unique_id` on every node and resolves `parent=` as the full path from the scene root. Hand-editing a node with a short relative parent path breaks instantiation. The node and its subtree are skipped. Re-save the scene in the editor to regenerate the full path and `unique_id`.
- 2026-08-21: An `AnimationPlayer` property track resolves its node path relative to `root_node`. A player nested under the node that owns the animated property needs `root_node = NodePath("../..")` to target it.
- 2026-08-23: `OS.execute_with_pipe(path, arguments, false)` returns `{stdio, stderr, pid}`. A non-blocking `get_buffer` never stalls. It returns empty bytes when no data is ready. Unlike `create_process`, it captures output. Unlike `execute`, it returns a pid for `kill()`.
- 2026-08-24: `Viewport.debug_draw = DEBUG_DRAW_UNSHADED` (=1) renders the whole SubViewport without shading. It needs no material swap.
- 2026-08-24: An orthographic camera keeps perspective framing when `size = 2 * dist * tan(fov / 2)`. `keep_aspect` stays at the default KEEP_HEIGHT.
- 2026-08-24: The `BaseButton.button_pressed` setter emits `toggled`. Use `set_pressed_no_signal()` to sync a button without a signal round-trip.
- 2026-08-24: A `ButtonGroup` unpresses siblings during a press. The order of the two `toggled` emissions is not fixed. Derive shared state in guarded per-button handlers, not from `get_pressed_button()`.
- 2026-08-24: A sync handler that writes `set_pressed_no_signal` during a sibling `toggled` cascade corrupts the engine press in flight. The next `toggled` then reports the corrupted value. Defer such sync with `call_deferred` to the end of the frame.
- 2026-08-31: Signal arguments are not converted to typed array parameters. Emitting an untyped `Array` (empty or not) into an `Array[Vector3i]` parameter drops the call. The handler never runs. Always emit a typed `Array[Vector3i]`.
- 2026-09-03: Setting `MultiMesh.instance_count` resizes the buffer and clears all instance data. Set it once at creation. Use `visible_instance_count` for the live count. It limits drawn instances without touching the buffers.
- 2026-09-07: A `.gd` file without a final newline fails to parse when it contains `func():` lambdas. The parser reports "Expected end of file". Always end GDScript files with a newline.
- 2026-09-07: `SpinBox.editable = false` disables the arrow buttons, the wheel, and the drag. `gui_input` returns early when the spinbox is not editable. Setting the value in code still works.
- 2026-09-07: `LineEdit.text` set in code does not emit `text_changed`. Only user typing emits it. Drive the rename handler directly in tests.
- 2026-09-07: A `GridContainer` child's `get_index()` counts cells in earlier rows. When a row is prepended, child indices shift. Pass an explicit index member to cells instead of deriving it from `get_index()`.
- 2026-09-07: A control receives `gui_input` motion only while the pointer stays over it. For a drag that crosses sibling cells, track motion in `_input` after `set_process_input(true)`.
- 2026-09-07: A container rebuilds its cells in the same frame. Tests must await a frame before they read cell rects. Otherwise the cells have zero size.
- 2026-09-07: `OptionButton.item_selected` fires only when the user picks from the popup. `select()` and the `selected` property do not emit it. Drive the handler directly in tests.
- 2026-09-07: `Control` drag-and-drop starts in `_get_drag_data`. The engine marks the viewport as dragging before it calls the method. `set_drag_preview` fails outside a drag. Guard it with `get_viewport().gui_is_dragging()`.
- 2026-09-07: A `Button` consumes its press, so a draggable button needs a `Button` subclass. A parent control cannot start the drag through it.

## Picking

- 2026-08-18: DDA picking in grid space must shift the ray origin by +0.5. Mesh cell `c` occupies `[c-0.5, c+0.5]`, but `floori()` cell `i` occupies `[i, i+1]`.
- 2026-08-19: Aseprite source is proprietary (source-available, non-free). Do not copy it. The smooth-stroke technique is implemented from public descriptions.
- 2026-08-19: The base tool interpolates the line between consecutive drag picks. `StrokeLine.cells` returns the connected 8-neighbor path, which always ends at the mouse cell. The stroke always paints the cell under the mouse; no filter may skip it.
- 2026-08-19: Pixel-perfect drawing uses the public "waiting pixel" scheme. `PixelPerfectStroke` holds a `waiting` cell that neighbors the last drawn cell. When the cursor pulls more than one cell away, it draws the connected path from the waiting cell to the cursor, so the stroke never gaps. `State.pixel_perfect` toggles it; the tool flushes the waiting cell on mouse-up.
- 2026-08-23: An unprojected cell center does not round back to that cell in `drag_pick`. Under an oblique view, the ray crosses the face plane up to half a cell away from the center. Tests must derive expected picks through the same pick functions.
- 2026-08-24: `start_pick` sets `target` to the hit voxel. With no voxel, it sets a ground plane (y=0) cell if the ray points down, else `NONE`. `hit` and `target` differ: an empty grid cell click has `hit = NONE` but a valid ground cell `target`.
- 2026-08-24: A single click on an empty grid cell selects that cell with the box and lasso tools. The wand does nothing on an empty cell. An empty cell click does not clear the selection. Deselect with the Clear button, Escape, or a no-target sky click in replace mode.
- 2026-09-07: Bounds use `AABB(cell - Vector3.ONE * 0.5, Vector3.ONE)` to match the mesh cell convention `[c-0.5, c+0.5]`. Selection, transform, and grid bounds share it. This keeps the camera centered on the rendered geometry.

## UI scene migration

- Static UI structure and static signal wiring live in `ui/main.tscn` and its child scenes.
- Scripts hold state and logic only. They construct no static UI nodes.
- MenuButton items live in the scene via `item_count` and `popup/item_N/text`.
- The MenuButton popup is internal. Connect `id_pressed` in `_ready()`.
- Use one small `_on_*` handler per connected control. The scene then needs no `.bind()`.
- Dynamic elements stay in code: frame strip buttons, palette swatches, tool strip buttons.
- The Aseprite-style layout (left palette panel, right tool strip) lands in M4.
- `main.gd` must construct no UI nodes except dynamic frame buttons and the FileDialog.
- 2026-08-22: A unique name is scoped to the owner scene. A node with `unique_name_in_owner` in a subscene does not resolve from the parent scene root. Get the subscene instance root, then call `get_node("%Name")` on it.
- 2026-08-23: `ToolInfo.tool_scene` holds the tool node scene that the viewport adds. `ToolOption.option_scene` points to an option widget scene. `OptionBar` instantiates it and sets `option` and `group`.
- 2026-08-23: An option widget scene is declarative. Buttons and icons live in the `.tscn`. The script wires state only.
- 2026-08-24: Option widget scenes live in the tools directory. `mode_picker.tscn` is shared by the select, lasso, and wand tools. It lives in `tools/select/` and the other tools reference it cross-directory.
- 2026-08-24: Option widgets that differ by one asset inherit a base scene. The child scene overrides only the icon. `ToolOption` stays free of presentation data.
- 2026-08-24: `SpinBox.suffix` is display-only. It does not scale the value. Scale in the widget script when the shown range differs from the stored range.

## Workflow

- 2026-10-07: For test clicks in viewport coordinates, pass `true` to `push_input()` to prevent display-scale coordinate conversion.
- 2026-09-07: The tool selection API is gone. `State.tools`, `set_tool`, `set_tool_option`, `get_tool_option`, and `State.tool` are removed. Tools are plugins under `/root`. A test activates a tool by setting the plugin toolbar button's `button_pressed`. It sets options by pressing the option-bar button (`press_option(tooltip)`).
- 2026-09-07: `State.NONE` is gone. Use `VoxelPicking.NONE`.
- 2026-09-07: The test harness adds Main in `_enter_tree`. Tests override only `_ready`. A base-class `_ready` would not run unless the subclass calls `super()`, so `_enter_tree` is the safe hook. Main is added with `call_deferred`.
- 2026-09-07: Every headless test run prints a stray GDScript backtrace at `_ready` plus RID-leak errors at exit. They appear on untouched tests too. They are noise, not failures.
- 2026-09-07: `run_all.gd` runs with `-s`, so no Main scene exists in that process. The State autoload still adds plugins to `/root`, and each plugin `_ready` targets `/root/Main`. That prints `/root/Main` not-found errors in the run_all output. They are noise from the runner, not from a test.
- New `class_name` scripts do not resolve until the project reimports. Run `godot --headless --import` to refresh the global class cache.
- `godot -s script.gd` cannot resolve autoload singleton identifiers at compile time. Run tests as scenes so autoloads resolve.
- Adding a child to the root during a main-scene node's `_ready()` fails with "Parent node is busy setting up children". Call the work with `call_deferred()`.
- The test harness `step` does not wait for `await` inside its step lambda. Put `await` calls in the test's `_run` function between steps.
- 2026-08-19: The harness waits two frames before each test body. Tests do not wait in `_run`.
- 2026-08-19: Every behavior test loads `res://ui/main.tscn`, the full editor. Scene wiring errors surface in the suite.
- 2026-08-21: GDScript lambdas capture local variables by value. A flag written inside a lambda is invisible outside. Share state through an array or a member variable.
- 2026-08-21: A `Timer` node keeps running while a script is suspended on `await`. Connect its `timeout` signal to a fail handler to time out a test body with no polling.
- 2026-08-23: A test scene whose script fails to parse loads no test logic. Nothing calls `quit()`, so the child hangs forever. The runner's outer 30 s timeout kills it.
- 2026-08-23: To author a `.tres` by hand without enum mistakes, build the resource in a throwaway `-s` script and `ResourceSaver.save()` it. This build serializes `SHADING_MODE_UNSHADED` as `0`.
- 2026-08-23: Input pushed into the editor SubViewport does not reach `_unhandled_key_input` on `main.gd`. Tests push action keys at `get_tree().root` instead.
- 2026-08-23: `Variant` works as an explicit type annotation on signal params, export vars, function params, returns, and lambda params. Probe-verified on 4.7.2.
- 2026-08-23: GDScript coerces a Variant return into a typed return at runtime. Returning `null` into a typed function errors every call. Guard consumers or compare against the expected type.
- 2026-08-23: Godot reserializes hand-authored `.tres` files on editor use. It reorders sub-resource properties and adds `uid` attributes to script references. Re-read before exact-string edits.
- 2026-08-23: Godot drops a signal connection when the callable's target object is freed. A lambda has no target object, so its connection survives and touches freed nodes. Wire state sync to node methods, not lambdas, when the node can be freed.
- 2026-08-23: A slice subscription like `arr[0:1]` fails to parse when passed as a function call argument in this build. Pass a plain array literal instead.
- 2026-08-24: `expect(cond, msg)` evaluates `cond` before `expect` runs. A script error in the condition aborts the step lambda. No check is recorded. The test then reports OK.
- 2026-08-24: A `const` value must be a constant expression. A call like `Color.from_rgba8(...)` fails to parse there. Use the named colors or a plain `var`.
- 2026-08-24: A base-class `_ready()` does not run when a subclass overrides `_ready()` without `super()`. Connect to the `ready` signal in `_init()` instead. The signal fires either way.
- 2026-08-24: `DirAccess.remove_absolute()` deletes a file or an empty directory only. Empty the directory with `get_files()`, `get_directories()`, and `remove()` first.
- 2026-08-24: Unhandled input reaches later siblings first. A node placed after the tool layer consumes events before tools see them. The camera rig uses this to intercept left-drag in pan mode.
- 2026-08-24: Every headless test run prints a stray GDScript backtrace at `_ready` plus RID-leak errors at exit. They appear on untouched tests too. They are noise, not failures.
- 2026-09-07: A test `_run` that ends directly with a step-lambda can fail to parse with 'Expected end of file'. The failure depends on the lambda body and the prior statements. Keep a trailing statement after the final step to parse reliably.
- 2026-10-06: The sprite sheet JSON names each frame `<tag>_<frame>`. A multi-view export appends `_<view>` to frames and tag names. A tag name keeps its own spaces.

## Regressions found in the plugin migration

- 2026-09-07: The Delete key no longer erases the selection. `State.erase_selection()` exists but nothing calls it. The `delete` input action is defined but has no handler.
- 2026-09-07: The center button in the viewport control bar does nothing. `%CenterBtn` exists in `Viewport.tscn` but no signal connects it. `CameraRig.center_active()` exists but is never called.
- 2026-09-07: The Selection plugin stores `_shift` on press but `_apply_mode()` never reads it. Shift-to-add does not work. The plugin also does not disable the Clear button when the selection is empty.
- 2026-09-07: The plane axis buttons used `set_pressed_no_signal`, which does not unpress the ButtonGroup siblings. Switching axis left several buttons pressed. Fixed in `Plugins/Plane/Options.gd` by using `button_pressed`.
- 2026-09-12: The dead move and rotate tool preview erased only the original grab-time cells, then redrew over a destination bounding box padded by one voxel. A drag that moved more than the padding between two updates left the prior redraw uncleared, cloning voxels. The box also scaled with its volume, not with voxel count, so a large or rotated selection could iterate millions of cells per drag update. The Transform plugin fixes this by erasing the previous update's exact destination cells and forward-mapping only the grabbed cells to their new positions.
- 2026-09-12: `VoxelRenderer.Chunk.set_color` finds a cell's multimesh index with `indexes.find_key(cell)`, a linear scan by value, not by key. Reporting a large `affected` array to `cells_changed` (such as an entire frame) turns a cheap edit into O(n²) work. Report only the cells that actually changed.
- 2026-09-12: Limiting the `affected` array does not fix `set_color`'s O(n) `find_key` scan on its own. Scale is not a bijection: its own per-drag affected set is legitimately large (it grows with the destination cell count), so the scan cost returns during a live scale drag even with a correctly minimal affected list. `Chunk` now keeps a `cell_index: Dictionary[Vector3i, int]` reverse map so `set_color` is O(1) regardless of affected-set size.
- 2026-09-12: A "click landed exactly on the pivot" fallback reference vector must not be a fixed world axis. `RotateTool` used to fall back to a world-space unit vector along the rotation's own in-plane axis. For some camera views that vector lands parallel or anti-parallel to the direction the user actually drags on screen, turning the same drag into 0 degrees on one view and 180 on another instead of 90. The fallback now uses the camera's own screen-right direction projected into the rotation plane, which stays roughly perpendicular to a vertical drag on any view.
- 2026-09-12: The exact (cardinal-angle) rotation and the smooth (RotSprite) preview used different placement conventions: exact keeps the original bounding box's own min corner fixed; smooth rotates around the continuous center. For a non-square selection these only agree at 0 and 180 degrees, not at 90 or 270, so the live preview visibly jumped position right where a free rotation hands off to the exact algorithm. Fixed by measuring where RotSprite's own combined output actually landed (not by predicting it from the source bounding box; RotSprite's candidate scan range is padded wider than the shape it finds, the same way any bounding-box estimate is) and translating it to match the exact algorithm's anchor. A square selection cannot show this bug: rotating a square around its own center already agrees with the fixed-corner convention at every 90 degree multiple.
- 2026-09-12: RotSprite's own continuous point-rotation-and-floor sampling has the same grid-parity boundary sensitivity that the exact algorithm exists to avoid, and it can only surface at a true, exact cardinal angle (verified: a solid, non-square block rotated by exactly 90 degrees through RotSprite loses cells that a `snapped(angle, DEGREE)` value 1 degree short of 90 does not). This never reaches players, since the dispatch between the two algorithms always routes an exact cardinal to the exact one, but it makes a direct exactly-90-degrees white-box comparison between the two algorithms an unreliable test; assert against a near-cardinal angle instead.
- 2026-09-12: A camera aimed with an exact 0-degree yaw sends a center-screen ray with a precisely zero horizontal component. A voxel stacked directly above another voxel on that same exact horizontal position can then sit exactly on the ray's grid-cell boundary, so picking becomes a coin flip between the two stacked cells. Placing test content so it is not exactly grid-aligned with the pivot avoids the coincidence.

## Undo/redo

- 2026-09-09: `UndoRedo.MERGE_ENDS` merges a new action with the previous action of the same name. It keeps the first undo and the last do. Use it for drag edits that fire many motions, like tag-range grips.
- 2026-09-09: An undo or redo callback must emit the state signals itself. The UI does not listen to `version_changed`. Emit `tag_changed`, `frames_changed`, or `frame_changed` to refresh the tag row, the range row, and the frame cells.
- 2026-09-09: `Array[VoxelFrame].duplicate()` keeps the typed array type. Store it in a `Dictionary` and bind it back to a `Array[VoxelFrame]` parameter. Assigning a plain `Array` to `document.frames` errors at runtime.
- 2026-09-09: `PopupMenu` checkable items do not toggle themselves. They only show a checkmark. Flip `set_item_checked` in the click handler.
