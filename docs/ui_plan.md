# UI Plan — Aseprite-style chrome

This document plans the look and behavior of the Voxi editor.
The target look is `UI_REFERENCE.png`. That file shows the Aseprite editor.
Build Voxi to match that structure.

## Current layout

Voxi is one vertical stack of five horizontal bars:

1. A menu bar: File, Edit, View.
2. A tool bar: text buttons for each tool, a color button, recent colors.
3. The 3D viewport.
4. A frame bar: playback buttons, the frame strip, frame action buttons.
5. A status bar.

The reference puts the tools and colors beside the viewport.
Voxi stacks them above and below it.

## Target layout

Keep the menu bar on top. Below it, a three-pane body.
A playback dock at the bottom. A status bar at the very bottom.

```
+--------------------------------------------------------------+
| File  Edit  View  (Frame  Select)                             |  menu bar
+-------------+----------------------------------+-------------+
| Palette     |  [1px] [stamp]  (pixel-perfect)  | (tools)     |
|  grid       +----------------------------------+  | B        |
|             |                                  |  | E        |
|             |         3D viewport              |  | F        |
|             |                                  |  | P        |
| Color area  |                                  |  | S        |
| Hue strip   +----------------------------------+  | M        |
| Alpha strip |  [---zoom---]  [1:1] [grid]      |             |
| #hex        |                                  |             |
+-------------+----------------------------------+-------------+
| [|<] [<] [>] [>|] [|>]   (frame strip)  [+] [dup] [-]        |  bottom dock
+--------------------------------------------------------------+
| Brush  #a1a1a1                        Frame 1/1  100%  16^3  |  status bar
+--------------------------------------------------------------+
```

## Left pane — palette and color

Width: fixed, 260–320 px.

1. Palette grid.
   - 8 columns. The grid scrolls when the palette overflows.
   - One swatch per color. Size: 36 x 36 px.
   - The first swatch is transparency. Show a checkerboard.
   - The current color gets a 2 px white border.
   - Click a swatch to make it the current color.
   - Click the empty area below the swatches to add a color.
   - Right-click a swatch to remove it.
2. Color picker, below the grid.
   - A compact picker with a color area, a hue strip, an alpha strip, and a hex field.
   - Moving the picker changes the current color at once.
3. Recent colors, below the picker.

The tool bar color button goes away. The left pane replaces it.

## Center pane — viewport

1. Option bar at the top, 28 px high.
   - A "Pixel-perfect" toggle. It turns voxel snapping of the ghost preview on and off.
   - A view menu: Top, Front, Side, Isometric, Reset.
   - Each entry sets the camera to a fixed angle.
2. The 3D viewport fills the rest of the pane.
   - The default camera frames the whole grid with even margins.
   - The grid center sits at the center of the viewport.
3. Control bar at the bottom, 28 px high.
   - A zoom slider. Range: 25–400 %.
   - A "1:1" button. It returns the zoom to 100 %.
   - A grid toggle button. The View menu keeps its grid item.

## Right pane — tool strip

Width: fixed, 40 px.

- One square button per tool, 32 x 32 px, stacked from the top.
- Tool order: Brush, Eraser, Fill, Pick, Select, Move.
- Each button shows a flat icon and a hover tooltip.
- The active tool stays visibly pressed.
- Keep the keyboard shortcuts (B, E, F, P).

The top tool bar goes away. The tool strip replaces it.

## Icons

One flat outline glyph per icon. Single stroke color. No gradients.
Tint the glyphs with the theme.

- Tools: brush, eraser, fill, pick, select, move.
- Playback: step to start, step back, play, pause, step forward, step to end.
- Frame actions: add, duplicate, delete.
- View: zoom to fit, grid, pixel perfect.
- Frame strip: show, hide, lock (later).

## Per-frame timing

Each frame has its own delay. The document no longer has one global speed.

- The delay is the time a frame stays on screen, in milliseconds.
- Default delay: 100 ms.
- A new frame copies the delay of the frame before the insert point.
- A duplicated frame copies the delay of its source frame.
- Playback shows each frame for its own delay.
- The total length is the sum of all frame delays.

UI:

- Each frame button shows its delay below its number.
- The delay of the selected frame is a small editable field.
- The delays of the other frames are dim text.
- The user types a value and presses Enter to apply it.
- The value is clamped to 1 to 10000 ms.
- The status bar shows the current delay and the total length.
- Format: `100ms / 2.45s`.

## Frame previews

Each frame button in the frame strip shows a small preview of that frame.

- The preview is 48 x 48 px.
- It shows the voxels from a fixed isometric angle.
- The angle does not follow the viewport camera.
- Each voxel shows its true color. Side and bottom faces are darker.
- An empty frame shows a transparency checkerboard.
- A preview refreshes when the frame's contents change.
- A preview refreshes after an add, duplicate, or delete action.

The reference shows named frame groups (idle, shoot, hurt).
Voxi has no frame groups. Track them as a separate task.

## Bottom dock — playback and frames

The dock has two rows.

1. Playback row, 28 px high.
   - Five icon buttons: step to start, step back, play/pause, step forward, step to end.
   - The play button swaps to a pause icon while playing.
   - Step to start selects the first frame. Step to end selects the last frame.
   - Stepping is manual. Playback runs on the per-frame delays.
2. Frame row, 76 px high.
   - The frame strip scrolls horizontally when the frames overflow.
   - Each frame button is a column: the 48 x 48 preview on top,
     the frame number below it, the delay below that.
   - The delay of the selected frame is the editable field.
     The other delays are dim text.
   - The current frame gets an accent background.
   - Add, Duplicate, and Delete sit at the far right as icon buttons.

## Status bar

- Left: `Brush   #A1A1A1`. The tool name, then the current color.
- Right: `100ms / 2.45s   Frame 1/1   100%   Grid 16`.
  The current delay and total length, frame position, zoom, grid size.

The current status bar already holds most of these values.
Change only the format.

## Look

One dark theme for the whole editor.

- Base background: `#1e1f22`.
- Panel background: `#26272b`.
- Border: `#3a3c42`, 1 px.
- Button face: `#2f3136`. Hover: `#3a3c42`. Pressed or active: `#31517a`.
- Text: `#c8cacc`.
- Accent (selection, active frame): `#31517a`.
- Corner radius: 2 px. Keep shapes nearly square.

Apply the theme at the top level. Do not style controls one by one.

## Work order

Do the steps in this order. Run the test suite after each step.

1. Apply the dark theme.
2. Add the icons.
3. Move the tools to the right strip. Remove the top tool bar.
4. Build the left pane: palette grid, color picker, recent colors.
5. Split the bottom dock into the playback row and the frame row.
6. Add the viewport option bar and the zoom bar.
7. Add the frame previews to the frame strip.
8. Add the per-frame delay labels and in-place delay editing.
9. Reformat the status bar text.

The existing tests reference node paths. Update them when a node moves.
Keep the viewport reachable at `Root/ViewportContainer/Viewport/Editor`.

## Out of scope

- Document tabs (the reference shows a "Home" tab and a sprite tab).
- Layers. Voxi has one implicit layer per frame.
- Frame groups. Track them as a separate task.
- Hover zoom on the frame strip. The 48 px preview is enough for the MVP.
- Onion skinning. Track it as a separate task.
- Multi-document editing.
