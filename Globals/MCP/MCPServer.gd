extends Node

## The in-app MCP server.
##
## It listens on the loopback interface and speaks newline-delimited JSON-RPC
## to the LVE bridge. The bridge converts stdio MCP messages to this connection.
## The tools drive the editor as the user: they use the real active tool, the
## current material, the shared selection, and the normal undo history.

## The default loopback port. The bridge uses the same default.
const DEFAULT_PORT := 17373
## The off-screen viewport used for screenshots.
const SCREENSHOT_VIEWPORT := preload("res://Globals/VoxelImageRenderer/RendererViewport.tscn")
## The server log in the shared user directory.
const LOG_PATH := "user://mcp_server.log"
## The largest request line the server accepts.
const MAX_LINE_BYTES := 4 * 1024 * 1024
## The largest cell box that one read scans.
const MAX_BOX_CELLS := 262144
## The default occupied-cell cap of one read.
const MAX_GET_CELLS := 512
## The largest cell count that one write accepts.
const MAX_WRITE_CELLS := 65536
## The largest cell count that one multi-frame write accepts.
const MAX_WRITE_TOTAL_CELLS := MAX_WRITE_CELLS * 4
## The largest frame cell count that the semantic read tools scan.
const MAX_SCAN_CELLS := 262144
## The largest island count that one read lists.
const MAX_INSPECT_ISLANDS := 256
## The largest number of entries the change journal keeps.
const MAX_JOURNAL_ENTRIES := 512
## The largest number of changed cells the change journal keeps.
const MAX_JOURNAL_CELLS := 262144
## The six face neighbors used by the connected region scan.
const REGION_NEIGHBORS := [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]
## The material slice characters. A slice with more materials uses "?".
const SLICE_CHARS := [
	"#", "+", "*", "o", "x", "=", "%", "&", "a", "b", "c", "d", "e", "f",
	"g", "h", "i", "j", "k", "l", "m", "n", "p", "q", "r", "s", "t", "u",
	"v", "w", "y", "z",
]

const TOOLS := [
	{
		"name": "get_state",
		"description": "Return the document, revision, current frame bounds, active tool, material, selection, symmetry, slice, busy, and undo state.",
		"inputSchema": {"type": "object", "additionalProperties": false},
	},
	{
		"name": "inspect_document",
		"description": "Read a semantic summary of one or more frames: integer cell bounds, occupied count, materials, connected islands, tags, and transitions between consecutive listed frames. Use this before get_cells.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"frame": {"type": "integer", "minimum": 0, "description": "One frame to inspect. Defaults to the current frame."},
				"frames": {
					"type": "array",
					"items": {"type": "integer", "minimum": 0},
					"minItems": 1,
					"maxItems": 64,
					"description": "Frame indices to inspect. Overrides frame.",
				},
				"materials": {"type": "boolean", "description": "Include the material histogram. Defaults to true."},
				"islands": {"type": "boolean", "description": "Include connected islands. Defaults to true."},
				"transitions": {"type": "boolean", "description": "Include changed counts and bounds between adjacent frames. Defaults to false."},
				"max_islands": {"type": "integer", "minimum": 1, "maximum": 256, "description": "Largest islands to list. Defaults to 32."},
				"min_island_cells": {"type": "integer", "minimum": 1, "description": "Skip smaller islands. Defaults to 1."},
				"group": {
					"type": "string",
					"enum": ["material", "frame"],
					"description": "Island grouping. material connects same-material cells. frame connects any occupied cells. Defaults to material.",
				},
				"palette": {"type": "boolean", "description": "Include the document palette at document.palette. Defaults to false."},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "get_regions",
		"description": "List connected regions of one frame. Use it to target a part without reading cells.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"frame": {"type": "integer", "minimum": 0},
				"box": {
					"type": "array",
					"items": {"type": "integer"},
					"minItems": 6,
					"maxItems": 6,
					"description": "Inclusive [x0, y0, z0, x1, y1, z1]. Connectivity is limited to the box.",
				},
				"group": {"type": "string", "enum": ["material", "frame"], "description": "Defaults to material."},
				"material": {"type": "string", "description": "Only this color, for example #ff0000."},
				"min_cells": {"type": "integer", "minimum": 1, "description": "Skip smaller regions. Defaults to 1."},
				"max_regions": {"type": "integer", "minimum": 1, "maximum": 256, "description": "Defaults to 32."},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "get_slice",
		"description": "Read labeled 2D slices or projections of one frame as text. Use it for exact shape and material layout.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"frame": {"type": "integer", "minimum": 0},
				"axis": {"type": "string", "enum": ["x", "y", "z"], "description": "Slice normal. Defaults to y."},
				"layers": {
					"type": "array",
					"items": {"type": "integer"},
					"minItems": 1,
					"maxItems": 32,
					"description": "Slice layers on the normal axis. Defaults to the middle layer.",
				},
				"mode": {
					"type": "string",
					"enum": ["occupancy", "materials", "height", "depth"],
					"description": "Defaults to materials. height and depth are projections along the axis.",
				},
				"scale": {"type": "integer", "minimum": 1, "maximum": 16, "description": "Cells per character or grid step. Defaults to fit max_size."},
				"max_size": {"type": "integer", "minimum": 8, "maximum": 256, "description": "Largest grid edge. Defaults to 64."},
				"box": {
					"type": "array",
					"items": {"type": "integer"},
					"minItems": 6,
					"maxItems": 6,
					"description": "Inclusive [x0, y0, z0, x1, y1, z1] to slice.",
				},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "get_map",
		"description": "Read a coarse occupancy grid of one frame. Use it to locate content before get_cells.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"frame": {"type": "integer", "minimum": 0},
				"cell_size": {"type": "integer", "minimum": 1, "maximum": 128, "description": "Block edge in cells. Defaults to 16."},
				"box": {
					"type": "array",
					"items": {"type": "integer"},
					"minItems": 6,
					"maxItems": 6,
					"description": "Inclusive [x0, y0, z0, x1, y1, z1].",
				},
				"max_blocks": {"type": "integer", "minimum": 1, "maximum": 4096, "description": "Largest block count. Defaults to 512."},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "get_changes",
		"description": "Read cells changed since a revision. Use the revision from get_state, inspect_document, get_cells, or a write response.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"since": {"type": "integer", "minimum": 0},
				"frame": {"type": "integer", "minimum": 0, "description": "Defaults to the current frame."},
				"box": {
					"type": "array",
					"items": {"type": "integer"},
					"minItems": 6,
					"maxItems": 6,
					"description": "Inclusive [x0, y0, z0, x1, y1, z1].",
				},
				"max_cells": {"type": "integer", "minimum": 1, "maximum": 65536, "description": "Changed-cell cap. Defaults to 4096."},
			},
			"required": ["since"],
			"additionalProperties": false,
		},
	},
	{
		"name": "get_cells",
		"description": "Read occupied cells in an inclusive box as x-runs of [x0, x1, y, z, material_index]. The material_index points into the returned materials list and is numbered per page, so read it back. Omit min and max to read the frame bounds. When truncated, pass next back as cursor with the same box to continue.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"min": {"type": "array", "items": {"type": "integer"}, "minItems": 3, "maxItems": 3},
				"max": {"type": "array", "items": {"type": "integer"}, "minItems": 3, "maxItems": 3},
				"cursor": {
					"type": "array",
					"items": {"type": "integer"},
					"minItems": 3,
					"maxItems": 3,
					"description": "Inclusive scan start from a previous next. Use the same min and max.",
				},
				"material": {"type": "string", "description": "Only this color, for example #ff0000."},
				"max_cells": {
					"type": "integer",
					"minimum": 1,
					"maximum": 4096,
					"description": "Occupied-cell cap. Defaults to 512.",
				},
				"frame": {"type": "integer", "minimum": 0},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "screenshot",
		"description": "Save a PNG to user://mcp_screenshot.png every call and overwrite it. Render one frame, a multi-view contact sheet, or a frame storyboard. Pass focus to frame a detail, or a far cell shrinks the model. Set inline true to also return the image.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"frame": {"type": "integer", "minimum": 0},
				"frames": {
					"type": "array",
					"items": {"type": "integer", "minimum": 0},
					"minItems": 1,
					"maxItems": 16,
					"description": "Render a storyboard of these frames in one image. Uses the union of their bounds.",
				},
				"views": {
					"type": "array",
					"items": {"type": "string", "enum": ["isometric", "low", "front", "back", "left", "right", "top", "bottom"]},
					"minItems": 1,
					"maxItems": 6,
					"description": "Render a contact sheet of these views in one image. Uses one shared bounds.",
				},
				"columns": {"type": "integer", "minimum": 1, "maximum": 8, "description": "Contact sheet columns. Defaults to a square grid."},
				"size": {"type": "integer", "minimum": 64, "maximum": 1024, "description": "Tile edge in pixels. Defaults to 256."},
				"view": {"type": "string", "enum": ["isometric", "low", "front", "back", "left", "right", "top", "bottom", "current"]},
				"orthographic": {"type": "boolean"},
				"inline": {"type": "boolean"},
				"focus": {
					"type": "array",
					"items": {"type": "integer"},
					"minItems": 6,
					"maxItems": 6,
					"description": "Inclusive [x0, y0, z0, x1, y1, z1] to frame. Named views only.",
				},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "new_document",
		"description": "Open a new empty document in a new tab and make it current. The current document stays open.",
		"inputSchema": {"type": "object", "additionalProperties": false},
	},
	{
		"name": "save_document",
		"description": "Save the current document as .lve or .lve.png and return its absolute path. It writes a copy by default and leaves the main document path and unsaved mark unchanged. Set copy false to save the main document. A .lve.png file also stores a preview.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"path": {"type": "string", "description": "A file name or user:// path ending in .lve or .lve.png."},
				"copy": {"type": "boolean", "description": "Write a copy and keep the main path and unsaved mark. Defaults to true."},
			},
			"required": ["path"],
			"additionalProperties": false,
		},
	},
	{
		"name": "open_document",
		"description": "Open a saved .lve or .lve.png document in a new tab and make it current. The current document stays open.",
		"inputSchema": {
			"type": "object",
			"properties": {"path": {"type": "string", "description": "A file name or user:// path."}},
			"required": ["path"],
			"additionalProperties": false,
		},
	},
	{
		"name": "add_frame",
		"description": "Add an empty frame. The default index is the last frame. The new frame becomes current.",
		"inputSchema": {
			"type": "object",
			"properties": {"index": {"type": "integer", "minimum": 0}},
			"additionalProperties": false,
		},
	},
	{
		"name": "remove_frame",
		"description": "Remove one frame. The last remaining frame is kept. Tags shift to the remaining frames.",
		"inputSchema": {
			"type": "object",
			"properties": {"frame": {"type": "integer", "minimum": 0}},
			"required": ["frame"],
			"additionalProperties": false,
		},
	},
	{
		"name": "move_frame",
		"description": "Move one frame to a new index.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"from": {"type": "integer", "minimum": 0},
				"to": {"type": "integer", "minimum": 0},
			},
			"required": ["from", "to"],
			"additionalProperties": false,
		},
	},
	{
		"name": "duplicate_frame",
		"description": "Copy the current frame and insert it after the current frame. The copy becomes current.",
		"inputSchema": {"type": "object", "additionalProperties": false},
	},
	{
		"name": "set_frame",
		"description": "Make one frame current.",
		"inputSchema": {
			"type": "object",
			"properties": {"frame": {"type": "integer", "minimum": 0}},
			"required": ["frame"],
			"additionalProperties": false,
		},
	},
	{
		"name": "set_frame_delay",
		"description": "Set one frame duration in milliseconds.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"frame": {"type": "integer", "minimum": 0},
				"ms": {"type": "integer", "minimum": 1, "maximum": 10000},
			},
			"required": ["ms"],
			"additionalProperties": false,
		},
	},
	{
		"name": "set_tag_loop",
		"description": "Set one tag's loop mode and repeat count. Omit tag to use the active tag. Repeats 0 means continuous playback.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"tag": {"type": "integer", "minimum": 0},
				"mode": {"type": "string", "enum": ["forward", "reverse", "ping_pong", "ping_pong_reverse"]},
				"repeats": {"type": "integer", "minimum": 0, "maximum": 1000},
			},
			"required": ["mode"],
			"additionalProperties": false,
		},
	},
	{
		"name": "add_tag",
		"description": "Add an animation tag with an inclusive frame range, loop mode, and repeat count. The new tag becomes active.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"name": {"type": "string"},
				"from": {"type": "integer", "minimum": 0},
				"to": {"type": "integer", "minimum": 0},
				"mode": {"type": "string", "enum": ["forward", "reverse", "ping_pong", "ping_pong_reverse"]},
				"repeats": {"type": "integer", "minimum": 0, "maximum": 1000},
			},
			"required": ["name"],
			"additionalProperties": false,
		},
	},
	{
		"name": "remove_tag",
		"description": "Remove one tag. The last remaining tag is kept.",
		"inputSchema": {
			"type": "object",
			"properties": {"tag": {"type": "integer", "minimum": 0}},
			"required": ["tag"],
			"additionalProperties": false,
		},
	},
	{
		"name": "rename_tag",
		"description": "Rename one tag.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"tag": {"type": "integer", "minimum": 0},
				"name": {"type": "string"},
			},
			"required": ["tag", "name"],
			"additionalProperties": false,
		},
	},
	{
		"name": "set_tag_range",
		"description": "Set one tag's inclusive frame range. The range must be inside the frames, or the call fails. Omit tag to use the active tag.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"tag": {"type": "integer", "minimum": 0},
				"from": {"type": "integer", "minimum": 0},
				"to": {"type": "integer", "minimum": 0},
			},
			"required": ["from", "to"],
			"additionalProperties": false,
		},
	},
	{
		"name": "set_active_tag",
		"description": "Select one tag by index. Set tag to -1 to clear the selection.",
		"inputSchema": {
			"type": "object",
			"properties": {"tag": {"type": "integer", "minimum": -1}},
			"required": ["tag"],
			"additionalProperties": false,
		},
	},
	{
		"name": "set_playback",
		"description": "Start or stop animation playback.",
		"inputSchema": {
			"type": "object",
			"properties": {"playing": {"type": "boolean"}},
			"required": ["playing"],
			"additionalProperties": false,
		},
	},
	{
		"name": "set_tool",
		"description": "Select the real editor tool and set its options. This changes the user's toolbar and option bar. Use brush, eraser, paint, or fill.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"tool": {"type": "string", "enum": ["brush", "eraser", "paint", "fill"]},
				"diameter": {"type": "integer", "minimum": 1, "maximum": 64},
				"shape": {"type": "string", "enum": ["cube", "sphere"]},
				"pixel_perfect": {"type": "boolean"},
				"connected": {"type": "boolean"},
			},
			"required": ["tool"],
			"additionalProperties": false,
		},
	},
	{
		"name": "set_material",
		"description": "Set the current material. A color keeps the current metallic and roughness. emission adds a glow. A palette_index selects that palette entry. The change is undoable.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"color": {"type": "string", "description": "#rrggbb or #rrggbbaa"},
				"emission": {"type": "string", "description": "#rrggbb or #rrggbbaa"},
				"palette_index": {"type": "integer", "minimum": 0},
				"metallic": {"type": "number", "minimum": 0, "maximum": 1},
				"roughness": {"type": "number", "minimum": 0, "maximum": 1},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "set_cursor",
		"description": "Move the active tool cursor to a cell. Pass null to hide it. This moves the user's cursor.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"cell": {"type": ["array", "null"], "items": {"type": "integer"}, "minItems": 3, "maxItems": 3},
			},
			"required": ["cell"],
			"additionalProperties": false,
		},
	},
	{
		"name": "stroke",
		"description": "Draw with the active brush, paint, or eraser tool through cell centers. Select the tool first. Each call is one undo action.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"points": {
					"type": "array",
					"items": {"type": "array", "items": {"type": "integer"}, "minItems": 3, "maxItems": 3},
					"minItems": 1,
					"maxItems": 4096,
				},
			},
			"required": ["points"],
			"additionalProperties": false,
		},
	},
	{
		"name": "fill",
		"description": "Fill a connected or matching region from an occupied seed cell. Select the fill tool first. The whole region is one undo action.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"seed": {"type": "array", "items": {"type": "integer"}, "minItems": 3, "maxItems": 3},
			},
			"required": ["seed"],
			"additionalProperties": false,
		},
	},
	{
		"name": "write_cells",
		"description": "Write or erase cells with per-cell materials and optional frames. Provide cells, boxes, or runs. Each call is one undo action, even across frames.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"cells": {
					"type": "array",
					"items": {"type": "array", "items": {"type": "integer"}, "minItems": 3, "maxItems": 4},
					"minItems": 1,
					"maxItems": 65536,
					"description": "Inclusive [x, y, z] or [x, y, z, material_index].",
				},
				"boxes": {
					"type": "array",
					"items": {"type": "array", "items": {"type": "integer"}, "minItems": 6, "maxItems": 7},
					"minItems": 1,
					"maxItems": 1024,
					"description": "Inclusive [x0, y0, z0, x1, y1, z1] or [x0, y0, z0, x1, y1, z1, material_index].",
				},
				"runs": {
					"type": "array",
					"items": {"type": "array", "items": {"type": "integer"}, "minItems": 4, "maxItems": 5},
					"minItems": 1,
					"maxItems": 65536,
					"description": "Inclusive x span [x0, x1, y, z] or [x0, x1, y, z, material_index].",
				},
				"materials": {
					"type": "array",
					"items": {
						"type": "object",
						"properties": {
							"color": {"type": "string", "description": "#rrggbb or #rrggbbaa"},
							"emission": {"type": "string", "description": "#rrggbb or #rrggbbaa"},
							"metallic": {"type": "number", "minimum": 0, "maximum": 1},
							"roughness": {"type": "number", "minimum": 0, "maximum": 1},
							"palette_index": {"type": "integer", "minimum": 0},
						},
						"additionalProperties": false,
					},
					"minItems": 1,
					"maxItems": 256,
					"description": "Material table for the shape material indices. A shape without an index uses the current material, not materials[0].",
				},
				"frames": {
					"type": "array",
					"items": {"type": "integer", "minimum": 0},
					"minItems": 1,
					"maxItems": 16,
					"description": "Frame indices to write. Defaults to the current frame. One undo action covers every frame.",
				},
				"erase": {"type": "boolean"},
				"label": {"type": "string", "description": "History action name. Defaults to Write Cells."},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "sample",
		"description": "Copy the full material of one occupied cell to the current material, like the eyedropper.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"cell": {"type": "array", "items": {"type": "integer"}, "minItems": 3, "maxItems": 3},
			},
			"required": ["cell"],
			"additionalProperties": false,
		},
	},
]

