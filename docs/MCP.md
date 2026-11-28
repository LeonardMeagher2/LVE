# MCP server

The editor hosts a local Model Context Protocol server. An agent can read the document and edit it with the current brush, paint, eraser, or fill tool.

## Start the server

Click the server icon in the status bar. The icon is dim when the server is off. It is bright when the server is on. The tooltip shows the endpoint when the server is on.

The server listens on `http://127.0.0.1:17373/mcp` while it runs. Use `--mcp-port=<port>` to change the port.

The app remembers the last state in `user://settings.cfg`. The server starts with the app when the saved state is on.

To start the server for one run, use the MCP flag:

```text
godot --path . -- --mcp
```

The flag does not change the saved state. Use `--no-mcp` to ignore a saved on state for one run.

The MCP tools change the editor as the user does. The agent uses the current tool, options, material, selection, and undo history. It has no private cursor or color.

## Connect opencode

Add this entry to `opencode.json`:

```json
{
  "mcp": {
    "servers": {
      "lve": {
        "type": "remote",
        "url": "http://127.0.0.1:17373/mcp",
        "oauth": false
      }
    }
  }
}
```

The `oauth` field must be `false`. The server uses no OAuth.

Other harnesses use the same URL:

- Claude Code: `claude mcp add --transport http lve http://127.0.0.1:17373/mcp`
- Cursor: put the URL in `.cursor/mcp.json`.
- Codex: put the URL under `[mcp_servers.lve]` in `config.toml`.

## Result shapes

Each tool declares an `outputSchema` with a root object. A client that renders the schema shows the return type before the first call. A tool result carries the data twice. `structuredContent` holds the object. `content[0].text` holds the same object as JSON text, for clients that read text only.

A legacy client rejects a tool list when one `outputSchema` is not a root object. Keep the root object when you add a tool.

## Protocol

The server answers protocol revision `2025-06-18` only. An older revision has no `outputSchema`, so the client could not show a return type.

The server publishes a short resource index and topic guides:

- `lve://guide` is the index. It points to the topic resources.
- `lve://guide/setup`, `lve://guide/tools`, `lve://guide/read`, `lve://guide/workspace`, `lve://guide/write`, `lve://guide/export`, `lve://guide/animate`, and `lve://guide/reference` are the topic slices.
- `lve://document-format` is the file format reference.

A client reads a resource with `resources/list` and `resources/read`. The initialize `instructions` field carries a short orientation, the guide map, and a one-line index of every tool generated from the input schemas. Each tool description ends with the guide topic for its workflow.

## Tools

