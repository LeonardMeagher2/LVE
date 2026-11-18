# MCP server

The editor hosts a local Model Context Protocol server. An agent can read the document and edit it with the current brush, paint, eraser, or fill tool.

## Start the server

Click the server icon in the status bar. The icon is dim when the server is off. It is bright when the server is on. The tooltip shows the endpoint.

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
| `inspect_document` | Read a semantic summary of one or more frames: integer bounds, occupied count, materials, connected islands, tags, and transitions. Limit islands to a box or one material. One frame also puts its fields at the root |
| `get_slice` | Read labeled 2D slices or projections as text. Use it for exact shape and material layout |
| `get_map` | Read a coarse occupancy grid. Use it to locate content in a large frame |
| `get_changes` | Read cells changed since a revision. Use the revision from a read or a write |
| `get_cells` | Read occupied cells in a box as x-runs. Omit min and max to use the frame bounds. Pass next back as cursor to continue |
| `screenshot` | Save a PNG of one frame, a view contact sheet, or a frame storyboard and return its absolute path. Set the view, lighting, shading, wireframe, and `inline` options |
| `model_sheet` | Render the standard seven-view model sheet for one frame: front, back, left, right, top, bottom, and isometric. Uses the same options as `screenshot` |
| `new_document` | Open an empty document in a new tab |
| `save_document` | Save the current document as `.lve` or `.lve.png` at an absolute path. Omit `path` to save the open document. A path writes a copy unless `copy` is false. A missing folder is created |
| `open_document` | Open a saved `.lve` or `.lve.png` document at an absolute path in a new tab |
| `get_workspace` | Read the saved workspace: camera, lighting, view, export, current frame and tag, playback, and size |
| `set_workspace` | Replace the saved camera, lighting, view, export, or playback state. The active editor applies it. It is not an undo action |
| `set_document_settings` | Set smooth normals, ambient occlusion strength, and the centered document size. One undo action |
| `get_export_settings` | Read the export settings the editor uses now. It also returns the document path and the default model and sprite paths |
| `export_model` | Export a `.glb` or `.gltf` file with per-call model settings. Omit `path` to export beside the document |
| `export_sprite_sheet` | Export a PNG sprite sheet, an optional aligned normal sheet, and optional Aseprite JSON metadata. Omit `path` to export beside the document |
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
| `set_tool` | Select brush, eraser, paint, or fill and set its options |
| `set_material` | Set the current material, emission, or palette entry |
| `set_palette` | Replace the document palette in order. One undo action |
| `stroke` | Draw a brush, paint, or eraser stroke through cell points |
| `fill` | Fill a connected or matching region from a seed |
| `write_cells` | Write or erase cells, boxes, or runs, one form per call, with optional per-cell materials and frames. A later call overwrites what it covers. One call is one undo action |
| `set_selection` | Set, add, subtract, or clear the shared selection from cells or boxes. One call is one undo action |

The tools use integer cell coordinates. Cell `c` covers `[c - 0.5, c + 0.5]`. Y is up.

An omitted `frame` means the current frame. An omitted `tag` means the active tag. Every path is an absolute file system path. The server refuses a relative path and a Godot `user://` or `res://` path, because the client names a location the server cannot resolve on its own. The server creates a missing folder before a save or an export.

Each tool description ends with the guide topic for its workflow. The topic holds the rules that do not fit in a call.

## Workspace

`get_workspace` reads the state that opens with the document. It returns `camera`, `lighting`, `view`, `export`, `frame`, `tag`, `playing`, and `size`.

`set_workspace` replaces one or more sections. An omitted section keeps its value. Read the workspace first, change the fields you need, and pass the sections back. The tool accepts these shapes:

- `camera`: `yaw`, `pitch`, `distance`, `initial_distance`, and `target` as `[x, y, z]`. Angles are radians. An export camera also accepts `orthographic` and `fov`.
- `lighting`: `basis`, `color`, `energy`, `ambient_color`, `ambient_energy`, `shadows`, `shaded`, `view_locked`, and `view_basis`. A basis is three vectors: x, y, then z.
- `view`: `grid`, `wireframe`, `orthographic`, `view_mode`, and `environment_open`.
- `export`: the export tab settings. It holds `view`, `frame_size`, `views`, `turntable`, `metadata`, `normal`, `center`, `sprite_center`, `model_tag`, `sheet_tag`, `lighting`, and `camera`.
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

`get_export_settings` reads the values the export tab uses now: the sheet view, the tile size, the tag, the normal sheet choice, and the model options.

`export_model` writes a `.glb` or `.gltf` file. It accepts `center`, `tag`, `smooth_normals`, `ao`, and `unlit`. It exports lit materials by default. `export_sprite_sheet` writes a PNG and optional Aseprite JSON metadata. It accepts `first_frame`, `last_frame`, `tag`, `tile_size`, `view`, `views`, `orthographic`, `center`, `metadata`, and `normal`. `export_gif` writes an animated GIF that loops forever and uses each frame delay. It accepts `first_frame`, `last_frame`, `tag`, `tile_size`, `view`, `views`, `orthographic`, and `center`. `tag` is a tag index, and -1 uses `first_frame` and `last_frame`. `views` is the number of turntable views per frame, so 8 views over 4 frames gives 32 tiles. The sprite projection defaults to the export camera. Omit `path` on any export tool to write beside the document. An unsaved document exports to the user directory. `get_export_settings` returns the default document, model, and sprite paths.

Set `normal` true to write a normal sheet beside the color sheet. The file is `<name>_normal.png`. It uses the same tile grid as the color sheet. The RGB channels hold the view-space normal in the +x, +y, +z convention. Alpha is 1 on a drawn pixel and 0 on an empty pixel. The sidecar names the file under `meta.lve.normal`. A GIF holds color frames only.

Pass a key only when the call needs a value that differs from the export tab. The call does not change the document or the saved export settings. Every export tool returns the resolved path and the resolved values.

The sheet and the GIF need a visible editor window. A headless run returns an unavailable error.

## Editing rules

- Call `set_tool` before `stroke` or `fill`.
- Each call is one undo action.
- A user edit blocks an agent action. The tool returns a busy error.
- The selection, slice, and document size limit every write.
- `write_cells` and `fill` use the current material. A shape without an index uses the current material, not `materials[0]`.

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

## Limits

The first version supports brush, paint, eraser, fill, exact writes, selection, screenshots, documents, frames, tags, and export. Terrain, transform, playback, and clipboard are not exposed yet.

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