## The shared response schema parts. A legacy revision requires a root object,
## so every output schema below is an object with properties.
const SCHEMA_CELL := {"type": "array", "items": {"type": "integer"}, "minItems": 3, "maxItems": 3}
const SCHEMA_BOUNDS := {
	"type": ["object", "null"],
	"properties": {"min": SCHEMA_CELL, "max": SCHEMA_CELL},
}
const SCHEMA_MATERIAL := {
	"type": "object",
	"properties": {
		"color": {"type": "string"},
		"metallic": {"type": "number"},
		"roughness": {"type": "number"},
		"emission": {"type": "string"},
	},
}
const SCHEMA_TAG := {
	"type": "object",
	"properties": {
		"tag": {"type": "integer"},
		"name": {"type": "string"},
		"from": {"type": "integer"},
		"to": {"type": "integer"},
		"mode": {"type": "integer"},
		"mode_name": {"type": "string"},
		"repeats": {"type": "integer"},
	},
}
const SCHEMA_RUNS := {"type": "array", "items": {"type": "array", "items": {"type": "integer"}}}
const SCHEMA_REGION := {
	"type": "object",
	"properties": {
		"id": {"type": "integer"},
		"cells": {"type": "integer"},
		"bounds": SCHEMA_BOUNDS,
		"center": SCHEMA_CELL,
		"material": SCHEMA_MATERIAL,
		"key": {"type": "string"},
		"materials": {
			"type": "array",
			"items": {
				"type": "object",
				"properties": {
					"material": SCHEMA_MATERIAL,
					"cells": {"type": "integer"},
					"key": {"type": "string"},
				},
			},
		},
	},
}
const SCHEMA_FRAME_RESULT := {
	"type": "object",
	"properties": {
		"frame": {"type": "integer"},
		"applied": {"type": "integer"},
		"chunks": {"type": "integer"},
		"occupied": {"type": "integer"},
		"changed_bounds": SCHEMA_BOUNDS,
	},
}

## The output schema of each tool, keyed by tool name. Clients show this as the
## return type, so an agent sees the shape before the first call. The guide
## resource lists the same keys.
const OUTPUT_SCHEMAS := {
	"get_state": {
		"type": "object",
		"properties": {
			"revision": {"type": "integer"},
			"document": {
				"type": "object",
				"properties": {
					"name": {"type": "string"},
					"frames": {"type": "integer"},
					"frame": {"type": "integer"},
					"delay_ms": {"type": "integer"},
					"palette": {"type": "integer", "description": "The palette entry count."},
					"bounds": {
						"type": "object",
						"properties": {
							"position": {"type": "array", "items": {"type": "number"}},
							"size": {"type": "array", "items": {"type": "number"}},
						},
					},
					"frame_bounds": {"type": ["array", "null"], "items": {"type": "integer"}},
				},
			},
			"tags": {"type": "array", "items": SCHEMA_TAG},
			"active_tag": {"type": "integer"},
			"active_tool": {
				"type": "object",
				"properties": {"id": {"type": "string"}, "params": {"type": "object"}},
			},
			"material": SCHEMA_MATERIAL,
			"selection": {"type": "integer"},
			"symmetry": {"type": "integer"},
			"slice": {"type": ["object", "boolean"]},
			"busy": {"type": "boolean"},
			"undo": {
				"type": "object",
				"properties": {"undo": {"type": "boolean"}, "redo": {"type": "boolean"}},
			},
		},
	},
	"inspect_document": {
		"type": "object",
		"properties": {
			"revision": {"type": "integer"},
			"document": {
				"type": "object",
				"properties": {
					"name": {"type": "string"},
					"frames": {"type": "integer"},
					"current_frame": {"type": "integer"},
					"palette": {
						"type": "array",
						"items": {
							"type": "object",
							"properties": {"index": {"type": "integer"}, "material": SCHEMA_MATERIAL},
						},
					},
				},
			},
			"frames": {
				"type": "array",
				"items": {
					"type": "object",
					"properties": {
						"index": {"type": "integer"},
						"delay_ms": {"type": "integer"},
						"occupied": {"type": "integer"},
						"bounds": SCHEMA_BOUNDS,
						"empty": {"type": "boolean"},
						"materials": {
							"type": "array",
							"items": {
								"type": "object",
								"properties": {
									"material": SCHEMA_MATERIAL,
									"cells": {"type": "integer"},
									"bounds": SCHEMA_BOUNDS,
									"key": {"type": "string"},
								},
							},
						},
						"islands": {"type": "array", "items": SCHEMA_REGION},
						"island_count": {"type": "integer"},
						"islands_truncated": {"type": "boolean"},
						"small_islands": {"type": "integer"},
						"scan_truncated": {"type": "boolean"},
					},
				},
			},
			"tags": {"type": "array", "items": SCHEMA_TAG},
			"transitions": {
				"type": "array",
				"items": {
					"type": "object",
					"properties": {
						"from": {"type": "integer"},
						"to": {"type": "integer"},
						"added": {"type": "integer"},
						"removed": {"type": "integer"},
						"changed": {"type": "integer"},
						"added_bounds": SCHEMA_BOUNDS,
						"removed_bounds": SCHEMA_BOUNDS,
						"bounds": SCHEMA_BOUNDS,
						"truncated": {"type": "boolean"},
					},
				},
			},
		},
	},
	"get_regions": {
		"type": "object",
		"properties": {
			"revision": {"type": "integer"},
			"frame": {"type": "integer"},
			"group": {"type": "string"},
			"regions": {"type": "array", "items": SCHEMA_REGION},
			"region_count": {"type": "integer"},
			"truncated": {"type": "boolean"},
			"small_regions": {"type": "integer"},
			"material": {"type": "string"},
		},
	},
	"get_slice": {
		"type": "object",
		"properties": {
			"revision": {"type": "integer"},
			"frame": {"type": "integer"},
			"axis": {"type": "string"},
			"mode": {"type": "string"},
			"scale": {"type": "integer"},
			"columns": {"type": "string"},
			"rows": {"type": "string"},
			"column_start": {"type": "integer"},
			"row_start": {"type": "integer"},
			"empty": {"type": "boolean"},
			"slices": {
				"type": "array",
				"items": {
					"type": "object",
					"properties": {
						"layer": {"type": "integer"},
						"origin": SCHEMA_CELL,
						"lines": {"type": "array", "items": {"type": "string"}},
					},
				},
			},
			"values": {"type": "array", "items": {"type": "array", "items": {"type": "integer"}}},
			"empty_value": {"type": "integer"},
			"legend": {
				"type": "array",
				"items": {
					"type": "object",
					"properties": {
						"char": {"type": "string"},
						"material": SCHEMA_MATERIAL,
						"key": {"type": "string"},
					},
				},
			},
		},
	},
	"get_map": {
		"type": "object",
		"properties": {
			"revision": {"type": "integer"},
			"frame": {"type": "integer"},
			"cell_size": {"type": "integer"},
			"origin": SCHEMA_CELL,
			"size": SCHEMA_CELL,
			"blocks": {"type": "array", "items": {}},
			"block_count": {"type": "integer"},
			"truncated": {"type": "boolean"},
			"occupied": {"type": "integer"},
			"chunk_aligned": {"type": "boolean"},
			"approximate": {"type": "boolean"},
			"empty": {"type": "boolean"},
		},
	},
	"get_changes": {
		"type": "object",
		"properties": {
			"revision": {"type": "integer"},
			"frame": {"type": "integer"},
			"from": {"type": "integer"},
			"full_refresh": {"type": "boolean"},
			"cells": SCHEMA_RUNS,
			"count": {"type": "integer"},
			"truncated": {"type": "boolean"},
			"chunk_origins": {"type": "array", "items": SCHEMA_CELL},
			"bounds": SCHEMA_BOUNDS,
			"other_frames": {"type": "array", "items": {"type": "integer"}},
		},
	},
	"get_cells": {
		"type": "object",
		"properties": {
			"frame": {"type": "integer"},
			"count": {"type": "integer"},
			"truncated": {"type": "boolean"},
			"runs": SCHEMA_RUNS,
			"materials": {
				"type": "array",
				"items": {
					"type": "object",
					"properties": {
						"color": {"type": "string"},
						"metallic": {"type": "number"},
						"roughness": {"type": "number"},
						"emission": {"type": "string"},
						"key": {"type": "string"},
					},
				},
			},
			"scanned_bounds": SCHEMA_BOUNDS,
			"returned_bounds": SCHEMA_BOUNDS,
			"next": SCHEMA_CELL,
			"material": {"type": "string"},
		},
	},
	"screenshot": {
		"type": "object",
		"properties": {
			"path": {"type": "string"},
			"width": {"type": "integer"},
			"height": {"type": "integer"},
			"tile_size": {"type": "integer"},
			"columns": {"type": "integer"},
			"rows": {"type": "integer"},
			"revision": {"type": "integer"},
			"bounds": SCHEMA_BOUNDS,
			"frame": {"type": "integer"},
			"frames": {"type": "array", "items": {"type": "integer"}},
			"view": {"type": "string"},
			"views": {"type": "array", "items": {"type": "string"}},
		},
	},
	"new_document": {
		"type": "object",
		"properties": {"tab": {"type": "integer"}, "frames": {"type": "integer"}},
	},
	"save_document": {
		"type": "object",
		"properties": {
			"path": {"type": "string"},
			"copy": {"type": "boolean"},
			"main_path": {"type": "string"},
			"dirty": {"type": "boolean"},
		},
	},
	"open_document": {
		"type": "object",
		"properties": {
			"tab": {"type": "integer"},
			"frames": {"type": "integer"},
			"path": {"type": "string"},
		},
	},
	"add_frame": {
		"type": "object",
		"properties": {"frame": {"type": "integer"}, "frames": {"type": "integer"}},
	},
	"remove_frame": {
		"type": "object",
		"properties": {"frame": {"type": "integer"}, "frames": {"type": "integer"}},
	},
	"move_frame": {
		"type": "object",
		"properties": {"frame": {"type": "integer"}, "frames": {"type": "integer"}},
	},
	"duplicate_frame": {
		"type": "object",
		"properties": {"frame": {"type": "integer"}, "frames": {"type": "integer"}},
	},
	"set_frame": {
		"type": "object",
		"properties": {"frame": {"type": "integer"}, "delay_ms": {"type": "integer"}},
	},
	"set_frame_delay": {
		"type": "object",
		"properties": {"frame": {"type": "integer"}, "delay_ms": {"type": "integer"}},
	},
	"set_tag_loop": SCHEMA_TAG,
	"add_tag": SCHEMA_TAG,
	"rename_tag": SCHEMA_TAG,
	"set_tag_range": SCHEMA_TAG,
	"remove_tag": {
		"type": "object",
		"properties": {"tag": {"type": "integer"}, "tags": {"type": "integer"}},
	},
	"set_active_tag": {
		"type": "object",
		"properties": {
			"tag": {"type": "integer"},
			"tags": {"type": "integer"},
			"name": {"type": "string"},
			"from": {"type": "integer"},
			"to": {"type": "integer"},
			"mode": {"type": "integer"},
			"repeats": {"type": "integer"},
		},
	},
	"set_playback": {
		"type": "object",
		"properties": {"playing": {"type": "boolean"}, "frame": {"type": "integer"}},
	},
	"set_tool": {
		"type": "object",
		"properties": {"tool": {"type": "string"}, "params": {"type": "object"}},
	},
	"set_material": {
		"type": "object",
		"properties": {"material": SCHEMA_MATERIAL},
	},
	"set_cursor": {
		"type": "object",
		"properties": {"cell": SCHEMA_CELL, "hidden": {"type": "boolean"}},
	},
	"stroke": {
		"type": "object",
		"properties": {
			"tool": {"type": "string"},
			"points": {"type": "integer"},
			"revision": {"type": "integer"},
			"occupied": {"type": "integer"},
			"changed_cells": {"type": "integer"},
			"changed_chunks": {"type": "integer"},
			"changed_bounds": SCHEMA_BOUNDS,
		},
	},
	"fill": {
		"type": "object",
		"properties": {
			"seed": SCHEMA_CELL,
			"revision": {"type": "integer"},
			"occupied": {"type": "integer"},
			"changed_cells": {"type": "integer"},
			"changed_chunks": {"type": "integer"},
			"changed_bounds": SCHEMA_BOUNDS,
		},
	},
	"write_cells": {
		"type": "object",
		"properties": {
			"applied": {"type": "integer"},
			"chunks": {"type": "integer"},
			"frames": {"type": "array", "items": SCHEMA_FRAME_RESULT},
			"action": {"type": "string"},
			"revision": {"type": "integer"},
			"occupied": {"type": "integer"},
			"changed_bounds": SCHEMA_BOUNDS,
		},
	},
	"sample": {
		"type": "object",
		"properties": {"material": SCHEMA_MATERIAL},
	},
}

## The guide resource. It gives the rules and the return shape of every tool
## without a skill install or a repository checkout.
const GUIDE_URI := "lve://guide"
const GUIDE_BODY := """# LVE MCP guide

LVE is a voxel editor that runs as its own app. You edit the document the user
has open, not a file copy. A read or a write lands in their real session.

## Rules

- Cells are integer points. Y is up. Negative coordinates are normal.
- Boxes are inclusive: [x0, y0, z0, x1, y1, z1].
- Read get_state first. It gives the document, revision, material, tool, and undo state.
- Call inspect_document for bounds, materials, islands, and frame transitions.
- Call get_slice or get_map to see shape. Use screenshot for a picture.
- Runs in get_cells are [x0, x1, y, z, material_index].
- The material_index points into the materials array of that page. It is not the index you wrote.
- Pass next back as cursor with the same min and max to continue a read.
- A write_cells shape without a material index uses the current material, not materials[0].
- Each call is one undo action, even across frames.
- Verify a write with get_changes since the revision you just received.
- stroke reports the bounds of the changed cells. A fill reports the chunk-aligned box.
- screenshot always writes user://mcp_screenshot.png. Pass focus to frame a detail.
- save_document writes a copy by default. Pass copy false to save the main document.
- new_document and open_document add a tab. The current document stays open.
- Frame and tag indices shift after add, move, or remove. Re-read them.
- set_tag_range fails when the range is outside the frames.
- inspect_document with palette true puts the palette at document.palette.

## Return shapes

Every tool declares an outputSchema. A client that renders it shows the return
type before the first call. The keys of each result are listed below.
"""

const INSTRUCTIONS := "LVE is a voxel editor. Cells are integers and Y is up. Boxes are inclusive. Read get_state for the document, material, and revision. Read the lve://guide resource once for the rules and the return shape of every tool. inspect_document gives bounds, materials, islands, and transitions. get_slice or get_map shows shape. get_cells returns runs [x0, x1, y, z, material_index]. Pass next back as cursor with the same box. write_cells uses the current material when a shape has no index. Each call is one undo action. save_document writes a copy unless copy is false. Verify with get_changes since the last revision."

## One accepted bridge or HTTP client.
class PeerState extends RefCounted:
	var peer: StreamPeerTCP
	var buffer := PackedByteArray()
	var busy := false
	var sse := false
	var last_ping_ms := 0


var _server := TCPServer.new()
var _peers: Array[PeerState] = []
var _http_mode := false
var _port := DEFAULT_PORT
## The document content revision. The read tools report it.
var _revision := 0
## The bounded journal of cell and chunk changes since a revision.
var _journal: Array[Dictionary] = []
## The number of cells in the journal.
var _journal_cells := 0
## The oldest revision that the journal can describe.
var _journal_floor := 0
## The revision of the last cell or chunk signal. A history change with no new
## content signal is an undo or redo that carries no cell list.
var _last_content_revision := 0
## Whether a cell or chunk signal arrived since the last history change.
var _content_since_history := false


## One direct cell write job. It writes a batch through the edit context.
class WriteJob extends VoxelFrame.EditJob:
	var edited_frame: VoxelFrame
	var changes: Dictionary
	var changed_chunks: Array[Vector3i] = []

	func run() -> void:
		stage("Writing cells", changes.size())
		changed_chunks = apply_cells(edited_frame, changes)


func _ready() -> void:
	set_process(false)
	_connect_state()


func _exit_tree() -> void:
	_disconnect_state()
	stop()


func _connect_state() -> void:
	if not State.cells_changed.is_connected(_on_cells_changed):
		State.cells_changed.connect(_on_cells_changed)
	if not State.chunks_changed.is_connected(_on_chunks_changed):
		State.chunks_changed.connect(_on_chunks_changed)
	if not State.history_changed.is_connected(_on_history_changed):
		State.history_changed.connect(_on_history_changed)
	if not State.document_changed.is_connected(_on_structure_changed):
		State.document_changed.connect(_on_structure_changed)
	if not State.frames_changed.is_connected(_on_structure_changed):
		State.frames_changed.connect(_on_structure_changed)
	if not State.frame_changed.is_connected(_on_structure_changed):
		State.frame_changed.connect(_on_structure_changed)
	if not State.palette_changed.is_connected(_on_structure_changed):
		State.palette_changed.connect(_on_structure_changed)
	if not State.tag_changed.is_connected(_on_structure_changed):
		State.tag_changed.connect(_on_structure_changed)


func _disconnect_state() -> void:
	if State.cells_changed.is_connected(_on_cells_changed):
		State.cells_changed.disconnect(_on_cells_changed)
	if State.chunks_changed.is_connected(_on_chunks_changed):
		State.chunks_changed.disconnect(_on_chunks_changed)
	if State.history_changed.is_connected(_on_history_changed):
		State.history_changed.disconnect(_on_history_changed)
	if State.document_changed.is_connected(_on_structure_changed):
		State.document_changed.disconnect(_on_structure_changed)
	if State.frames_changed.is_connected(_on_structure_changed):
		State.frames_changed.disconnect(_on_structure_changed)
	if State.frame_changed.is_connected(_on_structure_changed):
		State.frame_changed.disconnect(_on_structure_changed)
	if State.palette_changed.is_connected(_on_structure_changed):
		State.palette_changed.disconnect(_on_structure_changed)
	if State.tag_changed.is_connected(_on_structure_changed):
		State.tag_changed.disconnect(_on_structure_changed)