| Tool | Action |
| --- | --- |
| `get_state` | Read the compact document, tags, active tag, tool, material, selection count and bounds, symmetry, slice, busy, and undo state. It also returns the content revision and the current frame cell bounds |
| `inspect_document` | Read a semantic summary of one or more frames of the active layer: integer bounds, occupied count, materials, connected islands, tags, and transitions. It does not return exact cells. Limit islands to a box or one material. One frame also puts its fields at the root |
| `get_slice` | Read labeled 2D slices or projections as text. Use it for exact shape and material layout |
| `get_map` | Read a coarse occupancy grid. Use it to locate content in a large frame |
| `get_changes` | Read cells changed since a revision. Use the revision from a read or a write |
| `get_cells` | Read the active layer's occupied cells in a box as x-runs. Omit min and max to use the frame bounds. Pass next back as cursor to continue |
| `get_layer_cells` | Read one layer's occupied cells in a box as x-runs. Omit `layer` for the active layer. Uses the same box, material, and cursor options as `get_cells` |
| `screenshot` | Save a PNG of one frame, a view contact sheet, or a frame storyboard and return its absolute path. Set the view, lighting, shading, wireframe, and `inline` options. Set `layer` to render one layer; omit it for the visible composite |
| `model_sheet` | Render the standard seven-view model sheet for one frame: front, back, left, right, top, bottom, and isometric. Uses the same options as `screenshot`, including `layer` |
| `new_document` | Open an empty document in a new tab |
| `save_document` | Save the current document as `.lve` or `.lve.png` at an absolute path. Omit `path` to save the open document. A path writes a copy unless `copy` is false. A missing folder is created |
| `open_document` | Open a saved `.lve` or `.lve.png` document at an absolute path in a new tab |
| `get_workspace` | Read the saved workspace: camera, lighting, view, export, current frame and tag, playback, and size |
| `set_workspace` | Replace the saved camera, lighting, view, export, or playback state. The active editor applies it. It is not an undo action |
| `set_document_settings` | Set smooth normals, ambient occlusion strength, and the centered document size. One undo action |
| `get_export_settings` | Read the export settings the editor uses now. It also returns the document path and the default model and sprite paths |
| `export_model` | Export a `.glb` or `.gltf` file with per-call model settings. Omit `path` to export beside the document |
| `export_sprite_sheet` | Export a PNG sprite sheet, optional aligned normal and specular sheets, and optional Aseprite JSON metadata. Omit `path` to export beside the document |
| `export_gif` | Export an animated GIF with per-call settings. Omit `path` to export beside the document |
| `add_frame` | Add blank frames at the end or at an index, in one undo action. A new frame holds no cells |
| `remove_frame` | Remove one frame, or a list in one undo action. The last frame stays |
| `move_frame` | Move one frame or a block to a new index, in one undo action. Omit `from` to move the current frame |
| `duplicate_frame` | Copy the current frame and insert it after |
| `set_frame` | Make one frame current |
| `set_frame_delay` | Set one frame duration, or a list, in milliseconds |
| `add_tag` | Add a tag with a frame range, loop mode, and repeat count |
| `remove_tag` | Remove one tag. Omit `tag` to remove the active tag. The last tag stays |
| `rename_tag` | Rename one tag. Omit `tag` to rename the active tag |
| `set_tag_range` | Set one tag's inclusive frame range |
| `set_active_tag` | Select one tag or clear the selection |
| `set_tag_loop` | Set one tag's loop mode and repeat count |
| `get_layers` | Read every layer from bottom to top: index, name, visibility, lock, filled cels, and active state |
| `select_layer` | Make one layer active by index or name. A name must match one layer |
| `add_layer` | Add a layer as one undo action. The default index is above the active layer |
| `duplicate_layer` | Copy one layer and its cels as one undo action |
| `delete_layer` | Delete one layer as one undo action. The last layer and a locked layer are refused |
| `rename_layer` | Rename one layer as one undo action. The name cannot be empty |
| `set_layer_visible` | Show or hide one layer as one undo action |
| `set_layer_locked` | Lock or unlock one layer as one undo action |
| `move_layer` | Move one layer to a new index as one undo action |
| `merge_layer_down` | Merge one layer into the layer below across every frame. The upper cell wins |
| `move_selection_to_layer` | Move the selection or the current cel to another layer as one undo action |
| `set_tool` | Select brush, eraser, paint, or fill and set its options |
| `set_material` | Set the current material, emission, or palette entry |
| `set_palette` | Replace the document palette in order. One undo action |
| `stroke` | Draw a brush, paint, or eraser stroke through cell points |
| `fill` | Fill a connected or matching region from a seed |
| `build_shape` | Build a box, ellipsoid, or cone from SDF primitives. Add, subtract, or intersect. One call is one undo action |
| `write_cells` | Write or erase cells, boxes, or runs, one form per call, with optional per-cell materials and frames. A later call overwrites what it covers. One call is one undo action |
| `set_selection` | Set, add, subtract, or clear the shared selection from cells or boxes. One call is one undo action |

The tools use integer cell coordinates. Cell `c` covers `[c - 0.5, c + 0.5]`. Y is up.

An omitted `frame` means the current frame. An omitted `tag` means the active tag. Every path is an absolute file system path. The server refuses a relative path and a Godot `user://` or `res://` path, because the client names a location the server cannot resolve on its own. The server creates a missing folder before a save or an export.

Each tool description ends with the guide topic for its workflow. The topic holds the rules that do not fit in a call.

## Workspace

`get_workspace` reads the state that opens with the document. It returns `camera`, `lighting`, `view`, `export`, `frame`, `tag`, `playing`, and `size`.

`set_workspace` replaces one or more sections. An omitted section keeps its value. Read the workspace first, change the fields you need, and pass the sections back. The tool accepts these shapes:

- `camera`: `yaw`, `pitch`, `distance`, `initial_distance`, `target` as `[x, y, z]`, and `fov` in degrees. Angles are radians. The editor uses 10 to 135 degrees. An export camera also accepts `orthographic`.
- `lighting`: `basis`, `color`, `energy`, `ambient_color`, `ambient_energy`, `shadows`, `shaded`, `view_locked`, and `view_basis`. A basis is three vectors: x, y, then z.
- `view`: `grid`, `wireframe`, `orthographic`, and `view_mode`.
- `export`: the export tab settings. It holds `view`, `frame_size`, `views`, `turntable`, `metadata`, `normal`, `specular`, `center`, `sprite_center`, `model_tag`, `sheet_tag`, `lighting`, and `camera`.
- `playing`: a boolean. A saved document with `playing` true runs its active tag when it opens.

An export `lighting` entry must be complete. It needs `basis`, `color`, `energy`, `ambient_color`, `ambient_energy`, `shadows`, and `shaded`. The document stores each editor strength in the color alpha. Write `energy` and `ambient_energy` instead of an alpha value.

The active editor applies the change to the viewport and the export tab. It applies the camera and view before the lighting, so a view-locked light keeps the requested values.

An edit stops playback. Set `playing` true in the last workspace call. A workspace change is not an undo action and does not mark the document edited. Save the document to keep it.

## Read a document

Use this order to build a mental model without reading many cells.

1. Call `get_state` for the document name, revision, and current frame bounds.
2. Call `inspect_document` for bounds, materials, islands, and tags. Set `transitions` true to compare frames.
3. Call `get_slice` for exact shape. Call `get_map` to find content in a large frame.
4. Call `screenshot` with `views` for form and with `frames` for animation.
5. Call `get_cells` for exact cells. Omit `min` and `max` to read the frame bounds.
6. Call `get_changes` with the last revision to verify an edit.

One frame is the common read. Then `index`, `occupied`, `bounds`, `materials`, and `islands` also sit at the root of the result. `frames` holds the same object, so an earlier client still works.

A material or island entry names its material by `key`. The key is `color|metallic|roughness|emission`, so the entry does not repeat the same values as an object.

`inspect_document` groups islands by material by default. Set `group` to `frame` to merge touching cells of different materials. Set `box` to limit island connectivity to an inclusive box, and `material` to list only one color. It limits the island list to `max_islands`. It reports `island_count` and `islands_truncated` when the list is short.

`get_slice` uses `axis` x, y, or z. The `layers` list selects layers on that axis. The `materials` mode returns one character per material and a legend. A legend entry is `char` and `key`. The `height` and `depth` modes return a projection as `values`. `scale` sets the cells per character. The response states the column axis, the row axis, and the start cells.

`get_map` divides the frame into blocks of `cell_size` cells. A block entry is `[bx, by, bz, occupied, material]`. Block `0,0,0` starts at `origin`. The `material` is the most common material in the block.

A frame above the scan limit uses a chunk-aligned map. `cell_size` is 16, `chunk_aligned` is true, and `approximate` is true. The block coordinates are chunk coordinates. Block `0,0,0` starts at cell 0. Use this map to find a region, then call `get_cells` for exact cells.

`get_changes` returns x-runs. `full_refresh` true means the change journal cannot describe the range. Call `inspect_document` and `get_cells` after a full refresh. `chunk_origins` lists the first cell of every changed chunk. A stroke reports its exact changed cells. A fill reports chunk origins, so read the cells of those chunks with `get_cells`.

Every read returns a `revision`. Every write returns the new `revision` and its changed bounds. Pass the last revision to `get_changes`. An undo or redo asks for a full refresh because it has no cell list.

## Compact forms

`get_cells` returns x-runs. The result key is `runs`, not `cells`. A run is `[x_first, x_last, y, z, material_index]`. The material index refers to the `materials` table. The default cap is 512 cells. Set `max_cells` up to 4096. A truncated read returns `next`, the first occupied cell not included. Pass `next` back as `cursor` with the same `min` and `max` to continue. Do not use `next` as a new `min`. The scan order is z, then y, then x. Omit `min` and `max` to read the frame bounds. `scanned_bounds` names the box. `returned_bounds` names the cells in the result.

The material index is local to one response. The same material can have a different index on another page. Compare the `key` field of the `materials` entries across pages. Set `material` to a color to read only that material.

`write_cells` accepts three cell forms:

- `cells`: `[x, y, z]` or `[x, y, z, material_index]`
- `boxes`: `[x0, y0, z0, x1, y1, z1]`, inclusive, or the same with a trailing `material_index`
- `runs`: `[x0, x1, y, z]`, inclusive, or the same with a trailing `material_index`

Provide exactly one of `cells`, `boxes`, or `runs`. Call the tool again to layer shapes. A later call overwrites the cells it covers, so write the bulk shapes first and the detail cells last. A shape without an index uses the current material. Set `materials` to a list of material objects and use the index in a shape. Without `materials`, a shape index names the document palette, so `[x, y, z, 1]` uses palette entry 1. Set `frames` to write the same shapes to several frames. One call is one undo action, even across frames. An erase with several frames applies the same shapes to every frame, so erase per frame when their contents differ. `label` names the history action. The current frame stays the same.

`get_state` returns a compact state. It omits the camera and other detail that editing does not need. `selection` is the selected cell count. `selection_bounds` is the inclusive box around the selected cells, or null when the selection is empty.

`set_selection` sets the shared selection that the user sees. It accepts the same `cells` and `boxes` forms as `write_cells`. Set `mode` to `replace`, `add`, or `subtract`. Set `mode` to `clear` to empty the selection. A selection can hold cells outside the current frame. One call is one undo action, and undo and redo restore the earlier selection.

## Primitive shapes

`build_shape` builds a box, an ellipsoid, or a cone from signed-distance primitives. One call is one undo action. A call that changes no cell creates no history action.

The call uses the current frame, the shared selection, the slice, the document size, and the current material. It does not change the active tool.

```json
{
  "primitives": [
    {"kind": "box", "center": [0, 0, 0], "half_size": [2, 2, 2]},
    {"kind": "ellipsoid", "center": [6, 0, 0], "radii": [2, 1, 1]},
    {"kind": "cone", "a": [0, 0, 10], "b": [0, 0, 20], "r1": 2, "r2": 0, "roundness": 0}
  ],
  "op": "add",
  "smooth": 3,
  "shell": 1,
  "material": 0,
  "step": 1
}
```

A box uses `center` and `half_size`. An ellipsoid uses `center` and `radii`. A cone uses `a`, `b`, `r1`, and `r2`. The radii can be fractional. `roundness` runs from 0 to 1. It rounds box edges and blends cone ends from flat at 0 to round at 1. The old `round` boolean is also accepted for cone ends.

`rotation` is an optional `[x, y, z]` of Euler angles in degrees, applied in XYZ order around the primitive center. A box or an ellipsoid turns in its local frame. A cone turns both ends around the center. Omit it for an axis-aligned shape.

`op` is `add`, `subtract`, or `intersect`. `add` writes the field cells. `subtract` removes the field cells. `intersect` keeps only the occupied cells inside the field in the current frame. The selection, slice, and document size still limit the write.

`smooth` blends the primitives in the call and the committed cells near them. It applies to `add` only. It keeps the committed cells and their materials. It only adds the new fillet and the empty part of the primitive. The field is clamped to half the smallest primitive extent. `shell` keeps a surface band of that thickness. Zero is solid. `step` builds blocks of that edge for a coarse form. The default is 1.

`material` is a palette index. An omitted value uses the current material. `label` names the history action.

The result carries `applied`, `bounds`, `changed_bounds`, `chunks`, `revision`, `warnings`, and `action`. `bounds` is the cell box of the shape. `changed_bounds` is the exact changed cell box. Warnings name a small radius, a clamped smooth blend, a coarse step, or a skipped existing blend.

The call accepts at most 64 primitives and 1048576 evaluated cells. A smooth blend with existing cells uses a local distance field. A very large local region skips the existing blend and returns a warning.

`set_material` accepts `color`, `emission`, `metallic`, and `roughness`. Emission gives the voxel a glow. A color change clears the glow unless you also pass `emission`. Set `emission` to `#000000` to clear it explicitly.

`set_palette` replaces the document palette in order. Each entry is a material object with `color` and optional `emission`, `metallic`, and `roughness`. A missing field uses a plain value, not the active brush material. Duplicate entries are removed, as in the palette panel. Existing voxel materials do not change. One call is one undo action.

