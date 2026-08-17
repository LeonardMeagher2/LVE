# Godot 4.7.1 API notes

The Steam `4.7.1.stable` build differs from the Godot docs. This file records confirmed divergences. Verify each API here before you use it.

## Confirmed divergences

| Assumed API | 4.7.1 reality |
|---|---|
| `Mesh.PRIMITIVE_TRIANGLE_FAN` | Removed. Use `PRIMITIVE_TRIANGLE_STRIP` for a 4-vertex quad. |
| `BaseMaterial3D.SHADE_UNSHADED` | Use `SHADING_MODE_UNSHADED`. |
| `add_surface_from_arrays(primitive, [{ARRAY_VERTEX: pts}])` | `arrays` is a plain `Array` sized to `Mesh.ARRAY_MAX`, indexed by array type. |
| `Point2` | Use `Vector2`. |
| `FileDialog.ACCESS_USER_DIR` | Removed. Use `access = FileDialog.ACCESS_USERDATA`. |
| `MenuButton.popup` / `set_popup()` | Removed. Use `mb.get_popup()`. |
| `SubViewport.size_owns_texture` | Godot 3 only. Removed. |
| `SubViewport.input_event` | Signal removed. Capture input on `SubViewportContainer.gui_input`. |
| `add_theme_stylebox_override("normal", null)` | Errors. Use `remove_theme_stylebox_override("normal")`. |
| `Object.get_constant_list()` | Removed. |
| `Camera3D.right` / `.up`, `Basis.right` / `.up` | Removed. Use basis columns: `camera.basis.x`, `camera.basis.y`, `-camera.basis.z`. |

No change: `Mesh.PRIMITIVE_LINES` (=1), `BaseMaterial3D.TRANSPARENCY_ALPHA`, `SubViewport.size_changed`.

## Acceptance

- `godot --path "C:\Users\Leona\Desktop\Gamedev\Voxi" -s res://tests/smoke.gd` prints `VOXI TEST OK` with no script errors.
- Run windowed so failures save screenshots. Failures write `tests/artifacts/smoke/report.md` and `fail_*.png`, then exit 1. `--headless` skips the PNG.
- Grid lines and menus work.