func _on_cells_changed(frame: int, affected: Array[Vector3i]) -> void:
	if affected.is_empty():
		# A restore can change the model without listing the cells.
		_reset_journal()
		return
	_record_cells_change(frame, affected)


func _record_cells_change(frame: int, affected: Array) -> void:
	if affected.is_empty():
		_reset_journal()
		return
	_revision += 1
	_last_content_revision = _revision
	_content_since_history = true
	var typed: Array[Vector3i] = []
	typed.assign(affected)
	_journal.append({"revision": _revision, "frame": frame, "cells": typed})
	_journal_cells += typed.size()
	_prune_journal()


func _on_chunks_changed(frame: int, affected: Array[Vector3i]) -> void:
	if affected.is_empty():
		return
	_revision += 1
	_last_content_revision = _revision
	_content_since_history = true
	# A tool reports chunk locations, not cell coordinates. Store origins, so
	# every journal field uses cell units.
	var origins: Array[Vector3i] = []
	for location in affected:
		origins.append(location * VoxelFrame.CHUNK_SIZE)
	_journal.append({"revision": _revision, "frame": frame, "chunks": origins})
	_prune_journal()


func _on_history_changed() -> void:
	# Undo and redo emit no cell list. A history change after a content signal
	# belongs to that edit. A history change without one is opaque, so the next
	# delta read must ask for a full read.
	if _content_since_history:
		_content_since_history = false
		return
	_reset_journal()


func _on_structure_changed() -> void:
	_reset_journal()


func _reset_journal() -> void:
	_revision += 1
	_journal.clear()
	_journal_cells = 0
	_journal_floor = _revision
	_last_content_revision = _revision
	_content_since_history = false


func _prune_journal() -> void:
	while _journal.size() > MAX_JOURNAL_ENTRIES or _journal_cells > MAX_JOURNAL_CELLS:
		if _journal.is_empty():
			break
		var removed: Dictionary = _journal.pop_front()
		_journal_cells -= _entry_cell_count(removed)
		_journal_floor = int(removed.get("revision", _journal_floor))
	if _journal.is_empty():
		_journal_floor = _revision


func _entry_cell_count(entry: Dictionary) -> int:
	var cells_value: Variant = entry.get("cells", [])
	if cells_value is Array:
		return (cells_value as Array).size()
	return 0


## Starts the loopback server. A port of zero selects a free port. In HTTP mode
## the server accepts Streamable HTTP requests at `/mcp`; otherwise it accepts
## newline-delimited JSON-RPC for the stdio bridge.
func start(port: int = DEFAULT_PORT, http_mode := false) -> Error:
	stop()
	_port = port
	_http_mode = http_mode
	var error := _server.listen(port, "127.0.0.1")
	if error != OK:
		push_warning("LVE MCP: cannot listen on 127.0.0.1:%d: %s" % [port, error_string(error)])
		return error
	print("LVE MCP: listening on 127.0.0.1:%d (%s)" % [_server.get_local_port(), "HTTP" if http_mode else "line"])
	_log("start %d %s" % [_server.get_local_port(), "http" if http_mode else "line"])
	set_process(true)
	return OK


## Stops the server and closes every client connection.
func stop() -> void:
	for state in _peers:
		state.peer.disconnect_from_host()
	_peers.clear()
	if _server.is_listening():
		_server.stop()
	_log("stop")
	set_process(false)


## Returns the port that the server listens on, or zero when it is closed.
func local_port() -> int:
	return _server.get_local_port() if _server.is_listening() else 0


func _process(_delta: float) -> void:
	_accept_all()
	var now := Time.get_ticks_msec()
	for state in _peers.duplicate():
		var peer: StreamPeerTCP = state.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_remove_peer(state)
			continue
		if state.sse:
			if now - state.last_ping_ms >= 15000:
				_send_sse_comment(state)
				state.last_ping_ms = now
			continue
		if not _read_peer_bytes(state):
			continue
		if _http_mode:
			_drain_http(state)
		else:
			_drain_lines(state)


func _accept_all() -> void:
	while _server.is_connection_available():
		var peer := _server.take_connection()
		if peer == null:
			return
		peer.set_no_delay(true)
		var state := PeerState.new()
		state.peer = peer
		_peers.append(state)


func _remove_peer(state: PeerState) -> void:
	_peers.erase(state)
	if state.peer != null:
		state.peer.disconnect_from_host()


func _read_peer_bytes(state: PeerState) -> bool:
	var available := state.peer.get_available_bytes()
	if available <= 0:
		return true
	var result := state.peer.get_partial_data(available)
	if result[0] != OK:
		return true
	var bytes: PackedByteArray = result[1]
	state.buffer.append_array(bytes)
	if state.buffer.size() > MAX_LINE_BYTES:
		# Clear the request before the peer goes, so the same frame cannot
		# dispatch the request that this limit just refused.
		state.buffer.clear()
		if _http_mode:
			_send_http(state, 413, "Payload Too Large", "")
		else:
			_send_raw(state, _error_response(null, -32600, "Request is too large."))
		_remove_peer(state)
		return false
	return true


func _drain_http(state: PeerState) -> void:
	if state.busy:
		return
	var header_end := -1
	for index in range(0, state.buffer.size() - 3):
		if state.buffer[index] == 13 and state.buffer[index + 1] == 10 \
				and state.buffer[index + 2] == 13 and state.buffer[index + 3] == 10:
			header_end = index
			break
	if header_end < 0:
		return
	var header_text := state.buffer.slice(0, header_end).get_string_from_utf8()
	var header_lines := header_text.split("\r\n")
	if header_lines.is_empty():
		state.buffer = state.buffer.slice(header_end + 4)
		return
	var request_line := header_lines[0].split(" ")
	if request_line.size() < 2:
		_send_http(state, 400, "Bad Request", "")
		state.buffer = state.buffer.slice(header_end + 4)
		return
	var method := request_line[0]
	var path := request_line[1]
	var content_length := 0
	var origin := ""
	var content_type := ""
	for line_index in range(1, header_lines.size()):
		var header := header_lines[line_index]
		var separator := header.find(":")
		if separator < 0:
			continue
		var name := header.substr(0, separator).strip_edges().to_lower()
		var value := header.substr(separator + 1).strip_edges()
		if name == "content-length":
			content_length = maxi(0, int(value))
		elif name == "origin":
			origin = value
		elif name == "content-type":
			content_type = value.to_lower()
	var body_start := header_end + 4
	if state.buffer.size() < body_start + content_length:
		return
	var body := state.buffer.slice(body_start, body_start + content_length).get_string_from_utf8()
	state.buffer = state.buffer.slice(body_start + content_length)
	state.busy = true
	_handle_http(state, method, path, body, origin, content_type)


func _handle_http(state: PeerState, method: String, path: String, body: String, origin := "", content_type := "") -> void:
	if path != "/mcp":
		_send_http(state, 404, "Not Found", _error_response(null, -32601, "Unknown endpoint."))
		state.busy = false
		return
	match method:
		"GET":
			_start_sse(state)
			state.busy = false
			return
		"DELETE":
			_send_http(state, 204, "No Content", "")
			state.busy = false
			return
		"OPTIONS":
			_send_http(state, 204, "No Content", "")
			state.busy = false
			return
		"POST":
			pass
		_:
			_send_http(state, 405, "Method Not Allowed", "")
			state.busy = false
			return
	# A browser page can send a simple cross-origin POST without a preflight.
	# Reject browser origins and require JSON, so a visited page cannot drive
	# the editor tools.
	if not origin.is_empty():
		_send_http(state, 403, "Forbidden", _error_response(null, -32600, "Browser origins are not allowed."))
		state.busy = false
		return
	if not content_type.begins_with("application/json"):
		_send_http(state, 415, "Unsupported Media Type", _error_response(null, -32600, "Content-Type must be application/json."))
		state.busy = false
		return
	var request_value: Variant = JSON.parse_string(body)
	if not (request_value is Dictionary):
		_send_http(state, 400, "Bad Request", _error_response(null, -32700, "Parse error."))
		state.busy = false
		return
	var request: Dictionary = request_value
	var response: Variant = await _dispatch_request(request)
	if response is Dictionary:
		_send_http(state, 200, "OK", response)
	else:
		_send_http(state, 202, "Accepted", "")
	state.busy = false


func _start_sse(state: PeerState) -> void:
	var header := "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n: connected\n\n"
	var error := state.peer.put_data(header.to_utf8_buffer())
	if error != OK:
		_remove_peer(state)
		return
	state.sse = true
	state.last_ping_ms = Time.get_ticks_msec()


func _send_sse_comment(state: PeerState) -> void:
	var error := state.peer.put_data(": ping\n\n".to_utf8_buffer())
	if error != OK:
		_remove_peer(state)


func _send_http(state: PeerState, status: int, reason: String, body: Variant) -> void:
	var text := ""
	if body is Dictionary:
		text = JSON.stringify(body)
	elif body is String:
		text = body
	var payload := text.to_utf8_buffer()
	var header := "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: keep-alive\r\n\r\n" % [status, reason, payload.size()]
	var bytes := header.to_utf8_buffer()
	bytes.append_array(payload)
	var error := state.peer.put_data(bytes)
	if error != OK:
		_remove_peer(state)


func _drain_lines(state: PeerState) -> void:
	if state.busy:
		return
	# Scan past empty lines in one pass. A recursive call per blank line could
	# exhaust the stack, and slicing once per line copies the buffer each time.
	var start := 0
	while true:
		var index := state.buffer.find(10, start)
		if index < 0:
			if start > 0:
				state.buffer = state.buffer.slice(start)
			return
		var line := state.buffer.slice(start, index).get_string_from_utf8().strip_edges()
		start = index + 1
		if line.is_empty():
			continue
		state.buffer = state.buffer.slice(start)
		state.busy = true
		_handle_line(state, line)
		return


func _handle_line(state: PeerState, line: String) -> void:
	var request_value: Variant = JSON.parse_string(line)
	if not (request_value is Dictionary):
		_send_raw(state, _error_response(null, -32700, "Parse error."))
		state.busy = false
		return
	var request: Dictionary = request_value
	var response: Variant = await _dispatch_request(request)
	if response is Dictionary:
		_send_raw(state, response)
	state.busy = false


func _dispatch_request(request: Dictionary) -> Variant:
	var id: Variant = request.get("id", null)
	var method_value: Variant = request.get("method", "")
	if not (method_value is String):
		if id != null:
			return _error_response(id, -32600, "Invalid request.")
		return null
	var method: String = method_value
	if id == null:
		# A notification never gets a response.
		return null
	var params: Dictionary = {}
	var params_value: Variant = request.get("params", {})
	if params_value is Dictionary:
		params = params_value
	match method:
		"initialize":
			return _result_response(id, _initialize(params))
		"tools/list":
			var tool_list := _result_response(id, {"tools": _tools_json()})
			_log("tools/list %d bytes" % JSON.stringify(tool_list).length())
			return tool_list
		"tools/call":
			var response: Variant = await _call_tool(id, params)
			_log("tool %s %d bytes" % [str(params.get("name", "")), JSON.stringify(response).length()])
			return response
		"resources/list":
			return _result_response(id, {"resources": _resources_json()})
		"resources/read":
			return _read_resource(id, params)
		"ping":
			return _result_response(id, {})
		_:
			return _error_response(id, -32601, "Unknown method: " + method)


func _initialize(params: Dictionary) -> Dictionary:
	var requested_value: Variant = params.get("protocolVersion", "2025-11-25")
	var requested: String = requested_value if requested_value is String else "2025-11-25"
	var supported := ["2025-06-18", "2025-03-26"]
	var version := requested if supported.has(requested) else "2025-06-18"
	var version_string := str(ProjectSettings.get_setting("application/config/version", "0"))
	if version_string.count(".") < 2:
		version_string += ".0"
	return {
		"protocolVersion": version,
		"capabilities": {
			"tools": {"listChanged": false},
			"resources": {"subscribe": false, "listChanged": false},
		},
		"serverInfo": {"name": "lve", "title": "Leonard's Voxel Editor", "version": version_string},
		"instructions": INSTRUCTIONS,
	}


## Returns the tool list with the output schema of each tool. The schemas are
## kept in a separate table, so a tool entry stays readable.
func _tools_json() -> Array:
	var tools: Array = []
	for value in TOOLS:
		var tool: Dictionary = value
		var entry: Dictionary = tool.duplicate()
		var schema: Variant = OUTPUT_SCHEMAS.get(str(entry.get("name", "")), null)
		if schema is Dictionary:
			entry["outputSchema"] = schema
		tools.append(entry)
	return tools


## Returns the resources the client can read. The guide is the only one.
func _resources_json() -> Array:
	var text := _guide_text()
	return [{
		"uri": GUIDE_URI,
		"name": "guide",
		"title": "LVE MCP guide",
		"description": "The rules and the return shape of every tool. Read it before the first edit.",
		"mimeType": "text/markdown",
		"size": text.to_utf8_buffer().size(),
	}]


## Answers one resources/read request.
func _read_resource(id: Variant, params: Dictionary) -> Dictionary:
	var uri_value: Variant = params.get("uri", "")
	if not (uri_value is String):
		return _error_response(id, -32602, "uri must be a string.")
	var uri: String = uri_value
	if uri != GUIDE_URI:
		return _error_response(id, -32002, "Resource not found: " + uri)
	return _result_response(id, {
		"contents": [{
			"uri": GUIDE_URI,
			"mimeType": "text/markdown",
			"text": _guide_text(),
		}],
	})


## Returns the guide text: the fixed rules, then the result keys of each tool.
## The keys come from the output schemas, so the guide cannot drift from them.
func _guide_text() -> String:
	var lines: PackedStringArray = [GUIDE_BODY]
	for value in TOOLS:
		var tool: Dictionary = value
		var name := str(tool.get("name", ""))
		lines.append("\n### %s\n" % name)
		lines.append(str(tool.get("description", "")) + "\n")
		var schema_value: Variant = OUTPUT_SCHEMAS.get(name, null)
		if not (schema_value is Dictionary):
			continue
		var schema: Dictionary = schema_value
		var properties_value: Variant = schema.get("properties", {})
		if not (properties_value is Dictionary):
			continue
		var properties: Dictionary = properties_value
		var keys: PackedStringArray = []
		for key in properties:
			var field_value: Variant = properties[key]
			var kind := "value"
			if field_value is Dictionary:
				var field: Dictionary = field_value
				var type_value: Variant = field.get("type", "value")
				if type_value is String:
					kind = type_value
				elif type_value is Array:
					var names: PackedStringArray = []
					for entry in type_value:
						names.append(str(entry))
					kind = " or ".join(names)
			keys.append("%s: %s" % [key, kind])
		lines.append("Returns: " + ", ".join(keys) + "\n")
	return "".join(lines)


func _call_tool(id: Variant, params: Dictionary) -> Dictionary:
	var name_value: Variant = params.get("name", "")
	if not (name_value is String):
		return _error_response(id, -32602, "Tool name must be a string.")
	var tool_name: String = name_value
	var args: Dictionary = {}
	var args_value: Variant = params.get("arguments", {})
	if args_value is Dictionary:
		args = args_value
	match tool_name:
		"get_state":
			return _result_response(id, _get_state())
		"inspect_document":
			return _result_response(id, _inspect_document(args))
		"get_regions":
			return _result_response(id, _get_regions(args))
		"get_slice":
			return _result_response(id, _get_slice(args))
		"get_map":
			return _result_response(id, _get_map(args))
		"get_changes":
			return _result_response(id, _get_changes(args))
		"get_cells":
			return _result_response(id, _get_cells(args))
		"screenshot":
			return _result_response(id, await _screenshot(args))
		"new_document":
			return _result_response(id, _new_document())
		"save_document":
			return _result_response(id, await _save_document(args))
		"open_document":
			return _result_response(id, _open_document(args))
		"add_frame":
			return _result_response(id, _add_frame(args))
		"remove_frame":
			return _result_response(id, _remove_frame(args))
		"move_frame":
			return _result_response(id, _move_frame(args))
		"duplicate_frame":
			return _result_response(id, _duplicate_frame())
		"set_frame":
			return _result_response(id, _set_frame(args))
		"set_frame_delay":
			return _result_response(id, _set_frame_delay(args))
		"set_tag_loop":
			return _result_response(id, _set_tag_loop(args))
		"add_tag":
			return _result_response(id, _add_tag(args))
		"remove_tag":
			return _result_response(id, _remove_tag(args))
		"rename_tag":
			return _result_response(id, _rename_tag(args))
		"set_tag_range":
			return _result_response(id, _set_tag_range(args))
		"set_active_tag":
			return _result_response(id, _set_active_tag(args))
		"set_playback":
			return _result_response(id, _set_playback(args))
		"set_tool":
			return _result_response(id, _set_tool(args))
		"set_material":
			return _result_response(id, _set_material(args))
		"set_cursor":
			return _result_response(id, _set_cursor(args))
		"stroke":
			return _result_response(id, await _stroke(args))
		"fill":
			return _result_response(id, await _fill(args))
		"write_cells":
			return _result_response(id, await _write_cells(args))
		"sample":
			return _result_response(id, _sample(args))
		_:
			return _error_response(id, -32602, "Unknown tool: " + tool_name)


func _send_raw(state: PeerState, response: Dictionary) -> void:
	var line := JSON.stringify(response) + "\n"
	var error := state.peer.put_data(line.to_utf8_buffer())
	if error != OK:
		_remove_peer(state)


func _result_response(id: Variant, result: Dictionary) -> Dictionary:
	return {"jsonrpc": "2.0", "id": _response_id(id), "result": result}


func _error_response(id: Variant, code: int, message: String) -> Dictionary:
	return {"jsonrpc": "2.0", "id": _response_id(id), "error": {"code": code, "message": message}}


# JSON numbers parse as floats. A whole id goes back as an integer, so a client
# that sent 1 receives 1, not 1.0.
func _response_id(id: Variant) -> Variant:
	if id is float and is_equal_approx(id, roundf(id)):
		id = int(id)
	return id


