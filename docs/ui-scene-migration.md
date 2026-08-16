# UI scene migration (evaluation)

Goal: static UI structure + static signal wiring live in `scenes/main.tscn`;
scripts hold state and logic only. Scripts stay dependency-free — no node
construction, no signal connections — except where the scene can't express it.

## What moves to the scene (100% of static structure)

- All ~30 nodes: menu row (3 MenuButtons + spacer), tool row (4 toggle
  buttons, ColorPickerButton, recent-colors box), viewport row
  (SubViewportContainer > SubViewport > Editor Node3D), frame row
  (Play/Prev/Next, ScrollContainer > FrameStrip, Add/Dup/Del), status bar.
- 16 signal connections as `[connection]` entries: tool buttons pressed (4),
  ColorPicker color_changed, SubViewportContainer gui_input,
  SubViewport size_changed, Editor tool_pressed/tool_released/zoom_changed
  (3), frame buttons pressed (6).
- MenuButton item text via `item_count` + `"popup/item_N/text"` + `id`.

## What must stay in code

- MenuButton popup `id_pressed` wiring: the popup is an internal node, not
  addressable in the scene graph. Three `connect()` calls in `_ready`.
- Frame strip buttons: count = frame count (dynamic).
- Recent color swatches: count varies (dynamic).
- State: EditorState instance, playback vars, save path (main.gd);
  doc/camera/picking state (editor_viewport.gd).

## Handler convention

One small handler per connected control, so the scene needs no `.bind()`:
`_on_brush_pressed`, `_on_play_pressed`, `_on_prev_pressed`, etc.

## Aseprite reference (M4 layout target)

Compared to the current top-tool-row + single swatch + bottom frame row:

- Left panel: palette color grid + color area / hue / alpha / hex picker.
- Right: vertical tool icon strip.
- Bottom dock: animation playback toolbar + frame strip (layers out of MVP).
- Status bar: doc name + size (left), frame + zoom (right).

Layout changes land in M4; structure lives in the scene from now on.

## Acceptance criteria

- `main.gd` contains no UI node construction except dynamic frame/recent
  buttons and the FileDialog.
- `main.tscn` loads headless with zero script errors; all 16 connections
  resolve.
- File menu has 5 items with correct text (checked by smoke test).
- `godot --headless -s res://tests/smoke.gd` prints `VOXI SMOKE OK`.
