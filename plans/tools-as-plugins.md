# Plan: Brush plugin (Pencil + Paint)

## Goal

Refactor the brush tool group (Pencil, Paint) into a `plugins/brush/` plugin that follows the
eraser pilot. The toolbar keeps the old style: one `MenuButton` whose icon and tooltip swap per
mode. The brush and eraser behavior tests pass again.

The full migration plan for the remaining tool groups (pick, fill, select, transform, plane)
stays in this file after the brush lands.

## Scope

In scope:

- `plugins/brush/` plugin: toolbar scene, plugin script, tool scene + script moved in.
- `PencilTool._add_mode()` fix (the base tool no longer has `info`).
- `VoxiPlugin.gd` editor-node path fix (add and remove disagree).
- `state/State.gd` registration of the brush plugin.
- `tests/test.gd` harness helpers (dead types and viewport paths).
- The brush and eraser tests in the list below.

Out of scope (already broken by the strip; fixed when each tool migrates):
color_pick, delete_selection, fill_all, floor_plane, lasso, mask, move*, pixel_perfect_tool,
rotate, selection*, stroke tests other than the ones below, toolbar tests other than
toolbar_modes, wand_*, capture/capture_ui.

## Decisions (confirmed with the user)

- One `MenuButton` for the group. Two popup items: Pencil, Paint.
- B shortcut lives on the MenuButton. B opens the menu; Enter or click confirms.
  No shortcut for Paint.
- Pencil is active at startup, as before. `paint.gd` depends on it.
- Mode is carried by a `add_mode: bool` property on `PencilTool` (true for the pencil node,
  false for the paint node).

## Verified engine facts (Godot 4.7.2.stable.steam)

Source-verified against `base_button.cpp`, `base_button.h`, `menu_button.cpp` (4.5/4.6 stable;
press logic identical in master):

- Setting `button_pressed = true` on a toggle button unpresses every sibling in its `ButtonGroup`
  (each sibling emits `toggled(false)`) and emits `toggled(true)` on the button. Tests can
  activate a tool by pressing the button this way.
- `set_pressed_no_signal` sets state only: no signals, no group interaction.
- `ButtonGroup.allow_unpress` is `false` by default. Pressing the active tool again is a no-op.
- A `Shortcut` on a `MenuButton` fires the full press path: toggle state, group unpress, and
  `pressed()`, which opens the popup.
- `MenuButton` is always toggle. Opening the popup sets the button pressed; closing it
  unpresses it. Each change emits `toggled`.
- `PopupMenu.index_pressed` is the signal the old tool strip connected.

## New files: plugins/brush/

### toolbar.tscn

Root: `MenuButton` named `brush`.

- `button_group` = external `res://ui/ToolBarButtonGroup.tres` (same resource as the eraser).
- `shortcut` = subresource `Shortcut` with one `InputEventAction` for `tool_pencil`.
- `icon` = `res://icons/pencil.svg`. `icon_alignment = 1`.
- `tooltip_text = "Pencil"`.
- `item_count = 2`. `popup/item_0/text = "Pencil"` with the pencil icon.
  `popup/item_1/text = "Paint"` with the paint icon.

No script on this scene. The plugin script wires it, matching the eraser pilot.

### brush.gd (tool scene, moved from tools/brush/brush.tscn)

`Node3D` named `BrushTool` with the moved `pencil_tool.gd`. Content unchanged except the
script path. The two tool instances (pencil, paint) come from this one scene.

### pencil_tool.gd (moved from tools/brush/)

- Add `var add_mode := true`.
- `_add_mode()` returns `add_mode` instead of `info.id == "pencil"`.
- Remove every remaining `info` reference.

### BrushPlugin.gd

```
class_name BrushPlugin
extends VoxiPlugin
```

Members:

- `const ToolBar = preload("toolbar.tscn")`
- `const Tool = preload("brush.gd")` (the tool scene)
- `@onready var _toolbar: MenuButton = ToolBar.instantiate()`
- `var _pencil: PencilTool` and `var _paint: PencilTool`
- `var _mode := "pencil"`

`_ready()`:

1. Instantiate both tool nodes. Set `_pencil.add_mode = true`, `_paint.add_mode = false`.
2. Connect `_toolbar.toggled` to `_on_toolbar_toggled`.
3. Connect `_toolbar.get_popup().index_pressed` to `_on_mode_selected`.
4. `add_tool_bar_item(_toolbar)`.
5. `activate_tool()` so the pencil is active at startup.

`_on_toolbar_toggled(pressed: bool)`:

- `pressed` is true: `activate_tool()`.
- `pressed` is false: `deactivate_tool()`.

`_on_mode_selected(index: int)`:

- Map index to mode: 0 is `"pencil"`, 1 is `"paint"`.
- Set `_mode`.
- Swap `_toolbar.icon` and `_toolbar.tooltip_text` to the mode's values.
- If the button is pressed, call `activate_tool()`.
- If the button is not pressed, set `_toolbar.button_pressed = true` and let the resulting
  `toggled(true)` call `activate_tool()`.

The branch is required. In the app flow the popup close unpresses the button before
`index_pressed` fires, so only the button press activates. In the test flow the button stays
pressed and `index_pressed` is emitted directly, so the handler activates. A single
`activate_tool()` call per selection keeps the editor-node add and remove balanced.
The property-set press runs outside the engine press cascade, so the write is safe
(NOTES.md 2026-08-24).

`activate_tool()`:

- `_toolbar.set_pressed_no_signal(true)` (idempotent if already pressed).
- `remove_editor_node` the inactive node, `add_editor_node` the node for `_mode`.

`deactivate_tool()`:

- `remove_editor_node` the node for `_mode`.

The button and the tool node stay in lockstep: exactly one brush tool node is in the viewport
while the button is pressed.

## Changed files

### tools/voxel_tool.gd

No change. The base tool already has no `info`. The brush fixes its own `info` reference.

### VoxiPlugin.gd

`add_editor_node` targets `/root/Main/%Viewport/%ViewportScene`.
`remove_editor_node` targets `/root/Main/%ViewportContainer/%ViewportScene`, and no node with
that unique name exists. Point both at the same node:
`/root/Main/%Viewport/%ViewportScene` (the `ViewportScene` node in `ui/Viewport/Viewport.tscn`).

Leave `add_control_bar_item` as is. The `%ControlBar` node does not exist yet; that is a
separate task.

### state/State.gd

In `_ready()`, register the brush between the test and eraser plugins:

```
add_plugin(load("res://plugins/test/TestPlugin.gd").new())
add_plugin(load("res://plugins/brush/BrushPlugin.gd").new())
add_plugin(load("res://plugins/eraser/EraserPlugin.gd").new())
```

Order matters: the toolbar fills in registration order, and the tests resolve the brush button
as the first child of `%ToolBar`. The test plugin adds no toolbar button, so the brush stays
first.

### viewport/editor_viewport.gd

Restore `class_name EditorViewport` on line 1. The test harness and the tests type their
viewport handle with this name. The node structure did not move; only the class name went away.

### tests/test.gd

Rewrite `editor_viewport(inst)` for the new viewport tree. The old body resolves
`%ViewportContainer` and `%Editor`; neither exists anymore.

New body:

```
func editor_viewport(inst: Node) -> EditorViewport:
	var vp_root := inst.get_node("%Viewport")
	return vp_root.get_node("%ViewportScene") as EditorViewport
```

Unique names are scoped to the owner scene, so the call goes through the subscene instance root
(NOTES.md 2026-08-22).

Add a tool-activation helper:

```
func press_tool_button(inst: Node, button_name: String) -> void:
	var bar := inst.get_node("%ToolBar")
	var button := bar.get_node(button_name) as BaseButton
	button.button_pressed = true
```

The property-set press unpresses the other toolbar buttons through the shared `ButtonGroup`.
It does not open a `MenuButton` popup.

Add a mode-switch helper:

```
func select_brush_mode(inst: Node, index: int) -> void:
	var bar := inst.get_node("%ToolBar")
	var button := bar.get_node("brush") as MenuButton
	button.get_popup().index_pressed.emit(index)
```

