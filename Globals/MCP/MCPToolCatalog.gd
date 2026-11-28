extends RefCounted


const TOOLS := [
	{
		"name": "get_state",
		"description": "Return the document, revision, current frame bounds, active tool, material, selection count and bounds, symmetry, slice, busy, and undo state. Guide: `lve://guide/read`.",
		"inputSchema": {"type": "object", "additionalProperties": false},
	},
	{
		"name": "inspect_document",
		"description": "Read a semantic summary of one or more frames of the active layer: integer cell bounds, occupied count, materials, connected islands, tags, and transitions between consecutive listed frames. It does not return exact cells. Use get_cells for those. A single frame also puts its fields at the root, so materials sits beside frames. Use this before get_cells. Guide: `lve://guide/read`.",
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
				"box": {
					"type": "array",
					"items": {"type": "integer"},
					"minItems": 6,
					"maxItems": 6,
					"description": "Include [x0, y0, z0, x1, y1, z1]. Island connectivity is limited to the box.",
				},
				"material": {"type": "string", "description": "Only group islands of this color, for example #ff0000."},
				"palette": {"type": "boolean", "description": "Include the document palette at document.palette. Defaults to false."},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "get_slice",
		"description": "Read labeled 2D slices or projections of one frame as text. Use it for exact shape and material layout. Guide: `lve://guide/read`.",
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
		"description": "Read a coarse occupancy grid of one frame. Use it to locate content before get_cells. Guide: `lve://guide/read`.",
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
		"description": "Read cells changed since a revision. Use the revision from get_state, inspect_document, get_cells, or a write response. Guide: `lve://guide/read`.",
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
		"description": "Read occupied cells in an inclusive box as x-runs of [x0, x1, y, z, material_index]. The result is runs, not cells. The material_index points into the returned materials list and is numbered per page, so read it back. Omit min and max to read the frame bounds. When truncated, pass next back as cursor with the same box to continue. Guide: `lve://guide/read`.",
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
		"name": "get_layer_cells",
		"description": "Read occupied cells in one layer and frame as x-runs of [x0, x1, y, z, material_index]. Omit layer to use the active layer. Omit min and max to read the cel bounds. When truncated, pass next back as cursor with the same box to continue. Guide: `lve://guide/read`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"layer": {"type": "integer", "minimum": 0, "description": "Layer index from the bottom. Defaults to the active layer."},
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
		"description": "Save a PNG and return its absolute path. Set path to choose the file. The default is mcp_screenshot.png in the user directory. Render one frame, a multi-view contact sheet, or a frame storyboard. Pass focus to frame a detail, or a far cell shrinks the model. Set orthographic, environment, shadows, shaded, or wireframe to change the view. Set inline true to also return the image. Guide: `lve://guide/write`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"frame": {"type": "integer", "minimum": 0},
				"layer": {"type": "integer", "minimum": -1, "description": "Render one document layer. Omit it or use -1 to render the visible composite."},
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
					"maxItems": 8,
					"description": "Render a contact sheet of these views in one image. Uses one shared bounds.",
				},
				"columns": {"type": "integer", "minimum": 1, "maximum": 8, "description": "Contact sheet columns. Defaults to a square grid."},
				"size": {"type": "integer", "minimum": 64, "maximum": 1024, "description": "Tile edge in pixels. Defaults to 256."},
				"path": {"type": "string", "description": "An absolute path ending in .png. Defaults to mcp_screenshot.png in the user directory."},
				"view": {"type": "string", "enum": ["isometric", "low", "front", "back", "left", "right", "top", "bottom", "current"]},
				"orthographic": {"type": "boolean", "description": "Use an orthographic camera. Defaults to true."},
				"environment": {"type": "boolean", "description": "Use the document light direction, light color, and ambient color. Defaults to true."},
				"shadows": {"type": "boolean", "description": "Cast shadows. Defaults to true."},
				"shaded": {"type": "boolean", "description": "Draw the voxels with lighting. Set false for flat unshaded colors. Defaults to true."},
				"wireframe": {"type": "boolean", "description": "Draw the voxel edges as wireframe. Defaults to false."},
				"inline": {"type": "boolean"},
				"focus": {
					"type": "array",
					"items": {"type": "integer"},
					"minItems": 6,
					"maxItems": 6,
					"description": "Inclusive [x0, y0, z0, x1, y1, z1] to frame. Named views only.",
				},
				"clip": {
					"type": "array",
					"items": {"type": "integer"},
					"minItems": 6,
					"maxItems": 6,
					"description": "Keep only cells inside this inclusive [x0, y0, z0, x1, y1, z1] box in the rendered copy. The document does not change.",
				},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "model_sheet",
		"description": "Render the standard seven-view model sheet for one frame: front, back, left, right, top, bottom, and isometric. The sheet uses four columns and two rows. Defaults to frame 0, so playback does not choose the frame. Set inline true to also return the image. Guide: `lve://guide/write`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"frame": {"type": "integer", "minimum": 0, "description": "Frame to render. Defaults to frame 0."},
				"layer": {"type": "integer", "minimum": -1, "description": "Render one document layer. Omit it or use -1 to render the visible composite."},
				"size": {"type": "integer", "minimum": 64, "maximum": 1024, "description": "Tile edge in pixels. Defaults to 256."},
				"columns": {"type": "integer", "minimum": 1, "maximum": 8, "description": "Sheet columns. Defaults to 4."},
				"path": {"type": "string", "description": "An absolute path ending in .png. Defaults to mcp_screenshot.png in the user directory."},
				"orthographic": {"type": "boolean", "description": "Use an orthographic camera. Defaults to true."},
				"environment": {"type": "boolean", "description": "Use the document light direction, light color, and ambient color. Defaults to true."},
				"shadows": {"type": "boolean", "description": "Cast shadows. Defaults to true."},
				"shaded": {"type": "boolean", "description": "Draw the voxels with lighting. Defaults to true."},
				"wireframe": {"type": "boolean", "description": "Draw the voxel edges as wireframe. Defaults to false."},
				"inline": {"type": "boolean"},
				"focus": {
					"type": "array",
					"items": {"type": "integer"},
					"minItems": 6,
					"maxItems": 6,
					"description": "Inclusive [x0, y0, z0, x1, y1, z1] to frame.",
				},
				"clip": {
					"type": "array",
					"items": {"type": "integer"},
					"minItems": 6,
					"maxItems": 6,
					"description": "Keep only cells inside this inclusive [x0, y0, z0, x1, y1, z1] box in the rendered copy. The document does not change.",
				},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "new_document",
		"description": "Open a new empty document in a new tab and make it current. The current document stays open. Guide: `lve://guide/tools`.",
		"inputSchema": {"type": "object", "additionalProperties": false},
	},
	{
		"name": "save_document",
		"description": "Save the current document as .lve or .lve.png at an absolute path. Omit path to save the open document to its own path. A path writes a copy unless copy is false. The server creates a missing folder. A .lve.png file also stores a preview. Guide: `lve://guide/write`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"path": {"type": "string", "description": "An absolute path ending in .lve or .lve.png. Omit it to save the open document."},
				"copy": {"type": "boolean", "description": "With a path, write a copy and keep the main path and unsaved mark. Defaults to true. Ignored without a path."},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "open_document",
		"description": "Open a saved .lve or .lve.png document at an absolute path in a new tab and make it current. The current document stays open. Guide: `lve://guide/write`.",
		"inputSchema": {
			"type": "object",
			"properties": {"path": {"type": "string", "description": "An absolute path to a .lve or .lve.png file."}},
			"required": ["path"],
			"additionalProperties": false,
		},
	},
	{
		"name": "set_document_settings",
		"description": "Set the document render settings: smooth normals, ambient occlusion strength, and the centered size. Omit a field to keep it. One undo action. Guide: `lve://guide/tools`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"smooth_normals": {"type": "boolean", "description": "Use smooth normals."},
				"ao": {"type": "number", "minimum": 0, "maximum": 1, "description": "Ambient occlusion strength. Zero disables it."},
				"size": {
					"type": "array",
					"items": {"type": "integer", "minimum": 0, "maximum": 4096},
					"minItems": 3,
					"maxItems": 3,
					"description": "Centered document size as [x, y, z]. Zero on an axis means infinite.",
				},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "get_workspace",
		"description": "Read the workspace that opens with the document: the camera pose, lighting, view state, export settings, current frame and tag, playback, and size. The angles are radians. A basis is three vectors [x, y, z]. Lighting names its strength as energy. Guide: `lve://guide/workspace`.",
		"inputSchema": {"type": "object", "additionalProperties": false},
	},
	{
		"name": "set_workspace",
		"description": "Set the workspace that opens with the document. Each field you pass replaces its stored value, and an omitted field keeps the current value. Read get_workspace first and pass its shapes back. The active editor applies the change. It is not an undo action. Guide: `lve://guide/workspace`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"camera": {
					"type": "object",
					"description": "yaw, pitch, distance, initial_distance, target [x, y, z], and fov in degrees. Export cameras also accept orthographic.",
					"additionalProperties": true,
				},
				"lighting": {"type": "object", "description": "basis, color, energy, ambient_color, ambient_energy, shadows, shaded, view_locked, and view_basis.", "additionalProperties": true},
				"view": {"type": "object", "description": "grid, wireframe, orthographic, and view_mode.", "additionalProperties": true},
				"export": {"type": "object", "description": "The export tab settings: view, frame_size, views, turntable, metadata, normal, specular, specular_intensity, center, sprite_center, model_tag, sheet_tag, lighting, and camera.", "additionalProperties": true},
				"playing": {"type": "boolean", "description": "Whether the document plays its tag when it opens."},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "get_export_settings",
		"description": "Read the export settings the editor uses now. Use it to start from the current view, tile size, tag, normal and specular sheets, the specular preview intensity, and model options. It also returns the open document path and the default model and sprite paths. Guide: `lve://guide/export`.",
		"inputSchema": {"type": "object", "additionalProperties": false},
	},
	{
		"name": "export_model",
		"description": "Export the document as a .glb or .gltf file at an absolute path. Omit path to export beside the document. Set the model options for this call. The call does not change the document or the export tab settings. Guide: `lve://guide/export`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"path": {"type": "string", "description": "An absolute path ending in .glb or .gltf. Omit it to export beside the document."},
				"center": {"type": "boolean", "description": "Center the model on the origin. Defaults to false."},
				"tag": {"type": "integer", "minimum": -1, "description": "Export only this tag. -1 exports every tag. Defaults to -1."},
				"smooth_normals": {"type": "boolean", "description": "Use smooth normals. Defaults to the document setting."},
				"ao": {"type": "number", "minimum": 0, "maximum": 1, "description": "Ambient occlusion strength. Defaults to the document setting."},
				"unlit": {"type": "boolean", "description": "Export an unlit material. Defaults to lit materials."},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "export_sprite_sheet",
		"description": "Export a PNG sprite sheet, optional aligned normal and specular sheets, and the Aseprite JSON sidecar at an absolute path. Omit path to export beside the document. Set the view, tile size, turntable, and frame range for this call. The call does not change the export tab settings. Guide: `lve://guide/export`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"path": {"type": "string", "description": "An absolute path ending in .png. Omit it to export beside the document."},
				"first_frame": {"type": "integer", "minimum": 0, "description": "First frame. Defaults to 0."},
				"last_frame": {"type": "integer", "minimum": 0, "description": "Last frame, inclusive. Defaults to the last frame."},
				"tag": {"type": "integer", "minimum": -1, "description": "Tag index for the frame range. -1 uses first_frame and last_frame."},
				"tile_size": {"type": "integer", "minimum": 1, "maximum": 1024, "description": "Tile edge in pixels. Defaults to the export tab value."},
				"view": {"type": "string", "enum": ["current", "isometric", "front", "back", "left", "right", "top", "bottom"], "description": "Camera view. Defaults to the export tab value."},
				"views": {"type": "integer", "minimum": 1, "maximum": 16, "description": "Turntable views per frame. Defaults to the export tab value."},
				"orthographic": {"type": "boolean", "description": "Use an orthographic camera. Defaults to the export tab value."},
				"center": {"type": "boolean", "description": "Center the model in each tile. Defaults to the export tab value."},
				"metadata": {"type": "boolean", "description": "Write the JSON sidecar. Defaults to the export tab value."},
				"normal": {"type": "boolean", "description": "Also write the aligned normal sheet. Defaults to the export tab value."},
				"specular": {"type": "boolean", "description": "Also write the aligned specular sheet. Defaults to the export tab value."},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "export_gif",
		"description": "Export the frame range as an animated GIF at an absolute path. The GIF loops forever and uses each frame delay. It holds color frames only. Set the view, tile size, and frame range for this call. The call does not change the export tab settings. Guide: `lve://guide/export`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"path": {"type": "string", "description": "An absolute path ending in .gif. Omit it to export beside the document."},
				"first_frame": {"type": "integer", "minimum": 0, "description": "First frame. Defaults to 0."},
				"last_frame": {"type": "integer", "minimum": 0, "description": "Last frame, inclusive. Defaults to the last frame."},
				"tag": {"type": "integer", "minimum": -1, "description": "Tag index for the frame range. -1 uses first_frame and last_frame."},
				"tile_size": {"type": "integer", "minimum": 1, "maximum": 2048, "description": "Frame edge in pixels. Defaults to the export tab value."},
				"view": {"type": "string", "enum": ["current", "isometric", "front", "back", "left", "right", "top", "bottom"], "description": "Camera view. Defaults to the export tab value."},
				"views": {"type": "integer", "minimum": 1, "maximum": 16, "description": "Turntable views per frame. Defaults to the export tab value."},
				"orthographic": {"type": "boolean", "description": "Use an orthographic camera. Defaults to the export tab value."},
				"center": {"type": "boolean", "description": "Center the model in each frame. Defaults to the export tab value."},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "add_frame",
		"description": "Add blank frames as one undo action. A new frame holds no cells. Use duplicate_frame to copy the static set. The default index is the last frame. The new frames become current. Guide: `lve://guide/animate`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"index": {"type": "integer", "minimum": 0},
				"count": {"type": "integer", "minimum": 1, "maximum": 256, "description": "Frames to add. Defaults to 1."},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "remove_frame",
		"description": "Remove one or more frames as one undo action. The last remaining frame is kept. Tags shift to the remaining frames. Guide: `lve://guide/animate`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"frame": {"type": "integer", "minimum": 0},
				"frames": {
					"type": "array",
					"items": {"type": "integer", "minimum": 0},
					"minItems": 1,
					"maxItems": 256,
					"description": "Frame indices to remove. Overrides frame.",
				},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "move_frame",
		"description": "Move one frame or a contiguous block of frames to a new index as one undo action. Omit from to move the current frame. Tag ranges stay at their indices. Guide: `lve://guide/animate`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"from": {"type": "integer", "minimum": 0, "description": "First frame to move. Defaults to the current frame."},
				"to": {"type": "integer", "minimum": 0},
				"count": {"type": "integer", "minimum": 1, "maximum": 256, "description": "Frames to move as a block. Defaults to 1. to is the final index of the first moved frame."},
			},
			"required": ["to"],
			"additionalProperties": false,
		},
	},
	{
		"name": "duplicate_frame",
		"description": "Copy the current frame and insert it after the current frame. The copy becomes current. Guide: `lve://guide/animate`.",
		"inputSchema": {"type": "object", "additionalProperties": false},
	},
	{
		"name": "set_frame",
		"description": "Make one frame current. Guide: `lve://guide/animate`.",
		"inputSchema": {
			"type": "object",
			"properties": {"frame": {"type": "integer", "minimum": 0}},
			"required": ["frame"],
			"additionalProperties": false,
		},
	},
	{
		"name": "set_frame_delay",
		"description": "Set the duration of one or more frames as one undo action. Guide: `lve://guide/animate`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"frame": {"type": "integer", "minimum": 0},
				"frames": {
					"type": "array",
					"items": {"type": "integer", "minimum": 0},
					"minItems": 1,
					"maxItems": 256,
					"description": "Frame indices to set. Overrides frame.",
				},
				"ms": {"type": "integer", "minimum": 1, "maximum": 10000},
			},
			"required": ["ms"],
			"additionalProperties": false,
		},
	},
	{
		"name": "set_tag_loop",
		"description": "Set one tag's loop mode and repeat count. Omit tag to use the active tag. Repeats 0 means continuous playback. Guide: `lve://guide/animate`.",
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
		"description": "Add an animation tag with an inclusive frame range, loop mode, and repeat count. The new tag becomes active. Guide: `lve://guide/animate`.",
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
		"description": "Remove one tag. Omit tag to use the active tag. The last remaining tag is kept. Guide: `lve://guide/animate`.",
		"inputSchema": {
			"type": "object",
			"properties": {"tag": {"type": "integer", "minimum": 0, "description": "Defaults to the active tag."}},
			"additionalProperties": false,
		},
	},
	{
		"name": "rename_tag",
		"description": "Rename one tag. Omit tag to use the active tag. Guide: `lve://guide/animate`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"tag": {"type": "integer", "minimum": 0, "description": "Defaults to the active tag."},
				"name": {"type": "string"},
			},
			"required": ["name"],
			"additionalProperties": false,
		},
	},
	{
		"name": "set_tag_range",
		"description": "Set one tag's inclusive frame range. The range must be inside the frames, or the call fails. Omit tag to use the active tag. Guide: `lve://guide/animate`.",
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
		"description": "Select one tag by index. Set tag to -1 to clear the selection. Guide: `lve://guide/animate`.",
		"inputSchema": {
			"type": "object",
			"properties": {"tag": {"type": "integer", "minimum": -1}},
			"required": ["tag"],
			"additionalProperties": false,
		},
	},
	{
		"name": "get_layers",
		"description": "Read every layer from bottom to top. Each item reports its index, name, visibility, lock, filled cel count, and active state. Layer index 0 is the bottom layer. Guide: `lve://guide/layers`.",
		"inputSchema": {"type": "object", "additionalProperties": false},
	},
	{
		"name": "select_layer",
		"description": "Make one layer active by index or name. A name must match one layer. Selection works on hidden and locked layers. The edit tools use the active layer. Guide: `lve://guide/layers`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"layer": {"type": "integer", "minimum": 0, "description": "Layer index from the bottom. 0 is the bottom layer."},
				"name": {"type": "string", "description": "Exact layer name. It must match one layer."},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "add_layer",
		"description": "Add a layer as one undo action. The default index is above the active layer. The new layer becomes active. Guide: `lve://guide/layers`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"index": {"type": "integer", "minimum": 0, "description": "Insertion index from the bottom. Defaults to above the active layer."},
				"name": {"type": "string", "description": "Layer name. Defaults to the next available Layer number."},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "duplicate_layer",
		"description": "Copy one layer and its cels as one undo action. The copy sits above the source and becomes active. The copy name adds ' copy'. Guide: `lve://guide/layers`.",
		"inputSchema": {
			"type": "object",
			"properties": {"layer": {"type": "integer", "minimum": 0, "description": "Layer to copy. Defaults to the active layer."}},
			"additionalProperties": false,
		},
	},
	{
		"name": "delete_layer",
		"description": "Delete one layer as one undo action. The document keeps one layer. A locked layer is refused. The layer below becomes active. Guide: `lve://guide/layers`.",
		"inputSchema": {
			"type": "object",
			"properties": {"layer": {"type": "integer", "minimum": 0, "description": "Layer to delete. Defaults to the active layer."}},
			"additionalProperties": false,
		},
	},
	{
		"name": "rename_layer",
		"description": "Rename one layer as one undo action. The name is trimmed and cannot be empty. Hidden and locked layers can be renamed. Guide: `lve://guide/layers`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"layer": {"type": "integer", "minimum": 0, "description": "Layer to rename. Defaults to the active layer."},
				"name": {"type": "string"},
			},
			"required": ["name"],
			"additionalProperties": false,
		},
	},
	{
		"name": "set_layer_visible",
		"description": "Show or hide one layer as one undo action. Hidden layers leave the composite but keep their cells. Guide: `lve://guide/layers`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"layer": {"type": "integer", "minimum": 0, "description": "Layer to change. Defaults to the active layer."},
				"visible": {"type": "boolean"},
			},
			"required": ["visible"],
			"additionalProperties": false,
		},
	},
	{
		"name": "set_layer_locked",
		"description": "Lock or unlock one layer as one undo action. Edits and target moves refuse a locked layer. Locking the active layer cancels the open edit. Guide: `lve://guide/layers`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"layer": {"type": "integer", "minimum": 0, "description": "Layer to change. Defaults to the active layer."},
				"locked": {"type": "boolean"},
			},
			"required": ["locked"],
			"additionalProperties": false,
		},
	},
	{
		"name": "move_layer",
		"description": "Move one layer to a new index as one undo action. Indices run from bottom to top. The layer keeps its cels, name, visibility, and lock. Guide: `lve://guide/layers`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"from": {"type": "integer", "minimum": 0},
				"to": {"type": "integer", "minimum": 0, "description": "Final index after the move."},
			},
			"required": ["from", "to"],
			"additionalProperties": false,
		},
	},
	{
		"name": "merge_layer_down",
		"description": "Merge one layer into the layer below as one undo action. The merge covers every frame. The upper cell wins an overlap. Locked layers and the bottom layer are refused. Guide: `lve://guide/layers`.",
		"inputSchema": {
			"type": "object",
			"properties": {"layer": {"type": "integer", "minimum": 1, "description": "Layer to merge down. Defaults to the active layer."}},
			"additionalProperties": false,
		},
	},
	{
		"name": "move_selection_to_layer",
		"description": "Move the current selection or the whole current cel to another layer in the same frame as one undo action. The active layer must be editable. The target must be visible and unlocked. Guide: `lve://guide/layers`.",
		"inputSchema": {
			"type": "object",
			"properties": {"target": {"type": "integer", "minimum": 0, "description": "Target layer index from the bottom."}},
			"required": ["target"],
			"additionalProperties": false,
		},
	},
	{
		"name": "set_tool",
		"description": "Select the real editor tool and set its options. This changes the user's toolbar and option bar. Use brush, eraser, paint, or fill. For fill, set connected false to replace every matching cell in the frame, not only the connected region. Guide: `lve://guide/write`.",
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
		"description": "Set the current material. A color keeps the current metallic and roughness. emission adds a glow. A palette_index selects that palette entry. The change is undoable. Guide: `lve://guide/write`.",
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
		"name": "set_palette",
		"description": "Replace the document palette in order. Each entry is a material object with color, and optional emission, metallic, and roughness. An empty list is refused. One undo action. Existing voxel materials do not change. Guide: `lve://guide/write`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"materials": {
					"type": "array",
					"items": {
						"type": "object",
						"properties": {
							"color": {"type": "string", "description": "#rrggbb or #rrggbbaa"},
							"emission": {"type": "string", "description": "#rrggbb or #rrggbbaa"},
							"metallic": {"type": "number", "minimum": 0, "maximum": 1},
							"roughness": {"type": "number", "minimum": 0, "maximum": 1},
						},
						"required": ["color"],
						"additionalProperties": false,
					},
					"minItems": 1,
				},
			},
			"required": ["materials"],
			"additionalProperties": false,
		},
	},
	{
		"name": "stroke",
		"description": "Draw with the active brush, paint, or eraser tool through cell centers. Select the tool first. Each call is one undo action. Guide: `lve://guide/write`.",
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
		"description": "Fill a connected or matching region from an occupied seed cell. Select the fill tool first. Set connected false on the fill tool to replace every matching cell in the frame. The fill changes only cells inside the shared selection. The whole region is one undo action. Guide: `lve://guide/write`.",
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
		"name": "build_shape",
		"description": "Build a box, ellipsoid, or cone from signed-distance primitives. Smooth blends the primitives in the call and nearby committed cells. Set op to add, subtract, or intersect. A shell keeps a surface band. The call uses the current frame, the current selection, the slice, and the document size. One call is one undo action. Guide: `lve://guide/write`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"primitives": {
					"type": "array",
					"items": {
						"type": "object",
						"properties": {
							"kind": {"type": "string", "enum": ["box", "ellipsoid", "cone"]},
							"center": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3},
							"half_size": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3},
							"radii": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3},
							"a": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3},
							"b": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3},
							"r1": {"type": "number", "minimum": 0},
							"r2": {"type": "number", "minimum": 0},
							"rotation": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3, "description": "Euler angles in degrees around X, Y, and Z. Rotates the primitive around its center. Defaults to no rotation."},
							"roundness": {"type": "number", "minimum": 0, "maximum": 1, "description": "Roundness from 0 to 1. Rounds box edges and blends cone ends. Defaults to 0."},
							"round": {"type": "boolean", "description": "Use round cone ends. A shortcut for roundness 1 or 0. Defaults to false."},
						},
						"required": ["kind"],
						"additionalProperties": false,
					},
					"minItems": 1,
					"maxItems": 64,
					"description": "Box needs center and half_size. Ellipsoid needs center and radii. Cone needs a, b, r1, and r2. Any primitive accepts rotation in Euler degrees.",
				},
				"op": {"type": "string", "enum": ["add", "subtract", "intersect"], "description": "Defaults to add."},
				"smooth": {"type": "number", "minimum": 0, "maximum": 64, "description": "Smooth union width in cells. Blends the primitives in the call and nearby committed cells. Applies to add only. Defaults to 0."},
				"shell": {"type": "number", "minimum": 0, "maximum": 64, "description": "Shell thickness in cells. Zero is solid. Defaults to 0."},
				"material": {"type": "integer", "minimum": 0, "description": "Palette index. Defaults to the current material."},
				"step": {"type": "integer", "minimum": 1, "maximum": 4, "description": "Cell block edge for a coarse build. Defaults to 1."},
				"label": {"type": "string", "description": "History action name. Defaults to Build Shape."},
			},
			"required": ["primitives"],
			"additionalProperties": false,
		},
	},
	{
		"name": "write_cells",
		"description": "Write or erase cells with per-cell materials and optional frames. Provide exactly one of cells, boxes, or runs. Call the tool again to layer shapes. Each call is one undo action, even across frames. Guide: `lve://guide/write`.",
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
					"description": "Frame indices to write. Defaults to the current frame. One undo action covers every frame. An erase applies the same shapes to every frame; erase per frame when their contents differ.",
				},
				"erase": {"type": "boolean"},
				"label": {"type": "string", "description": "History action name. Defaults to Write Cells."},
			},
			"additionalProperties": false,
		},
	},
	{
		"name": "set_selection",
		"description": "Set the shared selection from world boxes or cells. mode replace swaps the set, add and subtract combine with it, and clear empties it. This changes the selection the user sees. One call is one undo action. Guide: `lve://guide/write`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"mode": {
					"type": "string",
					"enum": ["replace", "add", "subtract", "clear"],
					"description": "How the shape combines with the current selection. Defaults to replace.",
				},
				"cells": {
					"type": "array",
					"items": {"type": "array", "items": {"type": "integer"}, "minItems": 3, "maxItems": 3},
					"minItems": 1,
					"maxItems": 65536,
					"description": "Inclusive [x, y, z] cells.",
				},
				"boxes": {
					"type": "array",
					"items": {"type": "array", "items": {"type": "integer"}, "minItems": 6, "maxItems": 6},
					"minItems": 1,
					"maxItems": 1024,
					"description": "Inclusive [x0, y0, z0, x1, y1, z1] boxes.",
				},
				"label": {"type": "string", "description": "History action name. Defaults to Selection."},
			},
			"additionalProperties": false,
		},
	},
]

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
const SCHEMA_LAYER := {
	"type": "object",
	"properties": {
		"index": {"type": "integer"},
		"name": {"type": "string"},
		"visible": {"type": "boolean"},
		"locked": {"type": "boolean"},
		"filled": {"type": "integer"},
		"active": {"type": "boolean"},
	},
}
const SCHEMA_LAYER_RESULT := {
	"type": "object",
	"properties": {
		"layer": {"type": "integer"},
		"layers": {"type": "integer"},
		"name": {"type": "string"},
		"visible": {"type": "boolean"},
		"locked": {"type": "boolean"},
		"filled": {"type": "integer"},
		"active": {"type": "boolean"},
	},
}
const SCHEMA_GET_CELLS := {
	"type": "object",
	"properties": {
		"revision": {"type": "integer"},
		"layer": {"type": "integer"},
		"frame": {"type": "integer"},
		"count": {"type": "integer"},
		"truncated": {"type": "boolean"},
		"runs": {"type": "array", "items": {"type": "array", "items": {"type": "integer"}}},
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
}
const SCHEMA_RUNS := {"type": "array", "items": {"type": "array", "items": {"type": "integer"}}}
const SCHEMA_REGION := {
	"type": "object",
	"properties": {
		"id": {"type": "integer"},
		"cells": {"type": "integer"},
		"bounds": SCHEMA_BOUNDS,
		"center": SCHEMA_CELL,
		"key": {"type": "string"},
		"materials": {
			"type": "array",
			"items": {
				"type": "object",
				"properties": {
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
			"selection_bounds": SCHEMA_BOUNDS,
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
	"get_cells": SCHEMA_GET_CELLS,
	"get_layer_cells": SCHEMA_GET_CELLS,
	"screenshot": {
		"type": "object",
		"properties": {
			"path": {"type": "string"},
			"layer": {"type": "integer"},
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
			"orthographic": {"type": "boolean"},
			"environment": {"type": "boolean"},
			"shadows": {"type": "boolean"},
			"shaded": {"type": "boolean"},
			"wireframe": {"type": "boolean"},
			"clip": {"type": "array", "items": {"type": "integer"}},
		},
	},
	"model_sheet": {
		"type": "object",
		"properties": {
			"path": {"type": "string"},
			"layer": {"type": "integer"},
			"width": {"type": "integer"},
			"height": {"type": "integer"},
			"tile_size": {"type": "integer"},
			"columns": {"type": "integer"},
			"rows": {"type": "integer"},
			"revision": {"type": "integer"},
			"bounds": SCHEMA_BOUNDS,
			"frame": {"type": "integer"},
			"views": {"type": "array", "items": {"type": "string"}},
			"orthographic": {"type": "boolean"},
			"environment": {"type": "boolean"},
			"shadows": {"type": "boolean"},
			"shaded": {"type": "boolean"},
			"wireframe": {"type": "boolean"},
			"clip": {"type": "array", "items": {"type": "integer"}},
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
	"get_workspace": {
		"type": "object",
		"properties": {
			"revision": {"type": "integer"},
			"camera": {"type": "object"},
			"lighting": {"type": "object"},
			"view": {"type": "object"},
			"export": {"type": "object"},
			"frame": {"type": "integer"},
			"tag": {"type": "integer"},
			"playing": {"type": "boolean"},
			"size": {"type": "array", "items": {"type": "integer"}},
		},
	},
	"set_workspace": {
		"type": "object",
		"properties": {
			"revision": {"type": "integer"},
			"camera": {"type": "object"},
			"lighting": {"type": "object"},
			"view": {"type": "object"},
			"export": {"type": "object"},
			"frame": {"type": "integer"},
			"tag": {"type": "integer"},
			"playing": {"type": "boolean"},
			"size": {"type": "array", "items": {"type": "integer"}},
		},
	},
	"get_export_settings": {
		"type": "object",
		"properties": {
			"revision": {"type": "integer"},
			"document_path": {"type": "string"},
			"model_path": {"type": "string"},
			"sprite_path": {"type": "string"},
			"sprite": {
				"type": "object",
				"properties": {
					"view": {"type": "string"},
					"orthographic": {"type": "boolean"},
					"center": {"type": "boolean"},
					"tile_size": {"type": "integer"},
					"views": {"type": "integer"},
					"metadata": {"type": "boolean"},
					"tag": {"type": "integer"},
					"tag_name": {"type": "string"},
					"first_frame": {"type": "integer"},
					"last_frame": {"type": "integer"},
				},
			},
			"model": {
				"type": "object",
				"properties": {
					"center": {"type": "boolean"},
					"tag": {"type": "integer"},
					"smooth_normals": {"type": "boolean"},
					"ao": {"type": "number"},
					"unlit": {"type": "boolean"},
					"first_frame": {"type": "integer"},
					"last_frame": {"type": "integer"},
				},
			},
		},
	},
	"export_model": {
		"type": "object",
		"properties": {
			"path": {"type": "string"},
			"format": {"type": "string"},
			"frames": {"type": "integer"},
			"tags": {"type": "array", "items": {"type": "string"}},
			"revision": {"type": "integer"},
		},
	},
	"export_sprite_sheet": {
		"type": "object",
		"properties": {
			"path": {"type": "string"},
			"metadata_path": {"type": "string"},
			"width": {"type": "integer"},
			"height": {"type": "integer"},
			"tile_size": {"type": "integer"},
			"frames": {"type": "integer"},
			"views": {"type": "integer"},
			"view": {"type": "string"},
			"revision": {"type": "integer"},
		},
	},
	"export_gif": {
		"type": "object",
		"properties": {
			"path": {"type": "string"},
			"width": {"type": "integer"},
			"height": {"type": "integer"},
			"tile_size": {"type": "integer"},
			"frames": {"type": "integer"},
			"views": {"type": "integer"},
			"view": {"type": "string"},
			"revision": {"type": "integer"},
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
		"properties": {
			"frame": {"type": "integer"},
			"frames": {"type": "array", "items": {"type": "integer"}},
			"delay_ms": {"type": "integer"},
		},
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
	"get_layers": {
		"type": "object",
		"properties": {
			"layers": {"type": "integer"},
			"active": {"type": "integer"},
			"items": {"type": "array", "items": SCHEMA_LAYER},
		},
	},
	"select_layer": SCHEMA_LAYER_RESULT,
	"add_layer": SCHEMA_LAYER_RESULT,
	"duplicate_layer": SCHEMA_LAYER_RESULT,
	"delete_layer": {
		"type": "object",
		"properties": {"layer": {"type": "integer"}, "layers": {"type": "integer"}},
	},
	"rename_layer": SCHEMA_LAYER_RESULT,
	"set_layer_visible": SCHEMA_LAYER_RESULT,
	"set_layer_locked": SCHEMA_LAYER_RESULT,
	"move_layer": {
		"type": "object",
		"properties": {
			"layer": {"type": "integer"},
			"layers": {"type": "integer"},
			"name": {"type": "string"},
			"visible": {"type": "boolean"},
			"locked": {"type": "boolean"},
			"filled": {"type": "integer"},
			"active": {"type": "boolean"},
			"order": {"type": "array", "items": {"type": "string"}},
		},
	},
	"merge_layer_down": SCHEMA_LAYER_RESULT,
	"move_selection_to_layer": {
		"type": "object",
		"properties": {
			"layer": {"type": "integer"},
			"target": {"type": "integer"},
			"name": {"type": "string"},
			"moved": {"type": "integer"},
		},
	},
	"set_document_settings": {
		"type": "object",
		"properties": {
			"size": {"type": "array", "items": {"type": "integer"}},
			"smooth_normals": {"type": "boolean"},
			"ao": {"type": "number"},
			"revision": {"type": "integer"},
		},
	},
	"set_tool": {
		"type": "object",
		"properties": {"tool": {"type": "string"}, "params": {"type": "object"}},
	},
	"set_material": {
		"type": "object",
		"properties": {"material": SCHEMA_MATERIAL},
	},
	"set_palette": {
		"type": "object",
		"properties": {
			"palette": {
				"type": "array",
				"items": {
					"type": "object",
					"properties": {
						"index": {"type": "integer"},
						"material": SCHEMA_MATERIAL,
					},
				},
			},
			"count": {"type": "integer"},
			"revision": {"type": "integer"},
		},
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
	"build_shape": {
		"type": "object",
		"properties": {
			"applied": {"type": "integer"},
			"bounds": SCHEMA_BOUNDS,
			"changed_bounds": SCHEMA_BOUNDS,
			"chunks": {"type": "integer"},
			"revision": {"type": "integer"},
			"warnings": {"type": "array", "items": {"type": "string"}},
			"action": {"type": "string"},
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
	"set_selection": {
		"type": "object",
		"properties": {
			"revision": {"type": "integer"},
			"count": {"type": "integer"},
			"bounds": SCHEMA_BOUNDS,
			"action": {"type": "string"},
		},
	},
}

const INSTRUCTIONS_BODY := "LVE is a voxel editor. Cells are integers and Y is up. Boxes are inclusive. Read lve://guide first. It indexes the topic guides: setup, tools, read, workspace, write, export, animate, and reference. lve://document-format describes the .lve file. Start with get_state, then inspect_document. Paths are absolute. An edit stops playback, so set playing true in the last workspace call.\n\nTool index. A question mark marks an optional argument. Call these names directly. Do not search for them.\n"
