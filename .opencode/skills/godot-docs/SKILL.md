---
name: godot-docs
description: Look up and verify Godot APIs in the official docs. Use when writing or fixing GDScript, checking whether an API exists, or confirming exact member, enum, or signal names and values.
---

# Godot docs lookup

Use the current stable docs. Do not assume an API exists from memory. Validate API assumptions against the current stable docs.

## Fetch the raw RST source

The raw RST source is small and easy to grep. The `master` branch tracks the current stable release.

```
https://raw.githubusercontent.com/godotengine/godot-docs/master/classes/class_<snake_case>.rst
```

Use the rendered HTML as a fallback.

```
https://docs.godotengine.org/en/stable/classes/class_<snake_case>.html
```

For an unknown class name, fetch the class index or websearch.

- Index: `https://docs.godotengine.org/en/stable/classes/index.html`
- Search: `websearch` for `site:docs.godotengine.org <api>`

## Build the class URL

Drop the type suffix. Convert the name to snake_case. Keep digits.

| Godot class | URL stem |
|---|---|
| `ArrayMesh` | `class_arraymesh` |
| `SubViewportContainer` | `class_subviewportcontainer` |
| `Node3D` | `class_node3d` |
| `BaseMaterial3D` | `class_basematerial3d` |
| `MenuButton` | `class_menubutton` |

## Grep the class page

Target these RST sections with grep.

- `Properties`: name, default value, setter, getter.
- `Methods`: return type, arg types, `static`, `const`, `vararg`.
- `Signals`: parameter lists.
- `Enumerations` and `Constants`: exact names and numeric values.

Member names are snake_case. Examples: `shading_mode`, `render_target_update_mode`.

## Handle large output

Class pages are large. When a fetch is truncated, opencode saves it to a local tool-output file. Grep that file for the member. Do not fetch again.

## Validate an assumption

To confirm an API in the running build:

1. Run `godot --version`. Confirm the build.
2. Write a throwaway `extends SceneTree` probe. Run it headless. Confirm the API.
3. Delete the probe.
