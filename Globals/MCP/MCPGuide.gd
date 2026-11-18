extends RefCounted

## The MCP guide resources.
##
## The Markdown files are the single source of truth. This class slices the MCP
## guide into a short index and topic resources, so a client reads only the
## section it needs. The files are included in the export.

## The guide index and the file format resource.
const GUIDE_URI := "lve://guide"
const FORMAT_URI := "lve://document-format"
const GUIDE_PATH := "res://docs/MCP.md"
const FORMAT_PATH := "res://docs/DOCUMENT_FORMAT.md"
## The topic slices of the guide. Each entry joins one or more `##` sections
## from the guide file, so the file stays the single source of truth.
const GUIDE_GROUPS := [
	{
		"slug": "setup",
		"title": "Setup and connection",
		"description": "Start the server, connect a client, protocol revision, and result shapes.",
		"headings": ["Start the server", "Connect opencode", "Result shapes", "Protocol"],
	},
	{
		"slug": "tools",
		"title": "Tools",
		"description": "The tool table and what each call does.",
		"headings": ["Tools"],
	},
	{
		"slug": "read",
		"title": "Reading a document",
		"description": "State, inspection, slices, maps, changes, and cells.",
		"headings": ["Read a document"],
	},
	{
		"slug": "workspace",
		"title": "Workspace",
		"description": "Camera, lighting, view, export, and playback with get_workspace and set_workspace.",
		"headings": ["Workspace"],
	},
	{
		"slug": "write",
		"title": "Writing and editing",
		"description": "write_cells, materials, palette, selection, screenshots, and saving.",
		"headings": ["Compact forms"],
	},
	{
		"slug": "export",
		"title": "Export",
		"description": "Model, sprite sheet with optional normal and specular sheets, and GIF export.",
		"headings": ["Export"],
	},
	{
		"slug": "animate",
		"title": "Editing and animation",
		"description": "Editing rules and the animation workflow.",
		"headings": ["Editing rules", "Animate"],
	},
	{
		"slug": "reference",
		"title": "Reference",
		"description": "Limits, bridge mode, security, and tests.",
		"headings": ["Limits", "Bridge mode", "Security", "Tests"],
	},
]

static var _text_cache := ""
static var _sections_cache := {}


## Returns the published resources: the short guide index, one resource per
## topic, and the file format.
static func resources() -> Array:
	var entries: Array = [
		{
			"uri": GUIDE_URI,
			"name": "mcp-guide",
			"title": "LVE MCP guide",
			"description": "Start here: a short index of the topic guides.",
			"mimeType": "text/markdown",
			"size": _size(index_text()),
		},
	]
	for value in GUIDE_GROUPS:
		var group: Dictionary = value
		var slug := str(group.get("slug", ""))
		entries.append({
			"uri": GUIDE_URI + "/" + slug,
			"name": "mcp-guide-" + slug,
			"title": str(group.get("title", slug)),
			"description": str(group.get("description", "")),
			"mimeType": "text/markdown",
			"size": _size(group_text(slug)),
		})
	entries.append({
		"uri": FORMAT_URI,
		"name": "document-format",
		"title": "LVE document format",
		"description": "The .lve file format, workspace keys, and limits.",
		"mimeType": "text/markdown",
		"size": _size(_read_text(FORMAT_PATH)),
	})
	return entries


## Returns the text of one resource, or an empty string for an unknown URI.
static func read(uri: String) -> String:
	if uri == GUIDE_URI:
		return index_text()
	if uri == FORMAT_URI:
		return _read_text(FORMAT_PATH)
	if uri.begins_with(GUIDE_URI + "/"):
		return group_text(uri.trim_prefix(GUIDE_URI + "/"))
	return ""


## Returns the short index resource. The intro comes from the guide file, so
## the index does not repeat a second copy of the guide.
static func index_text() -> String:
	var text := _guide_text()
	if text.is_empty():
		return ""
	var intro := text.split("\n## ")[0].strip_edges()
	var lines: PackedStringArray = [intro, "", "## Topic guides", ""]
	for value in GUIDE_GROUPS:
		var group: Dictionary = value
		var slug := str(group.get("slug", ""))
		lines.append("- `%s/%s` — %s: %s" % [GUIDE_URI, slug, str(group.get("title", slug)), str(group.get("description", ""))])
	lines.append("- `%s` — The .lve file format, workspace keys, and limits." % FORMAT_URI)
	lines.append("")
	lines.append("Read a topic with `resources/read` and its URI.")
	return "\n".join(lines)


## Returns the joined text of one topic group, or an empty string for an
## unknown slug.
static func group_text(slug: String) -> String:
	var sections := _guide_sections()
	for value in GUIDE_GROUPS:
		var group: Dictionary = value
		if str(group.get("slug", "")) != slug:
			continue
		var parts: PackedStringArray = []
		var headings: Array = group.get("headings", [])
		for heading in headings:
			var key := str(heading)
			if sections.has(key):
				parts.append(str(sections[key]).strip_edges())
		return "\n\n".join(parts)
	return ""


static func _guide_text() -> String:
	if _text_cache.is_empty():
		_text_cache = _read_text(GUIDE_PATH)
	return _text_cache


## Parses the guide into a heading -> section map. A section runs from its `##`
## heading to the next `##` heading.
static func _guide_sections() -> Dictionary:
	if not _sections_cache.is_empty():
		return _sections_cache
	var text := _guide_text()
	var sections := {}
	var current := ""
	for line in text.split("\n"):
		if line.begins_with("## "):
			current = line.substr(3).strip_edges()
			sections[current] = line + "\n"
		elif not current.is_empty():
			sections[current] += line + "\n"
	_sections_cache = sections
	return sections


## Reads one packed text file. Returns an empty string when the file is missing.
static func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


static func _size(text: String) -> int:
	return text.to_utf8_buffer().size()
