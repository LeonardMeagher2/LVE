extends Node

## The per-document editor workspace state.
##
## The tool settings resources are shared by every consumer. This node snapshots
## their exported scalar values into the active document, then applies the saved
## values when a document becomes active. It also owns the active tool, the
## active material, and the editing aids. See `docs/DOCUMENT_FORMAT.md`.

# The accepted range of each exported enum. A value outside its range is ignored,
# so a damaged document cannot select an unknown tool.
const ENUM_RANGES := {
	"BrushPlugin": {"mode": Vector2i(0, 2), "shape": Vector2i(0, 2)},
	"PaintPlugin": {"tool": Vector2i(0, 2), "shape": Vector2i(0, 2)},
	"SelectionPlugin": {"tool": Vector2i(0, 2), "mode": Vector2i(0, 2)},
	"TransformPlugin": {"tool": Vector2i(0, 2)},
	"DeformPlugin": {"tool": Vector2i(0, 1)},
	"TerrainPlugin": {"tool": Vector2i(0, 2), "build_mode": Vector2i(0, 1)},
}

## The registered toolbar buttons, keyed by plugin and toolbar name.
var _tool_buttons: Dictionary[String, BaseButton] = {}
## The registered settings resources, keyed by plugin name.
var _settings_resources: Dictionary[String, Resource] = {}
# The document that owns the captured values. It is the previous document while
# an adoption runs, so a live write cannot hit the replacement.
var _state_document: VoxelDocument
var _applying := false
# A plugin registers during its own _ready. Activating its toolbar there can
# reach a tool node that the plugin has not created yet, so the press waits one
# idle frame.
var _pending_active_tool := ""
var _pending_apply_scheduled := false


func _ready() -> void:
	_state_document = State.document
	State.document_deactivating.connect(_save_current)
	State.document_changed.connect(_restore_document)
	State.material_changed.connect(_on_material_changed)
	State.symmetry_changed.connect(_on_editing_changed)
	State.floor_plane_changed.connect(_on_editing_changed)
	State.slice_changed.connect(_on_editing_changed)


func _exit_tree() -> void:
	if State.document_deactivating.is_connected(_save_current):
		State.document_deactivating.disconnect(_save_current)
	if State.document_changed.is_connected(_restore_document):
		State.document_changed.disconnect(_restore_document)
	if State.material_changed.is_connected(_on_material_changed):
		State.material_changed.disconnect(_on_material_changed)
	if State.symmetry_changed.is_connected(_on_editing_changed):
		State.symmetry_changed.disconnect(_on_editing_changed)
	if State.floor_plane_changed.is_connected(_on_editing_changed):
		State.floor_plane_changed.disconnect(_on_editing_changed)
	if State.slice_changed.is_connected(_on_editing_changed):
		State.slice_changed.disconnect(_on_editing_changed)
	for plugin in _settings_resources:
		var settings: Resource = _settings_resources[plugin]
		var callback := _on_settings_changed.bind(plugin)
		if settings != null and settings.changed.is_connected(callback):
			settings.changed.disconnect(callback)
	for id in _tool_buttons:
		var button: BaseButton = _tool_buttons[id]
		var toggle_callback := _on_tool_toggled.bind(id)
		if is_instance_valid(button) and button.toggled.is_connected(toggle_callback):
			button.toggled.disconnect(toggle_callback)


## Registers one plugin toolbar and its optional settings resource. The id is
## `PluginName/ToolbarName`.
func register_tool(id: String, button: BaseButton, settings: Resource) -> void:
	if _tool_buttons.get(id) != button:
		_tool_buttons[id] = button
		button.toggled.connect(_on_tool_toggled.bind(id))
	_prune()
	var plugin := id.get_slice("/", 0)
	if settings != null and _settings_resources.get(plugin) != settings:
		var previous: Resource = _settings_resources.get(plugin)
		if previous != null:
			var old_callback := _on_settings_changed.bind(plugin)
			if previous.changed.is_connected(old_callback):
				previous.changed.disconnect(old_callback)
		_settings_resources[plugin] = settings
		settings.changed.connect(_on_settings_changed.bind(plugin))
	# A plugin can register after a document with saved state is active.
	if _state_document != null:
		var saved: Variant = _state_document.tool_settings.get(plugin)
		if saved is Dictionary:
			_applying = true
			_apply_resource(plugin, saved)
			_applying = false
		if String(_state_document.tool_settings.get("active", "")) == id and not button.button_pressed:
			_pending_active_tool = id
			if not _pending_apply_scheduled:
				_pending_apply_scheduled = true
				_apply_pending_tool.call_deferred()


func _prune() -> void:
	for id in _tool_buttons.keys():
		if not is_instance_valid(_tool_buttons[id]):
			_tool_buttons.erase(id)


func _on_settings_changed(plugin: String) -> void:
	if _applying or not _can_save():
		return
	var settings: Resource = _settings_resources.get(plugin)
	if settings != null:
		_save_key(plugin, _capture_resource(settings))


func _on_tool_toggled(pressed: bool, _id: String) -> void:
	if not pressed or _applying or not _can_save():
		return
	_save_key("active", _active_tool_id())


func _on_material_changed() -> void:
	if _applying or not _can_save():
		return
	_save_key("material", State.current_material)