func _tool_ok(data: Variant) -> Dictionary:
	var result := {"content": [{"type": "text", "text": JSON.stringify(data)}]}
	if data is Dictionary:
		# The structured half lets a client use the result as data and check it
		# against the declared output schema. The text half keeps older clients.
		result["structuredContent"] = data
	return result


func _tool_error(message: String) -> Dictionary:
	return {"content": [{"type": "text", "text": message}], "isError": true}


func _get_state() -> Dictionary:
	var document := State.document
	var frame := State.get_current_voxel_frame()
	var info := _active_tool_info()
	var slice: Variant = false
	if State.slice_enabled:
		slice = {
			"axis": _axis_name(State.floor_axis),
			"first": State.slice_first(),
			"count": State.slice_count(),
		}
	var tags: Array = []
	for index in range(document.tags.size()):
		var tag := document.tags[index]
		tags.append({
			"name": tag.name,
			"from": tag.from,
			"to": tag.to,
			"mode": tag.loop_mode,
			"mode_name": _tag_loop_name(tag.loop_mode),
			"repeats": tag.repeats,
		})
	return _tool_ok({
		"revision": _revision,
		"document": {
			"name": document.get_file_name(),
			"frames": document.frames.size(),
			"frame": State.current_frame,
			"delay_ms": frame.delay_ms if frame != null else 0,
			"palette": document.palette.size(),
			"bounds": _aabb_json(document.bounds()),
			"frame_bounds": _frame_bounds_array(frame),
		},
		"tags": tags,
		"active_tag": State.active_tag,
		"active_tool": {"id": str(info.get("id", "")), "params": info.get("params", {})},
		"material": _material_json(State.current_material),
		"selection": State.selection.count(),
		"symmetry": State.symmetry_axes,
		"slice": slice,
		"busy": State.edit_busy() or State.active_edit() != null,
		"undo": {"undo": State.undo_redo.has_undo(), "redo": State.undo_redo.has_redo()},
	})


func _get_cells(args: Dictionary) -> Dictionary:
	var frame_index := State.current_frame
	var frame_value: Variant = args.get("frame", null)
	if frame_value is int or frame_value is float:
		frame_index = int(frame_value)
	var frame: VoxelFrame = State.get_voxel_frame(frame_index)
	if frame == null:
		return _tool_error("The frame does not exist.")
	var frame_bounds := _frame_cell_bounds(frame)
	var min_value: Variant = _parse_cell(args.get("min", null))
	var max_value: Variant = _parse_cell(args.get("max", null))
	if args.has("min") and min_value == null:
		return _tool_error("min must be [x, y, z].")
	if args.has("max") and max_value == null:
		return _tool_error("max must be [x, y, z].")
	var min_cell: Vector3i
	var max_cell: Vector3i
	if min_value == null and max_value == null:
		if frame_bounds.is_empty():
			return _tool_ok({
				"frame": frame_index,
				"count": 0,
				"truncated": false,
				"runs": [],
				"materials": [],
				"bounds": null,
			})
		min_cell = frame_bounds[0]
		max_cell = frame_bounds[1]
	elif min_value == null:
		if frame_bounds.is_empty():
			return _tool_error("min is required for an empty frame.")
		min_cell = frame_bounds[0]
		max_cell = max_value
	elif max_value == null:
		if frame_bounds.is_empty():
			return _tool_error("max is required for an empty frame.")
		min_cell = min_value
		max_cell = frame_bounds[1]
	else:
		min_cell = min_value
		max_cell = max_value
	if min_cell.x > max_cell.x or min_cell.y > max_cell.y or min_cell.z > max_cell.z:
		return _tool_error("min must not exceed max on any axis.")
	var extent := max_cell - min_cell + Vector3i.ONE
	if extent.x > MAX_BOX_CELLS or extent.y > MAX_BOX_CELLS or extent.z > MAX_BOX_CELLS:
		return _tool_error("The box is too large. Scan at most %d cells. Use get_map to locate content." % MAX_BOX_CELLS)
	var volume := extent.x * extent.y * extent.z
	if volume > MAX_BOX_CELLS:
		return _tool_error("The box is too large. Scan at most %d cells. Use get_map to locate content." % MAX_BOX_CELLS)
	var limit := MAX_GET_CELLS
	var limit_value: Variant = args.get("max_cells", MAX_GET_CELLS)
	if limit_value is int or limit_value is float:
		limit = clampi(int(limit_value), 1, 4096)
	var cursor_value: Variant = _parse_cell(args.get("cursor", null))
	if args.has("cursor") and cursor_value == null:
		return _tool_error("cursor must be [x, y, z].")
	var has_cursor := cursor_value is Vector3i
	var cursor: Vector3i = cursor_value if has_cursor else min_cell
	var material_filter := ""
	var material_value: Variant = args.get("material", null)
	if material_value != null:
		var material_color: Variant = _parse_color(material_value)
		if material_color == null:
			return _tool_error("material must be a color, for example #ff0000.")
		material_filter = _hex_color(material_color)
	var cells: Array = []
	var materials: Array = []
	var material_keys := {}
	var truncated := false
	var full := false
	var done := false
	var next_cell := Vector3i.ZERO
	var returned_min := Vector3i.MAX
	var returned_max := Vector3i.MIN
	for z in range(min_cell.z, max_cell.z + 1):
		if done:
			break
		for y in range(min_cell.y, max_cell.y + 1):
			if done:
				break
			for x in range(min_cell.x, max_cell.x + 1):
				var cell := Vector3i(x, y, z)
				if has_cursor and _cell_before_cursor(cell, cursor):
					continue
				if not frame.has(cell):
					continue
				var material := frame.get_material(cell)
				var material_key := _material_key(material)
				if not material_filter.is_empty() and not _material_key_matches(material_key, material_filter):
					continue
				if full:
					# The cap is reached only when one more matching cell exists.
					truncated = true
					next_cell = cell
					done = true
					break
				var material_index := -1
				if material_keys.has(material_key):
					material_index = int(material_keys[material_key])
				else:
					material_index = materials.size()
					material_keys[material_key] = material_index
					var material_data := _material_json(material)
					material_data["key"] = material_key
					materials.append(material_data)
				cells.append([x, y, z, material_index])
				returned_min = Vector3i(mini(returned_min.x, x), mini(returned_min.y, y), mini(returned_min.z, z))
				returned_max = Vector3i(maxi(returned_max.x, x), maxi(returned_max.y, y), maxi(returned_max.z, z))
				if cells.size() >= limit:
					full = true
	var runs: Array = []
	for value in cells:
		var cell: Array = value
		var x: int = cell[0]
		var y: int = cell[1]
		var z: int = cell[2]
		var material_index: int = cell[3]
		if not runs.is_empty():
			var last: Array = runs[-1]
			if last[1] + 1 == x and last[2] == y and last[3] == z and last[4] == material_index:
				last[1] = x
				continue
		runs.append([x, x, y, z, material_index])
	var data := {
		"frame": frame_index,
		"count": cells.size(),
		"truncated": truncated,
		"runs": runs,
		"materials": materials,
		"scanned_bounds": {"min": _json_cell(min_cell), "max": _json_cell(max_cell)},
		"returned_bounds": null,
	}
	if not cells.is_empty():
		data["returned_bounds"] = {"min": _json_cell(returned_min), "max": _json_cell(returned_max)}
	if truncated:
		data["next"] = _json_cell(next_cell)
	if not material_filter.is_empty():
		data["material"] = material_filter
	return _tool_ok(data)


func _inspect_document(args: Dictionary) -> Dictionary:
	var document := State.document
	if document == null:
		return _tool_error("No document is open.")
	var indices := _frame_indices_arg(args)
	if indices.is_empty():
		return _tool_error("The frame does not exist.")
	var include_materials := _bool_arg(args, "materials", true)
	var include_islands := _bool_arg(args, "islands", true)
	var include_transitions := _bool_arg(args, "transitions", false)
	var include_palette := _bool_arg(args, "palette", false)
	var max_islands := clampi(_int_arg(args, "max_islands", 32), 1, MAX_INSPECT_ISLANDS)
	var min_island_cells := maxi(1, _int_arg(args, "min_island_cells", 1))
	var group := str(args.get("group", "material"))
	if group != "material" and group != "frame":
		return _tool_error("group must be material or frame.")
	var scans := {}
	var frames: Array = []
	for index in indices:
		var frame: VoxelFrame = State.get_voxel_frame(index)
		if frame == null:
			return _tool_error("The frame does not exist.")
		var occupied := frame.count()
		var frame_data := {
			"index": index,
			"delay_ms": frame.delay_ms,
			"occupied": occupied,
			"bounds": _cell_bounds_json(frame.get_bounds()),
			"empty": occupied == 0,
		}
		if (include_materials or include_islands or include_transitions) and occupied > 0:
			var scan := _scan_frame(frame)
			scans[index] = scan
			if scan.truncated:
				frame_data["scan_truncated"] = true
			if include_materials and not scan.truncated:
				frame_data["materials"] = _materials_json(scan.materials)
			if include_islands and not scan.truncated:
				var region_result := _build_regions(scan.cells, group, min_island_cells, max_islands, "", scan.materials)
				frame_data["islands"] = region_result.regions
				frame_data["island_count"] = region_result.total
				if region_result.truncated:
					frame_data["islands_truncated"] = true
				if region_result.small_count > 0:
					frame_data["small_islands"] = region_result.small_count
		frames.append(frame_data)
	var transitions: Array = []
	if include_transitions:
		for transition_index in range(1, indices.size()):
			transitions.append(_transition_json(indices[transition_index - 1], indices[transition_index], scans))
	var document_data := {
		"name": document.get_file_name(),
		"frames": document.frames.size(),
		"current_frame": State.current_frame,
	}
	if include_palette:
		document_data["palette"] = _palette_json()
	var data := {
		"revision": _revision,
		"document": document_data,
		"frames": frames,
		"tags": _tags_json(),
	}
	if include_transitions:
		data["transitions"] = transitions
	return _tool_ok(data)


func _get_regions(args: Dictionary) -> Dictionary:
	var frame_index := _int_arg(args, "frame", State.current_frame)
	var frame: VoxelFrame = State.get_voxel_frame(frame_index)
	if frame == null:
		return _tool_error("The frame does not exist.")
	var group := str(args.get("group", "material"))
	if group != "material" and group != "frame":
		return _tool_error("group must be material or frame.")
	var max_regions := clampi(_int_arg(args, "max_regions", 32), 1, MAX_INSPECT_ISLANDS)
	var min_cells := maxi(1, _int_arg(args, "min_cells", 1))
	var material_filter := ""
	var material_value: Variant = args.get("material", null)
	if material_value != null:
		var material_color: Variant = _parse_color(material_value)
		if material_color == null:
			return _tool_error("material must be a color, for example #ff0000.")
		material_filter = _hex_color(material_color)
	var scan := _scan_frame(frame)
	if scan.truncated:
		return _tool_error("The frame is too large to scan. Use a smaller frame or get_cells in boxes.")
	var cells: Dictionary = scan.cells
	var box_value: Variant = args.get("box", null)
	if box_value != null:
		var box: Variant = _parse_box(box_value)
		if box == null:
			return _tool_error("box must be [x0, y0, z0, x1, y1, z1] with min <= max.")
		cells = _cells_in_box(cells, box[0], box[1])
	var region_result := _build_regions(cells, group, min_cells, max_regions, material_filter, scan.materials)
	var data := {
		"revision": _revision,
		"frame": frame_index,
		"group": group,
		"regions": region_result.regions,
		"region_count": region_result.total,
		"truncated": region_result.truncated,
	}
	if region_result.small_count > 0:
		data["small_regions"] = region_result.small_count
	if not material_filter.is_empty():
		data["material"] = material_filter
	return _tool_ok(data)


func _get_slice(args: Dictionary) -> Dictionary:
	var frame_index := _int_arg(args, "frame", State.current_frame)
	var frame: VoxelFrame = State.get_voxel_frame(frame_index)
	if frame == null:
		return _tool_error("The frame does not exist.")
	var axis := str(args.get("axis", "y"))
	if not ["x", "y", "z"].has(axis):
		return _tool_error("axis must be x, y, or z.")
	var mode := str(args.get("mode", "materials"))
	if not ["occupancy", "materials", "height", "depth"].has(mode):
		return _tool_error("mode must be occupancy, materials, height, or depth.")
	var bounds := _frame_cell_bounds(frame)
	if bounds.is_empty():
		return _tool_ok({"revision": _revision, "frame": frame_index, "axis": axis, "mode": mode, "empty": true, "slices": []})
	var min_cell: Vector3i = bounds[0]
	var max_cell: Vector3i = bounds[1]
	var box_value: Variant = args.get("box", null)
	if box_value != null:
		var box: Variant = _parse_box(box_value)
		if box == null:
			return _tool_error("box must be [x0, y0, z0, x1, y1, z1] with min <= max.")
		min_cell = box[0]
		max_cell = box[1]
	var scan := _scan_frame(frame)
	if scan.truncated:
		return _tool_error("The frame is too large to scan. Use a box or get_map.")
	var cells: Dictionary = _cells_in_box(scan.cells, min_cell, max_cell)
	if cells.is_empty():
		return _tool_ok({"revision": _revision, "frame": frame_index, "axis": axis, "mode": mode, "empty": true, "slices": []})
	var fixed_index := 1
	var column_axis := 0
	var row_axis := 2
	match axis:
		"x":
			fixed_index = 0
			column_axis = 2
			row_axis = 1
		"z":
			fixed_index = 2
			column_axis = 0
			row_axis = 1
	var col_start := min_cell[column_axis]
	var col_end := max_cell[column_axis]
	var row_start := min_cell[row_axis]
	var row_end := max_cell[row_axis]
	var fixed_start := min_cell[fixed_index]
	var fixed_end := max_cell[fixed_index]
	var width := col_end - col_start + 1
	var height := row_end - row_start + 1
	var max_size := clampi(_int_arg(args, "max_size", 64), 8, 256)
	var scale_arg := _int_arg(args, "scale", 0)
	var scale := scale_arg
	if scale <= 0:
		scale = maxi(1, ceili(float(maxi(width, height)) / float(max_size)))
	scale = clampi(scale, 1, 16)
	var grid_width := ceili(float(width) / float(scale))
	var grid_height := ceili(float(height) / float(scale))
	if grid_width * grid_height > 65536:
		return _tool_error("The slice is too large. Use a box or a larger scale.")
	var is_projection := mode == "height" or mode == "depth"
	var layer_values: Array = []
	if not is_projection:
		var layers_value: Variant = args.get("layers", null)
		if layers_value is Array:
			var source: Array = layers_value
			if source.is_empty() or source.size() > 32:
				return _tool_error("layers must hold 1 to 32 layer indices.")
			for value in source:
				if not (value is int or value is float):
					return _tool_error("layers must hold integers.")
				layer_values.append(int(value))
		else:
			layer_values.append(fixed_start + (fixed_end - fixed_start) / 2)
	var material_counts := {}
	if mode == "materials":
		for cell in cells:
			if is_projection or layer_values.has(cell[fixed_index]):
				var key: String = cells[cell]
				material_counts[key] = int(material_counts.get(key, 0)) + 1
	var material_list: Array = []
	for key in material_counts:
		material_list.append({"key": key, "cells": material_counts[key]})
	material_list.sort_custom(_region_more_cells)
	var char_by_key := {}
	var legend: Array = []
	for index in range(material_list.size()):
		var entry: Dictionary = material_list[index]
		var key: String = entry["key"]
		var slice_char: String = SLICE_CHARS[index] if index < SLICE_CHARS.size() else "?"
		char_by_key[key] = slice_char
		var material_json: Variant = {}
		var material_entry: Variant = scan.materials.get(key, null)
		if material_entry is Dictionary:
			material_json = material_entry.get("material", {})
		legend.append({"char": slice_char, "material": material_json, "key": key})
	var slices: Array = []
	var values: Array = []
	if is_projection:
		var cell_values := {}
		for cell in cells:
			var key := Vector2i(
				floori(float(cell[column_axis] - col_start) / float(scale)),
				floori(float(cell[row_axis] - row_start) / float(scale))
			)
			if mode == "height":
				if cell_values.has(key):
					cell_values[key] = maxi(int(cell_values[key]), int(cell[fixed_index]))
				else:
					cell_values[key] = int(cell[fixed_index])
			else:
				cell_values[key] = int(cell_values.get(key, 0)) + 1
		for gy in range(grid_height):
			var row: Array = []
			for gx in range(grid_width):
				var key := Vector2i(gx, gy)
				if mode == "height":
					row.append(int(cell_values[key]) if cell_values.has(key) else -1)
				else:
					row.append(int(cell_values.get(key, 0)))
			values.append(row)
	else:
		for layer in layer_values:
			var lines: Array = []
			for gy in range(grid_height):
				var line := ""
				for gx in range(grid_width):
					var chosen := ""
					if mode == "occupancy":
						var found := false
						for dy in range(scale):
							for dx in range(scale):
								var cell := _cell_with_axes(
									fixed_index, layer,
									column_axis, col_start + gx * scale + dx,
									row_axis, row_start + gy * scale + dy
								)
								if cells.has(cell):
									found = true
									break
							if found:
								break
						line += "#" if found else "."
					else:
						var block_materials := {}
						for dy in range(scale):
							for dx in range(scale):
								var cell := _cell_with_axes(
									fixed_index, layer,
									column_axis, col_start + gx * scale + dx,
									row_axis, row_start + gy * scale + dy
								)
								if cells.has(cell):
									var key: String = cells[cell]
									block_materials[key] = int(block_materials.get(key, 0)) + 1
						var chosen_count := 0
						for key in block_materials:
							if int(block_materials[key]) > chosen_count:
								chosen_count = int(block_materials[key])
								chosen = key
						line += "." if chosen.is_empty() else str(char_by_key.get(chosen, "?"))
				lines.append(line)
			var origin := _cell_with_axes(fixed_index, layer, column_axis, col_start, row_axis, row_start)
			slices.append({"layer": layer, "origin": _json_cell(origin), "lines": lines})
	var data := {
		"revision": _revision,
		"frame": frame_index,
		"axis": axis,
		"mode": mode,
		"scale": scale,
		"columns": _axis_name(column_axis),
		"rows": _axis_name(row_axis),
		"column_start": col_start,
		"row_start": row_start,
	}
	if is_projection:
		data["values"] = values
		data["empty_value"] = -1 if mode == "height" else 0
	else:
		data["slices"] = slices
	if mode == "materials":
		data["legend"] = legend
	return _tool_ok(data)