This mirrors the pattern the existing `toolbar_modes.gd` already uses.

Add a tool-node lookup helper:

```
func tool_node(inst: Node, node_name: String) -> Node3D:
	var vp := editor_viewport(inst)
	return vp.get_node_or_null(node_name) as Node3D
```

The tool nodes are children of `ViewportScene` under their scene root names (`BrushTool`,
`EraserTool`).

### Tests

Pattern for every changed test: replace `State.set_tool(State.tools.X)` with
`press_tool_button(_inst, "brush")` or `press_tool_button(_inst, "eraser")`. Replace
`_vp._tool.visual` with `tool_node(_inst, "BrushTool").visual` or the eraser equivalent.

- `tests/brush_modes.gd`
  - Line 25: `press_tool_button(_inst, "brush")` (pencil is the default mode).
  - Line 49: `select_brush_mode(_inst, 1)` then `press_tool_button(_inst, "brush")` if the
    button was unpressed; the mode handler re-presses it, so the press call is the assertable
    path. Verify against the running behavior during implementation.
- `tests/stroke_connect.gd`
  - Line 26: `press_tool_button(_inst, "brush")`.
- `tests/paint.gd`
  - No change. It relies on the pencil being active at startup.
- `tests/toolbar_modes.gd`
  - `%ToolStrip` becomes `%ToolBar`.
  - `State.tool == State.tools.paint_brush` becomes an assertion on the button: icon is the
    paint icon and `button_pressed` is true.
  - Keep the existing `popup.index_pressed.emit(1)` call; it is the same path the new helper
    wraps.
- `tests/erase_drag.gd`
  - Line 25: `press_tool_button(_inst, "eraser")`.
- `tests/erase_drag_visual.gd`
  - Line 25: `press_tool_button(_inst, "eraser")`.
  - Lines 49, 64: `_vp._tool.visual` becomes `tool_node(_inst, "EraserTool").visual`.
- `tests/erase_hover.gd`
  - Line 23: `press_tool_button(_inst, "eraser")`.
  - Line 34: `_vp._tool.visual` becomes `tool_node(_inst, "EraserTool").visual`.

## Deletions

- `tools/brush/` (the directory): `pencil_tool.gd` and `brush.tscn` move to `plugins/brush/`.
- `tools/pencil.tres` and `tools/paint_brush.tres`: orphaned `ToolInfo` resources. The base
  tool no longer reads them. The other orphaned `.tres` files stay; they are deleted with their
  own tool migrations.

## NOTES.md

Record, dated:

- A `Shortcut` on a `MenuButton` opens the popup. The full press path runs: group unpress,
  `toggled`, `pressed()`.
- Closing a `MenuButton` popup unpresses the button and emits `toggled(false)`. A mode handler
  that re-presses the button must set `button_pressed` after the selection, and the write runs
  outside the engine press cascade.

## Verification

1. `godot --headless --import` after `pencil_tool.gd` and `BrushPlugin.gd` land (new
   class names).
2. Run each changed test headless, one command per test:
   `brush_modes`, `paint`, `stroke_connect`, `toolbar_modes`,
   `erase_drag`, `erase_drag_visual`, `erase_hover`.
3. Fix failures against the running behavior. Re-run each failing test.
4. Windowed run of `brush_modes` and `erase_drag` for a visual check of the toolbar icon swap
   and the hover highlight (optional; the harness captures screenshots on failure).

The full suite is not run. The other tests are broken by the strip and are out of scope.

## After this lands: remaining migration steps

1. pick plugin (single Button, no options) -> color_pick.
2. fill plugin (single Button; options: connected, color_epsilon) -> fill_all, wand_all.
3. select plugin (MenuButton: select, lasso, wand; options: mode picker, clear, connected,
   tolerance) -> selection*, lasso, wand_*.
4. transform plugin (MenuButton: move, rotate; options: snap, commit, cancel) -> move*, rotate*.
5. plane plugin (single Button; options: axis picker) -> floor_plane.
6. Cleanup: delete `ToolInfo`/`ToolOption` remnants, the remaining tool `.tres` files, the dead
   `viewport/` members, and update the remaining tests. Full suite.
