# NOTES.md

This file records confirmed, non-obvious facts learned while working on Voxi. Record a new learning during the task that finds it. Use one bullet per learning. Start the bullet with the date. Keep the sentence short and in STE.

## Godot API changes

- 2026-08-16: `Mesh.PRIMITIVE_TRIANGLE_FAN` does not exist. Use `PRIMITIVE_TRIANGLE_STRIP` for a 4-vertex quad.
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

## Picking

- 2026-08-18: DDA picking in grid space must shift the ray origin by +0.5. Mesh cell `c` occupies `[c-0.5, c+0.5]`, but `floori()` cell `i` occupies `[i, i+1]`.
- 2026-08-19: Aseprite source is proprietary (source-available, non-free). Do not copy it. The smooth-stroke technique is implemented from public descriptions.
- 2026-08-19: The base tool interpolates the line between consecutive drag picks. `StrokeLine.cells` returns the connected 8-neighbor path, which always ends at the mouse cell. The stroke always paints the cell under the mouse; no filter may skip it.
- 2026-08-19: Pixel-perfect drawing uses the public "waiting pixel" scheme. `PixelPerfectStroke` holds a `waiting` cell that neighbors the last drawn cell. When the cursor pulls more than one cell away, it draws the connected path from the waiting cell to the cursor, so the stroke never gaps. `State.pixel_perfect` toggles it; the tool flushes the waiting cell on mouse-up.

## UI scene migration

- Static UI structure and static signal wiring live in `ui/main.tscn` and its child scenes.
- Scripts hold state and logic only. They construct no static UI nodes.
- MenuButton items live in the scene via `item_count` and `popup/item_N/text`.
- The MenuButton popup is internal. Connect `id_pressed` in `_ready()`.
- Use one small `_on_*` handler per connected control. The scene then needs no `.bind()`.
- Dynamic elements stay in code: frame strip buttons, palette swatches, tool strip buttons.
- The Aseprite-style layout (left palette panel, right tool strip) lands in M4.
- `main.gd` must construct no UI nodes except dynamic frame buttons and the FileDialog.

## Workflow

- New `class_name` scripts do not resolve until the project reimports. Run `godot --headless --import` to refresh the global class cache.
- `godot -s script.gd` cannot resolve autoload singleton identifiers at compile time. Run tests as scenes so autoloads resolve.
- Adding a child to the root during a main-scene node's `_ready()` fails with "Parent node is busy setting up children". Call the work with `call_deferred()`.
- The test harness `step` does not wait for `await` inside its step lambda. Put `await` calls in the test's `_run` function between steps.
- 2026-08-19: The harness waits two frames before each test body. Tests do not wait in `_run`.
- 2026-08-19: Every behavior test loads `res://ui/main.tscn`, the full editor. Scene wiring errors surface in the suite.
- 2026-08-21: GDScript lambdas capture local variables by value. A flag written inside a lambda is invisible outside. Share state through an array or a member variable.
- 2026-08-21: A `Timer` node keeps running while a script is suspended on `await`. Connect its `timeout` signal to a fail handler to time out a test body with no polling.
