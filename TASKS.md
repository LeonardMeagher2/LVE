---
max_active: 1
---

# M1 — Core loop

## Godot 4.7 API fixes
- [x] [Fix 4 remaining Godot 4.7.1 API issues](NOTES.md)
  - [x] MenuButton popup: replace `set_popup()` with `get_popup()`
  - [x] SubViewport input: replace broken `input_event` connection
  - [x] `_vertex_arrays`: return Array sized to `Mesh.ARRAY_MAX`
  - [x] `_highlight_frame`: use `remove_theme_stylebox_override("normal")`
- [x] Re-run `godot --headless -s res://tests/smoke.gd` until clean
- [x] Delete tests/probe.gd

## Scene-ify the UI
- [x] [Migrate static UI structure + signal wiring into main.tscn](NOTES.md)
  - [x] Rebuild main.tscn with the full static UI tree (~30 nodes)
  - [x] Declare all static signal connections in the scene ([connection] entries)
  - [x] Move MenuButton items into the scene (item_count + popup item text); only id_pressed wiring stays in code
  - [x] Slim main.gd down to state + handlers + dynamic builders (frame strip, recent swatches)
- [x] Re-run `godot --headless -s res://tests/smoke.gd` until clean

## Work-plane brush picking
- [x] [Anchor the brush stroke to the plane through the clicked point](NOTES.md)
  - [x] Start pick: ray DDA to a voxel, target is the cell beside the hit face
  - [x] Drag pick: ray to the stroke plane captured at stroke start
  - [x] Empty grid: ray to the floor plane, target on grid layer 0
  - [x] Orbit: trackball style, yaw inverted from the drag direction
  - [x] Default view: yaw -90°, pitch 45°
  - [x] Shift the DDA grid-space origin by +0.5 to match the mesh lattice
- [x] Add `tests/work_plane.gd` for floor and wall aim
- [x] Re-run `godot --headless -s res://tests/run_all.gd` until clean

## M1 verification
- [ ] Manual: paint 2-frame anim, undo/redo, playback, orbit/pan/zoom

# M2 — Save/load + in-game playback
- [ ] `scripts/game/voxel_animation_player.gd` (Node3D + MultiMesh playback)
- [ ] Test 3D scene loading + playing a `.tres`
- [ ] Verify save/load round-trip (ResourceSaver/ResourceLoader)

# M3 — Selection & editing
- [ ] Box select + move
- [ ] Copy/paste

# M4 — Aseprite-style chrome (ref: Aseprite screenshot)
- [ ] Left panel: palette color grid + color area / hue / alpha / hex picker
- [ ] Vertical tool icon strip (right side)
- [ ] Bottom dock: animation playback toolbar + frame strip (no layers in MVP)
- [ ] Onion skinning
- [ ] Palette management (add/remove/reorder colors)