To remap a color, set the current material to the new color, select the fill tool with `connected: false`, and fill a cell of the old color. The fill replaces every matching cell in the current frame, not only the connected region. It changes only cells inside the shared selection. Set a selection first to bound the replace, then clear it. The seed must lie inside the selection. The seed sets the target material, so run one fill for each material. Repeat for each frame. This is the same bucket remap as the editor, and it avoids a palette rebuild.

`screenshot` saves `mcp_screenshot.png` in the user directory and returns its absolute path by default. Set `path` to an absolute `.png` path to choose the file. Set `inline: true` to also return the image. The default size is 256. Use `focus` with an inclusive `[x0, y0, z0, x1, y1, z1]` box to frame a detail. `focus` applies to the named views. The current view refuses it. The `low` view frames a floating scene from below. Set `clip` to an inclusive `[x0, y0, z0, x1, y1, z1]` box to render only the cells inside it. The document does not change. The clipped cells supply the default bounds.

Set `orthographic: false` for a perspective view. `environment` defaults to true and applies the document light direction, light color, and ambient color. `shadows` and `shaded` default to true. `wireframe` defaults to false. The response reports every resolved option.

Set `views` to a list of named views to render a contact sheet. Set `frames` to a list of frame indices to render a storyboard. A storyboard uses the union bounds of the selected frames, so the content stays in place. `size` is the tile edge. The response reports `columns`, `rows`, `tile_size`, `bounds`, and the view or frame list.

`model_sheet` renders the standard seven views in one call: front, back, left, right, top, bottom, and isometric. It uses four columns and two rows by default, starts at frame 0 so playback cannot choose the frame, and accepts the same projection, lighting, shading, focus, clip, path, and `inline` options as `screenshot`.

`save_document` writes a `.lve` file. A `.lve.png` path also stores a 256 by 256 preview, which needs a visible window. Omit `path` to save the open document to its own path, update the tab path, and clear the unsaved mark. A path writes a copy by default: it leaves the main document path and unsaved mark unchanged. Set `copy` false to save the main document at that path. Use a new path for each iteration so an earlier file stays intact. `open_document` opens both forms in a new tab.

The server logs one line per tool call with its response bytes in `user://mcp_server.log`.

## Export

`get_export_settings` reads the values the export tab uses now: the sheet view, the tile size, the tag, the normal and specular sheet choices, and the model options.

`export_model` writes a `.glb` or `.gltf` file. It accepts `center`, `tag`, `smooth_normals`, `ao`, and `unlit`. It exports lit materials by default. `export_sprite_sheet` writes a PNG and optional Aseprite JSON metadata. It accepts `first_frame`, `last_frame`, `tag`, `tile_size`, `view`, `views`, `orthographic`, `center`, `metadata`, `normal`, and `specular`. `export_gif` writes an animated GIF that loops forever and uses each frame delay. It accepts `first_frame`, `last_frame`, `tag`, `tile_size`, `view`, `views`, `orthographic`, and `center`. `tag` is a tag index, and -1 uses `first_frame` and `last_frame`. `views` is the number of turntable views per frame, so 8 views over 4 frames gives 32 tiles. The sprite projection defaults to the export camera. Omit `path` on any export tool to write beside the document. An unsaved document exports to the user directory. `get_export_settings` returns the default document, model, and sprite paths.

Set `normal` true to write a normal sheet beside the color sheet. The file is `<name>_normal.png`. It uses the same tile grid as the color sheet. The RGB channels hold the view-space normal in the +x, +y, +z convention. Alpha is 1 on a drawn pixel and 0 on an empty pixel. The sidecar names the file under `meta.lve.normal`.

Set `specular` true to write a specular sheet. The file is `<name>_specular.png`. The RGB channels hold the metallic mask. The alpha channel holds shininess, which is `1 - roughness`. Set the `CanvasTexture.specular_shininess` value below 1 to enable the map. The sidecar names the file under `meta.lve.specular`. The color sheet keeps the baked lighting. In the editor, the Light toggle enables both the normal and specular sheets. The Specular value button changes only the preview light strength. `get_export_settings` reports that preview value as `specular_intensity`. The exported sheet keeps the full mask. A GIF holds color frames only.

Pass a key only when the call needs a value that differs from the export tab. The call does not change the document or the saved export settings. Every export tool returns the resolved path and the resolved values.

The sheet and the GIF need a visible editor window. A headless run returns an unavailable error.

## Editing rules