func _get_map(args: Dictionary) -> Dictionary:
	var frame_index := _int_arg(args, "frame", State.current_frame)
	var frame: VoxelFrame = State.get_voxel_frame(frame_index)
	if frame == null:
		return _tool_error("The frame does not exist.")
	var bounds := _frame_cell_bounds(frame)
	if bounds.is_empty():
		return _tool_ok({"revision": _revision, "frame": frame_index, "blocks": [], "empty": true})
	var min_cell: Vector3i = bounds[0]
	var max_cell: Vector3i = bounds[1]
	var box_value: Variant = args.get("box", null)
	if box_value != null:
		var box: Variant = _parse_box(box_value)
		if box == null:
			return _tool_error("box must be [x0, y0, z0, x1, y1, z1] with min <= max.")
		min_cell = box[0]
		max_cell = box[1]
	var cell_size := clampi(_int_arg(args, "cell_size", 16), 1, 128)
	var max_blocks := clampi(_int_arg(args, "max_blocks", 512), 1, 4096)
	var scan := _scan_frame(frame)
	if scan.truncated:
		return _chunk_map(frame, frame_index, min_cell, max_cell, max_blocks)
	var cells := _cells_in_box(scan.cells, min_cell, max_cell)
	var block_counts := {}
	var block_materials := {}
	for cell in cells:
		var block := Vector3i(
			floori(float(cell.x - min_cell.x) / float(cell_size)),
			floori(float(cell.y - min_cell.y) / float(cell_size)),
			floori(float(cell.z - min_cell.z) / float(cell_size))
		)
		block_counts[block] = int(block_counts.get(block, 0)) + 1
		var counts: Dictionary
		if block_materials.has(block):
			counts = block_materials[block]
		else:
			counts = {}
			block_materials[block] = counts
		var key: String = cells[cell]
		counts[key] = int(counts.get(key, 0)) + 1
	var block_keys: Array = block_counts.keys()
	block_keys.sort_custom(_cell_less)
	var blocks: Array = []
	for block in block_keys:
		if blocks.size() >= max_blocks:
			break
		var counts: Dictionary = block_materials[block]
		var best_key := ""
		var best_count := -1
		for key in counts:
			if int(counts[key]) > best_count:
				best_count = int(counts[key])
				best_key = key
		var material_json: Variant = {}
		if scan.materials.has(best_key):
			material_json = scan.materials[best_key].get("material", {})
		blocks.append([block.x, block.y, block.z, block_counts[block], material_json])
	var size := Vector3i(
		ceili(float(max_cell.x - min_cell.x + 1) / float(cell_size)),
		ceili(float(max_cell.y - min_cell.y + 1) / float(cell_size)),
		ceili(float(max_cell.z - min_cell.z + 1) / float(cell_size))
	)
	return _tool_ok({
		"revision": _revision,
		"frame": frame_index,
		"cell_size": cell_size,
		"origin": _json_cell(min_cell),
		"size": _json_cell(size),
		"blocks": blocks,
		"block_count": block_counts.size(),
		"truncated": block_keys.size() > blocks.size(),
		"occupied": cells.size(),
	})


func _chunk_map(frame: VoxelFrame, frame_index: int, min_cell: Vector3i, max_cell: Vector3i, max_blocks: int) -> Dictionary:
	var block_counts := {}
	for chunk_value in frame.chunks.values():
		var chunk: VoxelFrame.Chunk = chunk_value
		if chunk.occupied_count <= 0:
			continue
		var chunk_bounds := chunk.get_bounds()
		if not chunk_bounds.has_volume():
			continue
		var chunk_min := Vector3i(
			roundi(chunk_bounds.position.x + 0.5),
			roundi(chunk_bounds.position.y + 0.5),
			roundi(chunk_bounds.position.z + 0.5)
		)
		var chunk_max := Vector3i(
			roundi(chunk_bounds.end.x - 0.5),
			roundi(chunk_bounds.end.y - 0.5),
			roundi(chunk_bounds.end.z - 0.5)
		)
		if chunk_max.x < min_cell.x or chunk_min.x > max_cell.x:
			continue
		if chunk_max.y < min_cell.y or chunk_min.y > max_cell.y:
			continue
		if chunk_max.z < min_cell.z or chunk_min.z > max_cell.z:
			continue
		var block := VoxelFrame.chunk_position(chunk.origin())
		block_counts[block] = int(block_counts.get(block, 0)) + chunk.occupied_count
	var block_keys: Array = block_counts.keys()
	block_keys.sort_custom(_cell_less)
	var blocks: Array = []
	var occupied := 0
	for count in block_counts.values():
		occupied += int(count)
	for block in block_keys:
		if blocks.size() >= max_blocks:
			break
		blocks.append([block.x, block.y, block.z, block_counts[block], {}])
	return _tool_ok({
		"revision": _revision,
		"frame": frame_index,
		"cell_size": VoxelFrame.CHUNK_SIZE,
		"origin": [0, 0, 0],
		"chunk_aligned": true,
		"blocks": blocks,
		"block_count": block_counts.size(),
		"truncated": block_keys.size() > blocks.size(),
		"occupied": occupied,
		"approximate": true,
	})


func _get_changes(args: Dictionary) -> Dictionary:
	var since_value: Variant = args.get("since", null)
	if not (since_value is int or since_value is float):
		return _tool_error("since is required.")
	var since := int(since_value)
	var frame_index := _int_arg(args, "frame", State.current_frame)
	if frame_index < 0 or frame_index >= State.document.frames.size():
		return _tool_error("The frame does not exist.")
	if since == _revision:
		return _tool_ok({
			"revision": _revision,
			"frame": frame_index,
			"full_refresh": false,
			"cells": [],
			"count": 0,
			"chunk_origins": [],
		})
	if since < _journal_floor or since > _revision:
		return _tool_ok({"revision": _revision, "frame": frame_index, "full_refresh": true})
	var cells := {}
	var chunks := {}
	var other_frames := {}
	for entry in _journal:
		if int(entry.get("revision", 0)) <= since:
			continue
		var entry_frame := int(entry.get("frame", -1))
		if entry_frame != frame_index:
			other_frames[entry_frame] = true
			continue
		var entry_cells: Variant = entry.get("cells", null)
		if entry_cells is Array:
			for cell in entry_cells:
				cells[cell] = true
		var entry_chunks: Variant = entry.get("chunks", null)
		if entry_chunks is Array:
			for cell in entry_chunks:
				chunks[cell] = true
	var box_value: Variant = args.get("box", null)
	if box_value != null:
		var box: Variant = _parse_box(box_value)
		if box == null:
			return _tool_error("box must be [x0, y0, z0, x1, y1, z1] with min <= max.")
		var filtered := {}
		for cell in cells:
			if _cell_in_box(cell, box[0], box[1]):
				filtered[cell] = true
		cells = filtered
	var max_cells := clampi(_int_arg(args, "max_cells", 4096), 1, 65536)
	var sorted := _sorted_cell_keys(cells)
	var truncated := sorted.size() > max_cells
	if truncated:
		sorted.resize(max_cells)
	var data := {
		"revision": _revision,
		"frame": frame_index,
		"from": since,
		"full_refresh": false,
		"cells": _runs_from_sorted_cells(sorted),
		"count": sorted.size(),
		"truncated": truncated,
		"chunk_origins": _json_cells(chunks.keys(), max_cells),
		"bounds": _bounds_of_cell_array(sorted),
	}
	if not other_frames.is_empty():
		data["other_frames"] = other_frames.keys()
	return _tool_ok(data)


func _changed_counts_since(since: int, frame_index: int) -> Dictionary:
	var cells := {}
	var chunks := {}
	for entry in _journal:
		if int(entry.get("revision", 0)) <= since:
			continue
		if int(entry.get("frame", -1)) != frame_index:
			continue
		var entry_cells: Variant = entry.get("cells", null)
		if entry_cells is Array:
			for cell in entry_cells:
				cells[cell] = true
		var entry_chunks: Variant = entry.get("chunks", null)
		if entry_chunks is Array:
			for cell in entry_chunks:
				chunks[cell] = true
	return {"cells": cells.size(), "chunks": chunks.size()}


func _changed_bounds_since(since: int, frame_index: int) -> Variant:
	var cells := {}
	var chunks := {}
	for entry in _journal:
		if int(entry.get("revision", 0)) <= since:
			continue
		if int(entry.get("frame", -1)) != frame_index:
			continue
		var entry_cells: Variant = entry.get("cells", null)
		if entry_cells is Array:
			for cell in entry_cells:
				cells[cell] = true
		var entry_chunks: Variant = entry.get("chunks", null)
		if entry_chunks is Array:
			for cell in entry_chunks:
				chunks[cell] = true
	# A cell list is exact. A tool that reports only chunks has no cell list, so
	# its bounds cover the whole changed chunks and stay coarse.
	if not cells.is_empty():
		return _bounds_of_dictionaries([cells])
	if chunks.is_empty():
		return null
	var min_cell := Vector3i.MAX
	var max_cell := Vector3i.MIN
	for origin in chunks:
		var start: Vector3i = origin
		var stop: Vector3i = origin + Vector3i.ONE * (VoxelFrame.CHUNK_SIZE - 1)
		min_cell = Vector3i(mini(min_cell.x, start.x), mini(min_cell.y, start.y), mini(min_cell.z, start.z))
		max_cell = Vector3i(maxi(max_cell.x, stop.x), maxi(max_cell.y, stop.y), maxi(max_cell.z, stop.z))
	return _cell_bounds_json_from_cells(min_cell, max_cell)


func _frame_cell_bounds(frame: VoxelFrame) -> Array:
	if frame == null:
		return []
	var box := frame.get_bounds()
	if not box.has_volume():
		return []
	var min_cell := Vector3i(
		roundi(box.position.x + 0.5),
		roundi(box.position.y + 0.5),
		roundi(box.position.z + 0.5)
	)
	var max_cell := Vector3i(
		roundi(box.end.x - 0.5),
		roundi(box.end.y - 0.5),
		roundi(box.end.z - 0.5)
	)
	return [min_cell, max_cell]


func _frame_bounds_array(frame: VoxelFrame) -> Variant:
	var bounds := _frame_cell_bounds(frame)
	if bounds.is_empty():
		return null
	var min_cell: Vector3i = bounds[0]
	var max_cell: Vector3i = bounds[1]
	return [min_cell.x, min_cell.y, min_cell.z, max_cell.x, max_cell.y, max_cell.z]


func _cell_bounds_json(box: AABB) -> Variant:
	if not box.has_volume():
		return null
	var bounds := []
	var edge := box.position + Vector3.ONE * 0.5
	bounds.append(Vector3i(roundi(edge.x), roundi(edge.y), roundi(edge.z)))
	edge = box.end - Vector3.ONE * 0.5
	bounds.append(Vector3i(roundi(edge.x), roundi(edge.y), roundi(edge.z)))
	return {"min": _json_cell(bounds[0]), "max": _json_cell(bounds[1])}


func _cell_bounds_json_from_cells(min_cell: Vector3i, max_cell: Vector3i) -> Dictionary:
	return {"min": _json_cell(min_cell), "max": _json_cell(max_cell)}


func _cell_before_cursor(cell: Vector3i, cursor: Vector3i) -> bool:
	if cell.z != cursor.z:
		return cell.z < cursor.z
	if cell.y != cursor.y:
		return cell.y < cursor.y
	return cell.x < cursor.x


func _cell_in_box(cell: Vector3i, start: Vector3i, end: Vector3i) -> bool:
	return (
		cell.x >= start.x and cell.x <= end.x
		and cell.y >= start.y and cell.y <= end.y
		and cell.z >= start.z and cell.z <= end.z
	)


func _cells_in_box(cells: Dictionary, start: Vector3i, end: Vector3i) -> Dictionary:
	var filtered := {}
	for cell in cells:
		if _cell_in_box(cell, start, end):
			filtered[cell] = cells[cell]
	return filtered


func _cell_with_axes(fixed_axis: int, fixed_value: int, column_axis: int, column_value: int, row_axis: int, row_value: int) -> Vector3i:
	var cell := Vector3i.ZERO
	for axis in 3:
		var value := 0
		if axis == fixed_axis:
			value = fixed_value
		elif axis == column_axis:
			value = column_value
		else:
			value = row_value
		if axis == 0:
			cell.x = value
		elif axis == 1:
			cell.y = value
		else:
			cell.z = value
	return cell


func _cell_less(a: Vector3i, b: Vector3i) -> bool:
	if a.z != b.z:
		return a.z < b.z
	if a.y != b.y:
		return a.y < b.y
	return a.x < b.x


func _region_more_cells(a: Dictionary, b: Dictionary) -> bool:
	return int(a.get("cells", 0)) > int(b.get("cells", 0))


func _sorted_cell_keys(cells: Dictionary) -> Array:
	var keys: Array = cells.keys()
	keys.sort_custom(_cell_less)
	return keys


func _runs_from_sorted_cells(cells: Array) -> Array:
	var runs: Array = []
	for cell in cells:
		if not runs.is_empty():
			var last: Array = runs[-1]
			if last[1] + 1 == cell.x and last[2] == cell.y and last[3] == cell.z:
				last[1] = cell.x
				continue
		runs.append([cell.x, cell.x, cell.y, cell.z])
	return runs


func _bounds_of_cell_array(cells: Array) -> Variant:
	if cells.is_empty():
		return null
	var min_cell: Vector3i = cells[0]
	var max_cell: Vector3i = cells[0]
	for cell in cells:
		min_cell = Vector3i(mini(min_cell.x, cell.x), mini(min_cell.y, cell.y), mini(min_cell.z, cell.z))
		max_cell = Vector3i(maxi(max_cell.x, cell.x), maxi(max_cell.y, cell.y), maxi(max_cell.z, cell.z))
	return _cell_bounds_json_from_cells(min_cell, max_cell)


func _bounds_of_dictionaries(dictionaries: Array) -> Variant:
	var min_cell := Vector3i.MAX
	var max_cell := Vector3i.MIN
	var found := false
	for dictionary in dictionaries:
		for cell in dictionary:
			found = true
			min_cell = Vector3i(mini(min_cell.x, cell.x), mini(min_cell.y, cell.y), mini(min_cell.z, cell.z))
			max_cell = Vector3i(maxi(max_cell.x, cell.x), maxi(max_cell.y, cell.y), maxi(max_cell.z, cell.z))
	if not found:
		return null
	return _cell_bounds_json_from_cells(min_cell, max_cell)


func _json_cells(cells: Array, limit: int) -> Array:
	var result := []
	for index in range(mini(cells.size(), limit)):
		result.append(_json_cell(cells[index]))
	return result


func _bool_arg(args: Dictionary, key: String, fallback: bool) -> bool:
	var value: Variant = args.get(key, null)
	if value is bool:
		return value
	return fallback


func _frame_indices_arg(args: Dictionary) -> Array:
	var document := State.document
	if document == null:
		return []
	var frames_value: Variant = args.get("frames", null)
	if frames_value is Array:
		var source: Array = frames_value
		if source.is_empty() or source.size() > 64:
			return []
		var indices: Array = []
		for value in source:
			if not (value is int or value is float):
				return []
			var index := int(value)
			if index < 0 or index >= document.frames.size():
				return []
			indices.append(index)
		return indices
	var index := _int_arg(args, "frame", State.current_frame)
	if index < 0 or index >= document.frames.size():
		return []
	return [index]


func _tags_json() -> Array:
	var tags: Array = []
	for index in range(State.document.tags.size()):
		var tag := State.document.tags[index]
		tags.append({
			"name": tag.name,
			"from": tag.from,
			"to": tag.to,
			"mode": tag.loop_mode,
			"mode_name": _tag_loop_name(tag.loop_mode),
			"repeats": tag.repeats,
		})
	return tags


func _palette_json() -> Array:
	var entries: Array = []
	for index in range(State.document.palette.size()):
		entries.append({"index": index, "material": _material_json(State.document.palette[index])})
	return entries


func _material_key(material: PackedFloat32Array) -> String:
	var emission := Color(
		material[VoxelFrame.MATERIAL_EMISSION],
		material[VoxelFrame.MATERIAL_EMISSION + 1],
		material[VoxelFrame.MATERIAL_EMISSION + 2]
	)
	return "%s|%.3f|%.3f|%s" % [
		_hex_color(VoxelFrame.material_color(material)),
		material[VoxelFrame.MATERIAL_METALLIC],
		material[VoxelFrame.MATERIAL_ROUGHNESS],
		_hex_color(emission),
	]


func _material_key_matches(key: String, filter: String) -> bool:
	return filter.is_empty() or key.begins_with(filter + "|")


func _scan_frame(frame: VoxelFrame) -> Dictionary:
	var result := {"cells": {}, "materials": {}, "truncated": false, "occupied": 0}
	if frame == null:
		return result
	var total := frame.count()
	result["occupied"] = total
	if total > MAX_SCAN_CELLS:
		result["truncated"] = true
		return result
	var cells: Dictionary = result["cells"]
	var materials: Dictionary = result["materials"]
	for chunk_value in frame.chunks.values():
		var chunk: VoxelFrame.Chunk = chunk_value
		var entries := {}
		var material_count: int = chunk.materials.size() / VoxelFrame.MATERIAL_STRIDE
		for id in range(1, material_count + 1):
			var material: PackedFloat32Array = chunk.materials.slice((id - 1) * VoxelFrame.MATERIAL_STRIDE, id * VoxelFrame.MATERIAL_STRIDE)
			var key := _material_key(material)
			entries[id] = {"key": key, "json": _material_json(material)}
		for cell in chunk.world_cells():
			var id: int = chunk.material_id(cell)
			var entry: Dictionary = entries.get(id, {})
			if entry.is_empty():
				continue
			var key: String = entry["key"]
			cells[cell] = key
			var histogram: Dictionary
			if materials.has(key):
				histogram = materials[key]
			else:
				histogram = {"key": key, "material": entry["json"], "cells": 0, "min": cell, "max": cell}
				materials[key] = histogram
			histogram["cells"] = int(histogram["cells"]) + 1
			var old_min: Vector3i = histogram["min"]
			var old_max: Vector3i = histogram["max"]
			histogram["min"] = Vector3i(mini(old_min.x, cell.x), mini(old_min.y, cell.y), mini(old_min.z, cell.z))
			histogram["max"] = Vector3i(maxi(old_max.x, cell.x), maxi(old_max.y, cell.y), maxi(old_max.z, cell.z))
	return result


