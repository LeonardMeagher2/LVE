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

## UI scene migration

- Static UI structure and static signal wiring live in `scenes/main.tscn`.
- Scripts hold state and logic only. They construct no static UI nodes.
- MenuButton items live in the scene via `item_count` and `popup/item_N/text`.
- The MenuButton popup is internal. Connect `id_pressed` in `_ready()`.
- Use one small `_on_*` handler per connected control. The scene then needs no `.bind()`.
- Dynamic elements stay in code: frame strip buttons, recent color swatches.
- The Aseprite-style layout (left palette panel, right tool strip) lands in M4.
- `main.gd` must construct no UI nodes except dynamic frame and recent buttons, and the FileDialog.
