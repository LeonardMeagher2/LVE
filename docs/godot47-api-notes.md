# Godot 4.7.1 API notes

Background: Voxi was initially coded against generic Godot 4.x docs. Running
`godot --headless` with the installed `4.7.1.stable.steam` build surfaced a
number of API renames/removals. This file records what was confirmed in this
build so we never re-learn it the hard way.

## Confirmed renames / removals (4.7.1)

| Assumed API | 4.7.1 reality |
|---|---|
| `Mesh.PRIMITIVE_TRIANGLE_FAN` | Does not exist. Use `PRIMITIVE_TRIANGLE_STRIP` for a 4-vertex quad. |
| `BaseMaterial3D.SHADE_UNSHADED` | `BaseMaterial3D.SHADING_MODE_UNSHADED` |
| `add_surface_from_arrays(primitive, [{ARRAY_VERTEX: pts}])` | `arrays` must be a plain `Array` sized to `Mesh.ARRAY_MAX`, indexed by array type |
| `Point2` | Use `Vector2` |
| `FileDialog.ACCESS_USER_DIR` | Use `d.current_dir = OS.get_user_data_dir()` |
| `MenuButton.popup` / `set_popup()` | Neither exists. MenuButton auto-creates its popup; use `mb.get_popup()` |
| `SubViewport.size_owns_texture` | Godot 3 only, removed |
| `SubViewport.input_event` | "Invalid access to property or key" — signal gone; capture input on the `SubViewportContainer` (`gui_input`) instead |
| `add_theme_stylebox_override("normal", null)` | Errors "Required object rp_style is null". Use `remove_theme_stylebox_override("normal")` to clear |
| `Object.get_constant_list()` | Not available in this build |
| `Camera3D.right` / `.up`, `Basis.right` / `.up` | None of these exist. Camera axes are basis columns: right = `camera.basis.x`, up = `camera.basis.y`, forward = `-camera.basis.z` |

Still fine (no change): `Mesh.PRIMITIVE_LINES` (=1),
`BaseMaterial3D.TRANSPARENCY_ALPHA`, `SubViewport.size_changed`.

## The 4 pending fixes

1. **MenuButton popup** — `main.gd` `_menu_button()` creates its own
   `PopupMenu` and calls `mb.set_popup(popup)` (invalid). Fix: create the
   `MenuButton`, then use `mb.get_popup()` (the auto-created internal popup),
   add items to it, connect `id_pressed`.

2. **SubViewport input** — `main.gd` `viewport_row()` connects
   `_viewport.input_event` (invalid in 4.7). Fix: connect
   `SubViewportContainer.gui_input` instead; position comes from
   `get_local_mouse_position()` on the container, which matches viewport
   pixel coords.

3. **`_vertex_arrays`** — `editor_viewport.gd` `_vertex_arrays()` returns
   `[ {ARRAY_VERTEX: points} ]`. Fix:
   ```gdscript
   func _vertex_arrays(points: PackedVector3Array) -> Array:
       var a := Array()
       a.resize(Mesh.ARRAY_MAX)
       a[Mesh.ARRAY_VERTEX] = points
       return a
   ```

4. **`_highlight_frame`** — `main.gd` `_highlight_frame()` passes `null` to
   `add_theme_stylebox_override("normal", sb)` for unselected buttons. Fix:
   only add the override for the selected button; call
   `remove_theme_stylebox_override("normal")` for the rest.

## Acceptance criteria

- `godot --path "C:\Users\Leona\Desktop\Gamedev\Voxi" -s res://tests/smoke.gd`
  prints `VOXI SMOKE OK` with zero script errors. Run without `--headless` so a
  failing test can write full-window screenshots; on failure the `Test` base
  class (`tests/test.gd`) collects all failing `expect`s into a markdown report
  `tests/artifacts/smoke/report.md` plus `fail_*.png` screenshots and exits
  non-zero. `--headless` still works but produces trace-only output (no PNG).
- Grid lines + base quad render in the viewport.
- File / Edit / View menus open and their items work.