func _materials_json(materials: Dictionary) -> Array:
	var list: Array = []
	for histogram in materials.values():
		list.append({
			"material": histogram.get("material", {}),
			"cells": histogram.get("cells", 0),
			"bounds": _cell_bounds_json_from_cells(histogram.get("min", Vector3i.ZERO), histogram.get("max", Vector3i.ZERO)),
			"key": histogram.get("key", ""),
		})
	list.sort_custom(_region_more_cells)
	return list


func _build_regions(cells: Dictionary, group: String, min_cells: int, max_regions: int, material_filter: String, material_table: Dictionary) -> Dictionary:
	var visited := {}
	var regions: Array = []
	var total_found := 0
	var small_count := 0
	var small_cells := 0
	for start_value in cells.keys():
		var start: Vector3i = start_value
		if visited.has(start):
			continue
		var start_key: String = cells[start]
		if not _material_key_matches(start_key, material_filter):
			continue
		var stack: Array[Vector3i] = [start]
		visited[start] = true
		var count := 0
		var min_cell: Vector3i = start
		var max_cell: Vector3i = start
		var sum := Vector3i.ZERO
		var island_materials := {}
		while not stack.is_empty():
			var cell: Vector3i = stack.pop_back()
			count += 1
			sum += cell
			min_cell = Vector3i(mini(min_cell.x, cell.x), mini(min_cell.y, cell.y), mini(min_cell.z, cell.z))
			max_cell = Vector3i(maxi(max_cell.x, cell.x), maxi(max_cell.y, cell.y), maxi(max_cell.z, cell.z))
			var key: String = cells[cell]
			island_materials[key] = int(island_materials.get(key, 0)) + 1
			for offset in REGION_NEIGHBORS:
				var next: Vector3i = cell + offset
				if visited.has(next) or not cells.has(next):
					continue
				if group == "material" and cells[next] != key:
					continue
				if not _material_key_matches(cells[next], material_filter):
					continue
				visited[next] = true
				stack.append(next)
		total_found += 1
		if count < min_cells:
			small_count += 1
			small_cells += count
			continue
		regions.append({
			"cells": count,
			"min": min_cell,
			"max": max_cell,
			"sum": sum,
			"materials": island_materials,
		})
	regions.sort_custom(_region_more_cells)
	var truncated := regions.size() > max_regions
	if truncated:
		regions.resize(max_regions)
	var output: Array = []
	for index in range(regions.size()):
		var region: Dictionary = regions[index]
		var count := int(region["cells"])
		var sum: Vector3i = region["sum"]
		var center := Vector3i(floori(float(sum.x) / count), floori(float(sum.y) / count), floori(float(sum.z) / count))
		var region_data := {
			"id": index,
			"cells": count,
			"bounds": _cell_bounds_json_from_cells(region["min"], region["max"]),
			"center": _json_cell(center),
		}
		var island_materials: Dictionary = region["materials"]
		var material_list: Array = []
		for key in island_materials:
			var material_json: Variant = {}
			if material_table.has(key):
				material_json = material_table[key].get("material", {})
			material_list.append({
				"material": material_json,
				"cells": island_materials[key],
				"key": key,
			})
		material_list.sort_custom(_region_more_cells)
		if group == "material":
			if not material_list.is_empty():
				region_data["material"] = material_list[0]["material"]
				region_data["key"] = material_list[0]["key"]
		else:
			if not material_list.is_empty():
				region_data["material"] = material_list[0]["material"]
			if material_list.size() > 4:
				material_list.resize(4)
			region_data["materials"] = material_list
		output.append(region_data)
	return {
		"regions": output,
		"total": total_found,
		"truncated": truncated,
		"small_count": small_count,
		"small_cells": small_cells,
	}


func _transition_json(from_index: int, to_index: int, scans: Dictionary) -> Dictionary:
	var from_scan: Dictionary = scans.get(from_index, _scan_frame(State.get_voxel_frame(from_index)))
	var to_scan: Dictionary = scans.get(to_index, _scan_frame(State.get_voxel_frame(to_index)))
	if bool(from_scan.get("truncated", false)) or bool(to_scan.get("truncated", false)):
		return {"from": from_index, "to": to_index, "truncated": true}
	var from_cells: Dictionary = from_scan.get("cells", {})
	var to_cells: Dictionary = to_scan.get("cells", {})
	var added := {}
	var removed := {}
	var changed := {}
	for cell in to_cells:
		if not from_cells.has(cell):
			added[cell] = true
		elif from_cells[cell] != to_cells[cell]:
			changed[cell] = true
	for cell in from_cells:
		if not to_cells.has(cell):
			removed[cell] = true
	return {
		"from": from_index,
		"to": to_index,
		"added": added.size(),
		"removed": removed.size(),
		"changed": changed.size(),
		"added_bounds": _bounds_of_dictionaries([added]),
		"removed_bounds": _bounds_of_dictionaries([removed]),
		"bounds": _bounds_of_dictionaries([added, removed, changed]),
	}


func _screenshot(args: Dictionary) -> Dictionary:
	if DisplayServer.get_name() == "headless":
		return _tool_error("The screenshot needs a visible editor window.")
	var size := 256
	var size_value: Variant = args.get("size", 256)
	if size_value is int or size_value is float:
		size = clampi(int(size_value), 64, 1024)
	var inline := false
	var inline_value: Variant = args.get("inline", false)
	if inline_value is bool:
		inline = inline_value
	var orthographic := true
	var ortho_value: Variant = args.get("orthographic", true)
	if ortho_value is bool:
		orthographic = ortho_value
	var focus_value: Variant = args.get("focus", null)
	var focus_bounds: Variant = null
	if focus_value != null:
		var focus_box: Variant = _parse_box(focus_value)
		if focus_box == null:
			return _tool_error("focus must be [x0, y0, z0, x1, y1, z1] with min <= max.")
		var focus_array: Array = focus_box
		var focus_start: Vector3i = focus_array[0]
		var focus_end: Vector3i = focus_array[1]
		focus_bounds = AABB(Vector3(focus_start) - Vector3(0.5, 0.5, 0.5), Vector3(focus_end - focus_start + Vector3i.ONE))
	var views: Array = []
	var views_value: Variant = args.get("views", null)
	if views_value is Array:
		var view_source: Array = views_value
		if view_source.is_empty() or view_source.size() > 6:
			return _tool_error("views must hold 1 to 6 view names.")
		for value in view_source:
			if not (value is String) or not _named_view(str(value)):
				return _tool_error("views must name isometric, low, front, back, left, right, top, or bottom.")
			views.append(str(value))
	var frames: Array = []
	var frames_value: Variant = args.get("frames", null)
	if frames_value is Array:
		var frame_source: Array = frames_value
		if frame_source.is_empty() or frame_source.size() > 16:
			return _tool_error("frames must hold 1 to 16 frame indices.")
		for value in frame_source:
			if not (value is int or value is float):
				return _tool_error("frames must hold integers.")
			var index := int(value)
			if State.get_voxel_frame(index) == null:
				return _tool_error("The frame does not exist.")
			frames.append(index)
	var frame_index := _int_arg(args, "frame", State.current_frame)
	if State.get_voxel_frame(frame_index) == null:
		return _tool_error("The frame does not exist.")
	var view := "isometric"
	var view_value: Variant = args.get("view", "isometric")
	if view_value is String:
		view = str(view_value)
	if not _named_view(view) and view != "current":
		return _tool_error("view must name isometric, low, front, back, left, right, top, bottom, or current.")
	if frames.is_empty():
		frames = [frame_index]
	if views.is_empty():
		views = [view]
	var is_contact := views.size() > 1
	var is_storyboard := frames.size() > 1
	if is_contact and is_storyboard:
		return _tool_error("Use views or frames, not both.")
	if (is_contact or is_storyboard) and (views.has("current") or view == "current"):
		return _tool_error("The current view is not supported with views or frames.")
	if view == "current" and focus_value != null:
		return _tool_error("focus is not supported with the current view.")
	var bounds := AABB()
	if focus_bounds != null:
		bounds = focus_bounds
	elif is_storyboard:
		for index in frames:
			var frame: VoxelFrame = State.get_voxel_frame(index)
			var box := frame.get_bounds()
			if box.has_volume():
				bounds = bounds.merge(box) if bounds.has_volume() else box
	else:
		bounds = State.get_voxel_frame(frames[0]).get_bounds()
	if not bounds.has_volume():
		return _tool_error("The selected frames are empty.")
	var count := maxi(frames.size(), views.size())
	var columns := _int_arg(args, "columns", 0)
	if columns <= 0:
		columns = ceili(sqrt(float(count)))
	columns = clampi(columns, 1, 8)
	var rows := ceili(float(count) / float(columns))
	var gap := 4
	var max_edge := 4096
	var max_tile := maxi(64, (max_edge - (maxi(columns, rows) - 1) * gap) / maxi(columns, rows))
	size = mini(size, max_tile)
	var composite_width := columns * size + (columns - 1) * gap
	var composite_height := rows * size + (rows - 1) * gap
	var composite := Image.create(composite_width, composite_height, false, Image.FORMAT_RGBA8)
	composite.fill(Color(0.118, 0.122, 0.133, 1.0))
	var document := State.document
	var viewport: SubViewport = SCREENSHOT_VIEWPORT.instantiate()
	viewport.size = Vector2i(size, size)
	VoxelImageRenderer.add_child(viewport)
	var renderer: VoxelRenderer = viewport.get_node("%VoxelRenderer")
	var camera: Camera3D = viewport.get_node("Node3D/Camera3D")
	var light: DirectionalLight3D = viewport.get_node("Node3D/Light")
	camera.current = true
	var tile_index := 0
	for row in range(rows):
		for column in range(columns):
			if tile_index >= count:
				break
			var tile_frame: int = int(frames[tile_index] if is_storyboard else frames[0])
			var tile_view: String = str(views[tile_index] if is_contact else views[0])
			var frame: VoxelFrame = State.get_voxel_frame(tile_frame)
			if frame == null:
				viewport.free()
				return _tool_error("The frame does not exist.")
			renderer.source_frame = frame.copy_frame()
			if tile_view == "current":
				if not _apply_editor_camera(camera):
					viewport.free()
					return _tool_error("The editor camera is not available.")
			else:
				var angles := _view_angles(tile_view)
				VoxelImageRenderer.frame_camera(camera, bounds, angles.x, angles.y, orthographic)
			VoxelImageRenderer.apply_directional_shadow(light, camera)
			await get_tree().process_frame
			var deadline := Time.get_ticks_msec() + 10000
			while not renderer.is_settled() and Time.get_ticks_msec() < deadline:
				await get_tree().process_frame
				if State.document != document:
					viewport.free()
					return _tool_error("The document changed before the screenshot finished.")
			for draw in 2:
				viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
				await RenderingServer.frame_post_draw
			var image := viewport.get_texture().get_image()
			image.convert(Image.FORMAT_RGBA8)
			var target := Vector2i(column * (size + gap), row * (size + gap))
			composite.blend_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), target)
			tile_index += 1
	viewport.free()
	var path := "user://mcp_screenshot.png"
	var error := composite.save_png(path)
	if error != OK:
		return _tool_error("The screenshot could not be saved: " + error_string(error))
	var info := {
		"path": ProjectSettings.globalize_path(path),
		"width": composite_width,
		"height": composite_height,
		"tile_size": size,
		"columns": columns,
		"rows": rows,
		"revision": _revision,
		"bounds": _cell_bounds_json(bounds),
	}
	if is_storyboard:
		info["frames"] = frames
		info["view"] = views[0]
	elif is_contact:
		info["views"] = views
		info["frame"] = frames[0]
	else:
		info["frame"] = frames[0]
		info["view"] = views[0]
	if not inline:
		return _tool_ok(info)
	var png := composite.save_png_to_buffer()
	return {
		"content": [
			{"type": "image", "data": Marshalls.raw_to_base64(png), "mimeType": "image/png"},
			{"type": "text", "text": JSON.stringify(info)},
		],
		"structuredContent": info,
	}


func _named_view(view: String) -> bool:
	return ["isometric", "low", "front", "back", "left", "right", "top", "bottom"].has(view)


func _view_angles(view: String) -> Vector2:
	match view:
		"front":
			return Vector2(0.0, 0.0)
		"back":
			return Vector2(180.0, 0.0)
		"left":
			return Vector2(90.0, 0.0)
		"right":
			return Vector2(-90.0, 0.0)
		"top":
			return Vector2(0.0, 89.9)
		"bottom":
			return Vector2(0.0, -89.9)
		"low":
			return Vector2(-35.0, 18.0)
	return Vector2(-45.0, 45.0)


func _apply_editor_camera(camera: Camera3D) -> bool:
	var main: Node = get_tree().get_first_node_in_group("main")
	var editor_viewport: Node = null
	if main != null:
		editor_viewport = main.get_node_or_null("%Viewport")
	var editor_camera: Camera3D = null
	if editor_viewport != null:
		editor_camera = editor_viewport.get_node_or_null("%CameraRig") as Camera3D
	if editor_camera == null:
		return false
	camera.transform = editor_camera.global_transform
	camera.projection = editor_camera.projection
	camera.fov = editor_camera.fov
	camera.size = editor_camera.size
	camera.near = editor_camera.near
	camera.far = editor_camera.far
	return true


func _new_document() -> Dictionary:
	if State.active_edit() != null or State.edit_busy():
		return _tool_error("The editor is busy with another edit. Retry.")
	var index := State.open_tab(State.new_document())
	if State.active_tab != index:
		return _tool_error("The document opened but could not become current.")
	return _tool_ok({"tab": index, "frames": 1})


func _save_document(args: Dictionary) -> Dictionary:
	if State.active_edit() != null or State.edit_busy():
		return _tool_error("The editor is busy with another edit. Retry.")
	var copy := true
	var copy_value: Variant = args.get("copy", true)
	if copy_value is bool:
		copy = copy_value
	var path := _document_path(args.get("path", ""))
	if path.is_empty():
		return _tool_error("path is required.")
	var extension := path.get_extension().to_lower()
	if extension.is_empty():
		path += ".lve"
		extension = "lve"
	elif extension != "lve" and extension != "png":
		return _tool_error("path must end in .lve or .lve.png.")
	var document := State.document
	var encoded := document.encode_document()
	if encoded.is_empty():
		return _tool_error("The document exceeds the format limits or contains invalid data.")
	var preview: Image = null
	if extension == "png":
		if DisplayServer.get_name() == "headless":
			return _tool_error("The PNG preview needs a visible editor window.")
		var operation := State.begin_operation("Rendering preview", -1, true, self)
		preview = await VoxelImageRenderer.render_document_preview(document)
		State.finish_operation(operation)
		if State.document != document:
			return _tool_error("The document changed before the save finished.")
		if preview == null:
			return _tool_error("The preview could not be rendered.")
	var error := document.save_file(path, preview, encoded)
	if error != OK:
		return _tool_error("The document could not be saved: " + error_string(error))
	if not copy:
		State.record_saved(document, path)
	return _tool_ok({
		"path": ProjectSettings.globalize_path(path),
		"copy": copy,
		"main_path": ProjectSettings.globalize_path(document.edit_save_path) if not document.edit_save_path.is_empty() else "",
		"dirty": document.edit_dirty,
	})


func _open_document(args: Dictionary) -> Dictionary:
	if State.active_edit() != null or State.edit_busy():
		return _tool_error("The editor is busy with another edit. Retry.")
	var path := _document_path(args.get("path", ""))
	if path.is_empty():
		return _tool_error("path is required.")
	var document := VoxelDocument.load_file(path)
	if document == null:
		return _tool_error("The document could not be opened.")
	var index := State.open_tab(document)
	if State.active_tab != index:
		return _tool_error("The document opened but could not become current.")
	State.record_opened(document, path)
	return _tool_ok({
		"tab": index,
		"frames": document.frames.size(),
		"path": ProjectSettings.globalize_path(path),
	})


func _document_path(value: Variant) -> String:
	if not (value is String):
		return ""
	var path: String = String(value).strip_edges()
	if path.is_empty():
		return ""
	if path.begins_with("user://") or path.begins_with("res://") or path.is_absolute_path():
		return path
	return "user://" + path


func _add_frame(args: Dictionary) -> Dictionary:
	var count := State.document.frames.size()
	var index := _int_arg(args, "index", count)
	if index < 0 or index > count:
		return _tool_error("index must be between 0 and the frame count.")
	State.add_frame()
	if index < count:
		State.move_frame(count, index)
	return _tool_ok({"frame": State.current_frame, "frames": State.document.frames.size()})


func _remove_frame(args: Dictionary) -> Dictionary:
	var index := _int_arg(args, "frame", -1)
	if index < 0 or index >= State.document.frames.size():
		return _tool_error("The frame does not exist.")
	if State.document.frames.size() <= 1:
		return _tool_error("The document must keep one frame.")
	State.current_frame = index
	State.delete_frame()
	return _tool_ok({"frame": State.current_frame, "frames": State.document.frames.size()})


func _move_frame(args: Dictionary) -> Dictionary:
	var from := _int_arg(args, "from", -1)
	var to := _int_arg(args, "to", -1)
	var count := State.document.frames.size()
	if from < 0 or from >= count or to < 0 or to >= count:
		return _tool_error("from and to must name existing frames.")
	State.move_frame(from, to)
	return _tool_ok({"frame": State.current_frame, "frames": count})


func _duplicate_frame() -> Dictionary:
	State.duplicate_frame()
	return _tool_ok({"frame": State.current_frame, "frames": State.document.frames.size()})


func _set_frame(args: Dictionary) -> Dictionary:
	var index := _int_arg(args, "frame", State.current_frame)
	if index < 0 or index >= State.document.frames.size():
		return _tool_error("The frame does not exist.")
	State.current_frame = index
	return _tool_ok({"frame": index, "delay_ms": State.document.frames[index].delay_ms})


