# MCP server

The editor hosts a local Model Context Protocol server. An agent can read the document and edit it with the current brush, paint, eraser, or fill tool.

## Start the server

Click the server icon in the status bar. The icon is dim when the server is off. It is bright when the server is on. The tooltip shows the endpoint.

The server listens on `http://127.0.0.1:17373/mcp` while it runs. Use `--mcp-port=<port>` to change the port.

The app remembers the last state in `user://interface.cfg`. The server starts with the app when the saved state is on.

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
      "lve_local": {
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

- Claude Code: `claude mcp add --transport http lve_local http://127.0.0.1:17373/mcp`
- Cursor: put the URL in `.cursor/mcp.json`.
- Codex: put the URL under `[mcp_servers.lve_local]` in `config.toml`.

## Tools

| Tool | Action |
| --- | --- |
| `get_state` | Read the compact document, tags, active tag, tool, material, selection, symmetry, slice, busy, and undo state. It also returns the content revision and the current frame cell bounds |
| `inspect_document` | Read a semantic summary of one or more frames: integer bounds, occupied count, materials, connected islands, tags, and transitions |
| `get_regions` | List connected regions by material or by frame. Use it to target a part |
| `get_slice` | Read labeled 2D slices or projections as text. Use it for exact shape and material layout |
| `get_map` | Read a coarse occupancy grid. Use it to locate content in a large frame |
| `get_changes` | Read cells changed since a revision. Use the revision from a read or a write |
| `get_cells` | Read occupied cells in a box as x-runs. Omit min and max to use the frame bounds. Pass next back as cursor to continue |
| `screenshot` | Save a PNG of one frame, a view contact sheet, or a frame storyboard. Set `inline` true to return the image |
| `new_document` | Open an empty document in a new tab |
| `save_document` | Save a copy of the current document as `.lve` or `.lve.png`. Set `copy` false to save the main document |
| `open_document` | Open a saved `.lve` or `.lve.png` document in a new tab |
| `add_frame` | Add an empty frame at the end or at an index |
| `remove_frame` | Remove one frame. The last frame stays |
| `move_frame` | Move one frame to a new index |
| `duplicate_frame` | Copy the current frame and insert it after |
| `set_frame` | Make one frame current |
| `set_frame_delay` | Set one frame duration in milliseconds |
| `add_tag` | Add a tag with a frame range, loop mode, and repeat count |
| `remove_tag` | Remove one tag. The last tag stays |
| `rename_tag` | Rename one tag |
| `set_tag_range` | Set one tag's inclusive frame range |
| `set_active_tag` | Select one tag or clear the selection |
| `set_tag_loop` | Set one tag's loop mode and repeat count |
| `set_playback` | Start or stop animation playback |
| `set_tool` | Select brush, eraser, paint, or fill and set its options |
| `set_material` | Set the current material, emission, or palette entry |
| `set_cursor` | Move the active tool cursor |
| `stroke` | Draw a brush, paint, or eraser stroke through cell points |
| `fill` | Fill a connected or matching region from a seed |
| `write_cells` | Write or erase cells, boxes, or runs with optional per-cell materials and frames. One call is one undo action |
| `sample` | Copy a cell material to the current material |

The tools use integer cell coordinates. Cell `c` covers `[c - 0.5, c + 0.5]`. Y is up.

## Read a document

Use this order to build a mental model without reading many cells.

1. Call `get_state` for the document name, revision, and current frame bounds.
2. Call `inspect_document` for bounds, materials, islands, and tags. Set `transitions` true to compare frames.
3. Call `get_slice` for exact shape. Call `get_map` to find content in a large frame.
4. Call `screenshot` with `views` for form and with `frames` for animation.
5. Call `get_cells` for exact cells. Omit `min` and `max` to read the frame bounds.
6. Call `get_changes` with the last revision to verify an edit.

`inspect_document` groups islands by material by default. Set `group` to `frame` to merge touching cells of different materials. It limits the island list to `max_islands`. It reports `island_count` and `islands_truncated` when the list is short.

`get_slice` uses `axis` x, y, or z. The `layers` list selects layers on that axis. The `materials` mode returns one character per material and a legend. The `height` and `depth` modes return a projection as `values`. `scale` sets the cells per character. The response states the column axis, the row axis, and the start cells.

`get_map` divides the frame into blocks of `cell_size` cells. A block entry is `[bx, by, bz, occupied, material]`. Block `0,0,0` starts at `origin`. The `material` is the most common material in the block.

A frame above the scan limit uses a chunk-aligned map. `cell_size` is 16, `chunk_aligned` is true, and `approximate` is true. The block coordinates are chunk coordinates. Block `0,0,0` starts at cell 0. Use this map to find a region, then call `get_cells` for exact cells.

`get_changes` returns x-runs. `full_refresh` true means the change journal cannot describe the range. Call `inspect_document` and `get_cells` after a full refresh. `chunk_origins` lists one cell per changed chunk. A stroke or fill reports `changed_chunks`, not exact cells, because the tool publishes chunk ids. Read the cells in those chunks with `get_cells`.

Every read returns a `revision`. Every write returns the new `revision` and its changed bounds. Pass the last revision to `get_changes`. An undo or redo asks for a full refresh because it has no cell list.

## Compact forms

`get_cells` returns x-runs. A run is `[x_first, x_last, y, z, material_index]`. The material index refers to the `materials` table. The default cap is 512 cells. Set `max_cells` up to 4096. A truncated read returns `next`, the first occupied cell not included. Pass `next` back as `cursor` with the same `min` and `max` to continue. Do not use `next` as a new `min`. The scan order is z, then y, then x. Omit `min` and `max` to read the frame bounds. `scanned_bounds` names the box. `returned_bounds` names the cells in the result.

The material index is local to one response. The same material can have a different index on another page. Compare the `key` field of the `materials` entries across pages. Set `material` to a color to read only that material.

`write_cells` accepts three cell forms:

- `cells`: `[x, y, z]` or `[x, y, z, material_index]`
- `boxes`: `[x0, y0, z0, x1, y1, z1]`, inclusive, or the same with a trailing `material_index`
- `runs`: `[x0, x1, y, z]`, inclusive, or the same with a trailing `material_index`

Provide at least one form. A shape without an index uses the current material. Set `materials` to a list of material objects and use the index in a shape. Set `frames` to write the same shapes to several frames. One call is one undo action, even across frames. `label` names the history action. The current frame stays the same.

`get_state` returns a compact state. It omits the camera and other detail that editing does not need.

`set_material` accepts `color`, `emission`, `metallic`, and `roughness`. Emission gives the voxel a glow. A color change clears the glow unless you also pass `emission`. Set `emission` to `#000000` to clear it explicitly.

`screenshot` saves `user://mcp_screenshot.png` and returns the path by default. Set `inline: true` to also return the image. The default size is 256. Use `focus` with an inclusive `[x0, y0, z0, x1, y1, z1]` box to frame a detail. `focus` applies to the named views. The current view refuses it. The `low` view frames a floating scene from below.

Set `views` to a list of named views to render a contact sheet. Set `frames` to a list of frame indices to render a storyboard. A storyboard uses the union bounds of the selected frames, so the content stays in place. `size` is the tile edge. The response reports `columns`, `rows`, `tile_size`, `bounds`, and the view or frame list.

`save_document` writes a `.lve` file. A `.lve.png` path also stores a 256 by 256 preview, which needs a visible window. It writes a copy by default and leaves the main document path and unsaved mark unchanged. Set `copy` false to save the main document, update the tab path, clear the unsaved mark, and update the session. Use a new path for each iteration so an earlier file stays intact. `open_document` opens both forms in a new tab.

The server logs one line per tool call with its response bytes in `user://mcp_server.log`.

## Editing rules

- Call `set_tool` before `stroke` or `fill`.
- Each call is one undo action.
- A user edit blocks an agent action. The tool returns a busy error.
- The selection, slice, and document size limit every write.
- `write_cells` and `fill` use the current material.

## Animate

- Use `duplicate_frame` to keep the static set pieces and change only the moving parts.
- Erase the previous moving cells before you write the next frame.
- Use `set_frame_delay` to time each frame.
- Use `add_tag` to make one tag per action. The frame range is inclusive.
- Use `set_tag_range`, `rename_tag`, and `remove_tag` to edit a tag.
- Use `set_tag_loop` with `ping_pong` to reverse a growth sequence into a loop.
- Use `set_active_tag` to select the tag that playback runs.
- Use `set_playback` to start or stop the preview.
- The new tag becomes active. The last tag and the last frame are kept.

## Limits

The first version supports brush, paint, eraser, fill, exact writes, material sample, screenshots, documents, frames, tags, and playback. Terrain, selection, transform, and clipboard are not exposed yet.

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
godot --headless --path . -s res://tests/run_all.gd -- mcp_server
```

The server writes `user://mcp_server.log`. The bridge writes `user://mcp_bridge.log`.