- Call `set_tool` before `stroke` or `fill`.
- `build_shape` does not need `set_tool`. It works from any active tool.
- Each call is one undo action.
- A user edit blocks an agent action. The tool returns a busy error.
- The selection, slice, and document size limit every write.
- `write_cells` and `fill` use the current material. A shape without an index uses the current material, not `materials[0]`.
- `build_shape` uses the current material when `material` is omitted.

## Animate

- `add_frame` always adds blank frames. Use `duplicate_frame` to copy the static set pieces, then change only the moving parts.
- Erase the previous moving cells before you write the next frame.
- Use `set_frame_delay` to time each frame. A `frames` list sets several delays in one action.
- Use `add_frame`, `remove_frame`, and `move_frame` with batches. `move_frame` takes `count` for a block. `remove_frame` takes `frames`. One call is one undo action.
- After `remove_frame`, the current frame stays current. If it was removed, the next remaining frame is current.
- Use `add_tag` to make one tag per action. The frame range is inclusive.
- Use `set_tag_range`, `rename_tag`, and `remove_tag` to edit a tag. Omit `tag` to use the active tag.
- Use `set_tag_loop` with `ping_pong` to reverse a growth sequence into a loop.
- Use `set_active_tag` to select the tag that playback runs.
- The new tag becomes active. The last tag and the last frame are kept.

## Layers

- Layer index 0 is the bottom layer. The highest index is the top layer. The timeline shows the top layer first.
- `get_layers` lists every layer. `get_state` reports only the layer count and the active index.
- `select_layer` accepts an index or an exact name. A name that matches more than one layer is refused. Use the index.
- The edit tools use the active layer. Select a layer before you write cells to it.
- `get_cells` reads the active layer. Use `get_layer_cells` to read another layer by index, and set `layer` on `screenshot` or `model_sheet` to render one layer.
- `inspect_document` summarizes the active layer's frames. Select the layer first when you need a different layer.
- Omit `layer` on `screenshot` or `model_sheet` to render the visible composite.
- A hidden layer stays out of the viewport, the thumbnails, and the export composite. Its cells remain in the document.
- A locked layer refuses edits, deletes, merges, and target moves. It still allows selection, rename, reorder, and visibility changes.
- `add_layer` inserts above the active layer by default. The new layer becomes active.
- `duplicate_layer` copies every cel and adds " copy" to the name. The copy becomes active.
- `delete_layer` selects the layer below. If the deleted layer is the bottom layer, it selects the layer above.
- `move_layer` uses the bottom-to-top order. The layer keeps its cels and state. The active layer stays active.
- `merge_layer_down` covers every frame. The upper cell wins an overlap. The target layer keeps its name and state. It becomes active.
- `move_selection_to_layer` works on the current frame. An empty selection moves the whole cel. The source layer stays active.
- Each layer change is one undo action. Selection is not an undo action.
- `get_changes` lists cell edits. A merge reports the target layer's cells.
- A layer name, order, visibility, lock, add, or delete needs a new `get_layers` or `get_state` read.

## Limits

The first version supports brush, paint, eraser, fill, primitive shapes, exact writes, selection, screenshots, documents, frames, tags, layers, and export. Terrain, transform, playback, and clipboard are not exposed yet.

## Bridge mode

A stdio bridge remains for pipe-based harnesses. Start the app in line mode and run the same binary:

```text
godot --path . -- --mcp --mcp-line
godot --headless --path . --no-header -- --mcp-bridge
```

The bridge reads newline-delimited JSON-RPC from stdin. It writes responses to stdout with `printraw`. The project setting `application/run/flush_stdout_on_print` keeps release output flushed.

opencode uses HTTP. Its local stdio process can echo the bridge input, so HTTP is the supported path for opencode.

## Security

The server binds to `127.0.0.1`. It has no authentication yet. The app remembers the last state, so the server can start with the app. Click the icon to stop it. Enable it only when an agent must use the editor. The agent can change the current document. Use undo or close the document without saving.

A browser page can send a cross-origin POST to a loopback port. The server refuses a POST that carries an `Origin` header. It also requires `Content-Type: application/json`. A non-MCP client can still call the tools.

## Tests

Run the MCP tests:

```text
godot --path . -s res://addons/test_kit/run.gd -- mcp_server
```

The server writes `user://mcp_server.log`. The bridge writes `user://mcp_bridge.log`.