func _set_frame_delay(args: Dictionary) -> Dictionary:
	var index := _int_arg(args, "frame", State.current_frame)
	if index < 0 or index >= State.document.frames.size():
		return _tool_error("The frame does not exist.")
	var ms := _int_arg(args, "ms", State.document.frames[index].delay_ms)
	if ms < 1 or ms > 10000:
		return _tool_error("ms must be between 1 and 10000.")
	State.set_frame_delay(index, ms)
	return _tool_ok({"frame": index, "delay_ms": ms})


func _set_tag_loop(args: Dictionary) -> Dictionary:
	var mode := _tag_loop_mode(args.get("mode", "forward"))
	if mode < 0:
		return _tool_error("mode must be forward, reverse, ping_pong, or ping_pong_reverse.")
	var index := _int_arg(args, "tag", State.active_tag)
	if index < 0 and not State.document.tags.is_empty():
		index = 0
	if index < 0 or index >= State.document.tags.size():
		return _tool_error("The tag does not exist.")
	State.set_tag_loop_mode(index, mode)
	var repeats_value: Variant = args.get("repeats", null)
	if repeats_value is int or repeats_value is float:
		State.set_tag_repeats(index, clampi(int(repeats_value), 0, 1000))
	return _tool_ok(_tag_json(index, State.get_tag(index)))


func _add_tag(args: Dictionary) -> Dictionary:
	var name_value: Variant = args.get("name", "")
	if not (name_value is String):
		return _tool_error("name must be a string.")
	var tag_name: String = String(name_value).strip_edges()
	if tag_name.is_empty():
		return _tool_error("name is required.")
	var last := State.document.frames.size() - 1
	var from := _int_arg(args, "from", 0)
	var to := _int_arg(args, "to", last)
	if from < 0 or from > last or to < from or to > last:
		return _tool_error("The tag range must be inside the frames and from must not exceed to.")
	var mode := _tag_loop_mode(args.get("mode", "forward"))
	if mode < 0:
		return _tool_error("mode must be forward, reverse, ping_pong, or ping_pong_reverse.")
	State.add_tag(tag_name, from, to)
	var index := State.document.tags.size() - 1
	if index < 0:
		return _tool_error("The tag could not be added.")
	State.set_tag_loop_mode(index, mode)
	State.set_tag_repeats(index, clampi(_int_arg(args, "repeats", 0), 0, 1000))
	return _tool_ok(_tag_json(index, State.get_tag(index)))


func _remove_tag(args: Dictionary) -> Dictionary:
	var index := _int_arg(args, "tag", -1)
	if index < 0 or index >= State.document.tags.size():
		return _tool_error("The tag does not exist.")
	if State.document.tags.size() <= 1:
		return _tool_error("The document must keep one tag.")
	State.active_tag = index
	State.remove_tag()
	return _tool_ok({"tag": State.active_tag, "tags": State.document.tags.size()})


func _rename_tag(args: Dictionary) -> Dictionary:
	var index := _int_arg(args, "tag", -1)
	if index < 0 or index >= State.document.tags.size():
		return _tool_error("The tag does not exist.")
	var name_value: Variant = args.get("name", "")
	if not (name_value is String) or String(name_value).strip_edges().is_empty():
		return _tool_error("name is required.")
	State.set_tag_name(index, String(name_value).strip_edges())
	return _tool_ok(_tag_json(index, State.get_tag(index)))


func _set_tag_range(args: Dictionary) -> Dictionary:
	var index := _int_arg(args, "tag", State.active_tag)
	if index < 0 or index >= State.document.tags.size():
		return _tool_error("The tag does not exist.")
	var last := State.document.frames.size() - 1
	var from := _int_arg(args, "from", -1)
	var to := _int_arg(args, "to", -1)
	if from < 0 or from > last or to < from or to > last:
		return _tool_error("The tag range must be inside the frames and from must not exceed to.")
	State.active_tag = index
	State.set_tag_range(from, to)
	return _tool_ok(_tag_json(index, State.get_tag(index)))


func _set_active_tag(args: Dictionary) -> Dictionary:
	var index := _int_arg(args, "tag", -1)
	if index < -1 or index >= State.document.tags.size():
		return _tool_error("The tag does not exist.")
	State.active_tag = index
	var tag := State.get_tag(index)
	var data := {"tag": index, "tags": State.document.tags.size()}
	if tag != null:
		data["name"] = tag.name
		data["from"] = tag.from
		data["to"] = tag.to
		data["mode"] = tag.loop_mode
		data["repeats"] = tag.repeats
	return _tool_ok(data)


func _tag_loop_mode(value: Variant) -> int:
	match str(value):
		"forward":
			return AnimationTag.LoopMode.FORWARD
		"reverse":
			return AnimationTag.LoopMode.REVERSE
		"ping_pong":
			return AnimationTag.LoopMode.PING_PONG
		"ping_pong_reverse":
			return AnimationTag.LoopMode.PING_PONG_REVERSE
		_:
			return -1


func _tag_loop_name(mode: int) -> String:
	match mode:
		AnimationTag.LoopMode.REVERSE:
			return "reverse"
		AnimationTag.LoopMode.PING_PONG:
			return "ping_pong"
		AnimationTag.LoopMode.PING_PONG_REVERSE:
			return "ping_pong_reverse"
		_:
			return "forward"


func _tag_json(index: int, tag: AnimationTag) -> Dictionary:
	if tag == null:
		return {"tag": index}
	return {
		"tag": index,
		"name": tag.name,
		"from": tag.from,
		"to": tag.to,
		"mode": tag.loop_mode,
		"mode_name": _tag_loop_name(tag.loop_mode),
		"repeats": tag.repeats,
	}


func _set_playback(args: Dictionary) -> Dictionary:
	var playing_value: Variant = args.get("playing", false)
	var playing: bool = playing_value if playing_value is bool else false
	State.is_playing = playing
	return _tool_ok({"playing": State.is_playing, "frame": State.current_frame})


func _int_arg(args: Dictionary, key: String, fallback: int) -> int:
	var value: Variant = args.get(key, null)
	if value is int or value is float:
		return int(value)
	return fallback


func _set_tool(args: Dictionary) -> Dictionary:
	if State.active_edit() != null:
		return _tool_error("The editor has an open edit. Finish it before switching tools.")
	var tool_value: Variant = args.get("tool", "")
	if not (tool_value is String):
		return _tool_error("tool must be a string.")
	var tool_id: String = tool_value
	if not ["brush", "eraser", "paint", "fill"].has(tool_id):
		return _tool_error("tool must be brush, eraser, paint, or fill.")
	var diameter := -1
	var diameter_value: Variant = args.get("diameter", null)
	if diameter_value is int or diameter_value is float:
		diameter = clampi(int(diameter_value), 1, 64)
	var shape := -1
	var shape_value: Variant = args.get("shape", null)
	if shape_value is String:
		match str(shape_value):
			"cube":
				shape = StampToolSettings.BrushShape.CUBE
			"sphere":
				shape = StampToolSettings.BrushShape.SPHERE
			_:
				return _tool_error("shape must be cube or sphere.")
	var pixel_perfect: Variant = args.get("pixel_perfect", null)
	var connected: Variant = args.get("connected", null)
	if tool_id == "brush" or tool_id == "eraser":
		var plugin: Node = _plugin("BrushPlugin")
		if plugin == null:
			return _tool_error("The brush plugin is not ready.")
		var settings: BrushToolSettings = plugin.get("_settings")
		if settings == null:
			return _tool_error("The brush settings are not ready.")
		settings.mode = BrushToolSettings.BrushMode.ERASER if tool_id == "eraser" else BrushToolSettings.BrushMode.PENCIL
		if diameter > 0:
			settings.diameter = diameter
		if shape >= 0:
			settings.shape = shape
		if pixel_perfect is bool:
			settings.pixel_perfect = pixel_perfect
		_activate_plugin("BrushPlugin")
	else:
		var plugin: Node = _plugin("PaintPlugin")
		if plugin == null:
			return _tool_error("The paint plugin is not ready.")
		var settings: PaintToolSettings = plugin.get("_settings")
		if settings == null:
			return _tool_error("The paint settings are not ready.")
		settings.tool = PaintToolSettings.Tools.FILL if tool_id == "fill" else PaintToolSettings.Tools.PAINTBRUSH
		if diameter > 0:
			settings.diameter = diameter
		if shape >= 0:
			settings.shape = shape
		if pixel_perfect is bool:
			settings.pixel_perfect = pixel_perfect
		if connected is bool:
			settings.connected = connected
		_activate_plugin("PaintPlugin")
	var info := _active_tool_info()
	return _tool_ok({"tool": info.get("id", ""), "params": info.get("params", {})})


func _set_material(args: Dictionary) -> Dictionary:
	if State.active_edit() != null:
		return _tool_error("The editor has an open edit. Finish it before changing the material.")
	var material_value: Variant = _parse_material(args)
	if not (material_value is PackedFloat32Array):
		return _tool_error("Provide a valid color, palette_index, metallic, or roughness.")
	var material: PackedFloat32Array = material_value
	if not VoxelDocument.valid_material(material):
		return _tool_error("The material values must be between 0 and 1.")
	State.set_material(material)
	return _tool_ok({"material": _material_json(material)})


func _set_cursor(args: Dictionary) -> Dictionary:
	if State.active_edit() != null:
		return _tool_error("The editor has an open edit. Finish it before moving the cursor.")
	var info := _active_tool_info()
	var node_value: Variant = info.get("node")
	if not (node_value is VoxelTool):
		return _tool_error("Select a tool first.")
	var tool: VoxelTool = node_value
	var cell_value: Variant = args.get("cell", null)
	if cell_value == null:
		tool.visible = false
		return _tool_ok({"hidden": true})
	var cell: Variant = _parse_cell(cell_value)
	if cell == null:
		return _tool_error("cell must be [x, y, z] or null.")
	var cell_position: Vector3i = cell
	var tool_id := str(info.get("id", ""))
	tool.driver_show_cursor(cell_position, cell_position if tool_id == "paint" else VoxelPicking.NONE)
	return _tool_ok({"cell": _json_cell(cell_position)})


func _stroke(args: Dictionary) -> Dictionary:
	if State.active_edit() != null or State.edit_busy():
		return _tool_error("The editor is busy with another edit. Retry.")
	var before_revision := _revision
	var points_value: Variant = _parse_cells(args.get("points", null), 4096)
	if not (points_value is Array):
		return _tool_error("points must be an array of [x, y, z] cells.")
	var points: Array = points_value
	if points.is_empty():
		return _tool_error("points must hold at least one cell.")
	var info := _active_tool_info()
	var tool_id := str(info.get("id", ""))
	var node_value: Variant = info.get("node")
	if not (node_value is VoxelTool):
		return _tool_error("Select a tool first.")
	var tool: VoxelTool = node_value
	if tool_id != "brush" and tool_id != "paint" and tool_id != "eraser":
		return _tool_error("Select brush, paint, or eraser first.")
	var first: Vector3i = points[0]
	var hit := first if tool_id == "paint" else VoxelPicking.NONE
	if not tool.driver_begin_stroke(first, hit):
		return _tool_error("The tool could not start a stroke. The editor is busy.")
	for index in range(1, points.size()):
		var point: Vector3i = points[index]
		tool.driver_stroke_to(point)
	tool.driver_end_stroke()
	var completed := await _wait_tool_idle(tool, 30000)
	if not completed:
		return _tool_error("The stroke did not complete within 30 seconds.")
	for wait_frame in 2:
		await get_tree().process_frame
	var counts := _changed_counts_since(before_revision, State.current_frame)
	return _tool_ok({
		"tool": tool_id,
		"points": points.size(),
		"revision": _revision,
		"occupied": State.get_current_voxel_frame().count() if State.get_current_voxel_frame() != null else 0,
		"changed_cells": counts["cells"],
		"changed_chunks": counts["chunks"],
		"changed_bounds": _changed_bounds_since(before_revision, State.current_frame),
	})


func _fill(args: Dictionary) -> Dictionary:
	if State.active_edit() != null or State.edit_busy():
		return _tool_error("The editor is busy with another edit. Retry.")
	var before_revision := _revision
	var seed_value: Variant = _parse_cell(args.get("seed", null))
	if seed_value == null:
		return _tool_error("seed must be [x, y, z].")
	var seed: Vector3i = seed_value
	var info := _active_tool_info()
	var tool_id := str(info.get("id", ""))
	var node_value: Variant = info.get("node")
	if tool_id != "fill" or not (node_value is VoxelTool):
		return _tool_error("Select the fill tool first.")
	var tool: VoxelTool = node_value
	var error_value: Variant = tool.call("driver_fill", seed)
	if not (error_value is int):
		return _tool_error("The fill tool is not available.")
	var error: Error = error_value
	if error == ERR_BUSY:
		return _tool_error("The fill tool is busy.")
	if error != OK:
		return _tool_error("The seed cell is empty or invalid.")
	var completed := await _wait_tool_idle(tool, 60000)
	if not completed:
		return _tool_error("The fill did not complete within 60 seconds.")
	for wait_frame in 2:
		await get_tree().process_frame
	var counts := _changed_counts_since(before_revision, State.current_frame)
	return _tool_ok({
		"seed": _json_cell(seed),
		"revision": _revision,
		"occupied": State.get_current_voxel_frame().count() if State.get_current_voxel_frame() != null else 0,
		"changed_cells": counts["cells"],
		"changed_chunks": counts["chunks"],
		"changed_bounds": _changed_bounds_since(before_revision, State.current_frame),
	})