func _on_editing_changed() -> void:
	if _applying or not _can_save():
		return
	_save_key("editing", _capture_editing())


func _can_save() -> bool:
	return _state_document != null and State.document == _state_document


# Writes one top-level tool key and keeps the others. Unknown keys from another
# build stay in the document.
func _save_key(key: String, value: Variant) -> void:
	if not _can_save():
		return
	var data: Dictionary = _state_document.tool_settings.duplicate()
	data[key] = value
	_state_document.tool_settings = data


func _save_current() -> void:
	if _state_document == null:
		return
	var data: Dictionary = _state_document.tool_settings.duplicate()
	for plugin in _settings_resources:
		data[plugin] = _capture_resource(_settings_resources[plugin])
	data["active"] = _active_tool_id()
	data["material"] = State.current_material
	data["editing"] = _capture_editing()
	_state_document.tool_settings = data


func _restore_document() -> void:
	_state_document = State.document
	_pending_active_tool = ""
	if _state_document == null:
		return
	var data: Dictionary = _state_document.tool_settings
	if data.is_empty():
		return
	_applying = true
	if data.has("editing"):
		_apply_editing(data["editing"])
	for plugin in _settings_resources:
		if data.has(plugin):
			_apply_resource(plugin, data[plugin])
	var material: Variant = data.get("material")
	if material is PackedFloat32Array:
		State.apply_workspace_material(material)
	var active := String(data.get("active", ""))
	_applying = false
	_apply_active_tool(active)


func _apply_pending_tool() -> void:
	_pending_apply_scheduled = false
	var id := _pending_active_tool
	_pending_active_tool = ""
	_apply_active_tool(id)


func _apply_active_tool(id: String) -> void:
	if id.is_empty():
		return
	var button: BaseButton = _tool_buttons.get(id)
	if button == null or not is_instance_valid(button) or button.button_pressed:
		return
	_applying = true
	button.button_pressed = true
	_applying = false


func _active_tool_id() -> String:
	for id in _tool_buttons:
		var button: BaseButton = _tool_buttons[id]
		if is_instance_valid(button) and button.button_pressed:
			return id
	return ""


func _capture_resource(settings: Resource) -> Dictionary:
	var values := {}
	for property in settings.get_property_list():
		var usage: int = property.usage
		if not (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) or not (usage & PROPERTY_USAGE_STORAGE):
			continue
		var value: Variant = settings.get(property.name)
		if value is bool or value is int or value is float:
			if value is float and not is_finite(value):
				continue
			values[String(property.name)] = value
	return values


func _apply_resource(plugin: String, data: Variant) -> void:
	var settings: Resource = _settings_resources.get(plugin)
	if settings == null or not data is Dictionary:
		return
	var ranges: Dictionary = ENUM_RANGES.get(plugin, {})
	for property in settings.get_property_list():
		var usage: int = property.usage
		if not (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) or not (usage & PROPERTY_USAGE_STORAGE):
			continue
		var name := String(property.name)
		if not data.has(name):
			continue
		var stored: Variant = data[name]
		var current: Variant = settings.get(property.name)
		if not _value_matches(current, stored):
			continue
		var allowed: Variant = ranges.get(name)
		if allowed is Vector2i:
			var bounds: Vector2i = allowed
			if stored < bounds.x or stored > bounds.y:
				continue
		if current is float and stored is int:
			stored = float(stored)
		settings.set(property.name, stored)
	if settings is StampToolSettings:
		var stamp: StampToolSettings = settings
		if stamp.shape == StampToolSettings.BrushShape.SELECTION and stamp.selection_pattern.is_empty():
			stamp.shape = StampToolSettings.BrushShape.CUBE
			# Keep a later save honest about the fallback.
			if _state_document != null:
				var fallback: Dictionary = _state_document.tool_settings.duplicate()
				var entry: Variant = fallback.get(plugin)
				if entry is Dictionary:
					entry["shape"] = int(StampToolSettings.BrushShape.CUBE)
					fallback[plugin] = entry
					_state_document.tool_settings = fallback


static func _value_matches(current: Variant, stored: Variant) -> bool:
	if current is bool:
		return stored is bool
	if current is int:
		return stored is int
	if current is float:
		return stored is float or stored is int
	return false


func _capture_editing() -> Dictionary:
	return {
		"symmetry_axes": State.symmetry_axes,
		"symmetry_origin": State.symmetry_origin,
		"floor_axis": int(State.floor_axis),
		"floor_index": State.floor_index,
		"slice_layers": State.slice_layers,
	}


func _apply_editing(data: Variant) -> void:
	if not data is Dictionary:
		return
	var axes: Variant = data.get("symmetry_axes")
	if axes is int:
		State.symmetry_axes = axes
	var origin: Variant = data.get("symmetry_origin")
	if origin is Vector3:
		State.symmetry_origin = origin
	var axis: Variant = data.get("floor_axis")
	if axis is int:
		match int(axis):
			0:
				State.floor_axis = Vector3.Axis.AXIS_X
			1:
				State.floor_axis = Vector3.Axis.AXIS_Y
			2:
				State.floor_axis = Vector3.Axis.AXIS_Z
	var floor_index: Variant = data.get("floor_index")
	if floor_index is int:
		State.floor_index = floor_index
	var layers: Variant = data.get("slice_layers")
	if layers is int:
		State.slice_layers = layers
