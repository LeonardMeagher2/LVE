# Architecture Refactor Plan

This document records the architecture analysis and the proposed refactor.
It covers three changes. They are S1, S2, and S3.

The goal is lower complexity and better modularization.
The changes follow the Godot OOP node-based philosophy.

## Current architecture

The code has four layers. They are separated by folder.

1. Data. These are Resources.
   They live in `document/` and `tools/`.
   They are `VoxiDocument`, `VoxelFrame`, `AnimationTag`, and `ToolInfo`.
2. Global state. This is the autoload `State`.
   It lives in `state/voxi.gd`.
   It holds session state, the tool registry, and an event bus.
3. Domain helpers. These are RefCounted classes.
   They live in `state/` and `viewport/`.
   They are `VoxelPicking`, `StrokeLine`, `PixelPerfectStroke`, `VoxelSelection`, and `Playback`.
4. Presentation. These are the widgets and the 3D world.
   They live in `ui/` and `viewport/`.

## What already follows Godot conventions

The code already does these things well.

- Widgets are nodes. They use signals. No widget references another widget.
  The `main.gd` file wires the widgets together.
- Data uses Resources. Save and load work with `ResourceSaver`.
- Tools are Node3D scenes. The editor instances them into a tool layer.
  The `ToolInfo` Resource makes the tools data-driven.
- Playback uses `AnimationPlayer` with a property track on `frame_index`.
- Tests run whole scenes. They do not use mocks.

## Complexity drivers

### The State autoload is a god object

All files read `State.document`, `State.current_frame`, and `State.current_color`.
Leaf utilities also use `State.NONE`.
This constant appears in `pick_result.gd`, `pixel_perfect.gd`, and `voxel_picking.gd`.
Leaf code depends on the global singleton.

### The viewport is a monolith

The file `viewport/editor_viewport.gd` has 335 lines.
It owns six concerns.

1. Camera rig. This handles orbit, pan, zoom, and presets.
2. Grid building.
3. MultiMesh voxel sync.
4. Selection outline.
5. Playback animation.
6. Tool spawning.

A change to one concern can affect the others.
The roadmap adds onion skinning and per-frame delays.
Both will force edits to this same file.

### main.gd is a mediator hub

The file `ui/main.gd` has 215 lines.
It wires more than 25 signals.
It owns the file dialogs and the save path.
It steps playback.
It formats the status bar.
Every new feature adds wires to this file.

### The tool base carries the whole stroke pipeline

The file `tools/voxel_tool.gd` has 241 lines.
It handles input routing, the press plane, pixel-perfect filtering, and undo snapshots.
`MoveTool` and `SelectTool` override `handle_input`.
They duplicate the mouse down, up, and motion structure.

### Minor issues

- The panel `viewport/viewport_container.gd` is a pass-through facade.
  It re-emits three signals and forwards methods with no logic.
- The `Playback` class mixes playback state with frame CRUD.
- The palette and the frame strip rebuild fully on each change.
  This is cheap now. It will cost more when the previews grow.

## The proposed changes

### S1. Split the viewport into child nodes

Status: done. The suite passes 21 of 21 tests after the change.

The `Editor` node keeps the coordinator role.
Each concern lives in its own Node3D child.
The `Editor` node is a thin parent that composes the children.

The scene tree after the change:

```
Editor (Node3D, editor_viewport.gd)
├── WorldEnvironment
├── Light
├── CameraRig (camera_rig.gd)
│   └── Camera3D
├── GridRoot (grid_renderer.gd)
├── ToolLayer
├── SelectionLayer (selection_overlay.gd)
│   └── SelectionOutline
├── Playback (playback_animator.gd)
│   └── AnimationPlayer
└── Voxels (voxel_renderer.gd)
```

The new files and their jobs:

- `viewport/camera_rig.gd` (`EditorCameraRig`).
  It handles orbit, pan, zoom, presets, and `zoom_changed`.
- `viewport/voxel_renderer.gd` (`VoxelRenderer`).
  It handles `sync_to`.
- `viewport/grid_renderer.gd` (`GridRenderer`).
  It builds the grid and the floor.
- `viewport/selection_overlay.gd` (`SelectionOverlay`).
  It builds the selection outline.
- `viewport/playback_animator.gd` (`PlaybackAnimator`).
  It rebuilds the animation and plays or stops preview.
- `viewport/mesh_util.gd` (`MeshUtil`).
  It builds the vertex arrays for the grid and the outline.

The `Editor` node keeps tool management, picking, and the `frame_index` property.
It forwards the child methods to its public contract.
The `EditorViewportPanel` facade stays unchanged.

Three details needed care.

1. The `AnimationPlayer` property track resolves its node path
   relative to `root_node`.
   The player now sits under `Playback`.
   Its `root_node` must be `NodePath("../..")` to target
   the `frame_index` property on the `Editor` node.
2. The test `tests/camera.gd` reads the camera state directly.
   It uses `_vp.camera_rig` for yaw, pitch, and target.
3. Input order needs no change.
   The tools use the left button.
   The camera rig uses the right and middle buttons.
   The two concerns never overlap.

The child nodes reduce the size of one class.
Each concern has a clear owner.
Godot uses the scene tree as its composition unit.
This change is not an abstraction layer.
It moves each concern to where Godot expects it.

### S2. Thin main.gd with controller nodes

Extract two cohesive nodes from `main.gd`.

- `FileController`. It owns the dialogs, the save path, and `ResourceSaver`.
- `PlaybackController`. It owns play, step, to-start, and to-end.

`main.gd` keeps the signal wiring and the status bar.
The file I/O block is already self-contained.
This move changes no behavior.
The file handling gets a name and a home.

### S3. Decouple the NONE constant from the autoload

Move `State.NONE` into a small static class.
The class name is `VoxelMath`.
Update the references in the leaf utilities.
This removes an accidental dependency.
The pure modules no longer need the global to compile.
This change is mechanical and small.

## Changes we will not do now

We keep these as documented tradeoffs.

- Whole-frame undo snapshots. They are simple and correct at this scale.
- Full rebuilds on change. They are cheap at the MVP scale.
- The two View menus. The plan keeps both.
- The `StrokeController` composition refactor. It is large and risky.
  Do it only when a new tool demands it.

## Order of work

Do the changes in this order.

1. S1. Split the viewport into child nodes. Done.
2. S3. Move the NONE constant.
3. S2. Extract the controllers from `main.gd`.

Run the full test suite after each change.
The suite is the only verification step.
The changes are independent of the Phase 3-5 UI work.
