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
| `get_state` | Read the compact document, tool, material, selection, symmetry, slice, busy, and undo state |
| `get_cells` | Read occupied cells in a box as x-runs |
| `screenshot` | Save a PNG of one frame. Set `inline` true to return the image |
| `new_document` | Open an empty document in a new tab |
| `save_document` | Save the current document as `.lve` or `.lve.png` |
| `open_document` | Open a saved `.lve` or `.lve.png` document in a new tab |
| `add_frame` | Add an empty frame at the end |
| `duplicate_frame` | Copy the current frame and insert it after |
| `set_frame` | Make one frame current |
| `set_frame_delay` | Set one frame duration in milliseconds |
| `set_tag_loop` | Set the active tag loop mode and repeat count |
| `set_playback` | Start or stop animation playback |
| `set_tool` | Select brush, eraser, paint, or fill and set its options |
| `set_material` | Set the current material, emission, or palette entry |
| `set_cursor` | Move the active tool cursor |
| `stroke` | Draw a brush, paint, or eraser stroke through cell points |
| `fill` | Fill a connected or matching region from a seed |
| `write_cells` | Write or erase cells, boxes, or runs |
| `sample` | Copy a cell material to the current material |

The tools use integer cell coordinates. Cell `c` covers `[c - 0.5, c + 0.5]`. Y is up.

## Compact forms

`get_cells` returns x-runs. A run is `[x_first, x_last, y, z, material_index]`. The material index refers to the `materials` table. The default cap is 512 cells. Set `max_cells` up to 4096. A truncated read returns `next`, the first occupied cell not included.

`write_cells` accepts three cell forms:

- `cells`: `[x, y, z]`
- `boxes`: `[x0, y0, z0, x1, y1, z1]`, inclusive
- `runs`: `[x0, x1, y, z]`, inclusive

Provide at least one form. All forms use the current material and make one undo action.

`get_state` returns a compact state. It omits the camera and other detail that editing does not need.

`set_material` accepts `color`, `emission`, `metallic`, and `roughness`. Emission gives the voxel a glow. A color change clears the glow unless you also pass `emission`. Set `emission` to `#000000` to clear it explicitly.

`screenshot` saves `user://mcp_screenshot.png` and returns the path by default. Set `inline: true` to also return the image. The default size is 256. Use `focus` with an inclusive `[x0, y0, z0, x1, y1, z1]` box to frame a detail. `focus` applies to the named views. The current view refuses it. The `low` view frames a floating scene from below.

`save_document` writes a `.lve` file. A `.lve.png` path also stores a 256 by 256 preview, which needs a visible window. `open_document` opens both forms in a new tab. A successful save updates the tab save path, clears the unsaved mark, and updates the session. Use a new path for each iteration so an earlier file stays intact.

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
- Use `set_tag_loop` with `ping_pong` to reverse a growth sequence into a loop.
- Use `set_playback` to start or stop the preview.

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