func _write_cells(args: Dictionary) -> Dictionary:
	if State.active_edit() != null or State.edit_busy():
		return _tool_error("The editor is busy with another edit. Retry.")
	var materials: Array = []
	var materials_value: Variant = args.get("materials", null)
	if materials_value != null:
		if not (materials_value is Array):
			return _tool_error("materials must be an array of material objects.")
		var entries: Array = materials_value
		if entries.is_empty() or entries.size() > 256:
			return _tool_error("materials must hold 1 to 256 entries.")
		for index in range(entries.size()):
			var entry: Variant = entries[index]
			if not (entry is Dictionary):
				return _tool_error("materials[%d] must be a material object." % index)
			var material_value: Variant = _parse_material(entry)
			if not (material_value is PackedFloat32Array):
				return _tool_error("materials[%d] has invalid values." % index)
			var material: PackedFloat32Array = material_value
			if not VoxelDocument.valid_material(material):
				return _tool_error("materials[%d] values must be between 0 and 1." % index)
			materials.append(material)
	var erase := false
	var erase_value: Variant = args.get("erase", false)
	if erase_value is bool:
		erase = erase_value
	var current_material := VoxelFrame.material(Color.TRANSPARENT) if erase else State.current_material
	var changes := {}
	var cell_count := 0
	var cells_value: Variant = args.get("cells", null)
	if cells_value != null:
		if not (cells_value is Array):
			return _tool_error("cells must be an array of [x, y, z] or [x, y, z, material_index].")
		var cell_list: Array = cells_value
		if cell_list.is_empty() or cell_list.size() > MAX_WRITE_CELLS:
			return _tool_error("cells must hold 1 to %d entries." % MAX_WRITE_CELLS)
		for index in range(cell_list.size()):
			var parsed: Variant = _parse_write_cell(cell_list[index])
			if parsed == null:
				return _tool_error("cells[%d] must be [x, y, z] or [x, y, z, material_index]." % index)
			var shape: Array = parsed
			var material: Variant = _write_material(shape[1], materials, current_material, erase)
			if material == null:
				return _tool_error("cells[%d] names a material index that does not exist." % index)
			changes[shape[0]] = material
			cell_count += 1
			if cell_count > MAX_WRITE_CELLS:
				return _tool_error("The write exceeds %d cells." % MAX_WRITE_CELLS)
	var boxes_value: Variant = args.get("boxes", null)
	if boxes_value != null:
		if not (boxes_value is Array):
			return _tool_error("boxes must be an array of [x0, y0, z0, x1, y1, z1] with an optional material index.")
		var box_list: Array = boxes_value
		if box_list.is_empty() or box_list.size() > 1024:
			return _tool_error("boxes must hold 1 to 1024 entries.")
		for index in range(box_list.size()):
			var parsed: Variant = _parse_write_box(box_list[index])
			if parsed == null:
				return _tool_error("boxes[%d] must be [x0, y0, z0, x1, y1, z1] with min <= max and an optional material index." % index)
			var shape: Array = parsed
			var start: Vector3i = shape[0]
			var end: Vector3i = shape[1]
			var material: Variant = _write_material(shape[2], materials, current_material, erase)
			if material == null:
				return _tool_error("boxes[%d] names a material index that does not exist." % index)
			var extent := end - start + Vector3i.ONE
			# Check each axis before the product, so a wide box cannot overflow the
			# cell cap and enter the write loops.
			if extent.x > MAX_WRITE_CELLS or extent.y > MAX_WRITE_CELLS or extent.z > MAX_WRITE_CELLS:
				return _tool_error("The write exceeds %d cells." % MAX_WRITE_CELLS)
			var volume := extent.x * extent.y * extent.z
			if cell_count + volume > MAX_WRITE_CELLS:
				return _tool_error("The write exceeds %d cells." % MAX_WRITE_CELLS)
			for x in range(start.x, end.x + 1):
				for y in range(start.y, end.y + 1):
					for z in range(start.z, end.z + 1):
						changes[Vector3i(x, y, z)] = material
			cell_count += volume
	var runs_value: Variant = args.get("runs", null)
	if runs_value != null:
		if not (runs_value is Array):
			return _tool_error("runs must be an array of [x0, x1, y, z] with an optional material index.")
		var run_list: Array = runs_value
		if run_list.is_empty() or run_list.size() > MAX_WRITE_CELLS:
			return _tool_error("runs must hold 1 to %d entries." % MAX_WRITE_CELLS)
		for index in range(run_list.size()):
			var parsed: Variant = _parse_write_run(run_list[index])
			if parsed == null:
				return _tool_error("runs[%d] must be [x0, x1, y, z] with x0 <= x1 and an optional material index." % index)
			var shape: Array = parsed
			var first: int = shape[0]
			var last: int = shape[1]
			var y: int = shape[2]
			var z: int = shape[3]
			var material: Variant = _write_material(shape[4], materials, current_material, erase)
			if material == null:
				return _tool_error("runs[%d] names a material index that does not exist." % index)
			var length := last - first + 1
			if length > MAX_WRITE_CELLS:
				return _tool_error("The write exceeds %d cells." % MAX_WRITE_CELLS)
			if cell_count + length > MAX_WRITE_CELLS:
				return _tool_error("The write exceeds %d cells." % MAX_WRITE_CELLS)
			for x in range(first, last + 1):
				changes[Vector3i(x, y, z)] = material
			cell_count += length
	if changes.is_empty():
		return _tool_error("Provide cells, boxes, or runs.")
	var frames := _write_frames(args)
	if frames.is_empty():
		return _tool_error("frames must hold 1 to 16 existing frame indices.")
	var writes_other_frame := false
	for frame_index in frames:
		if int(frame_index) != State.current_frame:
			writes_other_frame = true
			break
	if writes_other_frame and State.selection.count() > 0:
		return _tool_error("Clear the selection before writing to other frames.")
	if changes.size() * frames.size() > MAX_WRITE_TOTAL_CELLS:
		return _tool_error("The write exceeds %d cells across frames." % MAX_WRITE_TOTAL_CELLS)
	var uniform_material: Variant = null
	var first_material := true
	for material in changes.values():
		if first_material:
			uniform_material = material
			first_material = false
		elif material != uniform_material:
			uniform_material = null
			break
	var label := "Write Cells"
	var label_value: Variant = args.get("label", null)
	if label_value is String and not String(label_value).strip_edges().is_empty():
		label = String(label_value).strip_edges().left(80)
	var document := State.document
	var collected: Array = []
	var frame_results: Array = []
	var total_applied := 0
	var total_chunks := 0
	var total_bounds_min := Vector3i.MAX
	var total_bounds_max := Vector3i.MIN
	var has_bounds := false
	for frame_index in frames:
		if State.document != document:
			State.cancel_changes(collected)
			return _tool_error("The document changed before the write finished.")
		var frame: VoxelFrame = State.get_voxel_frame(int(frame_index))
		if frame == null:
			State.cancel_changes(collected)
			return _tool_error("The frame does not exist.")
		var tx := State.begin_edit(int(frame_index))
		if tx == null:
			State.cancel_changes(collected)
			return _tool_error("The editor is busy with another edit. Retry.")
		var job := WriteJob.new()
		job.edit_context = tx.edit_context
		job.edited_frame = VoxelFrame.job_frame(frame)
		job.changes = changes
		job.applied_uniform = uniform_material
		if changes.size() <= 4096:
			job.run()
		else:
			var operation := State.begin_operation("Writing cells", changes.size(), true, self, job.cancel)
			await State.run_edit_job(job, operation, "MCP write")
			State.finish_operation(operation)
		if State.active_edit() != tx:
			State.cancel_changes(collected)
			return _tool_error("The edit was cancelled or the document changed.")
		if not job.checkpoint(0):
			State.cancel_edit(tx)
			State.cancel_changes(collected)
			return _tool_error("The write was cancelled.")
		frame.apply_published(job.changed_chunks, job.edited_frame)
		State.document._bounds_dirty = true
		if not job.changed_chunks.is_empty():
			State.chunks_changed.emit(int(frame_index), job.changed_chunks)
		_record_cells_change(int(frame_index), job.applied_cells.keys())
		var change := State.finish_edit_collect(tx)
		if change != null:
			collected.append(change)
		var applied_keys: Array = job.applied_cells.keys()
		var bounds: Variant = _bounds_of_cell_array(applied_keys)
		if bounds != null:
			var bounds_data: Dictionary = bounds
			var bounds_min: Array = bounds_data["min"]
			var bounds_max: Array = bounds_data["max"]
			var min_cell := Vector3i(int(bounds_min[0]), int(bounds_min[1]), int(bounds_min[2]))
			var max_cell := Vector3i(int(bounds_max[0]), int(bounds_max[1]), int(bounds_max[2]))
			total_bounds_min = Vector3i(mini(total_bounds_min.x, min_cell.x), mini(total_bounds_min.y, min_cell.y), mini(total_bounds_min.z, min_cell.z))
			total_bounds_max = Vector3i(maxi(total_bounds_max.x, max_cell.x), maxi(total_bounds_max.y, max_cell.y), maxi(total_bounds_max.z, max_cell.z))
			has_bounds = true
		frame_results.append({
			"frame": int(frame_index),
			"applied": job.applied_cells.size(),
			"chunks": job.changed_chunks.size(),
			"occupied": frame.count(),
			"changed_bounds": bounds,
		})
		total_applied += job.applied_cells.size()
		total_chunks += job.changed_chunks.size()
	State.commit_changes(collected, label)
	var current_frame := State.get_current_voxel_frame()
	return _tool_ok({
		"applied": total_applied,
		"chunks": total_chunks,
		"frames": frame_results,
		"action": label,
		"revision": _revision,
		"occupied": current_frame.count() if current_frame != null else 0,
		"changed_bounds": _cell_bounds_json_from_cells(total_bounds_min, total_bounds_max) if has_bounds else null,
	})


func _parse_write_cell(value: Variant) -> Variant:
	if not (value is Array):
		return null
	var components: Array = value
	if components.size() < 3 or components.size() > 4:
		return null
	var cell_value: Variant = _parse_cell(components.slice(0, 3))
	if cell_value == null:
		return null
	var material_index := -1
	if components.size() == 4:
		if not (components[3] is int or components[3] is float):
			return null
		material_index = int(components[3])
		if material_index < -1:
			return null
	return [cell_value, material_index]


func _parse_write_box(value: Variant) -> Variant:
	if not (value is Array):
		return null
	var components: Array = value
	if components.size() < 6 or components.size() > 7:
		return null
	var box_value: Variant = _parse_box(components.slice(0, 6))
	if box_value == null:
		return null
	var box: Array = box_value
	var material_index := -1
	if components.size() == 7:
		if not (components[6] is int or components[6] is float):
			return null
		material_index = int(components[6])
		if material_index < -1:
			return null
	return [box[0], box[1], material_index]


func _parse_write_run(value: Variant) -> Variant:
	if not (value is Array):
		return null
	var components: Array = value
	if components.size() < 4 or components.size() > 5:
		return null
	var run_value: Variant = _parse_run(components.slice(0, 4))
	if run_value == null:
		return null
	var run: Array = run_value
	var material_index := -1
	if components.size() == 5:
		if not (components[4] is int or components[4] is float):
			return null
		material_index = int(components[4])
		if material_index < -1:
			return null
	return [run[0], run[1], run[2], run[3], material_index]


func _write_material(index: int, materials: Array, current_material: PackedFloat32Array, erase: bool) -> Variant:
	if erase:
		return VoxelFrame.material(Color.TRANSPARENT)
	if index < 0:
		return current_material
	if index >= materials.size():
		return null
	return materials[index]


func _write_frames(args: Dictionary) -> Array:
	var frames: Array = []
	var frames_value: Variant = args.get("frames", null)
	if frames_value == null:
		frames.append(State.current_frame)
		return frames
	if not (frames_value is Array):
		return []
	var source: Array = frames_value
	if source.is_empty() or source.size() > 16:
		return []
	var seen := {}
	for value in source:
		if not (value is int or value is float):
			return []
		var index := int(value)
		if index < 0 or index >= State.document.frames.size():
			return []
		if seen.has(index):
			continue
		seen[index] = true
		frames.append(index)
	return frames


func _sample(args: Dictionary) -> Dictionary:
	if State.active_edit() != null:
		return _tool_error("The editor has an open edit. Finish it before sampling a material.")
	var cell_value: Variant = _parse_cell(args.get("cell", null))
	if cell_value == null:
		return _tool_error("cell must be [x, y, z].")
	var cell: Vector3i = cell_value
	if not State.has_cell(cell):
		return _tool_error("The cell is empty.")
	var frame := State.get_current_voxel_frame()
	if frame == null:
		return _tool_error("The document has no current frame.")
	var material := frame.get_material(cell)
	State.set_material(material)
	return _tool_ok({"material": _material_json(material)})


func _wait_tool_idle(tool: VoxelTool, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while is_instance_valid(tool) and tool.driver_is_busy():
		if Time.get_ticks_msec() >= deadline:
			return false
		await get_tree().process_frame
	return is_instance_valid(tool)


func _active_tool_info() -> Dictionary:
	var brush: Node = _plugin("BrushPlugin")
	if brush != null and _toolbar_pressed(brush):
		var settings: BrushToolSettings = brush.get("_settings")
		var tool_node: Node3D = brush.get("_tool")
		if settings != null and tool_node != null:
			var tool_id := "brush"
			if settings.mode == BrushToolSettings.BrushMode.ERASER:
				tool_id = "eraser"
			elif settings.mode == BrushToolSettings.BrushMode.LINE:
				tool_id = "line"
			return {
				"id": tool_id,
				"node": tool_node,
				"params": {
					"diameter": settings.diameter,
					"shape": "sphere" if settings.shape == StampToolSettings.BrushShape.SPHERE else "cube",
					"pixel_perfect": settings.pixel_perfect,
				},
			}
	var paint: Node = _plugin("PaintPlugin")
	if paint != null and _toolbar_pressed(paint):
		var settings: PaintToolSettings = paint.get("_settings")
		var tool_node: Node3D = paint.get("_tool")
		if settings != null and tool_node != null:
			var tool_id := "paint"
			if settings.tool == PaintToolSettings.Tools.FILL:
				tool_id = "fill"
			elif settings.tool == PaintToolSettings.Tools.SPRAY:
				tool_id = "spray"
			return {
				"id": tool_id,
				"node": tool_node,
				"params": {
					"diameter": settings.diameter,
					"shape": "sphere" if settings.shape == StampToolSettings.BrushShape.SPHERE else "cube",
					"pixel_perfect": settings.pixel_perfect,
					"connected": settings.connected,
					"spot_diameter": settings.spot_diameter,
					"spray_size": settings.spray_size,
					"speed": settings.speed,
				},
			}
	var terrain: Node = _plugin("TerrainPlugin")
	if terrain != null and _toolbar_pressed(terrain):
		return {"id": "terrain", "node": terrain.get("_tool"), "params": {}}
	var selection: Node = _plugin("SelectionPlugin")
	if selection != null and _toolbar_pressed(selection):
		return {"id": "select", "node": selection.get("_current_tool"), "params": {}}
	var transform: Node = _plugin("TransformPlugin")
	if transform != null and _toolbar_pressed(transform):
		return {"id": "transform", "node": transform.get("_current_tool"), "params": {}}
	var eyedropper: Node = _plugin("EyedropperPlugin")
	if eyedropper != null and _toolbar_pressed(eyedropper):
		return {"id": "eyedropper", "node": eyedropper.get("_tool"), "params": {}}
	return {"id": "", "node": null, "params": {}}


func _activate_plugin(name: String) -> void:
	for other in ["BrushPlugin", "PaintPlugin", "TerrainPlugin", "SelectionPlugin", "TransformPlugin", "EyedropperPlugin"]:
		if other == name:
			continue
		var plugin: Node = _plugin(other)
		if plugin != null and _toolbar_pressed(plugin):
			var toolbar: BaseButton = plugin.get("_toolbar")
			if toolbar != null:
				toolbar.button_pressed = false
	var target: Node = _plugin(name)
	if target == null:
		return
	var target_toolbar: BaseButton = target.get("_toolbar")
	if target_toolbar == null:
		return
	if target_toolbar.button_pressed:
		target.call("activate_tool")
		return
	target_toolbar.button_pressed = true
	if not target_toolbar.button_pressed:
		target.call("activate_tool")


func _plugin(plugin_name: String) -> Node:
	return get_node_or_null("/root/" + plugin_name)


func _toolbar_pressed(plugin: Node) -> bool:
	var toolbar: BaseButton = plugin.get("_toolbar")
	return toolbar != null and toolbar.button_pressed


func _parse_material(args: Dictionary) -> Variant:
	var material: PackedFloat32Array = State.current_material
	var color_changed := false
	var palette_value: Variant = args.get("palette_index", null)
	if palette_value != null:
		if not (palette_value is int or palette_value is float):
			return null
		var index := int(palette_value)
		var palette := State.get_palette()
		if index < 0 or index >= palette.size():
			return null
		material = palette[index]
	var color_value: Variant = args.get("color", null)
	if color_value != null:
		var color_value_parsed: Variant = _parse_color(color_value)
		if not (color_value_parsed is Color):
			return null
		var color: Color = color_value_parsed
		material[0] = color.r
		material[1] = color.g
		material[2] = color.b
		material[3] = color.a
		color_changed = true
	var metallic_value: Variant = args.get("metallic", null)
	if metallic_value != null:
		if not (metallic_value is int or metallic_value is float):
			return null
		material[VoxelFrame.MATERIAL_METALLIC] = clampf(float(metallic_value), 0.0, 1.0)
	var roughness_value: Variant = args.get("roughness", null)
	if roughness_value != null:
		if not (roughness_value is int or roughness_value is float):
			return null
		material[VoxelFrame.MATERIAL_ROUGHNESS] = clampf(float(roughness_value), 0.0, 1.0)
	var emission_value: Variant = args.get("emission", null)
	if emission_value != null:
		var emission_parsed: Variant = _parse_color(emission_value)
		if not (emission_parsed is Color):
			return null
		var emission: Color = emission_parsed
		material[VoxelFrame.MATERIAL_EMISSION] = emission.r
		material[VoxelFrame.MATERIAL_EMISSION + 1] = emission.g
		material[VoxelFrame.MATERIAL_EMISSION + 2] = emission.b
	elif color_changed:
		# A new color is not glowing unless the caller asks for it.
		material[VoxelFrame.MATERIAL_EMISSION] = 0.0
		material[VoxelFrame.MATERIAL_EMISSION + 1] = 0.0
		material[VoxelFrame.MATERIAL_EMISSION + 2] = 0.0
	return material


func _parse_color(value: Variant) -> Variant:
	if value is String:
		var text: String = value
		if not Color.html_is_valid(text):
			return null
		return Color.html(text)
	if value is Array:
		var components: Array = value
		if components.size() < 3 or components.size() > 4:
			return null
		for component in components:
			if not (component is int or component is float):
				return null
		var alpha := 1.0
		if components.size() == 4:
			alpha = float(components[3])
		return Color(float(components[0]), float(components[1]), float(components[2]), alpha)
	return null


func _parse_cell(value: Variant) -> Variant:
	if not (value is Array):
		return null
	var components: Array = value
	if components.size() != 3:
		return null
	for component in components:
		if not (component is int or component is float):
			return null
	var x := int(components[0])
	var y := int(components[1])
	var z := int(components[2])
	if not _cell_in_range(x, y, z):
		return null
	return Vector3i(x, y, z)


## Returns [code]true[/code] when one cell coordinate is inside the storage limit.
func _cell_in_range(x: int, y: int, z: int) -> bool:
	var limit := VoxelFrame.MAX_CHUNK_COORDINATE * VoxelFrame.CHUNK_SIZE
	return (
		x >= -limit and x <= limit
		and y >= -limit and y <= limit
		and z >= -limit and z <= limit
	)


func _parse_cells(value: Variant, max_count: int) -> Variant:
	if not (value is Array):
		return null
	var source: Array = value
	if source.is_empty() or source.size() > max_count:
		return null
	var cells: Array[Vector3i] = []
	for item in source:
		var cell: Variant = _parse_cell(item)
		if cell == null:
			return null
		var cell_position: Vector3i = cell
		cells.append(cell_position)
	return cells


func _parse_box(value: Variant) -> Variant:
	if not (value is Array):
		return null
	var components: Array = value
	if components.size() != 6:
		return null
	for component in components:
		if not (component is int or component is float):
			return null
	var sx := int(components[0])
	var sy := int(components[1])
	var sz := int(components[2])
	var ex := int(components[3])
	var ey := int(components[4])
	var ez := int(components[5])
	if sx > ex or sy > ey or sz > ez:
		return null
	if not _cell_in_range(sx, sy, sz) or not _cell_in_range(ex, ey, ez):
		return null
	return [Vector3i(sx, sy, sz), Vector3i(ex, ey, ez)]


func _parse_run(value: Variant) -> Variant:
	if not (value is Array):
		return null
	var components: Array = value
	if components.size() != 4:
		return null
	for component in components:
		if not (component is int or component is float):
			return null
	var first := int(components[0])
	var last := int(components[1])
	if first > last:
		return null
	var y := int(components[2])
	var z := int(components[3])
	if not _cell_in_range(first, y, z) or not _cell_in_range(last, y, z):
		return null
	return [first, last, y, z]


func _axis_name(axis: int) -> String:
	match axis:
		Vector3.AXIS_X:
			return "x"
		Vector3.AXIS_Z:
			return "z"
	return "y"


func _material_json(material: PackedFloat32Array) -> Dictionary:
	var color := VoxelFrame.material_color(material)
	var emission := Color(
		material[VoxelFrame.MATERIAL_EMISSION],
		material[VoxelFrame.MATERIAL_EMISSION + 1],
		material[VoxelFrame.MATERIAL_EMISSION + 2]
	)
	var data := {
		"color": _hex_color(color),
		"metallic": snappedf(material[VoxelFrame.MATERIAL_METALLIC], 0.001),
		"roughness": snappedf(material[VoxelFrame.MATERIAL_ROUGHNESS], 0.001),
	}
	if emission != Color.BLACK:
		data["emission"] = _hex_color(emission)
	return data


func _hex_color(color: Color) -> String:
	if color.a < 0.999:
		return "#" + color.to_html(true)
	return "#" + color.to_html(false)


func _aabb_json(box: AABB) -> Dictionary:
	return {"position": _vector_json(box.position), "size": _vector_json(box.size)}


func _vector_json(value: Vector3) -> Array:
	return [_number_json(value.x), _number_json(value.y), _number_json(value.z)]


func _number_json(value: float) -> Variant:
	if is_equal_approx(value, roundf(value)):
		return int(roundf(value))
	return snappedf(value, 0.001)


func _json_cell(cell: Vector3i) -> Array:
	return [cell.x, cell.y, cell.z]


## Appends one diagnostic line to the server log.
func _log(message: String) -> void:
	var file := FileAccess.open(LOG_PATH, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.seek_end()
	file.store_line("%s %s" % [Time.get_datetime_string_from_system(), message])
